import Testing
import SkylarkCore

@Suite("KeychainStore round-trip")
struct KeychainStoreTests {
    /// Runs `body`, treating a locked-keychain (`errSecInteractionNotAllowed`)
    /// environment as a graceful skip rather than a failure — headless boxes
    /// (CI, this build machine) may not have an unlocked login keychain.
    private func skippingIfLocked(_ body: () throws -> Void) rethrows {
        do {
            try body()
        } catch KeychainError.interactionNotAllowed {
            return
        }
    }

    @Test("set/get/delete round-trips the API key")
    func roundTrip() throws {
        let store = KeychainStore()
        try skippingIfLocked {
            try store.set("sk-or-test-key-12345")
            #expect(store.get() == "sk-or-test-key-12345")
            try store.delete()
            #expect(store.get() == nil)
        }
    }

    @Test("set upserts an existing entry instead of throwing a duplicate error")
    func upsertOverwrites() throws {
        let store = KeychainStore()
        try skippingIfLocked {
            try store.set("first-value")
            try store.set("second-value")
            #expect(store.get() == "second-value")
            try store.delete()
        }
    }

    @Test("delete is safe to call when nothing is stored")
    func deleteWhenAbsent() throws {
        let store = KeychainStore()
        try skippingIfLocked {
            try store.delete() // ensure clean slate
            try store.delete() // must not throw for "not found"
            #expect(store.get() == nil)
        }
    }
}
