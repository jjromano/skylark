import Testing
import SkylarkCore

/// Accessibility can be revoked while Skylark runs; the hotkey tap then dies with
/// nothing on screen to explain it. `PermissionsService.changes` is the edge
/// signal the app layer turns into a note, so it must fire on a FLIP and stay
/// quiet otherwise. The live TCC readers can't be flipped from a test, so the
/// snapshot reader is injected.
@Suite("PermissionsService change stream")
@MainActor
struct PermissionsChangeStreamTests {
    private final class Box: @unchecked Sendable {
        var snapshot: PermissionsService.Snapshot
        init(_ snapshot: PermissionsService.Snapshot) { self.snapshot = snapshot }
    }

    private func snapshot(accessibility: PermissionsService.Grant) -> PermissionsService.Snapshot {
        PermissionsService.Snapshot(
            microphone: .granted,
            accessibility: accessibility,
            inputMonitoring: .granted
        )
    }

    private func service(_ box: Box) -> PermissionsService {
        PermissionsService(reader: { MainActor.assumeIsolated { box.snapshot } })
    }

    @Test("A revoked Accessibility grant emits a snapshot")
    func revocationEmits() async {
        let box = Box(snapshot(accessibility: .granted))
        let permissions = service(box)
        var iterator = permissions.changes.makeAsyncIterator()

        permissions.refresh()
        #expect(await iterator.next()?.accessibility == .granted)

        box.snapshot = snapshot(accessibility: .denied)
        permissions.refresh()
        #expect(await iterator.next()?.accessibility == .denied)
        #expect(permissions.accessibility == .denied)
    }

    @Test("Re-granting emits the recovery edge")
    func reGrantEmits() async {
        let box = Box(snapshot(accessibility: .denied))
        let permissions = service(box)
        var iterator = permissions.changes.makeAsyncIterator()

        permissions.refresh()
        _ = await iterator.next()
        box.snapshot = snapshot(accessibility: .granted)
        permissions.refresh()
        #expect(await iterator.next()?.accessibility == .granted)
    }

    @Test("Unchanged polls emit nothing (the 500 ms poll must not spam consumers)")
    func steadyStateIsQuiet() async {
        let box = Box(snapshot(accessibility: .granted))
        let permissions = service(box)
        var iterator = permissions.changes.makeAsyncIterator()

        permissions.refresh()
        _ = await iterator.next()
        for _ in 0..<10 { permissions.refresh() }

        box.snapshot = snapshot(accessibility: .denied)
        permissions.refresh()
        // The next value is the flip, not a repeat of the steady state.
        #expect(await iterator.next()?.accessibility == .denied)
    }
}
