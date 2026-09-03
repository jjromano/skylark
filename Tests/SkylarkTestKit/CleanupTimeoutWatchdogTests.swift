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
        #expect(w.recommendationIfNeeded(bound: .milliseconds(600)) == nil)
    }

    @Test("Stays quiet when cleanup is mostly succeeding")
    func quietWhenHealthy() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 2, completed: 6)
        #expect(!w.isTimingOutPersistently)
        #expect(w.recommendationIfNeeded(bound: .milliseconds(600)) == nil)
    }

    @Test("Recommends once the timeout rate crosses half over enough attempts")
    func recommendsOnPersistentTimeouts() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 2)
        #expect(w.isTimingOutPersistently)
        let advice = w.recommendationIfNeeded(bound: .milliseconds(600))
        #expect(advice != nil)
        // The message must name the pattern, the cost, and a way out — a vague
        // "cleanup was slow" is what the per-dictation note already says.
        #expect(advice?.contains("4 of your last 6") == true)
        // Sub-second bounds must not round to "1s".
        #expect(advice?.contains("0.6 s") == true)
        #expect(advice?.contains("Raw") == true)
        // The cleanup timeout setting does not govern the paste path any more,
        // so the advice must not send the user to it.
        #expect(advice?.contains("Settings") == false)
        #expect(advice?.contains("faster cleanup model") == true)
    }

    @Test("Recommends only once, so a bad setting never nags")
    func recommendsOnlyOnce() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 2)
        #expect(w.recommendationIfNeeded(bound: .milliseconds(600)) != nil)
        w.record(.timedOut)
        #expect(w.isTimingOutPersistently)
        #expect(w.recommendationIfNeeded(bound: .milliseconds(600)) == nil)
    }

    @Test("A settings change re-arms it and forgets the old configuration")
    func resetReArms() {
        var w = CleanupTimeoutWatchdog()
        feed(&w, timeouts: 4, completed: 2)
        _ = w.recommendationIfNeeded(bound: .milliseconds(600))
        w.reset()
        #expect(w.attemptCount == 0)
        #expect(!w.isTimingOutPersistently)
        // The new configuration is judged on its own evidence, not the old.
        feed(&w, timeouts: 5, completed: 1)
        #expect(w.recommendationIfNeeded(bound: .seconds(5))?.contains("5 s") == true)
    }

    @Test("Bound labels stay honest below a second")
    func boundLabelsAreSubSecond() {
        #expect(CleanupTimeoutWatchdog.boundLabel(.milliseconds(600)) == "0.6 s")
        #expect(CleanupTimeoutWatchdog.boundLabel(.seconds(2)) == "2 s")
        #expect(CleanupTimeoutWatchdog.boundLabel(.milliseconds(1500)) == "1.5 s")
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
