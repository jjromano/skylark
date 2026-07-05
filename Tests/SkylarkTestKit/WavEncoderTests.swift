import Testing
import Foundation
import SkylarkCore

@Suite("WavEncoder golden header")
struct WavEncoderTests {
    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 2]
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    private func ascii(_ data: Data, _ range: Range<Int>) -> String {
        let bytes = data[data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound]
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test("44-byte header matches the WAV/PCM16 spec exactly")
    func headerFields() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5]
        let data = WavEncoder.encode(samples: samples, sampleRate: 16_000)

        let expectedDataSize: UInt32 = 4 * 2 // 4 samples * 16-bit
        #expect(data.count == 44 + Int(expectedDataSize))

        #expect(ascii(data, 0..<4) == "RIFF")
        #expect(readUInt32LE(data, at: 4) == 36 + expectedDataSize)
        #expect(ascii(data, 8..<12) == "WAVE")
        #expect(ascii(data, 12..<16) == "fmt ")
        #expect(readUInt32LE(data, at: 16) == 16) // PCM fmt chunk size
        #expect(readUInt16LE(data, at: 20) == 1) // audio format = PCM
        #expect(readUInt16LE(data, at: 22) == 1) // mono
        #expect(readUInt32LE(data, at: 24) == 16_000) // sample rate
        #expect(readUInt32LE(data, at: 28) == 32_000) // byte rate = sr * channels * bytes/sample
        #expect(readUInt16LE(data, at: 32) == 2) // block align
        #expect(readUInt16LE(data, at: 34) == 16) // bits per sample
        #expect(ascii(data, 36..<40) == "data")
        #expect(readUInt32LE(data, at: 40) == expectedDataSize)
    }

    @Test("PCM16 sample quantization: 0, +full-scale, -full-scale, mid-scale")
    func sampleQuantization() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5]
        let data = WavEncoder.encode(samples: samples, sampleRate: 16_000)

        func sample(_ index: Int) -> Int16 {
            Int16(bitPattern: readUInt16LE(data, at: 44 + index * 2))
        }

        #expect(sample(0) == 0)
        #expect(sample(1) == Int16.max) // clamped to +32767, not overflowing
        #expect(sample(2) == -Int16.max) // symmetric clamp: -32767, not -32768
        #expect(sample(3) == 16_384) // round(0.5 * 32767) == 16384
    }

    @Test("Out-of-range samples are clamped, not wrapped")
    func clampsOutOfRange() {
        let data = WavEncoder.encode(samples: [2.0, -2.0], sampleRate: 16_000)
        func sample(_ index: Int) -> Int16 {
            Int16(bitPattern: readUInt16LE(data, at: 44 + index * 2))
        }
        #expect(sample(0) == Int16.max)
        #expect(sample(1) == -Int16.max)
    }

    @Test("Empty samples produce a header-only (44-byte) WAV")
    func emptySamples() {
        let data = WavEncoder.encode(samples: [], sampleRate: 16_000)
        #expect(data.count == 44)
        #expect(readUInt32LE(data, at: 40) == 0)
    }
}
