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
    /// Surface degrade events to the user (menu-bar note) — a cloud tier
    /// falling back must never be invisible. Never receives transcript content.
    private let notice: (@Sendable (String) -> Void)?

    public init(
        raw: any Cleaner = RawPassthrough(),
        local: (any Cleaner)? = nil,
        cloud: [String: any Cleaner] = [:],
        cloudFactory: (@Sendable (String) -> (any Cleaner)?)? = nil,
        notice: (@Sendable (String) -> Void)? = nil
    ) {
        self.raw = raw
        self.local = local
        self.cloud = cloud
        self.cloudFactory = cloudFactory
        self.notice = notice
    }

    /// A copy with a different local-tier cleaner — the seam the Settings
    /// "Local cleanup engine" picker uses to swap Apple Foundation Models for a
    /// Qwen GGUF (or back) without rebuilding raw/cloud or the orchestrator.
    public func withLocal(_ cleaner: any Cleaner) -> CleanerRegistry {
        CleanerRegistry(raw: raw, local: cleaner, cloud: cloud, cloudFactory: cloudFactory, notice: notice)
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
        return DegradingCleaner(tier: cloud.tier, chain: chain, notice: notice)
    }
}

/// Tries each cleaner in order, returning the first usable output; if all throw,
/// returns the input verbatim (raw). Never throws — the caller keeps raw either
/// way — but every degrade is REPORTED via `notice` so the user knows the tier
/// they picked isn't the one that ran (error reason only, never content).
struct DegradingCleaner: Cleaner {
    let tier: CleanupTier
    let chain: [any Cleaner]
    var notice: (@Sendable (String) -> Void)?

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        try await cleanTracked(transcript, context: context).text
    }

    func cleanTracked(_ transcript: String, context: CleanupContext) async throws -> CleanOutcome {
        var firstError: (any Error)?
        for (index, cleaner) in chain.enumerated() {
            // A cancelled task (e.g. the pre-paste timeout racing this call)
            // must not fall through to the next tier: that would start a local
            // generation — possibly a multi-GB model load — whose result is
            // guaranteed to be discarded. Bail before touching the next cleaner.
            try Task.checkCancellation()
            do {
                let output = try await cleaner.clean(transcript, context: context)
                if index > 0 {
                    notice?("Cloud cleanup failed — used local instead (\(Self.reason(firstError)))")
                }
                return CleanOutcome(text: output, engine: cleaner.engineID)
            } catch is CancellationError {
                // Same reasoning: the caller no longer wants any result, so
                // degrade no further and propagate the cancellation.
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        notice?("Cleanup unavailable — kept raw text (\(Self.reason(firstError)))")
        return CleanOutcome(text: transcript, engine: "raw")
    }

    /// Short human-readable failure reason; never transcript content.
    private static func reason(_ error: (any Error)?) -> String {
        guard let error else { return "unknown error" }
        let text = error.localizedDescription
        return text.count > 80 ? String(text.prefix(77)) + "…" : text
    }
}
