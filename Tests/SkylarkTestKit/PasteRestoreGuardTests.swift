import AppKit
import Testing
import SkylarkCore

/// Guards around the restore WRITE (P1-1) and the U2 read-attribution floor.
/// The coordinator's AppKit half isn't unit-testable headless, so the decisions
/// it makes are exercised directly — plus one live AppKit assumption
/// (`changeCount` vs promise fulfillment) that the whole fix rests on.
@Suite("Paste restore guards")
struct PasteRestoreGuardTests {
    @Test("Untouched pasteboard: restoring is safe")
    func restoreSafeWhenUnchanged() {
        #expect(PasteRestoreGuards.restoreIsSafe(expectedChangeCount: 42, currentChangeCount: 42))
    }

    /// The live P1-1 bug: the user hits Cmd-C during the ~120 ms restore window.
    /// Their copy bumped the changeCount, so our snapshot must NOT go back on top
    /// of it.
    @Test("Another writer bumped changeCount: restore stands down")
    func restoreSkippedWhenForeignWrite() {
        #expect(!PasteRestoreGuards.restoreIsSafe(expectedChangeCount: 42, currentChangeCount: 43))
        // Any difference counts, including a counter that jumped several writes.
        #expect(!PasteRestoreGuards.restoreIsSafe(expectedChangeCount: 42, currentChangeCount: 57))
    }

    @Test("Normal read timing: the grace is exactly the read grace")
    func graceIsReadGraceWhenReadIsLate() {
        let delay = PasteRestoreGuards.readGraceDelay(
            readGrace: .milliseconds(100),
            sinceArm: .milliseconds(40),
            minimumRestoreDelay: .milliseconds(120)
        )
        #expect(delay == .milliseconds(100)) // restores at ~140 ms — past the floor
    }

    /// U2: a read 2 ms after Cmd-V is far more likely a clipboard manager than
    /// the target. We can't tell, so we don't shorten the target's window —
    /// the grace stretches so the restore still lands no earlier than the floor.
    @Test("Implausibly early read: grace stretches to the floor")
    func graceStretchesForEarlyRead() {
        let delay = PasteRestoreGuards.readGraceDelay(
            readGrace: .milliseconds(20),
            sinceArm: .milliseconds(2),
            minimumRestoreDelay: .milliseconds(120)
        )
        #expect(delay == .milliseconds(118)) // 2 + 118 = 120 ms after arming
    }

    @Test("Late read never shortens the grace below the read grace")
    func graceNeverShrinks() {
        let delay = PasteRestoreGuards.readGraceDelay(
            readGrace: .milliseconds(100),
            sinceArm: .milliseconds(480),
            minimumRestoreDelay: .milliseconds(120)
        )
        #expect(delay == .milliseconds(100))
    }

    /// The assumption the whole changeCount guard rests on: fulfilling our lazy
    /// promise must NOT look like a foreign write, or every restore would be
    /// skipped and the user's clipboard would stay displaced forever.
    @Test("Fulfilling a lazy promise does not bump changeCount")
    @MainActor
    func promiseFulfillmentDoesNotBumpChangeCount() {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.jjromano.skylark.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let provider = CountingProvider(text: "promised")
        let item = NSPasteboardItem()
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setDataProvider(provider, forTypes: [.string])
        pb.clearContents()
        pb.writeObjects([item])

        let afterWrite = pb.changeCount
        #expect(pb.string(forType: .string) == "promised")
        #expect(provider.reads >= 1)
        #expect(pb.changeCount == afterWrite)
        #expect(PasteRestoreGuards.restoreIsSafe(expectedChangeCount: afterWrite, currentChangeCount: pb.changeCount))

        // And the contrast: a real foreign write DOES move it.
        pb.clearContents()
        pb.setString("the user's own Cmd-C", forType: .string)
        #expect(!PasteRestoreGuards.restoreIsSafe(expectedChangeCount: afterWrite, currentChangeCount: pb.changeCount))
    }
}

/// Stands in for `LazyTranscriptProvider` (internal) to pin the AppKit behaviour.
private final class CountingProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private(set) var reads = 0

    init(text: String) {
        self.text = text
        super.init()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        reads += 1
        item.setString(text, forType: type)
    }
}
