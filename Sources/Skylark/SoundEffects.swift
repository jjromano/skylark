import AVFoundation
import AppKit
import SkylarkCore

/// Start/stop dictation cues. The user picks from the built-in macOS system
/// sounds (played via `NSSound`) plus a couple of Skylark-synthesized options.
/// Sounds are cached/prewarmed and played asynchronously, off the audio-capture
/// and paste latency paths. No third-party audio files are bundled.
@MainActor
final class SoundEffects {
    /// One selectable cue. `id` is persisted; it's either a macOS system-sound
    /// name (e.g. "Tink") or a `skylark.*` key for a synthesized cue.
    struct Cue: Identifiable, Hashable {
        let id: String
        let label: String
    }

    /// The classic macOS system sounds, in a friendly order (Tink/Pop first).
    static let systemSoundNames = [
        "Tink", "Pop", "Bottle", "Purr", "Glass", "Blow", "Frog", "Funk",
        "Hero", "Morse", "Ping", "Sosumi", "Submarine", "Basso",
    ]

    /// Everything selectable in the Settings dropdowns.
    static let catalog: [Cue] =
        systemSoundNames.map { Cue(id: $0, label: $0) }
            + [Cue(id: "skylark.twotone", label: "Two-tone (Skylark)"),
               Cue(id: "skylark.chirp", label: "Chirp (Skylark)")]

    static let defaultStartID = "Tink"
    static let defaultStopID = "Pop"
    static let defaultVolume: Double = 0.5

    var enabled: Bool
    private var startID: String
    private var stopID: String
    /// Cue volume 0…1, applied only to Skylark's own cues (never the system
    /// output volume). Stored as Double to bind directly to a SwiftUI Slider.
    private var volume: Double

    // Caches so playback never allocates/decodes on the hot path.
    private var systemSounds: [String: NSSound] = [:]
    private var synthPlayers: [String: AVAudioPlayer] = [:]

    init(enabled: Bool, startID: String, stopID: String, volume: Double = SoundEffects.defaultVolume) {
        self.enabled = enabled
        self.startID = startID
        self.stopID = stopID
        self.volume = min(max(volume, 0), 1)
        prewarm(startID)
        prewarm(stopID)
    }

    func setStart(_ id: String) { startID = id; prewarm(id) }
    func setStop(_ id: String) { stopID = id; prewarm(id) }

    /// Applies to all cached and future players immediately.
    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        for sound in systemSounds.values { sound.volume = Float(volume) }
        for player in synthPlayers.values { player.volume = Float(volume) }
    }

    func playStart() { guard enabled else { return }; play(startID) }
    func playStop() { guard enabled else { return }; play(stopID) }

    /// Play a cue regardless of `enabled` — for auditioning a selection in Settings.
    func preview(_ id: String) { play(id) }

    // MARK: - Playback

    private func play(_ id: String) {
        if id.hasPrefix("skylark.") {
            guard let player = synthPlayers[id] else { return }
            player.currentTime = 0
            player.play()
        } else {
            let sound = systemSound(id)
            sound?.stop()
            sound?.play()
        }
    }

    private func prewarm(_ id: String) {
        if id.hasPrefix("skylark.") {
            if synthPlayers[id] == nil, let player = Self.synthPlayer(for: id) {
                player.volume = Float(volume)
                player.prepareToPlay()
                synthPlayers[id] = player
            }
        } else {
            _ = systemSound(id)
        }
    }

    private func systemSound(_ name: String) -> NSSound? {
        if let cached = systemSounds[name] { return cached }
        let sound = NSSound(named: NSSound.Name(name))
        if let sound {
            sound.volume = Float(volume)
            systemSounds[name] = sound
        }
        return sound
    }

    private static func synthPlayer(for id: String) -> AVAudioPlayer? {
        let samples: [Float]
        switch id {
        case "skylark.chirp": samples = ToneSynth.startCue()
        case "skylark.twotone": samples = ToneSynth.stopCue()
        default: return nil
        }
        let data = WavEncoder.encode(samples: samples, sampleRate: ToneSynth.sampleRate)
        return try? AVAudioPlayer(data: data)
    }
}

/// Synthesizer for the two built-in Skylark cues (used only when the user picks
/// them from the dropdown): an upward-glided chirp and a soft descending two-tone.
enum ToneSynth {
    static let sampleRate: Double = 44_100

    static func startCue() -> [Float] {
        chirp(from: 740, to: 1500, ms: 105, amp: 0.26, attackMs: 2, releaseMs: 16, odd3: 0.20, odd5: 0.07)
    }

    static func stopCue() -> [Float] {
        softTone(freq: 466, ms: 85, amp: 0.24, decay: 9, even2: 0.28)
            + softTone(freq: 349, ms: 150, amp: 0.24, decay: 6, even2: 0.28)
    }

    private static func chirp(
        from f0: Double, to f1: Double, ms: Double, amp: Float,
        attackMs: Double, releaseMs: Double, odd3: Double, odd5: Double
    ) -> [Float] {
        let n = max(1, Int(sampleRate * ms / 1000))
        let attack = max(1, Int(sampleRate * attackMs / 1000))
        let release = max(1, min(n, Int(sampleRate * releaseMs / 1000)))
        let norm = 1 + odd3 + odd5
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let frac = Double(i) / Double(max(1, n - 1))
            let f = f0 * pow(f1 / f0, frac)
            phase += 2 * Double.pi * f / sampleRate
            var s = sin(phase) + odd3 * sin(3 * phase) + odd5 * sin(5 * phase)
            s /= norm
            var env = 1.0
            if i < attack { env = Double(i) / Double(attack) }
            let fromEnd = n - 1 - i
            if fromEnd < release { env *= Double(fromEnd) / Double(release) }
            out[i] = Float(s * env) * amp
        }
        return out
    }

    private static func softTone(freq: Double, ms: Double, amp: Float, decay: Double, even2: Double) -> [Float] {
        let n = max(1, Int(sampleRate * ms / 1000))
        let attack = max(1, min(n, Int(sampleRate * 0.004)))
        let release = max(1, min(n, Int(sampleRate * 0.030)))
        let norm = 1 + even2
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var s = sin(2 * Double.pi * freq * t) + even2 * sin(2 * Double.pi * 2 * freq * t)
            s /= norm
            s *= exp(-t * decay)
            var env = 1.0
            if i < attack { env = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(attack)) }
            let fromEnd = n - 1 - i
            if fromEnd < release { env *= Double(fromEnd) / Double(release) }
            out[i] = Float(s * env) * amp
        }
        return out
    }
}
