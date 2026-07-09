import AVFoundation
import SkylarkCore

/// Subtle start/stop dictation cues, synthesized as soft sine blips rather than
/// any recognizable macOS system sound (and never third-party audio files). The
/// tones are rendered once to in-memory WAV and played asynchronously, so they
/// stay off the audio-capture and paste latency paths.
@MainActor
final class SoundEffects {
    private let startPlayer: AVAudioPlayer?
    private let stopPlayer: AVAudioPlayer?

    /// Gates playback without tearing down the prewarmed players.
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
        startPlayer = Self.player(for: ToneSynth.startCue())
        stopPlayer = Self.player(for: ToneSynth.stopCue())
        startPlayer?.prepareToPlay()
        stopPlayer?.prepareToPlay()
    }

    private static func player(for samples: [Float]) -> AVAudioPlayer? {
        let data = WavEncoder.encode(samples: samples, sampleRate: ToneSynth.sampleRate)
        let player = try? AVAudioPlayer(data: data)
        player?.volume = 0.5
        return player
    }

    /// Play the recording-start cue (restart from the top if still ringing).
    func playStart() {
        guard enabled, let startPlayer else { return }
        startPlayer.currentTime = 0
        startPlayer.play()
    }

    /// Play the recording-stop cue.
    func playStop() {
        guard enabled, let stopPlayer else { return }
        stopPlayer.currentTime = 0
        stopPlayer.play()
    }
}

/// Tiny physically-inspired synthesizer for the dictation cues. Rather than a
/// static harmonic stack (which reads as "synthy"), each note is struck: a brief
/// contact transient, then partials that **decay at different rates** — the
/// upper overtones fade fast while the fundamental rings on, so the tone is
/// bright at onset and mellows like a mallet/plucked instrument or a water drop.
/// Two notes keep the liked pitch contour: ascending to open, descending to close.
enum ToneSynth {
    static let sampleRate: Double = 44_100

    /// Rising cue — "listening".
    static func startCue() -> [Float] {
        note(freq: 294, ms: 130, amp: 0.30) + note(freq: 392, ms: 190, amp: 0.30)
    }

    /// Falling cue — "done".
    static func stopCue() -> [Float] {
        note(freq: 294, ms: 130, amp: 0.28) + note(freq: 196, ms: 210, amp: 0.28)
    }

    /// Partials as (frequency ratio, amplitude, decay rate). Higher partials
    /// decay faster → the natural "brightness fades to warmth" of a struck note.
    /// A touch of inharmonicity on the top partial adds woody realism.
    private static let partials: [(ratio: Double, amp: Double, decay: Double)] = [
        (1.00, 1.00, 3.5),
        (2.00, 0.40, 8.0),
        (3.00, 0.18, 15.0),
        (4.02, 0.09, 24.0),
    ]

    private static func note(freq: Double, ms: Double, amp: Float) -> [Float] {
        let n = max(1, Int(sampleRate * ms / 1000))
        let attack = max(1, min(n, Int(sampleRate * 0.004)))    // 4 ms soft onset
        let release = max(1, min(n, Int(sampleRate * 0.014)))   // 14 ms fade-out
        let contactN = min(n, Int(sampleRate * 0.007))          // ~7 ms "tap"
        let norm = partials.reduce(0) { $0 + $1.amp }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var s = 0.0
            for p in partials {
                s += p.amp * exp(-t * p.decay) * sin(2 * Double.pi * freq * p.ratio * t)
            }
            s /= norm

            // Contact transient: a quick high blip that decays in ~2 ms, giving an
            // organic "tap"/"drop" onset instead of a clean synthetic attack.
            if i < contactN {
                s += sin(2 * Double.pi * freq * 6.0 * t) * exp(-t * 520) * 0.16
            }

            // Attack swell + short release fade (decay itself lives in the partials).
            var env = 1.0
            if i < attack { env = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(attack)) }
            let fromEnd = n - 1 - i
            if fromEnd < release { env *= Double(fromEnd) / Double(release) }

            out[i] = Float(s * env) * amp
        }
        return out
    }
}
