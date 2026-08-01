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
/// Nothing is PUBLISHED from the render thread either (audit U9): HUD levels,
/// raw VAD/preview frames and the cap boundary all leave via a 20 Hz timer on
/// `levelQueue`, which reads the same lock-free atomics and the already-written
/// samples. The tap's whole job is convert → copy → two relaxed atomic stores.
///
/// `@unchecked Sendable`: the buffer is written only on the audio render thread
/// and read only in `stop()` after the tap is removed; engine lifecycle calls
/// (`prepare`/`start`/`stop`) are serialized by the owning orchestrator actor
/// and, since the configuration-change observer can also drive them from an
/// arbitrary thread, by `lifecycle` (never taken on the audio thread).
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000
    /// Hard cap on one recording. Kept deliberately (a 2-minute utterance is
    /// already far past what dictation is for, and the preallocated buffer is
    /// what keeps the audio path allocation-free) — but honest: reaching it
    /// FINALIZES the session via `.capReached` rather than quietly dropping
    /// everything the user keeps saying.
    public static let maxDuration: TimeInterval = 120
    /// Hard cap: 120 s at 16 kHz.
    public static let maxSamples = Int(targetSampleRate * maxDuration)
    /// How long before the cap the HUD starts counting down (§ decision 4:
    /// "warn on the pill as it approaches").
    public static let capWarningLeadTime: TimeInterval = 20
    /// HUD level cadence. Levels are PUBLISHED from a timer on `levelQueue`, not
    /// from the render callback (see `handleTap`), so the audio thread never
    /// takes the stream's lock.
    private static let levelInterval: DispatchTimeInterval = .milliseconds(50)
    /// Ticks without a new tap callback after which the published level decays to
    /// zero (≈250 ms). Long enough that an 85 ms callback cadence never combs the
    /// waveform, short enough that a stalled tap visibly flatlines it.
    private static let levelStaleTicks = 5
    /// Cap on recorded RMS-trace entries (one per tap callback). Even a tiny
    /// 256-sample callback can only produce ~7.5 k entries in 120 s, so this is
    /// generous; an overflow simply stops extending the trace (the audio is
    /// unaffected, and the analyzer judges what it has).
    public static let maxTraceEntries = 30_000

    private let engine = AVAudioEngine()

    // Preallocated capture storage (never reallocated on the audio path).
    private let storage: UnsafeMutableBufferPointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let overflowed = Atomic<Bool>(false)

    // Preallocated RMS trace: the per-callback RMS already computed for the HUD,
    // plus how many samples each value covers. Two stores into preallocated
    // memory per callback — no allocation, no locks (see `handleTap`).
    private let traceValues: UnsafeMutableBufferPointer<Float>
    private let traceCounts: UnsafeMutableBufferPointer<Int>
    private let traceIndex = Atomic<Int>(0)

    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?
    private var tapInstalled = false
    /// Reused across callbacks: the `@Sendable` converter block needs a box for
    /// the (non-Sendable) input buffer, and allocating that class per callback
    /// was a malloc on the render thread (audit U9). One box, reset in place.
    /// Safe because `handleTap` is serialized by AVAudioEngine and the converter
    /// invokes the block synchronously on that same thread — the same reason
    /// `outputBuffer` is already shared.
    private let feed = ConverterFeed()

    /// Capture lifecycle shared between the orchestrator (start/stop) and the
    /// configuration-change observer (which fires on an arbitrary thread).
    /// Guarded by `lifecycle`; NEVER touched from the audio thread.
    private struct Lifecycle: Sendable {
        var recording = false
        /// First disruption seen during the current capture (the boundary).
        var interruption: CaptureInterruption?
    }
    private let lifecycle = Mutex(Lifecycle())
    private var configObserver: NSObjectProtocol?
    /// Configuration-change handling runs here, never on the posting thread: the
    /// notification can be delivered synchronously from inside an
    /// `AVAudioEngine` call we make while holding `lifecycle`, and re-entering a
    /// non-recursive Mutex would hang the app. Hopping to a serial queue makes
    /// re-entrancy impossible.
    private let configQueue = DispatchQueue(label: "com.jjromano.skylark.capture-config", qos: .userInitiated)

    private let interruptionsContinuation: AsyncStream<CaptureInterruption>.Continuation
    public let interruptions: AsyncStream<CaptureInterruption>

    private let levelsContinuation: AsyncStream<Float>.Continuation
    public let levels: AsyncStream<Float>

    // Latest RMS + a monotonic callback counter, written ONLY on the render
    // thread with relaxed stores (Float isn't AtomicRepresentable, so the level
    // travels as a bit pattern). The publisher timer below reads both and does
    // the actual `levels` yield off the audio thread.
    private let levelBits = Atomic<UInt32>(0)
    private let levelSeq = Atomic<UInt64>(0)
    private let levelQueue = DispatchQueue(label: "com.jjromano.skylark.capture-levels", qos: .userInitiated)
    /// Timer source driving `levels`. Created in `start()`, cancelled in
    /// `stop()`; both are serialized by the owning orchestrator actor.
    private var levelTimer: DispatchSourceTimer?
    /// Publisher-side state — touched ONLY on `levelQueue`.
    private var lastPublishedSeq: UInt64 = 0
    private var staleTicks = 0
    private var capSignalled = false

    // Raw-frame delivery for hands-free VAD and for the optional live preview.
    // Gated by `framesWanted` / `previewWanted` so an idle consumer costs
    // nothing. Frames are drained from the capture buffer by the publisher tick
    // (see `drainFrames`) — the audio thread never yields and never allocates.
    //
    // The continuations are REPLACED on every access to `frames` /
    // `previewFrames`; see those properties for why a stored stream can't work.
    private let framesSink = Mutex<AsyncStream<[Float]>.Continuation?>(nil)
    private let framesWanted = Atomic<Bool>(false)
    private let previewSink = Mutex<AsyncStream<[Float]>.Continuation?>(nil)
    private let previewWanted = Atomic<Bool>(false)
    /// How far the frame drain has read (publisher-side; `levelQueue` only).
    private var drainIndex = 0

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
        traceValues = UnsafeMutableBufferPointer<Float>.allocate(capacity: Self.maxTraceEntries)
        traceValues.initialize(repeating: 0)
        traceCounts = UnsafeMutableBufferPointer<Int>.allocate(capacity: Self.maxTraceEntries)
        traceCounts.initialize(repeating: 0)
        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(4))
        levels = stream
        levelsContinuation = continuation
        let (interruptionStream, interruptionCont) = AsyncStream<CaptureInterruption>
            .makeStream(bufferingPolicy: .bufferingNewest(4))
        interruptions = interruptionStream
        interruptionsContinuation = interruptionCont
        // Configuration-change observer, SCOPED TO THIS ENGINE (an app-wide
        // observer would also fire for unrelated engines). This is usually the
        // earliest sign another app grabbed the input or the route changed.
        // Adapted from Hex (MIT): SuperFastCaptureController's
        // restartPreservingRecording() pattern.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            configQueue.async { self.handleConfigurationChange() }
        }
    }

    deinit {
        levelTimer?.cancel()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        storage.deallocate()
        traceValues.deallocate()
        traceCounts.deallocate()
        levelsContinuation.finish()
        framesSink.withLock { $0 }?.finish()
        previewSink.withLock { $0 }?.finish()
        interruptionsContinuation.finish()
    }

    /// Raw 16 kHz frames for the hands-free VAD.
    ///
    /// EVERY ACCESS MINTS A NEW STREAM and retires the previous one. That is not
    /// a stylistic choice: an `AsyncStream` whose consuming task is CANCELLED is
    /// finished permanently (verified — a later `for await` over the same stream
    /// returns immediately), and hands-free is torn down by cancelling its VAD
    /// task on every stop that isn't the VAD's own. A stored stream therefore
    /// endpointed exactly once per launch and then silently never again — the
    /// P1-2a "hands-free never stops" report. Per-access streams contain the
    /// damage to the consumer that was cancelled.
    public var frames: AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(32))
        framesSink.withLock { sink in
            sink?.finish()
            sink = continuation
        }
        return stream
    }

    /// Raw 16 kHz frames for the live-preview prototype. Separate sink from
    /// `frames` so preview and hands-free never contend; same per-access rule.
    public var previewFrames: AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(32))
        previewSink.withLock { sink in
            sink?.finish()
            sink = continuation
        }
        return stream
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
        lifecycle.withLock { _ in
            configureConverterIfNeeded()
            engine.prepare()
        }
    }

    public func start() throws {
        writeIndex.store(0, ordering: .relaxed)
        overflowed.store(false, ordering: .relaxed)
        traceIndex.store(0, ordering: .relaxed)
        try lifecycle.withLock { state in
            state.interruption = nil
            // Throws with the tap already cleaned up (see `installTapAndStart`),
            // so a failed start leaves nothing installed for the NEXT start to
            // collide with (P1-8).
            try installTapAndStart()
            state.recording = true
        }
        startLevelPublisher()
        captureStart = .now
        let id = signposter.makeSignpostID()
        captureSignpostID = id
        signposter.emitEvent("capture.start", id: id)
    }

    public func stop() -> AudioClip {
        stopLevelPublisher()
        // Take the lock so a configuration-change restart can't be mid-flight
        // while we tear the engine down (and so `recording` flips atomically:
        // a change arriving after this is ignored).
        let interruption = lifecycle.withLock { state -> CaptureInterruption? in
            state.recording = false
            stopEngineLocked()
            let seen = state.interruption
            state.interruption = nil
            return seen
        }

        let count = min(writeIndex.load(ordering: .acquiring), Self.maxSamples)
        let samples = Array(UnsafeBufferPointer(start: storage.baseAddress, count: count))
        let duration = Double(count) / Self.targetSampleRate
        let trace = snapshotTrace()

        if let id = captureSignpostID {
            signposter.emitEvent("capture.stop", id: id)
            captureSignpostID = nil
        }
        var wallDuration: TimeInterval?
        if let start = captureStart {
            wallDuration = start.duration(to: .now).seconds
            captureStart = nil
        }
        let capReached = overflowed.load(ordering: .relaxed)
        if capReached {
            // The cap's OWN log line: a designed limit, not a fault. The
            // stalled-tap line below is suppressed for exactly this reason.
            logger.notice("""
                capture reached the \(Int(Self.maxDuration), privacy: .public)s limit — \
                finalized at the cap (samples pinned, wall \
                \(wallDuration ?? duration, format: .fixed(precision: 2), privacy: .public)s)
                """)
        }

        writeIndex.store(0, ordering: .relaxed)
        traceIndex.store(0, ordering: .relaxed)
        overflowed.store(false, ordering: .relaxed)
        let clip = AudioClip(
            samples: samples,
            sampleRate: Self.targetSampleRate,
            duration: duration,
            wallDuration: wallDuration,
            rms: trace,
            interruption: interruption,
            capReached: capReached
        )
        if let wallDuration {
            // Divergence guard: the sample-derived duration should track wall time.
            // If far fewer samples arrived than the hold lasted, the input tap
            // stalled mid-capture (mic seized by another app, coreaudiod hiccup) —
            // surface it (content-free). The orchestrator reads the same
            // `tapStalled` verdict off the clip and treats it as an interruption.
            if clip.tapStalled {
                logger.notice("capture sample duration \(duration, format: .fixed(precision: 2), privacy: .public)s ≪ wall \(wallDuration, format: .fixed(precision: 2), privacy: .public)s — input tap likely stalled (possible mic interruption)")
            } else {
                logger.debug("capture wall time: \(wallDuration, privacy: .public)s, samples=\(count, privacy: .public)")
            }
        }
        return clip
    }

    /// Copy the recorded RMS trace out of the preallocated buffers. Called in
    /// `stop()` after the tap is removed, never on the audio thread.
    private func snapshotTrace() -> RMSTrace? {
        let entries = min(traceIndex.load(ordering: .acquiring), Self.maxTraceEntries)
        guard entries > 0 else { return nil }
        let values = Array(UnsafeBufferPointer(start: traceValues.baseAddress, count: entries))
        let counts = Array(UnsafeBufferPointer(start: traceCounts.baseAddress, count: entries))
        return RMSTrace(values: values, frameCounts: counts, sampleRate: Self.targetSampleRate)
    }

    // MARK: - Level + cap publisher (off the audio thread)

    /// Seconds of headroom left before the hard cap, once inside the warning
    /// window (nil = plenty left, or not recording). One relaxed atomic load —
    /// safe to call per HUD tick; the HUD renders it as a countdown.
    public func capCountdown() -> TimeInterval? {
        let captured = Double(min(writeIndex.load(ordering: .relaxed), Self.maxSamples))
            / Self.targetSampleRate
        guard captured > 0 else { return nil }
        let remaining = Self.maxDuration - captured
        guard remaining <= Self.capWarningLeadTime else { return nil }
        return max(0, remaining)
    }

    /// Start the 20 Hz publisher that turns the render thread's atomics into
    /// `levels` events — and raises `.capReached` when the buffer fills.
    ///
    /// Why a timer instead of yielding from the tap (audit U9): `AsyncStream
    /// .yield` takes the stream's internal lock, which a consumer task on another
    /// thread also holds. Doing that in the render callback is a priority
    /// inversion waiting to happen, and it was the ONE thing the always-on audio
    /// path did that the file's stated invariant forbids. The tap now does two
    /// relaxed atomic stores instead.
    private func startLevelPublisher() {
        levelTimer?.cancel()
        levelQueue.async { [self] in
            lastPublishedSeq = 0
            staleTicks = 0
            capSignalled = false
            drainIndex = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: levelQueue)
        timer.schedule(
            deadline: .now() + Self.levelInterval,
            repeating: Self.levelInterval,
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in self?.publishTick() }
        levelTimer = timer
        timer.resume()
    }

    private func stopLevelPublisher() {
        levelTimer?.cancel()
        levelTimer = nil
    }

    /// One publisher tick. Runs on `levelQueue` — never on the audio thread.
    private func publishTick() {
        let seq = levelSeq.load(ordering: .relaxed)
        if seq == lastPublishedSeq {
            staleTicks += 1
        } else {
            lastPublishedSeq = seq
            staleTicks = 0
        }
        // Decay to zero when the tap stops delivering, so a stalled input
        // flatlines the waveform instead of freezing it mid-bar.
        let level = staleTicks >= Self.levelStaleTicks
            ? 0
            : Float(bitPattern: levelBits.load(ordering: .relaxed))
        levelsContinuation.yield(level)

        drainFrames()

        // Cap boundary: raised here (≤50 ms late) rather than from the render
        // callback, keeping the audio thread free of stream yields entirely.
        if !capSignalled, overflowed.load(ordering: .relaxed) {
            capSignalled = true
            let at = Double(min(writeIndex.load(ordering: .relaxed), Self.maxSamples))
                / Self.targetSampleRate
            logger.notice("""
                capture buffer full at \(at, format: .fixed(precision: 1), privacy: .public)s — \
                finalizing at the limit
                """)
            interruptionsContinuation.yield(CaptureInterruption(reason: .capReached, at: at))
        }
    }

    /// Hand every sample captured since the last tick to whichever raw-frame
    /// consumers are active. Runs on `levelQueue`.
    ///
    /// Single producer (the render thread, publishing `writeIndex` with a release
    /// store), single consumer (this queue): reading below the published index is
    /// safe without any lock, and the audio thread is never delayed by it. The
    /// read cursor advances every tick whether or not anyone is listening, so a
    /// consumer that arms mid-recording starts from NOW — the same behaviour the
    /// per-callback delivery had.
    private func drainFrames() {
        let end = min(writeIndex.load(ordering: .acquiring), Self.maxSamples)
        defer { drainIndex = end }
        guard end > drainIndex else { return }
        let wantFrames = framesWanted.load(ordering: .relaxed)
        let wantPreview = previewWanted.load(ordering: .relaxed)
        guard wantFrames || wantPreview else { return }
        // One allocation per tick (~50 ms of audio), off the audio thread, shared
        // by both consumers (copy-on-write, and both only read it).
        let copy = Array(UnsafeBufferPointer(
            start: storage.baseAddress! + drainIndex, count: end - drainIndex
        ))
        if wantFrames { framesSink.withLock { $0 }?.yield(copy) }
        if wantPreview { previewSink.withLock { $0 }?.yield(copy) }
    }

    // MARK: - Interruption handling

    /// `AVAudioEngineConfigurationChange` for OUR engine. Fires on an arbitrary
    /// thread. Mid-recording this is treated as an interruption: keep every
    /// sample already captured, stamp the boundary, and restart the engine so the
    /// SAME recording continues appending after the gap. If the restart fails the
    /// utterance is over — the orchestrator finalizes on `.restartFailed`.
    private func handleConfigurationChange() {
        let outcome = lifecycle.withLock { state -> (CaptureInterruption, Bool)? in
            guard state.recording else { return nil }
            let at = Double(writeIndex.load(ordering: .acquiring)) / Self.targetSampleRate
            let restarted = restartPreservingRecordingLocked()
            // Keep the FIRST marker (the disruption boundary), but a failed
            // restart always wins — it's the one that ends the utterance.
            let marker = CaptureInterruption(
                reason: restarted ? .configurationChange : .restartFailed, at: at
            )
            if state.interruption == nil || !restarted { state.interruption = marker }
            if !restarted { state.recording = false }
            return (marker, restarted)
        }
        guard let (marker, restarted) = outcome else { return }
        logger.notice("""
            audio engine configuration changed \(marker.at ?? 0, format: .fixed(precision: 2), privacy: .public)s \
            into capture — restart \(restarted ? "ok" : "FAILED", privacy: .public)
            """)
        interruptionsContinuation.yield(marker)
    }

    /// Rebuild the tap and restart the engine WITHOUT touching `writeIndex`, so
    /// everything captured so far is preserved and new callbacks append after it.
    /// Caller holds `lifecycle`. Adapted from Hex (MIT).
    private func restartPreservingRecordingLocked() -> Bool {
        stopEngineLocked()
        do {
            // `installTapAndStart` re-reads the (possibly new) input format and
            // rebuilds the converter for it.
            try installTapAndStart()
            return true
        } catch {
            logger.error("engine restart after configuration change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Remove the tap and stop the engine. Caller holds `lifecycle`.
    private func stopEngineLocked() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
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
        do {
            try engine.start()
        } catch {
            // P1-8: a tap left installed by a failed start is a LEAK the next
            // dictation pays for — `AVAudioEngine` does not tolerate a second tap
            // on the same bus, so attempt #2 traps instead of recording. Undo
            // everything this call did, then rethrow unchanged.
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            if engine.isRunning { engine.stop() }
            logger.error("engine start failed; tap removed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
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
        // synchronously on this same thread. The (non-Sendable) buffer and the
        // consumed flag travel in a REUSED box — allocating one per callback was
        // the render-thread malloc audit U9 flagged.
        let feed = self.feed
        feed.buffer = inputBuffer
        feed.consumed = false
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
            // Buffer full. Raise the flag (one relaxed store) and stop: the
            // publisher tick turns it into `.capReached` within 50 ms and the
            // orchestrator finalizes the session at this boundary. Everything
            // below is deliberately skipped — the samples are pinned, so there is
            // no new level, no trace entry and no VAD frame to report.
            overflowed.store(true, ordering: .relaxed)
            return
        }
        (storage.baseAddress! + start).update(from: channel, count: frames)
        writeIndex.store(start + frames, ordering: .releasing)

        // RMS for the HUD (cheap; ~10–20 Hz). Published by the timer on
        // `levelQueue`, not yielded here — two relaxed stores, no lock.
        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        levelBits.store(rms.bitPattern, ordering: .relaxed)
        levelSeq.wrappingAdd(1, ordering: .relaxed)

        // Record the same RMS (plus the samples it covers) into the preallocated
        // trace for the post-capture dead-tail analysis (WS1). Two stores into
        // already-allocated memory and one atomic bump — no allocation, no locks,
        // nothing to block on; the value was computed above regardless.
        let t = traceIndex.load(ordering: .relaxed)
        if t < Self.maxTraceEntries {
            traceValues[t] = rms
            traceCounts[t] = frames
            traceIndex.store(t + 1, ordering: .releasing)
        }

        // Raw-frame delivery to the hands-free VAD / live preview is NOT done
        // here: the samples are already in `storage`, published by the release
        // store above, so `drainFrames` reads them straight out on the publisher
        // queue. That keeps the render callback free of the Array allocation and
        // the stream lock it used to take per buffer (audit U9).
    }
}

/// Boxes the input buffer + consumed flag for the `@Sendable` converter block,
/// which actually runs synchronously on the audio thread. Allocated ONCE and
/// reset per callback (see `AudioCaptureService.feed`).
private final class ConverterFeed: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    var consumed = false
}

private extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
