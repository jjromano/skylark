import Foundation
import os

/// The session state machine: `idle → recording → transcribing → injecting →
/// idle` (+ `cancelled`). Owns the only pipeline-state writes, wiring
/// AudioCapture → Transcriber → TextInjector and publishing `HUDState`
/// snapshots for the UI. A failed optional stage never blocks the paste.
public actor DictationOrchestrator {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        case transcribing
        case injecting
    }

    private let capture: any AudioCapturing
    private let transcriber: any Transcriber
    private let injector: any TextInjecting
    private let hint: TranscriptionHint

    public private(set) var phase: Phase = .idle

    private let hudContinuation: AsyncStream<HUDState>.Continuation
    /// HUD snapshots for the UI to observe.
    public nonisolated let hudStates: AsyncStream<HUDState>

    private var levelsTask: Task<Void, Never>?

    private let signposter = OSSignposter(subsystem: "com.jjromano.skylark", category: "pipeline")
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "pipeline")

    public init(
        capture: any AudioCapturing,
        transcriber: any Transcriber,
        injector: any TextInjecting,
        hint: TranscriptionHint = .none
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.injector = injector
        self.hint = hint
        let (stream, continuation) = AsyncStream<HUDState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        hudStates = stream
        hudContinuation = continuation
        continuation.yield(.idle)
    }

    /// Consume hotkey events until the stream ends.
    public func run(events: AsyncStream<HotkeyEvent>) async {
        for await event in events {
            await handle(event)
        }
    }

    /// Handle a single hotkey event. Public for unit tests.
    public func handle(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording:
            startRecording()
        case .stopRecording:
            await finishRecording()
        case .cancel, .discard:
            cancelRecording()
        }
    }

    // MARK: - Transitions

    private func startRecording() {
        guard phase == .idle else { return }
        do {
            try capture.start()
        } catch {
            logger.error("capture.start failed: \(error.localizedDescription, privacy: .public)")
            publish(.idle)
            return
        }
        phase = .recording
        publish(.listening(level: 0))
        startLevelForwarding()
    }

    private func finishRecording() async {
        guard phase == .recording else { return }
        stopLevelForwarding()

        // Fn-up → text-inserted is THE latency metric.
        let interval = signposter.beginInterval("fnup_to_inserted")
        defer { signposter.endInterval("fnup_to_inserted", interval) }

        let clip = capture.stop()
        phase = .transcribing
        publish(.processing)

        guard !clip.isEmpty else {
            phase = .idle
            publish(.idle)
            return
        }

        let text: String
        do {
            text = try await transcriber.transcribe(clip, hint: hint)
        } catch {
            logger.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            publish(.idle)
            return
        }

        phase = .injecting
        do {
            _ = try await injector.insert(text)
        } catch {
            // An injection failure must not wedge the state machine.
            logger.error("injection failed: \(error.localizedDescription, privacy: .public)")
        }

        phase = .idle
        publish(.idle)
    }

    private func cancelRecording() {
        guard phase == .recording else { return }
        stopLevelForwarding()
        _ = capture.stop() // discard audio
        phase = .idle
        publish(.idle)
    }

    // MARK: - Levels

    private func startLevelForwarding() {
        levelsTask?.cancel()
        levelsTask = Task { [capture, weak self] in
            for await level in capture.levels {
                if Task.isCancelled { break }
                await self?.forwardLevel(level)
            }
        }
    }

    private func stopLevelForwarding() {
        levelsTask?.cancel()
        levelsTask = nil
    }

    private func forwardLevel(_ level: Float) {
        guard phase == .recording else { return }
        publish(.listening(level: level))
    }

    private func publish(_ state: HUDState) {
        hudContinuation.yield(state)
    }
}
