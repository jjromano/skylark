import Foundation
import os

/// Resolves the OpenRouter `provider.order` pin for a CLEANUP model slug.
///
/// PRD §7 wants cleanup models pinned so switching model never silently routes a
/// paste through a slow backend. That only holds for slugs we actually know:
/// pinning an ARBITRARY, user-entered slug to Groq (what the app used to do for
/// every custom slug) achieves the opposite — Groq may not serve that model at
/// all, so the request either lands on whatever `allow_fallbacks` finds or fails
/// outright, and the user's deliberate model switch quietly stops meaning
/// anything.
///
/// Rule:
/// - a slug present in the registry — the seed the `update-models` skill curates,
///   plus whatever rows this install has — uses THAT row's pin, which may itself
///   be nil (several models have a single provider and need no pin);
/// - an unknown slug gets NO pin and OpenRouter routes it.
///
/// The instance form exists because the cloud-cleanup factory runs off the main
/// actor (it builds a cleaner per dictation), so it can't read the main-actor
/// registry list or touch the database. The app publishes the loaded rows into
/// it; until then — and always as the floor — the seed answers.
public final class CleanupProviderPins: @unchecked Sendable {
    /// slug → pin (the inner optional is the row's own nil pin; a MISSING key
    /// means the slug is unknown to the registry).
    private var known: [String: String?]
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "models")

    /// Starts seeded from `ModelRegistryEntry.seed`, so a cleanup built before the
    /// registry rows finish loading still pins the models we ship.
    public init() {
        known = Self.index(ModelRegistryEntry.seed)
    }

    /// Publish the registry rows this install actually has. They win over the
    /// seed for slugs present in both; the seed stays as the floor so a row the
    /// database never returned (no persistence, load failure) is still pinned.
    public func publish(_ entries: [ModelRegistryEntry]) {
        let merged = Self.index(ModelRegistryEntry.seed + entries)
        lock.lock()
        known = merged
        lock.unlock()
    }

    /// The pin to send for `slug`, or nil to let OpenRouter route. Safe on any
    /// thread and allocation-free on the hit path.
    public func providerPin(for slug: String) -> String? {
        lock.lock()
        let hit = known[slug]
        lock.unlock()
        guard let pin = hit else {
            // Not a decision to make silently: an unknown slug is the case that
            // used to be force-pinned to groq.
            logger.debug("cleanup provider pin: \(slug, privacy: .public) unknown to the registry — no pin (OpenRouter routes)")
            return nil
        }
        logger.debug("cleanup provider pin: \(slug, privacy: .public) → \(pin ?? "none", privacy: .public) (registry)")
        return pin
    }

    /// Pure resolution against a caller-supplied row set, with the shipped seed as
    /// the fallback. Used where the rows are already in hand (the ad-hoc upsert in
    /// `ModelSelection`) and by the tests.
    public static func providerPin(for slug: String, known entries: [ModelRegistryEntry]) -> String? {
        if let entry = entries.first(where: { $0.kind == .cleanup && $0.slug == slug }) {
            return entry.providerPin
        }
        return ModelRegistryEntry.seed
            .first { $0.kind == .cleanup && $0.slug == slug }?
            .providerPin
    }

    /// Whether the registry (rows + seed) knows this cleanup slug at all.
    public static func isKnown(slug: String, known entries: [ModelRegistryEntry]) -> Bool {
        entries.contains { $0.kind == .cleanup && $0.slug == slug }
            || ModelRegistryEntry.seed.contains { $0.kind == .cleanup && $0.slug == slug }
    }

    private static func index(_ entries: [ModelRegistryEntry]) -> [String: String?] {
        var table: [String: String?] = [:]
        for entry in entries where entry.kind == .cleanup {
            table[entry.slug] = entry.providerPin
        }
        return table
    }
}
