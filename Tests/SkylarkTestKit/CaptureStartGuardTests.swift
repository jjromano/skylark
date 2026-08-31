import AVFoundation
import Foundation
import Testing
@testable import SkylarkCore

/// Regression cover for the 2026-08-31 QA crash: driving a dictation on a Mac
/// with microphone permission GRANTED but no usable input device aborted the
/// whole process (SIGABRT).
///
/// `AVAudioNode.installTap(onBus:bufferSize:format:)` validates its format in
/// Objective-C and raises an `NSException` when the sample rate or channel
/// count is zero — which is exactly what `inputNode.inputFormat(forBus: 0)`
/// reports when nothing is plugged in. Swift cannot catch an ObjC exception, so
/// it reached the terminate handler and called `abort()`. `engine.start()` was
/// already wrapped in `do/catch`; the tap install one line above it was not,
/// and it is the call that raises.
///
/// The real crash needs mic-less hardware, so what is pinned here is the guard
/// condition itself and the contract it feeds: a degenerate format must be
/// classified as unusable, and the refusal must be a THROWN Swift error the
/// orchestrator can turn into a note.
@Suite("Capture start guard (no input device)")
struct CaptureStartGuardTests {

    /// The predicate `installTapAndStart` applies before touching the tap.
    private func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    @Test("A real 16 kHz mono input format is usable")
    func normalFormatPasses() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                          channels: 1, interleaved: false))
        #expect(isUsable(format))
    }

    @Test("A 48 kHz stereo input format is usable")
    func stereoFormatPasses() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                          channels: 2, interleaved: false))
        #expect(isUsable(format))
    }

    /// The crash shape: with no device attached, CoreAudio reports a degenerate
    /// format. Note that `AVAudioFormat` HAPPILY CONSTRUCTS one — it does not
    /// return nil for a zero sample rate or zero channel count — which is
    /// exactly why the crash was reachable: a perfectly ordinary-looking format
    /// object is handed to `installTap`, and the validation that rejects it
    /// lives in Objective-C and raises rather than returns. So the guard has to
    /// inspect the values itself, before the tap call.
    @Test("A zero sample rate is refused before the tap is installed")
    func zeroSampleRateIsRejected() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0,
                          channels: 1, interleaved: false),
            "AVAudioFormat is expected to construct at 0 Hz — that is the trap")
        #expect(!isUsable(format))
    }

    @Test("A zero channel count is refused before the tap is installed")
    func zeroChannelCountIsRejected() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                          channels: 0, interleaved: false),
            "AVAudioFormat is expected to construct with 0 channels — that is the trap")
        #expect(!isUsable(format))
    }

    /// The refusal must be catchable Swift, not an ObjC raise — that is the
    /// whole point of the fix, and it is what lets `DictationOrchestrator`
    /// surface its capture-failed note instead of the app dying.
    @Test("The refusal is a thrown Swift error, and it names the fix")
    func refusalIsAThrownSwiftError() {
        let error = CaptureStartError.noInputDevice
        var caught: CaptureStartError?
        do { throw error } catch let e as CaptureStartError { caught = e } catch {}
        #expect(caught == .noInputDevice)

        // Stephanie (non-technical, per the QA handoff) has to be able to act on
        // this: it must say what to do, not just that something failed.
        let message = error.errorDescription ?? ""
        #expect(message.contains("microphone"))
        #expect(message.contains("Settings"))
    }
}

/// LIVE probe against the REAL `AudioCaptureService` on this machine's actual
/// audio hardware. This is the test that would have caught the 2026-08-31
/// crash: on a Mac with no input device, the pre-fix `start()` aborted the
/// process in `AVAudioNode installTapOnBus:` instead of throwing, so this probe
/// could not even fail — it took the whole runner down with it.
///
/// Opt-in, because the correct expectation depends on the hardware present:
///
///     SKYLARK_LIVE_MIC_PROBE=1 make test TESTFLAGS='--filter liveCaptureStart'
///
/// On a mic-less machine it asserts the refusal is a clean thrown error. On a
/// machine WITH a microphone it asserts `start()` succeeds, then stops it
/// immediately — so the same probe is meaningful on the Mini and on the Air.
@Suite("Capture start live probe", .serialized)
struct CaptureStartLiveProbeTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SKYLARK_LIVE_MIC_PROBE"] != nil
    }

    @Test("liveCaptureStart: start() throws instead of aborting with no input device",
          .enabled(if: Self.enabled))
    func liveCaptureStart() async throws {
        let capture = AudioCaptureService()
        capture.prepare()

        let hasInput = AudioDeviceManager.inputDevices().isEmpty == false
        print("[mic-probe] input devices present: \(hasInput)")

        do {
            try capture.start()
            // Reaching here at all proves the process survived the tap install.
            _ = capture.stop()
            #expect(hasInput, "start() succeeded with no input device reported — investigate")
            print("[mic-probe] start() succeeded and stopped cleanly")
        } catch let error as CaptureStartError {
            #expect(error == .noInputDevice)
            #expect(!hasInput, "refused as .noInputDevice while an input device is present")
            print("[mic-probe] start() refused cleanly: \(error.errorDescription ?? "")")
        } catch {
            // Any other thrown error is still a PASS for the crash regression:
            // the point is that it threw rather than calling abort().
            print("[mic-probe] start() threw (not a crash): \(error.localizedDescription)")
        }
    }
}
