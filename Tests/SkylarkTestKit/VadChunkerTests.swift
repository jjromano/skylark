import Testing
import SkylarkCore

@Suite("VadChunker framing math")
struct VadChunkerTests {
    private let cs = VadChunker.chunkSize // 4096

    @Test("Incoming smaller than a chunk is all remainder")
    func smallerThanChunk() {
        let incoming = Array(repeating: Float(1), count: 1_000)
        let (chunks, remainder) = VadChunker.split(buffer: [], incoming: incoming)
        #expect(chunks.isEmpty)
        #expect(remainder.count == 1_000)
    }

    @Test("Exactly one chunk yields one chunk, no remainder")
    func exactlyOneChunk() {
        let incoming = Array(repeating: Float(1), count: cs)
        let (chunks, remainder) = VadChunker.split(buffer: [], incoming: incoming)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == cs)
        #expect(remainder.isEmpty)
    }

    @Test("Leftover buffer combines with incoming across the boundary")
    func combinesWithLeftover() {
        let buffer = Array(repeating: Float(1), count: cs - 100)
        let incoming = Array(repeating: Float(2), count: 300)
        // total 4096 + 200 → one chunk + 200 remainder
        let (chunks, remainder) = VadChunker.split(buffer: buffer, incoming: incoming)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == cs)
        #expect(remainder.count == 200)
        // Chunk starts with the buffered samples, then the incoming ones.
        #expect(chunks[0].first == 1)
        #expect(chunks[0].last == 2)
    }

    @Test("Multiple chunks with a tail")
    func multipleChunks() {
        let incoming = Array(repeating: Float(1), count: cs * 2 + 500)
        let (chunks, remainder) = VadChunker.split(buffer: [], incoming: incoming)
        #expect(chunks.count == 2)
        #expect(remainder.count == 500)
    }

    @Test("No samples at all → empty chunks, empty remainder")
    func nothing() {
        let (chunks, remainder) = VadChunker.split(buffer: [], incoming: [])
        #expect(chunks.isEmpty)
        #expect(remainder.isEmpty)
    }
}
