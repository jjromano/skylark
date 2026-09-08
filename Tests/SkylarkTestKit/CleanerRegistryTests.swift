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

@Suite("CleanerRegistry fallback ownership")
struct CleanerRegistryFallbackOwnershipTests {
    /// A cancelled selected local cleaner must propagate immediately, not start
    /// Apple inside the cancelled task. The orchestrator owns the fresh Apple
    /// fallback attempt and its remaining time budget.
    @Test("Cancelled first cleaner never invokes the second")
    func cancellationSkipsRemainingChain() async {
        let qwen = CountingCleaner(tier: .local, behaviour: .hangUntilCancelled)
        let apple = CountingCleaner(tier: .local, behaviour: .transform("APPLE"))
        let registry = CleanerRegistry(local: qwen, localFallback: apple)
        let degrading = registry.cleaner(for: .local)

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
        await #expect(apple.calls() == 0)
    }

    /// The orchestrator, not the registry, owns fallback timing. Keeping Apple
    /// outside this cleaner prevents it from being restarted after cancellation.
    @Test("A local cleaner does not consume its Apple fallback itself")
    func localCleanerDoesNotEmbedAppleFallback() async {
        let qwen = CountingCleaner(tier: .local, behaviour: .fail(CleanerError.unusableOutput))
        let apple = CountingCleaner(tier: .local, behaviour: .transform("APPLE"))
        let registry = CleanerRegistry(local: qwen, localFallback: apple)

        await #expect(throws: CleanerError.self) {
            _ = try await registry.cleaner(for: .local)
                .cleanTracked("hello", context: CleanupContext())
        }
        await #expect(apple.calls() == 0)
    }

    /// Cloud fallback is budgeted by the orchestrator. If the registry embeds
    /// Qwen and Apple inside the cloud cleaner, a cloud timeout can restart Qwen
    /// and spend Apple's entire fallback window before Apple gets a turn.
    @Test("A cloud cleaner does not consume the local fallback chain itself")
    func cloudCleanerDoesNotEmbedLocalFallbacks() async {
        let cloud = CountingCleaner(tier: .cloud(slug: "test"), behaviour: .fail(CleanerError.unusableOutput))
        let qwen = CountingCleaner(tier: .local, behaviour: .transform("QWEN"))
        let apple = CountingCleaner(tier: .local, behaviour: .transform("APPLE"))
        let registry = CleanerRegistry(
            local: qwen, localFallback: apple, cloud: ["test": cloud]
        )

        await #expect(throws: CleanerError.self) {
            _ = try await registry.cleaner(for: .cloud(slug: "test"))
                .cleanTracked("hello", context: CleanupContext())
        }
        await #expect(qwen.calls() == 0)
        await #expect(apple.calls() == 0)
    }
}
