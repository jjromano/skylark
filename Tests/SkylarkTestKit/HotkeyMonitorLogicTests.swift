import Testing
import SkylarkCore

// The full reconcile path lives inside HotkeyMonitor.handle, which needs real
// CGEvents (not unit-testable headless). The load-bearing DECISION — whether to
// synthesize an fnUp after the tap is re-enabled — is extracted into a pure
// static helper and tested here.
@Suite("HotkeyMonitor reconcile decision")
struct HotkeyMonitorLogicTests {
    @Test("Fn was pressed and is now released → synthesize fnUp")
    func pressedToReleased() {
        #expect(HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: true, nowPressed: false))
    }

    @Test("Still pressed → no synthetic fnUp")
    func stillPressed() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: true, nowPressed: true))
    }

    @Test("Was already released → no synthetic fnUp")
    func alreadyReleased() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: false, nowPressed: false))
    }

    @Test("Newly pressed → no synthetic fnUp")
    func newlyPressed() {
        #expect(!HotkeyMonitor.reconcileNeedsSyntheticFnUp(wasPressed: false, nowPressed: true))
    }
}
