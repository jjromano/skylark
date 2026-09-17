import Foundation
import os

enum FallbackTranscriberError: Error, Sendable {
    /// Neither engine produced text within the hard cap.
    case primaryTimedOut
}

/// Wraps a `primary` transcriber (cloud STT) with a local `fallback` (the active
/// local engine, normally Parakeet) so a slow or unreachable cloud never holds up
/// dictation (phase-3 spec §4).
///
/// Both engines start on the same clip at once. The cloud text wins if it lands
/// within `cloudDeadline`; past that, the local text is used the moment it is
/// ready, so a slow provider costs the deadline and nothing more (it used to cost
/// a 10 s wait PLUS a local decode). If the local engine fails, the cloud keeps
/// its chance up to `primaryTimeout`. Nothing leaves the machine that didn't
/// before: the local run is on-device, and a cloud win just discards it.
///
/// Why 2 s: cloud MAI answered in 0.3-1.5 s on almost every dictation in the
/// 2026-09-16 diagnostics, with outliers at 2.1, 2.2 and 3.4 s and one 10 s hang.
/// `warmUp()` warms BOTH so the local engine stays resident (PRD §6.2).
public struct FallbackTranscriber: Transcriber {
    public let id: TranscriberID

    private let primary: any Transcriber
    private let fallback: any Transcriber
    private let cloudDeadline: Duration
    private let primaryTimeout: Duration
    private let notice: @Sendable (String) -> Void

    /// The engine that ran the most recent `transcribe` (primary until a
    /// fallback actually happens). Boxed so this Sendable struct can update
    /// it from `transcribe`; read by the orchestrator for history rows.
    private let lastRun: LockedBox<TranscriberID>

    /// True provenance for history: primary's id until a run falls back.
    public var lastRunID: TranscriberID { lastRun.value }

    /// The most recent local decode. A cloud win abandons it, but a local engine
    /// does not stop on cancellation, and Parakeet is not safe to enter twice at
    /// once (it swaps shared decoder state across an await). The next local run
    /// waits for this one first; in practice it has finished long before.
    private let lastLocalRun = LockedBox<Task<Void, Never>?>(nil)

