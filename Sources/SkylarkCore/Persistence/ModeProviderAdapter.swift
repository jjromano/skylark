import Foundation

/// Bridges the GRDB `ModeStore` (`ModeRecord` rows) to the pipeline's read-side
/// `ModeProviding` surface (`DictationMode`). The two types carry the same shape;
/// the only mapping of note is the cloud slug, which lives inside `CleanupTier`
/// on both sides and is mirrored to `DictationMode.cloudCleanupSlug` for callers
/// that read it directly.
public struct ModeProviderAdapter: ModeProviding {
    private let store: ModeStore

    public init(store: ModeStore) {
        self.store = store
    }

    public func modes() async throws -> [DictationMode] {
        try await store.all().map(Self.toDictationMode)
    }

    /// `ModeRecord` → `DictationMode`.
    public static func toDictationMode(_ record: ModeRecord) -> DictationMode {
        DictationMode(
            id: record.id,
            name: record.name,
            bundleIDPattern: record.bundleIDPattern,
            cleanupTier: record.cleanupTier,
            cloudCleanupSlug: record.cleanupTier.cloudSlug,
            registerHint: record.registerHint,
            whisperModeOverride: record.whisperModeOverride,
            isDefault: record.isDefault
        )
    }

    /// `DictationMode` → `ModeRecord` (round-trip inverse). `engine` has no
    /// `DictationMode` counterpart yet (Phase 4), so it maps to nil.
    public static func toRecord(_ mode: DictationMode) -> ModeRecord {
        ModeRecord(
            id: mode.id,
            name: mode.name,
            bundleIDPattern: mode.bundleIDPattern,
            engine: nil,
            cleanupTier: mode.cleanupTier,
            registerHint: mode.registerHint,
            whisperModeOverride: mode.whisperModeOverride,
            isDefault: mode.isDefault
        )
    }
}
