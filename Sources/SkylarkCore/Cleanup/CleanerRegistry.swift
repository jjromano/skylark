import Foundation

/// Resolves the active `Cleaner` for a cleanup tier. The app target populates it
/// at the composition root (local + optional cloud); core ships a raw-only
/// default. Cloud cleaners land in the persistence/networking integration pass
/// (`OpenRouterCleaner`), keyed by registry slug — until then `.cloud` falls
/// back to local, and an unregistered local falls back to raw.
public struct CleanerRegistry: Sendable {
    private let raw: any Cleaner
    private let local: (any Cleaner)?
    private let cloud: [String: any Cleaner]

    public init(
        raw: any Cleaner = RawPassthrough(),
        local: (any Cleaner)? = nil,
        cloud: [String: any Cleaner] = [:]
    ) {
        self.raw = raw
        self.local = local
        self.cloud = cloud
    }

    /// Returns the cleaner for `tier`, degrading gracefully so a request never
    /// fails to resolve: cloud → local → raw, local → raw.
    public func cleaner(for tier: CleanupTier) -> any Cleaner {
        switch tier {
        case .raw:
            return raw
        case .local:
            return local ?? raw
        case .cloud(let slug):
            return cloud[slug] ?? local ?? raw
        }
    }
}
