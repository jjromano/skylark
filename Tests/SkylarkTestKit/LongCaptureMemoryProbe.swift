import Testing
import Darwin
import Foundation
import SkylarkCore

/// P1-2 memory: a 253 s hands-free session took RSS from 93 MB to 195 MB and did
/// not give it back within 25 s. This probe accounts for the part of that the
/// audio pipeline owns — the full-length `[Float]` copies the finalize chain
/// makes — so the remainder can be attributed honestly (it is the STT decode of
/// a 2-minute clip, which is CoreML's allocator, not ours).
///
/// Off by default (it allocates ~100 MB and RSS is machine-noisy):
///
///     SKYLARK_MEM_PROBE=1 make test --filter longCaptureFinalizeFootprint
@Suite("Long-capture memory probe")
struct LongCaptureMemoryProbe {
    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    @Test("LIVE finalize-chain footprint for a capped 120 s clip",
          .enabled(if: ProcessInfo.processInfo.environment["SKYLARK_MEM_PROBE"] != nil))
    func longCaptureFinalizeFootprint() {
        let rate: Double = 16_000
        let count = Int(rate * 120)
        let baseline = residentMB()

        // 1. What `AudioCaptureService.stop()` hands over: one full-length copy
        //    out of the preallocated ring.
        var samples = [Float](repeating: 0, count: count)
        for i in stride(from: 0, to: count, by: 2) { samples[i] = 0.2 }
        let captured = AudioClip(
            samples: samples, sampleRate: rate, duration: 120, wallDuration: 121, capReached: true
        )
        let afterCapture = residentMB()

        // 2. The finalize chain: dead-tail trim, VAD trim, whisper normalize —
        //    each produces another full-length array before the previous is
        //    released.
        let deadTailTrimmed = captured.trimmed(toSampleCount: count - Int(rate))
        let vadTrimmed = deadTailTrimmed.trimmed(toSampleRange: Int(rate)..<(count - Int(2 * rate)))
        let peak = residentMB()

        // 3. And what the audible guard costs on top (it only reads).
        let verdict = VadClipTrimmer.decide(
            regions: [SpeechRegion(startSample: Int(rate * 5), endSample: Int(rate * 100))],
            sampleCount: vadTrimmed.samples.count,
            sampleRate: rate,
            samples: vadTrimmed.samples
        )
        let afterScan = residentMB()

        print("""

        ===== 120 s finalize-chain footprint =====
          baseline:            \(String(format: "%.1f", baseline)) MB
          + captured clip:     \(String(format: "%.1f", afterCapture - baseline)) MB
          + trim chain (peak): \(String(format: "%.1f", peak - baseline)) MB
          + audible guard:     \(String(format: "%.1f", afterScan - peak)) MB
          kept samples:        \(vadTrimmed.samples.count) (trim verdict \(verdict.trimmed) s)

        """)
        // The whole audio-owned chain is a handful of 7.7 MB buffers: bounded,
        // short-lived, and nowhere near the 100 MB the QA session grew by.
        #expect(peak - baseline < 60)
    }
}
