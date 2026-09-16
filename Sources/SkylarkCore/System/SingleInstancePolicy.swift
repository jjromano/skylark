import Foundation

/// Pure decision logic for "newest launch wins" single-instance enforcement.
/// AppKit-free and fully unit-testable: given the current process and the
/// other running copies of the app, decide which of those others are older
/// and should be quit. Never decides to quit `current`, and never lets two
/// instances launched at the exact same instant quit each other (ties break
/// on pid, so exactly one side wins).
public enum SingleInstancePolicy {
    /// A running copy of the app, described only by what we need to order it.
    public struct Instance: Sendable, Equatable {
        public let pid: Int32
        public let launchDate: Date?

        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// Returns the pids of `others` that are older than `current` and should
    /// be terminated. Ordering: an earlier `launchDate` is older; a `nil`
    /// launchDate is treated as older than any known date (we can't prove the
    /// instance is newer, so it loses); equal (or both-nil) dates break the
    /// tie by the lower pid being older. `current.pid` is never included,
    /// even if it also appears in `others`.
    public static func instancesToReplace(others: [Instance], current: Instance) -> [Int32] {
        others
            .filter { $0.pid != current.pid }
            .filter { isOlder($0, than: current) }
            .map(\.pid)
    }

    /// True iff `lhs` is strictly older than `rhs` under the rules above.
    private static func isOlder(_ lhs: Instance, than rhs: Instance) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.pid < rhs.pid
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        case (.none, .none):
            return lhs.pid < rhs.pid
        }
    }
}
