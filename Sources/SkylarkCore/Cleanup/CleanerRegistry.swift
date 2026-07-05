import Foundation

/// Resolves the active `Cleaner` for a cleanup tier. The app target populates it
/// at the composition root (local + a cloud factory); core ships a raw-only
/// default. Cloud cleaners are built per-dictation from a slug via `cloudFactory`
/// (phase-3 spec §3) — this keeps the resolved slug (mode's `cloudCleanupSlug`,
/// or the global override) authoritative without pre-registering every model.
public struct CleanerRegistry: Sendable {
    private let raw: any Cleaner
    private let local: (any Cleaner)?
    private let cloud: [String: any Cleaner]
    private let cloudFactory: (@Sendable (String) -> (any Cleaner)?)?

    public init(
        raw: any Cleaner = RawPassthrough(),
        local: (any Cleaner)? = nil,
        cloud: [String: any Cleaner] = [:],
        cloudFactory: (@Sendable (String) -> (any Cleaner)?)? = nil
    ) {
        self.raw = raw
        self.local = local
        self.cloud = cloud
        self.cloudFactory = cloudFactory
    }

    /// Returns the cleaner for `tier`, degrading gracefully so a request never
    /// fails to resolve. A resolved cloud cleaner is wrapped so a runtime failure
    /// (no key / unavailable) silently falls back cloud → local → raw.
    public func cleaner(for tier: CleanupTier) -> any Cleaner {
        switch tier {
        case .raw:
            return raw
        case .local:
            return local ?? raw
        case .cloud(let slug):
            if let registered = cloud[slug] {
                return degrading(registered)
            }
            if let built = cloudFactory?(slug) {
                return degrading(built)
            }
            return local ?? raw
        }
    }

    /// Wrap a cloud cleaner so a thrown error falls through to local, then raw.
    private func degrading(_ cloud: any Cleaner) -> any Cleaner {
        var chain: [any Cleaner] = [cloud]
        if let local { chain.append(local) }
        return DegradingCleaner(tier: cloud.tier, chain: chain)
    }
}

/// Tries each cleaner in order, returning the first usable output; if all throw,
/// returns the input verbatim (raw). Never throws — the caller keeps raw either
/// way, and this preserves the "cloud → local → raw" degradation silently.
struct DegradingCleaner: Cleaner {
    let tier: CleanupTier
    let chain: [any Cleaner]

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        for cleaner in chain {
            if let output = try? await cleaner.clean(transcript, context: context) {
                return output
            }
        }
        return transcript
    }
}
