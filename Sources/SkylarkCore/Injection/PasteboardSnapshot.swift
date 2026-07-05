import AppKit
import Foundation

// Adapted from Hex (MIT): Clients/PasteboardClient.swift (snapshot/restore).

/// A byte-for-byte snapshot of every item and type on a pasteboard, so the
/// clipboard can be restored after a synthesized paste (privacy invariant:
/// clipboard preserved byte-for-byte across paste fallback, PRD §10).
public struct PasteboardSnapshot: Sendable, Equatable {
    /// One dictionary per pasteboard item: raw type string → data.
    public let items: [[String: Data]]

    public init(items: [[String: Data]]) {
        self.items = items
    }

    @MainActor
    public init(pasteboard: NSPasteboard) {
        var saved: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var itemDict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemDict[type.rawValue] = data
                }
            }
            saved.append(itemDict)
        }
        items = saved
    }

    @MainActor
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        var pbItems: [NSPasteboardItem] = []
        for itemDict in items {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
            }
            pbItems.append(item)
        }
        pasteboard.writeObjects(pbItems)
    }
}
