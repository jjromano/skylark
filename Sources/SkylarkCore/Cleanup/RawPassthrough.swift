import Foundation

/// Tier 0 cleaner — verbatim passthrough, zero added latency (PRD §6.3).
public struct RawPassthrough: Cleaner {
    public let tier: CleanupTier = .raw

    public init() {}

    public func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        transcript
    }
}
