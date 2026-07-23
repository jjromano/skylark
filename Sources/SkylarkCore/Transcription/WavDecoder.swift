import AVFoundation
import Foundation

/// Reads a retained WAV file back into an `AudioClip` (mono Float32) for the
/// History → Re-transcribe path (opt-in audio retention, phase-5a spec §2).
/// Pure read; never mutates the file. The inverse of `WavEncoder`, but tolerant
/// of any WAV `AVAudioFile` can open — it decodes via the file's Float32
/// `processingFormat` and takes channel 0, so a stereo or non-16 kHz file
/// (which Skylark never writes, but a user might drop in) still loads.
public enum WavDecoder {
    /// Decode `url` into an `AudioClip`, or nil if the file is missing/unreadable
    /// or contains no frames. Never throws — the caller treats nil as "audio
    /// unavailable" and surfaces it, off any latency path.
    public static func decode(url: URL) -> AudioClip? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let n = Int(buffer.frameLength)
        // processingFormat is always deinterleaved Float32; channel 0 is mono
        // (Skylark only ever writes mono) or the left channel of a stray stereo.
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: n))
        let sr = format.sampleRate
        return AudioClip(samples: samples, sampleRate: sr, duration: Double(n) / sr)
    }
}
