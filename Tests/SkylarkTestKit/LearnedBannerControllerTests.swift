import Foundation
import Testing
import SkylarkCore

// MARK: - Test doubles

/// Clock that resolves every sleep immediately — for tests that only care
/// about the end state after a full auto-dismiss/undo cycle runs to
/// completion, not the timing itself.
private struct ImmediateClock: WatchClock {
    func sleep(for duration: Duration) async -> Bool { true }
}

/// Clock whose sleeps stay pending until the test explicitly resolves them —
/// used to prove the banner survives until its timer actually fires (not
/// merely "eventually", but specifically not-before), and to observe the
/// `.reverted` phase deterministically before it lingers away.
private actor GatedClock: WatchClock {
    private var pending: [CheckedContinuation<Bool, Never>] = []

    func sleep(for duration: Duration) async -> Bool {
        await withCheckedContinuation { pending.append($0) }
    }

    /// Yields until at least `n` sleep calls are outstanding.
    func waitForPendingCount(_ n: Int) async {
        while pending.count < n { await Task.yield() }
    }

    /// Resolves every outstanding sleep (order doesn't matter: the
    /// controller re-checks `Task.isCancelled` after every sleep, so a
    /// cancelled task's dangling sleep resolving is a harmless no-op).
    func resolveAll(_ result: Bool = true) {
        let all = pending
        pending.removeAll()
        for continuation in all { continuation.resume(returning: result) }
    }
}

/// Records every id the controller asked to delete.
private actor DeleteBox {
    private(set) var ids: [Int64] = []
    private var result = true

    func setResult(_ r: Bool) { result = r }

    func delete(_ id: Int64) async -> Bool {
        ids.append(id)
        return result
    }
}

@MainActor
private func pollUntil(limit: Int = 2000, _ condition: () -> Bool) async {
    for _ in 0..<limit {
        if condition() { return }
        await Task.yield()
    }
}

// MARK: - Tests

@Suite("LearnedBannerController")
@MainActor
struct LearnedBannerControllerTests {
    @Test("First learn shows a banner with the learned text")
    func firstLearnShowsBanner() {
        let controller = LearnedBannerController(clock: ImmediateClock(), delete: { _ in true })
        controller.learned(word: "GitHub", entryID: 1)

        #expect(controller.banner?.phase == .learned)
        #expect(controller.banner?.entries.map(\.word) == ["GitHub"])
        #expect(controller.banner?.learnedText == "Learned “GitHub”")
    }

    @Test("A second learn while the first is still showing combines into one banner")
    func combinesConsecutiveLearns() {
        let controller = LearnedBannerController(clock: ImmediateClock(), delete: { _ in true })
        controller.learned(word: "GitHub", entryID: 1)
        controller.learned(word: "Skylark", entryID: 2)

        #expect(controller.banner?.entries.map(\.word) == ["GitHub", "Skylark"])
        #expect(controller.banner?.entries.map(\.entryID) == [1, 2])
        #expect(controller.banner?.learnedText == "Learned “GitHub”, “Skylark”")
    }

    @Test("The banner does not disappear before the auto-dismiss timer fires")
    func survivesUntilTimerFires() async {
        let clock = GatedClock()
        let controller = LearnedBannerController(clock: clock, delete: { _ in true })

        controller.learned(word: "GitHub", entryID: 1)
        await clock.waitForPendingCount(1)
        #expect(controller.banner != nil) // still showing — the timer hasn't fired

        await clock.resolveAll()
        await pollUntil { controller.banner == nil }
        #expect(controller.banner == nil)
    }

    @Test("Undo deletes the entry, flips to reverted for a linger, then dismisses")
    func undoDeletesAndReverts() async {
        let box = DeleteBox()
        let clock = GatedClock()
        let controller = LearnedBannerController(clock: clock, delete: { await box.delete($0) })

        controller.learned(word: "GitHub", entryID: 42)
        await clock.waitForPendingCount(1) // auto-dismiss timer armed

        controller.undo()
        // undo() cancels the auto-dismiss sleep (its continuation dangles,
        // harmlessly, in `pending`) and starts its own linger sleep once the
        // delete resolves — wait for that second registration.
        await clock.waitForPendingCount(2)

        #expect(controller.banner?.phase == .reverted)
        await #expect(box.ids == [42])

        await clock.resolveAll()
        await pollUntil { controller.banner == nil }
        #expect(controller.banner == nil)
    }

    @Test("Undo on an entry already deleted elsewhere dismisses quietly, no reverted linger")
    func undoAlreadyGoneDismissesQuietly() async {
        let box = DeleteBox()
        await box.setResult(false)
        let controller = LearnedBannerController(clock: ImmediateClock(), delete: { await box.delete($0) })

        controller.learned(word: "GitHub", entryID: 42)
        controller.undo()

        await pollUntil { controller.banner == nil }
        #expect(controller.banner == nil)
        await #expect(box.ids == [42])
    }

    @Test("Undo is a no-op when nothing is showing")
    func undoNoopWhenIdle() async {
        let box = DeleteBox()
        let controller = LearnedBannerController(clock: ImmediateClock(), delete: { await box.delete($0) })

        controller.undo()

        #expect(controller.banner == nil)
        await #expect(box.ids.isEmpty)
    }

    @Test("dismiss() clears the banner immediately and cancels any pending timer")
    func dismissClears() {
        let controller = LearnedBannerController(clock: ImmediateClock(), delete: { _ in true })
        controller.learned(word: "GitHub", entryID: 1)

        controller.dismiss()

        #expect(controller.banner == nil)
    }

    @Test("onChange fires on every transition")
    func onChangeFires() async {
        let controller = LearnedBannerController(clock: ImmediateClock(), delete: { _ in true })
        var seen: [LearnedBanner?] = []
        controller.onChange = { seen.append($0) }

        controller.learned(word: "GitHub", entryID: 1)
        controller.dismiss()

        #expect(seen.count == 2)
        #expect(seen[0]?.entries.map(\.word) == ["GitHub"])
        #expect(seen[1] == nil)
    }
}
