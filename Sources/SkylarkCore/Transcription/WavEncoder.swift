import Foundation

/// Encodes mono Float32 PCM samples (the `AudioClip` format) into a WAV
/// (RIFF/PCM16) container, for cloud STT endpoints that want an audio file
/// rather than raw samples. Pure function — no I/O.
public enum WavEncoder {
    /// - Parameters:
    ///   - samples: mono samples in [-1, 1] (clamped before quantizing).
    ///   - sampleRate: e.g. 16_000.
    public static func encode(samples: [Float], sampleRate: Double) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sr = UInt32(sampleRate)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sr * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let riffSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))
        data.append(ascii: "RIFF")
        data.appendLE(riffSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.appendLE(UInt32(16)) // PCM fmt chunk size
        data.appendLE(UInt16(1)) // audio format = PCM
        data.appendLE(numChannels)
        data.appendLE(sr)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(ascii: "data")
        data.appendLE(dataSize)

        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = clamped * Float(Int16.max)
            let intValue = Int16(scaled.rounded())
            data.appendLE(UInt16(bitPattern: intValue))
        }
        return data
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
