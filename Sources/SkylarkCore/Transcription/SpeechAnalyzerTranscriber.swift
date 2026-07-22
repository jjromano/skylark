import AVFoundation
import Foundation
import Speech
import os

/// Local Apple Speech engine — macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`
/// (the third fully on-device ASR alongside Parakeet and WhisperKit). Batch path
/// only: the whole clip is converted to the analyzer's preferred format and fed
/// as a one-shot `AsyncSequence<AnalyzerInput>`, then finalized. Output carries
/// Apple's native punctuation + capitalization (no cleanup stage required for
/// basic formatting).
///
/// Residency (deviation from Parakeet/WhisperKit, reported to the orchestrator):
/// a `SpeechAnalyzer` is single-use — `finalizeAndFinish(through:)` *finishes*
/// the actor and ends the transcriber's `results` stream, so the analyzer +
/// transcriber pair is recreated per utterance. The expensive part (the on-device
/// model) is kept resident by the OS via `Options.modelRetention = .processLifetime`,
/// a reserved locale, and a one-time `prepareToAnalyze` preheat in `warmUp()`.
/// Assets are system-wide and OS-managed (`AssetInventory`); the OS may evict
/// them under disk pressure, so a missing asset is a runtime state handled by
/// re-checking on `warmUp`, never a crash.
///
/// Adapted (ideas only) from Yap (finnvoor/Yap, CC0) — the `SpeechTranscriber`
/// setup and locale/asset flow. No code copied.
public actor SpeechAnalyzerTranscriber: Transcriber {
    public nonisolated let id: TranscriberID = .speechAnalyzer

    /// Same short/quiet-clip floor as the other local engines (uniform latency +
    /// privacy behaviour: a borderline clip returns "" without touching the model).
    public static let minClipDuration: TimeInterval = 0.3
    static let silenceFloor: Float = 1e-4

    private let desiredLocale: Locale
    private let progress: @Sendable (ModelPreparationState) -> Void

    /// Resolved supported locale (set during `warmUp`).
    private var resolvedLocale: Locale?
    /// The analyzer's preferred input format (what `AnalyzerInput` buffers use),
    /// resolved once in `warmUp` and reused to build converters.
    private var analyzerFormat: AVAudioFormat?
    private var preparing: Task<Void, Error>?
    private var silenceFloor: Float = SpeechAnalyzerTranscriber.silenceFloor

    public private(set) var isReady = false

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "asr")

    /// - Parameters:
    ///   - locale: desired dictation locale (default: system, falling back to en-US).
    ///   - progress: preparation-state callback (menu-bar / HUD). No-op default
    ///     for headless use (bench, tests).
    public init(
        locale: Locale = Locale(identifier: "en-US"),
        progress: @escaping @Sendable (ModelPreparationState) -> Void = { _ in }
    ) {
        self.desiredLocale = locale
        self.progress = progress
    }

    // MARK: - Lifecycle

    /// Ensure the on-device asset for the locale is installed (kicking a download
    /// with progress reported through `ModelPreparationState`) and preheat the
    /// model. Idempotent; concurrent calls share one preparation task.
    public func warmUp() async throws {
        if isReady { return }
        if let preparing {
            try await preparing.value
            return
        }
        let task = Task { try await self.prepare() }
        preparing = task
        do {
            try await task.value
            preparing = nil
        } catch {
            preparing = nil
            progress(.failed(message: error.localizedDescription))
            throw error
        }
    }

    private func prepare() async throws {
        progress(.checking)

        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerError.notAvailable
        }

        // Resolve the locale against what the OS supports (pure helper, tested).
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = Self.resolveLocale(desired: desiredLocale, supported: supported) else {
            throw SpeechAnalyzerError.unsupportedLocale(desiredLocale.identifier)
        }
        resolvedLocale = locale

        // Reserve the locale so the OS won't evict its asset out from under us.
        // Best-effort: a full reservation table (other apps) is not fatal.
        _ = try? await AssetInventory.reserve(locale: locale)

        let transcriber = Self.makeTranscriber(locale: locale)
        let modules: [any SpeechModule] = [transcriber]

        // Install the asset if the locale isn't already present. Report download
        // progress by polling the request's Progress (content-free, off any path).
        let installed = await SpeechTranscriber.installedLocales
        let alreadyInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if !alreadyInstalled {
            progress(.downloading(progress: 0))
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                let report = progress
                let reporter = Task {
                    while !Task.isCancelled {
                        report(.downloading(progress: request.progress.fractionCompleted))
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { reporter.cancel() }
                try await request.downloadAndInstall()
            }
        }

        progress(.loading)
        // Resolve the analyzer's preferred input format once (used to build the
        // per-utterance converter), then preheat the model. The throwaway analyzer
        // loads the model, which `.processLifetime` retention keeps resident so
        // subsequent per-utterance analyzers reuse it.
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        analyzerFormat = format
        let analyzer = SpeechAnalyzer(modules: modules, options: Self.analyzerOptions)
        try await analyzer.prepareToAnalyze(in: format)

        isReady = true
        progress(.ready)
        logger.info("Apple Speech ready")
    }

    /// Whether the locale asset is installed on this system (system-managed).
    /// Cheap; used by the settings model manager to show install state.
    public func isAssetInstalled() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = Self.resolveLocale(desired: desiredLocale, supported: supported) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// The resolved BCP-47 locale identifier shown in the settings row (e.g. "en-US").
    public func localeIdentifier() async -> String {
        if let resolvedLocale { return resolvedLocale.identifier(.bcp47) }
        return desiredLocale.identifier(.bcp47)
    }

    /// Release the reserved locale (only on quit / engine switch). Assets are
    /// system-managed; we don't delete them, just drop our reservation.
    public func shutdown() async {
        if let resolvedLocale {
            _ = await AssetInventory.release(reservedLocale: resolvedLocale)
        }
        isReady = false
    }

    /// Whisper-mode tuning (silence floor for the skip guard). Next `transcribe`.
    public func setSilenceFloor(_ floor: Float) {
        silenceFloor = floor
    }

    // MARK: - Transcription

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        // Guard first — a too-short/silent clip returns "" without touching the
        // model (privacy + latency: never throw for that).
        if ClipGuard.shouldSkip(clip, minDuration: Self.minClipDuration, silenceFloor: silenceFloor) {
            return ""
        }

        guard isReady, let locale = resolvedLocale else {
            throw SpeechAnalyzerError.notReady
        }

        // Fresh transcriber + analyzer per utterance (the analyzer is single-use;
        // see the type doc). Model stays warm via `.processLifetime` retention.
        let transcriber = Self.makeTranscriber(locale: locale)
        let modules: [any SpeechModule] = [transcriber]
        // Prefer the format resolved at warmUp; re-resolve if the OS changed it.
        let format: AVAudioFormat
        if let cached = analyzerFormat {
            format = cached
        } else if let resolved = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) {
            format = resolved
        } else {
            throw SpeechAnalyzerError.converterUnavailable
        }
        let buffer = try Self.makeInputBuffer(from: clip, to: format)

        let analyzer = SpeechAnalyzer(modules: modules, options: Self.analyzerOptions)

        // Collect finalized results concurrently — the stream ends when the
        // analyzer finishes (below). `results` is `Sendable`, so this crosses to
        // a child task cleanly while the transcriber stays actor-isolated.
        let results = transcriber.results
        let collector = Task { () throws -> String in
            var accumulated = AttributedString()
            for try await result in results {
                accumulated += result.text
            }
            return String(accumulated.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // One-shot input sequence: the whole clip in a single buffer.
        let input = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
        }

        do {
            // Feed the sequence, then finalize — the input stream ending alone
            // does NOT finish the analyzer; `finalizeAndFinish` is required.
            let lastTime = try await analyzer.analyzeSequence(input)
            if let lastTime {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            collector.cancel()
            throw error
        }

        return try await collector.value
    }

    // MARK: - Helpers (pure where possible, unit-tested)

    private static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Native punctuation/capitalization with no extra reporting/attributes —
        // finalized results only (batch path).
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// Pick the OS-supported locale best matching `desired`: exact BCP-47 first,
    /// then a language-code match (e.g. desired "en" → supported "en-US"), else
    /// nil. Pure — unit-tested without live recognition.
    static func resolveLocale(desired: Locale, supported: [Locale]) -> Locale? {
        let wantBCP47 = desired.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == wantBCP47 }) {
            return exact
        }
        let wantLang = desired.language.languageCode?.identifier
        if let wantLang,
           let byLanguage = supported.first(where: { $0.language.languageCode?.identifier == wantLang }) {
            return byLanguage
        }
        return nil
    }

    /// Convert a 16 kHz mono Float32 clip into an `AVAudioPCMBuffer` in the
    /// analyzer's preferred `format` (hand-rolled AVAudioConverter — no SDK
    /// converter helper exists for this). Pure — unit-tested with a synthetic sine.
    static func makeInputBuffer(from clip: AudioClip, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = makeSourceBuffer(samples: clip.samples, sampleRate: clip.sampleRate) else {
            throw SpeechAnalyzerError.bufferAllocationFailed
        }
        // Same format? Feed straight through (avoids a needless conversion copy).
        if source.format.isEqual(format) {
            return source
        }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            throw SpeechAnalyzerError.converterUnavailable
        }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SpeechAnalyzerError.bufferAllocationFailed
        }
        let feed = ConverterFeed(source)
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if feed.fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.fed = true
            outStatus.pointee = .haveData
            return feed.buffer
        }
        if let convError { throw convError }
        guard status == .haveData || status == .inputRanDry else {
            throw SpeechAnalyzerError.conversionFailed
        }
        return output
    }

    /// Build a 16 kHz mono Float32 source buffer from raw samples.
    static func makeSourceBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    /// Boxes the converter's input buffer + "already fed" flag for the `@Sendable`
    /// input block, which AVAudioConverter invokes synchronously on the calling
    /// thread (same pattern as `AudioCaptureService.ConverterFeed`).
    private final class ConverterFeed: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var fed = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}

public enum SpeechAnalyzerError: Error, Sendable {
    /// `SpeechTranscriber` reports it isn't available on this system.
    case notAvailable
    /// No OS-supported locale matches the requested one.
    case unsupportedLocale(String)
    /// `transcribe` was called before `warmUp()` completed (or the asset was evicted).
    case notReady
    case bufferAllocationFailed
    case converterUnavailable
    case conversionFailed
}
