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
        let types = Set(snapshot.items[0].keys)
        #expect(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        #expect(types.contains(NSPasteboard.PasteboardType.html.rawValue))
    }
}
