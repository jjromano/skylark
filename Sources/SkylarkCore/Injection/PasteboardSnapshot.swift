import AppKit
import Foundation
import os

// Adapted from Hex (MIT): Clients/PasteboardClient.swift (snapshot/restore).

/// A byte-for-byte snapshot of every item and type on a pasteboard, so the
/// clipboard can be restored after a synthesized paste (privacy invariant:
/// clipboard preserved byte-for-byte across paste fallback, PRD §10).
public struct PasteboardSnapshot: Sendable, Equatable {
    /// One (type, data) pair captured from a pasteboard item, in the order the
    /// item declared its types. Order matters: a receiving app that supports
    /// several of the declared types picks its preferred representation by
    /// declaration order (`NSPasteboardItem.types` / `setData(_:forType:)`
    /// docs), so a restore must reproduce it exactly, not just the byte content.
    public struct Entry: Sendable, Equatable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    /// One ordered list of entries per pasteboard item, in `item.types` order.
    public let items: [[Entry]]

    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "pasteboard")

    public init(items: [[Entry]]) {
        self.items = items
    }

    /// Convenience initializer from unordered dictionaries — dictionary
    /// iteration order is not the original declaration order, so this exists
    /// only for callers (tests) that don't care about order preservation.
    public init(items: [[String: Data]]) {
        self.items = items.map { dict in dict.map { Entry(type: $0.key, data: $0.value) } }
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
        var saved: [[Entry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [Entry] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append(Entry(type: type.rawValue, data: data))
                }
            }
            saved.append(entries)
        }
        items = saved
    }

    @MainActor
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        var pbItems: [NSPasteboardItem] = []
        for entries in items {
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(rawValue: entry.type))
            }
            pbItems.append(item)
        }
        pasteboard.writeObjects(pbItems)
    }
}
