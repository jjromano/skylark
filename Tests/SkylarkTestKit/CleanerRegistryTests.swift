import Testing
import SkylarkCore

/// Counting stub: records how many times `clean` was invoked, and either
/// returns a fixed transform, throws a fixed error, or hangs until cancelled
/// (to exercise the cancellation path deterministically instead of racing a
/// real timeout).
private actor CountingCleaner: Cleaner {
    enum Behaviour {
        case transform(String)
        case fail(any Error)
        case hangUntilCancelled
    }

    let tier: CleanupTier
    private let behaviour: Behaviour
    private(set) var callCount = 0

    init(tier: CleanupTier, behaviour: Behaviour) {
        self.tier = tier
        self.behaviour = behaviour
    }

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        callCount += 1
        switch behaviour {
        case let .transform(output):
            return output
        case let .fail(error):
            throw error
        case .hangUntilCancelled:
            // Sleeps respect cooperative cancellation: a cancelled task makes
            // this throw CancellationError instead of returning normally.
            try await Task.sleep(for: .seconds(60))
            return transcript
        }
    }

    func calls() -> Int { callCount }
}

@Suite("DegradingCleaner cancellation")
struct DegradingCleanerCancellationTests {
    /// A cancelled first cleaner (the pre-paste timeout cancelling the cloud
    /// generation) must propagate the cancellation immediately, not degrade to
    /// the next tier — degrading would start a local generation (possibly a
    /// multi-GB model load) whose result is guaranteed to be discarded.
    @Test("Cancelled first cleaner never invokes the second")
    func cancellationSkipsRemainingChain() async {
        let cloud = CountingCleaner(tier: .cloud(slug: "test"), behaviour: .hangUntilCancelled)
        let local = CountingCleaner(tier: .local, behaviour: .transform("LOCAL"))
        // `CleanerRegistry.cleaner(for:)` wraps the resolved cloud cleaner in
        // the internal `DegradingCleaner` chain — exercise it through this
        // public seam rather than the internal type directly.
        let registry = CleanerRegistry(local: local, cloud: ["test": cloud])
        let degrading = registry.cleaner(for: .cloud(slug: "test"))

        let task = Task {
            try await degrading.cleanTracked("hello", context: CleanupContext())
        }
        // Give the cloud cleaner a moment to actually start sleeping, then
        // cancel — mirrors `group.cancelAll()` in the orchestrator's
        // `cleanWithTimeout` race.
        await Task.yield()
        task.cancel()

        var threwCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(threwCancellation)
        await #expect(local.calls() == 0)
    }

    /// Sanity check: a plain (non-cancellation) failure still degrades to the
    /// next cleaner in the chain, exactly as before this fix.
    @Test("A non-cancellation failure still degrades to the next cleaner")
    func plainFailureStillDegrades() async throws {
        let cloud = CountingCleaner(tier: .cloud(slug: "test"), behaviour: .fail(CleanerError.unusableOutput))
        let local = CountingCleaner(tier: .local, behaviour: .transform("LOCAL"))
        let registry = CleanerRegistry(local: local, cloud: ["test": cloud])
        let degrading = registry.cleaner(for: .cloud(slug: "test"))

        let outcome = try await degrading.cleanTracked("hello", context: CleanupContext())

        #expect(outcome.text == "LOCAL")
        await #expect(local.calls() == 1)
    }
}
