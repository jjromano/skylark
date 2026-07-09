import Testing
import SkylarkCore

// The full reconcile path lives inside HotkeyMonitor.handle, which needs real
// CGEvents (not unit-testable headless). The load-bearing DECISION — whether to
// synthesize a triggerUp after the tap is re-enabled — is extracted into a pure
// static helper and tested here.
@Suite("HotkeyMonitor reconcile decision")
struct HotkeyMonitorLogicTests {
    @Test("Trigger was pressed and is now released → synthesize triggerUp")
    func pressedToReleased() {
        #expect(HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: true, nowPressed: false))
    }

    @Test("Still pressed → no synthetic triggerUp")
    func stillPressed() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: true, nowPressed: true))
    }

    @Test("Was already released → no synthetic triggerUp")
    func alreadyReleased() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: false, nowPressed: false))
    }

    @Test("Newly pressed → no synthetic triggerUp")
    func newlyPressed() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticUp(wasPressed: false, nowPressed: true))
    }

    @Test("Legacy Fn-named helper delegates to the generalized decision")
    func legacyAliasMatches() {
        #expect(HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: true, nowPressed: false))
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: true, nowPressed: true))
    }
}
