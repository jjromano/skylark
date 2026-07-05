import Foundation

/// One recorded utterance. Capture converts to 16 kHz mono Float32 once at the
/// tap (confirmed native rate for FluidAudio ASR + VAD and WhisperKit).
public struct AudioClip: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    public let duration: TimeInterval

    public init(samples: [Float], sampleRate: Double, duration: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
    }

    /// An empty clip (nothing captured).
    public static let empty = AudioClip(samples: [], sampleRate: 16_000, duration: 0)

    public var isEmpty: Bool { samples.isEmpty }
}
