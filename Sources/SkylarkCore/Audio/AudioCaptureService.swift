import Accelerate
import AVFoundation
import CoreAudio
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

    // Raw-frame delivery for hands-free VAD. Gated by `framesWanted` so the
    // push-to-talk path never allocates a per-callback array copy.
    private let framesContinuation: AsyncStream<[Float]>.Continuation
    public let frames: AsyncStream<[Float]>
    private let framesWanted = Atomic<Bool>(false)

    // Separate raw-frame delivery for the optional live transcription preview.
    // Kept distinct from `frames` (a single-consumer stream owned by the VAD
    // path) so preview and hands-free never contend for the same iterator.
    // Gated by `previewWanted`; off = no per-callback allocation.
    private let previewFramesContinuation: AsyncStream<[Float]>.Continuation
    public let previewFrames: AsyncStream<[Float]>
    private let previewWanted = Atomic<Bool>(false)

    // Whisper-mode capture gain, stored as Float bit-pattern for lock-free reads
    // on the audio thread (Float isn't AtomicRepresentable). 1.0 = unity.
    private let gainBits = Atomic<UInt32>(Float(1.0).bitPattern)

    // Preferred input-device UID (nil = system default). Read off the audio path
    // in `start()`; guarded by the orchestrator's serialization of lifecycle.
    private let uidLock = Mutex<String?>(nil)

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
        let (frameStream, frameCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        frames = frameStream
        framesContinuation = frameCont
        let (previewStream, previewCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        previewFrames = previewStream
        previewFramesContinuation = previewCont
    }

    deinit {
        storage.deallocate()
        levelsContinuation.finish()
        framesContinuation.finish()
        previewFramesContinuation.finish()
    }

    public func setFramesWanted(_ wanted: Bool) {
        framesWanted.store(wanted, ordering: .relaxed)
    }

    public func setPreviewWanted(_ wanted: Bool) {
        previewWanted.store(wanted, ordering: .relaxed)
    }

    /// Set the whisper-mode capture gain (linear multiplier). Applied in the tap,
    /// vectorized and clamped to [-1, 1]. Lock-free; safe to call any time.
    public func setGain(_ gain: Float) {
        gainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Choose the input device by CoreAudio UID (nil = system default). Applied
    /// at the next `start()`; a missing/unplugged UID falls back to the default.
    public func setPreferredDeviceUID(_ uid: String?) {
        uidLock.withLock { $0 = uid }
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
            let wall = start.duration(to: .now).seconds
            // Divergence guard: the sample-derived duration should track wall time.
            // If far fewer samples arrived than the hold lasted, the input tap
            // stalled mid-capture (mic seized by another app, coreaudiod hiccup) —
            // surface it (content-free) so the diagnostics export can show it.
            if wall > 1.0, duration < wall * 0.6 {
                logger.notice("capture sample duration \(duration, format: .fixed(precision: 2), privacy: .public)s ≪ wall \(wall, format: .fixed(precision: 2), privacy: .public)s — input tap likely stalled (possible mic interruption)")
            } else {
                logger.debug("capture wall time: \(wall, privacy: .public)s, samples=\(count, privacy: .public)")
            }
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
        // Re-apply the preferred input device at every start so a device that
        // appeared/vanished between dictations is honoured (or falls back safely).
        applyPreferredDevice()
        configureConverterIfNeeded()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
        try engine.start()
    }

    /// Set the engine's input hardware device from the preferred UID, if any and
    /// still present. Must run while the engine is stopped (before `start`). A
    /// missing UID or resolution failure leaves the system default in place.
    private func applyPreferredDevice() {
        guard let uid = uidLock.withLock({ $0 }), !uid.isEmpty else { return }
        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else {
            logger.notice("preferred input device not found; using system default")
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.notice("failed to set input device (osstatus \(status, privacy: .public)); using default")
        }
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

        // Whisper-mode gain: vectorized in-place multiply + clamp on the converted
        // samples before they're stored or RMS'd. Allocation-free; unity when off.
        let gain = Float(bitPattern: gainBits.load(ordering: .relaxed))
        WhisperModeTuning.applyGain(channel, count: frames, gain: gain)

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

        // Deliver a copy of the converted frames to whichever raw-frame
        // consumers are active (hands-free VAD and/or live preview). Both gates
        // off = push-to-talk with no preview → the zero-allocation path (no Array
        // built at all). When either is on, allocate the copy ONCE and hand the
        // same value to both streams: it's copy-on-write and both consumers only
        // read it, so a single buffer is safe (was two identical allocations).
        let wantFrames = framesWanted.load(ordering: .relaxed)
        let wantPreview = previewWanted.load(ordering: .relaxed)
        if wantFrames || wantPreview {
            let copy = Array(UnsafeBufferPointer(start: channel, count: frames))
            if wantFrames { framesContinuation.yield(copy) }
            if wantPreview { previewFramesContinuation.yield(copy) }
        }
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
