import Testing
import Foundation
import SkylarkCore

@Suite("SingleInstancePolicy")
struct SingleInstancePolicyTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("An older instance is replaced")
    func olderReplaced() {
        let current = SingleInstancePolicy.Instance(pid: 200, launchDate: Self.base)
        let older = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base - 60)
        #expect(SingleInstancePolicy.instancesToReplace(others: [older], current: current) == [100])
    }

    @Test("A newer instance is left alone")
    func newerLeftAlone() {
        let current = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base)
        let newer = SingleInstancePolicy.Instance(pid: 200, launchDate: Self.base + 60)
        #expect(SingleInstancePolicy.instancesToReplace(others: [newer], current: current).isEmpty)
    }

    @Test("Equal launch dates break the tie by lower pid being older")
    func equalDatesTieBreakByPid() {
        let current = SingleInstancePolicy.Instance(pid: 200, launchDate: Self.base)
        let lowerPid = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base)
        #expect(SingleInstancePolicy.instancesToReplace(others: [lowerPid], current: current) == [100])

        // Flip pid ordering: the lower pid is now `current`, so the higher
        // pid (with the same date) is the newer one and must not be replaced.
        let currentLow = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base)
        let higherPid = SingleInstancePolicy.Instance(pid: 200, launchDate: Self.base)
        #expect(SingleInstancePolicy.instancesToReplace(others: [higherPid], current: currentLow).isEmpty)
    }

    @Test("A nil launchDate counts as older than any known date")
    func nilDateIsOlder() {
        let current = SingleInstancePolicy.Instance(pid: 200, launchDate: Self.base)
        let unknown = SingleInstancePolicy.Instance(pid: 100, launchDate: nil)
        #expect(SingleInstancePolicy.instancesToReplace(others: [unknown], current: current) == [100])
    }

    @Test("Both nil dates break the tie by lower pid being older")
    func bothNilDatesTieBreakByPid() {
        let current = SingleInstancePolicy.Instance(pid: 200, launchDate: nil)
        let lowerPid = SingleInstancePolicy.Instance(pid: 100, launchDate: nil)
        #expect(SingleInstancePolicy.instancesToReplace(others: [lowerPid], current: current) == [100])
    }

    @Test("current's own pid is never included, even if present in others")
    func currentPidExcluded() {
        let current = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base)
        let sameEntryAgain = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base - 60)
        #expect(SingleInstancePolicy.instancesToReplace(others: [sameEntryAgain], current: current).isEmpty)
    }

    @Test("An empty others list replaces nothing")
    func emptyList() {
        let current = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base)
        #expect(SingleInstancePolicy.instancesToReplace(others: [], current: current).isEmpty)
    }

    @Test("Mixed list only replaces the older ones, preserving pids")
    func mixedList() {
        let current = SingleInstancePolicy.Instance(pid: 300, launchDate: Self.base)
        let older = SingleInstancePolicy.Instance(pid: 100, launchDate: Self.base - 60)
        let newer = SingleInstancePolicy.Instance(pid: 400, launchDate: Self.base + 60)
        let unknown = SingleInstancePolicy.Instance(pid: 50, launchDate: nil)
        let result = SingleInstancePolicy.instancesToReplace(
            others: [older, newer, unknown], current: current)
        #expect(Set(result) == Set([100, 50]))
    }
}
