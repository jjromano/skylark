import AVFoundation
import Foundation
import Synchronization
import os

/// Microphone capture via `AVAudioEngine`. The render-thread tap converts to
/// 16 kHz mono Float32 and appends into a preallocated buffer — no allocation
/// per callback beyond the converter's own working buffer, no locks on the
/// audio thread (a lock-free `Atomic` write index is used instead).
///
/// `@unchecked Sendable`: the buffer is written only on the audio render thread
/// and read only in `stop()` after the tap is removed; engine lifecycle calls
/// (`prepare`/`start`/`stop`) are serialized by the owning orchestrator actor.
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000
    /// Hard cap: 120 s at 16 kHz.
    public static let maxSamples = Int(targetSampleRate * 120)

    private let engine = AVAudioEngine()

    // Preallocated capture storage (never reallocated on the audio path).
    private let storage: UnsafeMutableBufferPointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let overflowed = Atomic<Bool>(false)

    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?
    private var tapInstalled = false

    private let levelsContinuation: AsyncStream<Float>.Continuation
    public let levels: AsyncStream<Float>

    private let signposter = OSSignposter(subsystem: "com.jjromano.skylark", category: "audio")
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "audio")
    private var captureSignpostID: OSSignpostID?
    private var captureStart: ContinuousClock.Instant?

    public init() {
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: Self.maxSamples)
        storage.initialize(repeating: 0)
        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(4))
        levels = stream
        levelsContinuation = continuation
    }

    deinit {
        storage.deallocate()
        levelsContinuation.finish()
    }

    // MARK: - Lifecycle

    public func prepare() {
        // Allocate engine resources ahead of the first press. `prepare()` does
        // not open the mic, so it's safe headless; the real cold start is in
        // `start()`, which degrades gracefully if the engine can't run.
        configureConverterIfNeeded()
        engine.prepare()
    }

    public func start() throws {
        writeIndex.store(0, ordering: .relaxed)
        overflowed.store(false, ordering: .relaxed)
        try installTapAndStart()
        captureStart = .now
        let id = signposter.makeSignpostID()
        captureSignpostID = id
        signposter.emitEvent("capture.start", id: id)
    }

    public func stop() -> AudioClip {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }

        let count = min(writeIndex.load(ordering: .acquiring), Self.maxSamples)
        let samples = Array(UnsafeBufferPointer(start: storage.baseAddress, count: count))
        let duration = Double(count) / Self.targetSampleRate

        if let id = captureSignpostID {
            signposter.emitEvent("capture.stop", id: id)
            captureSignpostID = nil
        }
        if let start = captureStart {
            let wall = start.duration(to: .now)
            logger.debug("capture wall time: \(wall.seconds, privacy: .public)s, samples=\(count, privacy: .public)")
            captureStart = nil
        }
        if overflowed.load(ordering: .relaxed) {
            logger.notice("capture hit 120s cap; clip truncated")
        }

        writeIndex.store(0, ordering: .relaxed)
        return AudioClip(samples: samples, sampleRate: Self.targetSampleRate, duration: duration)
    }

    // MARK: - Engine wiring

    private func configureConverterIfNeeded() {
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Self.targetSampleRate,
                  channels: 1,
                  interleaved: false
              )
        else {
            return
        }
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outFormat)
            // Generous per-callback output buffer; reused across callbacks.
            outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_384)
        }
    }

    private func installTapAndStart() throws {
        configureConverterIfNeeded()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
        try engine.start()
    }

    /// Render-thread callback. Converts to 16 kHz mono, appends lock-free.
    private func handleTap(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let outputBuffer else { return }
        outputBuffer.frameLength = 0

        // The input block is typed `@Sendable`, but the converter invokes it
        // synchronously on this same thread. Box the (non-Sendable) buffer and
        // consumed flag to satisfy Sendable checking without extra copies.
        let feed = ConverterFeed(inputBuffer)
        var convError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if feed.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.consumed = true
            outStatus.pointee = .haveData
            return feed.buffer
        }
        guard status == .haveData || status == .inputRanDry,
              let channel = outputBuffer.floatChannelData?.pointee
        else {
            return
        }

        let frames = Int(outputBuffer.frameLength)
        guard frames > 0 else { return }

        // Reserve a contiguous slot in the preallocated storage, lock-free.
        let start = writeIndex.load(ordering: .relaxed)
        if start + frames > Self.maxSamples {
            overflowed.store(true, ordering: .relaxed)
            return
        }
        (storage.baseAddress! + start).update(from: channel, count: frames)
        writeIndex.store(start + frames, ordering: .releasing)

        // RMS for the HUD (cheap; ~10–20 Hz).
        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        levelsContinuation.yield(rms)
    }
}

/// Boxes the input buffer + consumed flag for the `@Sendable` converter block,
/// which actually runs synchronously on the audio thread.
private final class ConverterFeed: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
