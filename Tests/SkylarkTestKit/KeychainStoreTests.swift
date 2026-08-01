import Foundation
import Testing
import SkylarkCore

@Suite("KeychainStore round-trip")
struct KeychainStoreTests {
    /// Every test uses a dedicated test service + unique account so the suite
    /// can never read, overwrite, or delete the user's real API key — and so
    /// concurrent/aborted runs can't collide on a shared item.
    private static func makeStore() -> KeychainStore {
        KeychainStore(service: "com.jjromano.skylark.tests", account: "test-\(UUID().uuidString)")
    }

    /// Runs `body`, recording a *known issue* — never a plain pass — when the
    /// keychain is locked (`errSecInteractionNotAllowed`): headless boxes (CI,
    /// this build machine) may not have an unlocked login keychain. Swift
    /// Testing has no first-class runtime skip, so `withKnownIssue` is the
    /// idiomatic way to make this visibly distinct from a clean round-trip in
    /// the runner output — a locked run reports as an expected (known) issue,
    /// not a success with zero assertions behind it. `isIntermittent: true`
    /// is required here because, unlike a permanently-known bug, whether the
    /// keychain is locked varies by machine/session — an unlocked run must
    /// still report as a genuine pass, not "known issue not recorded".
    private func skippingIfLocked(_ body: () throws -> Void) rethrows {
        try withKnownIssue(
            "keychain is locked on this build machine — round-trip not exercised",
            isIntermittent: true
        ) {
            try body()
        } matching: { issue in
            guard case .errorCaught(let error) = issue.kind else { return false }
            return (error as? KeychainError) == .interactionNotAllowed
        }
    }

    @Test("set/get/delete round-trips the API key")
    func roundTrip() throws {
        let store = Self.makeStore()
        try skippingIfLocked {
            try store.set("sk-or-test-key-12345")
            #expect(store.get() == "sk-or-test-key-12345")
            try store.delete()
            #expect(store.get() == nil)
        }
    }

    @Test("set upserts an existing entry instead of throwing a duplicate error")
    func upsertOverwrites() throws {
        let store = Self.makeStore()
        try skippingIfLocked {
            try store.set("first-value")
            try store.set("second-value")
            #expect(store.get() == "second-value")
            try store.delete()
        }
    }

    @Test("delete is safe to call when nothing is stored")
    func deleteWhenAbsent() throws {
        let store = Self.makeStore()
        try skippingIfLocked {
            try store.delete() // ensure clean slate
            try store.delete() // must not throw for "not found"
            #expect(store.get() == nil)
        }
    }
}
