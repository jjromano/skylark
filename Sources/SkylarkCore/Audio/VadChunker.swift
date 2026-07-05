import Foundation

/// Pure framing math for streaming VAD: FluidAudio's `VadManager` wants fixed
/// 4096-sample chunks (256 ms at 16 kHz), but the capture tap hands us frames of
/// arbitrary size. This accumulates a leftover buffer and slices out every whole
/// chunk it can, keeping the sub-chunk tail for next time. Unit-tested as one.
public enum VadChunker {
    /// Chunk size the Silero VAD model consumes (256 ms @ 16 kHz).
    public static let chunkSize = 4096

    /// Combine `buffer` (previous leftover) with newly-arrived `incoming`
    /// samples, returning every full `chunkSize` chunk now available plus the
    /// remaining tail (`< chunkSize`) to carry forward.
    public static func split(
        buffer: [Float],
        incoming: [Float],
        chunkSize: Int = chunkSize
    ) -> (chunks: [[Float]], remainder: [Float]) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        if buffer.isEmpty && incoming.count < chunkSize {
            return ([], incoming)
        }
        var combined = buffer
        combined.append(contentsOf: incoming)

        var chunks: [[Float]] = []
        var idx = 0
        while idx + chunkSize <= combined.count {
            chunks.append(Array(combined[idx..<(idx + chunkSize)]))
            idx += chunkSize
        }
        let remainder = idx < combined.count ? Array(combined[idx...]) : []
        return (chunks, remainder)
    }
}
