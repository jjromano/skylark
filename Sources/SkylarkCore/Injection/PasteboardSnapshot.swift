import AppKit
import Foundation
import os

// Adapted from Hex (MIT): Clients/PasteboardClient.swift (snapshot/restore).

/// A byte-for-byte snapshot of every item and type on a pasteboard, so the
/// clipboard can be restored after a synthesized paste (privacy invariant:
/// clipboard preserved byte-for-byte across paste fallback, PRD §10).
public struct PasteboardSnapshot: Sendable, Equatable {
    /// One dictionary per pasteboard item: raw type string → data.
    public let items: [[String: Data]]

    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "pasteboard")

    public init(items: [[String: Data]]) {
        self.items = items
    }

    /// `NSPasteboard.accessBehavior` (macOS 15.4+, always present at our
    /// macOS 26 deployment target) reports the user's per-app pasteboard
    /// access setting: `.default`/`.ask` prompt or silently allow depending
    /// on system state, `.alwaysAllow` never prompts, `.alwaysDeny` silently
    /// denies every programmatic read. When it's `.alwaysDeny`, macOS is
    /// going to hand back nothing for every `item.data(forType:)` call below
    /// anyway (silently, per the header — it never raises a user-facing
    /// alert on its own), so we skip the per-item read loop entirely and
    /// produce an empty snapshot: same effective result, no wasted work on
    /// the paste path, and one content-free log line explaining why the
    /// snapshot is empty instead of a silent no-op. This is a plain
    /// synchronous property read — not `detectPatterns`/`detectValues`,
    /// which are async and have no place on this synchronous snapshot path.
    @MainActor
    public init(pasteboard: NSPasteboard) {
        if pasteboard.accessBehavior == .alwaysDeny {
            Self.logger.notice("Pasteboard access is set to Always Deny for this app; snapshotting an empty clipboard")
            items = []
            return
        }
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
