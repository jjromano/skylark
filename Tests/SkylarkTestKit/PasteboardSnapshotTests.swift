import AppKit
import Testing
import SkylarkCore

@Suite("PasteboardSnapshot round-trip", .serialized)
@MainActor
struct PasteboardSnapshotTests {
    /// PRD §10 clipboard test: a multi-type pasteboard survives snapshot →
    /// (mutate) → restore byte-for-byte, on the app's own named pasteboard.
    @Test("Multi-type snapshot restores byte-for-byte")
    func multiTypeRoundTrip() {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.jjromano.skylark.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let string = "Hello, clipboard"
        let rtf = "{\\rtf1\\ansi Rich text}".data(using: .utf8)!
        let customType = NSPasteboard.PasteboardType("com.jjromano.skylark.custom")
        let customData = Data([0x00, 0x01, 0xFE, 0xFF, 0x42])

        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(rtf, forType: .rtf)
        item.setData(customData, forType: customType)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot(pasteboard: pb)

        // Clobber the pasteboard with unrelated content.
        pb.clearContents()
        pb.setString("junk that must be gone", forType: .string)

        // Restore.
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == string)
        #expect(pb.data(forType: .rtf) == rtf)
        #expect(pb.data(forType: customType) == customData)
    }

    @Test("Snapshot captures every type present")
    func snapshotCapturesAllTypes() {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.jjromano.skylark.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let item = NSPasteboardItem()
        item.setString("a", forType: .string)
        item.setString("<b>a</b>", forType: .html)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        #expect(snapshot.items.count == 1)
        let types = Set(snapshot.items[0].map(\.type))
        #expect(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        #expect(types.contains(NSPasteboard.PasteboardType.html.rawValue))
    }

    /// D7: restore must reproduce the exact type DECLARATION ORDER, not just
    /// the bytes — a receiving app picks its preferred representation by
    /// `NSPasteboardItem.types` order, so a shuffled order (e.g. dictionary
    /// iteration order) is a real behavior difference even when bytes match.
    @Test("Restore preserves declared type order")
    func restorePreservesTypeOrder() {
        let pb = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        defer { pb.releaseGlobally() }

        let typeA = NSPasteboard.PasteboardType("com.jjromano.skylark.test.a")
        let typeB = NSPasteboard.PasteboardType("com.jjromano.skylark.test.b")
        let typeC = NSPasteboard.PasteboardType("com.jjromano.skylark.test.c")
        let dataA = Data([0x01])
        let dataB = Data([0x02])
        let dataC = Data([0x03])

        let item = NSPasteboardItem()
        item.setData(dataA, forType: typeA)
        item.setData(dataB, forType: typeB)
        item.setData(dataC, forType: typeC)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot(pasteboard: pb)

        let fresh = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        defer { fresh.releaseGlobally() }
        snapshot.restore(to: fresh)

        let restoredItem = fresh.pasteboardItems?[0]
        #expect(restoredItem?.types == [typeA, typeB, typeC])
        #expect(restoredItem?.data(forType: typeA) == dataA)
        #expect(restoredItem?.data(forType: typeB) == dataB)
        #expect(restoredItem?.data(forType: typeC) == dataC)
    }
}