    private final class LockedBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        /// Replace the value with one built from the current value, atomically.
        func update(_ body: (Value) -> Value) -> Value {
            lock.withLock {
                stored = body(stored)
                return stored
            }
        }
    }

    public init(
        primary: any Transcriber,
        fallback: any Transcriber,
        cloudDeadline: Duration = .seconds(2),
        primaryTimeout: Duration = .seconds(10),
        notice: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.cloudDeadline = cloudDeadline
        self.primaryTimeout = max(primaryTimeout, cloudDeadline)
        self.notice = notice
        // Report the primary's identity — that's the engine the user selected.
        self.id = primary.id
        self.lastRun = LockedBox(primary.id)
    }

    public func warmUp() async throws {
        // Warm both; neither failure should block the other. A cloud primary's
        // warmUp is a no-op, and the local fallback must stay resident.
        async let warmedPrimary: Void = Self.warmQuietly(primary)
        async let warmedFallback: Void = Self.warmQuietly(fallback)
        _ = await (warmedPrimary, warmedFallback)
    }

    private static func warmQuietly(_ transcriber: any Transcriber) async {
        try? await transcriber.warmUp()
    }

    private enum Event: Sendable {
        case cloud(Result<String, any Error>)
        case local(Result<String, any Error>)
        case deadline
        case hardCap
    }

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        let primary = primary
        let cloudDeadline = cloudDeadline, primaryTimeout = primaryTimeout
        // Unstructured tasks feeding one stream, NOT a task group: a group waits
        // for every child before returning, so a cloud win would still sit
        // behind a local decode that ignores cancellation.
        let (events, sink) = AsyncStream<Event>.makeStream()
        let tasks = [
            Task {
                do { sink.yield(.cloud(.success(try await primary.transcribe(clip, hint: hint)))) } catch { sink.yield(.cloud(.failure(error))) }
            },
            startLocal(clip: clip, hint: hint, sink: sink),
            Task {
                guard (try? await Task.sleep(for: cloudDeadline)) != nil else { return }
                sink.yield(.deadline)
            },
            Task {
                guard (try? await Task.sleep(for: primaryTimeout)) != nil else { return }
                sink.yield(.hardCap)
            },
        ]
        defer {
            for task in tasks { task.cancel() }
            sink.finish()
        }
        return try await withTaskCancellationHandler {
            try await decide(events, clip: clip)
        } onCancel: {
            for task in tasks { task.cancel() }
            sink.finish()
        }
    }

    /// Start the local decode behind any still-running earlier one (see
    /// `lastLocalRun`). The lock makes read-previous-and-record-new one step.
    private func startLocal(clip: AudioClip, hint: TranscriptionHint, sink: AsyncStream<Event>.Continuation) -> Task<Void, Never> {
        let fallback = fallback
        let run = lastLocalRun.update { previous in
            Task {
                await previous?.value
                // The cloud may have won while this waited: skip a decode nobody reads.
                guard !Task.isCancelled else { return }
                do { sink.yield(.local(.success(try await fallback.transcribe(clip, hint: hint)))) } catch { sink.yield(.local(.failure(error))) }
            }
        }
        // `update` always stores the task it just built.
        return run!
    }

    /// Pick the text from the engines' events as they arrive (see the type doc).
    private func decide(_ events: AsyncStream<Event>, clip: AudioClip) async throws -> String {
        var cloudError: (any Error)?
        var localText: String?
        var localError: (any Error)?
        var pastDeadline = false

        for await event in events {
            switch event {
            case .cloud(.success(let text)):
                lastRun.value = primary.id
                return text
            case .cloud(.failure(let error)):
                cloudError = error
                if let localText { return useLocal(localText, because: error, clip: clip) }
                if let localError { throw localError }
            case .local(.success(let text)):
                if let cloudError { return useLocal(text, because: cloudError, clip: clip) }
                if pastDeadline { return useLocal(text, because: FallbackTranscriberError.primaryTimedOut, clip: clip) }
                localText = text
            case .local(.failure(let error)):
                localError = error
                if let cloudError { throw cloudError }
            case .deadline:
                pastDeadline = true
                if let localText { return useLocal(localText, because: FallbackTranscriberError.primaryTimedOut, clip: clip) }
            case .hardCap:
                // The local engine failed and the cloud never answered.
                throw cloudError ?? localError ?? FallbackTranscriberError.primaryTimedOut
            }
        }
        // The stream only ends early when the caller cancelled.
        throw CancellationError()
    }

    private func useLocal(_ text: String, because error: any Error, clip: AudioClip) -> String {
        // Content-free: which engine gave up and why, so a diagnostics report
        // can tell a slow provider (timeout) from a rejected request.
        Self.logger.notice("stt fallback: \(primary.id.historyColumn, privacy: .public) failed (\(Self.reason(error), privacy: .public)) → \(fallback.id.historyColumn, privacy: .public), clip-ms: \(Int(clip.duration * 1000), privacy: .public)")
        let slow = (error as? FallbackTranscriberError) == .primaryTimedOut
        notice(slow ? "Cloud speech was slow — used the local engine" : "Cloud transcription unavailable — used the local engine")
        lastRun.value = fallback.id
        return text
    }

    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "pipeline")

    /// A log-safe failure reason. Never includes a server message body.
    static func reason(_ error: any Error) -> String {
        switch error {
        case FallbackTranscriberError.primaryTimedOut: return "timeout"
        case let error as OpenRouterError:
            switch error {
            case .noKey: return "no-key"
            case .invalidKey: return "invalid-key"
            case .rateLimited: return "rate-limited"
            case .timeout: return "network-timeout"
            case .network(let underlying): return "network \((underlying as NSError).domain) \((underlying as NSError).code)"
            case .server(let status, _): return "http \(status)"
            case .decoding: return "decoding"
            case .responseTruncated: return "truncated"
            }
        case let error as GroqError:
            switch error {
            case .noKey: return "no-key"
            case .timeout: return "network-timeout"
            case .http(let status, _): return "http \(status)"
            case .decoding: return "decoding"
            case .network: return "network"
            }
        default:
            return "\(type(of: error))"
        }
    }
}
