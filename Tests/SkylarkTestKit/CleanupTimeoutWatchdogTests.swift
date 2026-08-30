import Testing
import Foundation
@testable import SkylarkCore

@Suite("CleanupTimeoutWatchdog")
struct CleanupTimeoutWatchdogTests {
    private func feed(_ w: inout CleanupTimeoutWatchdog, timeouts: Int, completed: Int) {
        for _ in 0..<timeouts { w.record(.timedOut) }
        for _ in 0..<completed { w.record(.completed) }
    }

    @Test("Stays quiet below the minimum sample, however bad the rate")
    func quietBelowMinimumSample() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 0)
        #expect(!w.isTimingOutPersistently)
        #expect(w.recommendationIfNeeded(timeoutSeconds: 2) == nil)
    }

    @Test("Stays quiet when cleanup is mostly succeeding")
    func quietWhenHealthy() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 2, completed: 6)
        #expect(!w.isTimingOutPersistently)
        #expect(w.recommendationIfNeeded(timeoutSeconds: 2) == nil)
    }

    @Test("Recommends once the timeout rate crosses half over enough attempts")
    func recommendsOnPersistentTimeouts() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 2)
        #expect(w.isTimingOutPersistently)
        let advice = w.recommendationIfNeeded(timeoutSeconds: 2)
        #expect(advice != nil)
        // The message must name the pattern, the cost, and a way out — a vague
        // "cleanup was slow" is what the per-dictation note already says.
        #expect(advice?.contains("4 of your last 6") == true)
        #expect(advice?.contains("2s") == true)
        #expect(advice?.contains("Raw") == true)
    }

    @Test("Recommends only once, so a bad setting never nags")
    func recommendsOnlyOnce() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 2)
        #expect(w.recommendationIfNeeded(timeoutSeconds: 2) != nil)
        w.record(.timedOut)
        #expect(w.isTimingOutPersistently)
        #expect(w.recommendationIfNeeded(timeoutSeconds: 2) == nil)
    }

    @Test("A settings change re-arms it and forgets the old configuration")
    func resetReArms() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 2)
        _ = w.recommendationIfNeeded(timeoutSeconds: 2)
        w.reset()
        #expect(w.attemptCount == 0)
        #expect(!w.isTimingOutPersistently)
        // The new configuration is judged on its own evidence, not the old.
        feed(&w, timeouts: 5, completed: 1)
        #expect(w.recommendationIfNeeded(timeoutSeconds: 5)?.contains("5s") == true)
    }

    @Test("The window slides, so an old bad patch stops counting once behavior recovers")
    func windowSlides() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 6, completed: 0)
        #expect(w.isTimingOutPersistently)
        w.reset()
        feed(&w, timeouts: 6, completed: 0)
        feed(&w, timeouts: 0, completed: 10)
        #expect(w.attemptCount == CleanupTimeoutWatchdog.windowSize)
        #expect(w.timeoutCount == 0)
        #expect(!w.isTimingOutPersistently)
    }
}
