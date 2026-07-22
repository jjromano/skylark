import Testing
import Foundation
import AVFoundation
@testable import SkylarkCore

/// Unit tests for the parts of the Apple Speech engine that don't require live
/// recognition: STT-choice serialization, the pure locale-selection helper, and
/// the sample→buffer conversion (synthetic sine). The live recognition path is
/// exercised only by `SkylarkBench`, so these pass on a box with no assets.
@Suite("SpeechAnalyzerTranscriber (offline-testable pieces)")
struct SpeechAnalyzerTranscriberTests {

    // MARK: STTChoice serialization round-trip

    @Test("localApple serializes to \"localApple\" and round-trips")
    func localAppleSerialization() {
        #expect(STTChoice.localApple.serialized == "localApple")
        #expect(STTChoice(serialized: "localApple") == .localApple)
    }

    @Test("localApple is a local (offline) engine")
    func localAppleIsLocal() {
        #expect(STTChoice.localApple.isLocal)
    }

    @Test("Every STT choice round-trips through serialization")
    func allChoicesRoundTrip() {
        let choices: [STTChoice] = [
            .localParakeet, .localWhisper, .localApple, .cloud(slug: "openai/whisper-large-v3-turbo"),
        ]
        for choice in choices {
            #expect(STTChoice(serialized: choice.serialized) == choice)
        }
    }

    @Test("Unknown / nil serialization falls back to Parakeet")
    func unknownFallsBack() {
        #expect(STTChoice(serialized: nil) == .localParakeet)
        #expect(STTChoice(serialized: "garbage") == .localParakeet)
    }

    // MARK: Locale selection helper (pure)

    @Test("Exact BCP-47 match wins")
    func localeExactMatch() {
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        let chosen = SpeechAnalyzerTranscriber.resolveLocale(desired: Locale(identifier: "en-US"), supported: supported)
        #expect(chosen?.identifier(.bcp47) == "en-US")
    }

    @Test("Language-only fallback (en → en-US)")
    func localeLanguageFallback() {
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "de-DE")]
        let chosen = SpeechAnalyzerTranscriber.resolveLocale(desired: Locale(identifier: "en"), supported: supported)
        #expect(chosen?.language.languageCode?.identifier == "en")
    }

    @Test("No match returns nil")
    func localeNoMatch() {
        let supported = [Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")]
        let chosen = SpeechAnalyzerTranscriber.resolveLocale(desired: Locale(identifier: "ja-JP"), supported: supported)
        #expect(chosen == nil)
    }

    @Test("Empty supported list returns nil")
    func localeEmptySupported() {
        let chosen = SpeechAnalyzerTranscriber.resolveLocale(desired: Locale(identifier: "en-US"), supported: [])
        #expect(chosen == nil)
    }

    // MARK: Sample → buffer conversion (synthetic sine)

    /// A 1 s 440 Hz sine at `sampleRate`, mono Float32.
    private func sineClip(sampleRate: Double, seconds: Double = 1.0) -> AudioClip {
        let n = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: n)
        let twoPiF = 2.0 * Double.pi * 440.0
        for i in 0..<n {
            samples[i] = Float(0.5 * sin(twoPiF * Double(i) / sampleRate))
        }
        return AudioClip(samples: samples, sampleRate: sampleRate, duration: seconds)
    }

    @Test("Source buffer carries every sample at the source rate")
    func sourceBufferShape() throws {
        let clip = sineClip(sampleRate: 16_000)
        let buffer = try #require(SpeechAnalyzerTranscriber.makeSourceBuffer(samples: clip.samples, sampleRate: 16_000))
        #expect(buffer.frameLength == AVAudioFrameCount(clip.samples.count))
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
    }

    @Test("Same-format conversion passes the buffer straight through")
    func conversionSameFormatPassthrough() throws {
        let clip = sineClip(sampleRate: 16_000)
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let out = try SpeechAnalyzerTranscriber.makeInputBuffer(from: clip, to: target)
        #expect(out.frameLength == AVAudioFrameCount(clip.samples.count))
        #expect(out.format.sampleRate == 16_000)
    }

    @Test("Upsampling 16 kHz → 48 kHz yields ~3x frames of real audio")
    func conversionUpsamples() throws {
        let clip = sineClip(sampleRate: 16_000)
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let out = try SpeechAnalyzerTranscriber.makeInputBuffer(from: clip, to: target)
        #expect(out.format.sampleRate == 48_000)
        // ~3x the input frames (allow slack for the converter's edge handling).
        let expected = clip.samples.count * 3
        #expect(out.frameLength > AVAudioFrameCount(Double(expected) * 0.9))
        // The converted signal isn't all zeros (real audio came through).
        var peak: Float = 0
        if let ch = out.floatChannelData?.pointee {
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[i])) }
        }
        #expect(peak > 0.1)
    }
}
