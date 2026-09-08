import Foundation

/// Resolves the active `Cleaner` for a cleanup tier. The app target populates it
/// at the composition root (local + a cloud factory); core ships a raw-only
/// default. Cloud cleaners are built per-dictation from a slug via `cloudFactory`
/// (phase-3 spec §3) — this keeps the resolved slug (mode's `cloudCleanupSlug`,
/// or the global override) authoritative without pre-registering every model.
public struct CleanerRegistry: Sendable {
    private let raw: any Cleaner
    private let local: (any Cleaner)?
    /// Apple Intelligence when the selected local cleaner is a downloaded
    /// model. nil when Apple is already primary, so it is never retried.
    private let localFallback: (any Cleaner)?
    private let cloud: [String: any Cleaner]
    private let cloudFactory: (@Sendable (String) -> (any Cleaner)?)?

    public init(
        raw: any Cleaner = RawPassthrough(),
        local: (any Cleaner)? = nil,
        localFallback: (any Cleaner)? = nil,
        cloud: [String: any Cleaner] = [:],
        cloudFactory: (@Sendable (String) -> (any Cleaner)?)? = nil
    ) {
        self.raw = raw
        self.local = local
        self.localFallback = localFallback
        self.cloud = cloud
        self.cloudFactory = cloudFactory
    }

    /// A copy with a different local-tier cleaner — the seam the Settings
    /// "Local cleanup engine" picker uses to swap Apple Foundation Models for a
    /// Qwen GGUF (or back) without rebuilding raw/cloud or the orchestrator.
    public func withLocal(
        _ cleaner: any Cleaner, fallback: (any Cleaner)? = nil
    ) -> CleanerRegistry {
        CleanerRegistry(
            raw: raw, local: cleaner, localFallback: fallback,
            cloud: cloud, cloudFactory: cloudFactory
        )
    }

    /// Returns the cleaner for `tier`. Local Qwen failures can degrade to Apple
    /// inside the same tier. Cloud fallback stays with the orchestrator because
    /// it must divide one user-visible timeout budget between Qwen and Apple.
    public func cleaner(for tier: CleanupTier) -> any Cleaner {
        switch tier {
        case .raw:
            return raw
        case .local:
            return local ?? raw
        case .cloud(let slug):
            if let registered = cloud[slug] {
                return registered
            }
            if let built = cloudFactory?(slug) {
                return built
            }
            return cleaner(for: .local)
        }
    }

    /// The selected local cleaner without its Apple fallback wrapper. Cloud
    /// fallback uses this so it can reserve time for Apple if Qwen stalls.
    func selectedLocalCleaner() -> (any Cleaner)? { local }

    /// The backup on-device cleaner used after a selected Qwen times out.
    /// Kept separate from `cleaner(for: .local)` so the timeout path does not
    /// restart the Qwen generation it just cancelled.
    func localFallbackCleaner() -> (any Cleaner)? { localFallback }
}
