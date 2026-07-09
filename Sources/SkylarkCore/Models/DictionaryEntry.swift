import Foundation

/// A custom-dictionary term (PRD §8): `phrase` is always the correct spelling
/// (biased/protected during recognition), and `misspellings` lists common
/// mistakes that get rewritten to `phrase` post-transcription.
public struct DictionaryEntry: Sendable, Equatable, Codable, Identifiable {
    public enum Source: String, Sendable, Codable {
        case manual
        case autoCorrection
    }

    public var id: Int64?
    /// The correct word/phrase; always biased/protected during recognition.
    public let phrase: String
    /// Common misspellings/mistakes that get rewritten to `phrase`. Empty
    /// means "just bias recognition toward this spelling, nothing to rewrite".
    public let misspellings: [String]
    public let source: Source
    public let createdAt: Date

    public init(
        id: Int64? = nil,
        phrase: String,
        misspellings: [String] = [],
        source: Source,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.phrase = phrase
        self.misspellings = misspellings
        self.source = source
        self.createdAt = createdAt
    }
}

/// Read-side surface the pipeline consumes; the GRDB `DictionaryStore` conforms.
public protocol DictionaryProviding: Sendable {
    func entries() async throws -> [DictionaryEntry]
}

/// In-memory default used until the GRDB store is wired in (integration pass).
public struct InMemoryDictionaryProvider: DictionaryProviding {
    private let seeded: [DictionaryEntry]
    public init(entries: [DictionaryEntry] = []) { self.seeded = entries }
    public func entries() async throws -> [DictionaryEntry] { seeded }
}
