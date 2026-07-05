import Foundation

/// A custom-dictionary term (PRD §8): bias recognition toward `phrase`, and when
/// `replacement` is set, rewrite matches post-transcription.
public struct DictionaryEntry: Sendable, Equatable, Codable, Identifiable {
    public enum Source: String, Sendable, Codable {
        case manual
        case autoCorrection
    }

    public var id: Int64?
    /// What the transcript tends to contain (or the term to protect).
    public let phrase: String
    /// Corrected spelling; nil means "phrase is already correct, just prefer it".
    public let replacement: String?
    public let source: Source
    public let createdAt: Date

    public init(id: Int64? = nil, phrase: String, replacement: String?, source: Source, createdAt: Date = .init()) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.source = source
        self.createdAt = createdAt
    }
}

/// Read-side surface the pipeline consumes; the GRDB `DictionaryStore` conforms.
public protocol DictionaryProviding: Sendable {
    func entries() async throws -> [DictionaryEntry]
}
