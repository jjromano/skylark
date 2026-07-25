import AppKit
import Foundation
import os

// Adapted from Handy (MIT), PR #1770 (lazy pasteboard data provider): the
// transcript is written to the pasteboard as a PROMISE served by an
// `NSPasteboardItem` data provider, so the moment the target app actually READS
// the clipboard we get a callback — that read is the signal that Cmd-V consumed
// our text and the user's clipboard can go back. The old blind 500 ms timer both
// raced slow apps (restore landed before the read → the app pasted the user's
// OLD clipboard) and held the user's clipboard hostage for half a second when the
// target read in 20 ms. The timer survives only as a ceiling for targets that
// never read at all.

/// Pure decision logic for "when do we put the user's clipboard back?".
///
/// No AppKit, no clock, no I/O — the coordinator below feeds it events and
/// performs the returned action, so every transition is unit-tested directly.
///
/// Phases: `unarmed` (written, Cmd-V not yet posted) → `armed` (posted; reads
/// from here on are the target consuming our text) → `awaitingGrace` (first read
/// seen; short grace covers apps that read twice) → `restored` (terminal).
public struct PasteRestoreDecider: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// Cmd-V has been posted. Reads after this point are the paste.
        case armed
        /// The pasteboard asked us for the promised data (someone read it).
        case pasteboardRead
        /// The post-read grace elapsed.
        case readGraceElapsed
        /// The fallback ceiling elapsed (target never read).
        case fallbackElapsed
        /// Another paste is starting, or the injector is flushing — restore now.
        case superseded
    }

    public enum Action: Sendable, Equatable {
        case ignore
        /// Start the short grace timer, then send `.readGraceElapsed`.
        case startReadGrace
        /// Put the snapshot back (exactly once per paste).
        case restore
    }

    public enum Phase: Sendable, Equatable {
        case unarmed
        case armed
        case awaitingGrace
        case restored
    }

    public private(set) var phase: Phase = .unarmed

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch phase {
        case .restored:
            // Terminal: restore happens exactly once, so late reads, a late
            // fallback tick, or a double supersede are all no-ops.
            return .ignore

        case .unarmed:
            switch event {
            case .armed:
                phase = .armed
                return .ignore
            case .superseded:
                phase = .restored
                return .restore
            case .pasteboardRead:
                // A read BEFORE the keystroke is not the target pasting — it's a
                // clipboard manager (Maccy/Paste/Alfred) or a metadata scan
                // reacting to the write. Ignoring it degrades at worst to the
                // fallback ceiling; honouring it would restore before the paste
                // and make the target paste the user's OLD clipboard.
                return .ignore
            case .readGraceElapsed, .fallbackElapsed:
                return .ignore
            }

        case .armed:
            switch event {
            case .pasteboardRead:
                phase = .awaitingGrace
                return .startReadGrace
            case .fallbackElapsed:
                // Nobody ever read it (focus died, app ignored the paste): the
                // clipboard still has to go back.
                phase = .restored
                return .restore
            case .superseded:
                phase = .restored
                return .restore
            case .armed, .readGraceElapsed:
                return .ignore
            }

        case .awaitingGrace:
            switch event {
            case .pasteboardRead:
                // Verified behaviour: the pasteboard server caches the data once
                // the promise is fulfilled, so only the FIRST read reaches the
                // provider — a second read (Electron/Chromium targets read again
                // for other flavours, or retry) is served from that cache, or
                // from the RESTORED clipboard if we've already put it back. That
                // is what the grace buys, and why a re-read never re-triggers.
                return .ignore
            case .readGraceElapsed:
                phase = .restored
                return .restore
            case .fallbackElapsed:
                // Read landed right at the ceiling. Restoring slightly early
                // beats risking a clipboard that never comes back.
                phase = .restored
                return .restore
            case .superseded:
                phase = .restored
                return .restore
            case .armed:
                return .ignore
            }
        }
    }
}

/// Serves the transcript to the pasteboard on demand and reports the read.
///
/// `NSPasteboardItemDataProvider` is declared `NS_SWIFT_NONISOLATED`: AppKit
/// calls this on an arbitrary thread. So the callback does the minimum — hand
/// over the data synchronously (that's the promise contract; blocking here
/// blocks the *pasting* app) and hop the signal to the main actor.
final class LazyTranscriptProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    /// Held only in memory for the few ms the promise is live; never logged.
    private let text: String
    private let onRead: @Sendable () -> Void

    init(text: String, onRead: @escaping @Sendable () -> Void) {
        self.text = text
        self.onRead = onRead
        super.init()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(text, forType: type)
        onRead()
    }
}

/// Owns one synthesized paste's clipboard lifecycle: writes the promise item,
/// arms the read signal after Cmd-V is posted, and restores the snapshot exactly
/// once — on first read (+ grace), on the fallback ceiling, or when superseded.
///
/// Main-actor isolated: every pasteboard mutation and the decider live here, and
/// the provider's arbitrary-thread callback hops in.
@MainActor
final class PasteRestoreCoordinator {
    /// Clipboard managers that honour this marker keep the transcript out of
    /// their history — it is only here to be pasted and is restored moments later.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Released the moment it is put back: the user's clipboard can be megabytes
    /// (images), and the injector keeps this coordinator around until the next
    /// paste. nil = already restored.
    private var snapshot: PasteboardSnapshot?
    private let pasteboard: NSPasteboard
    private let readGrace: Duration
    private let fallback: Duration
    private let logger: Logger

    private var decider = PasteRestoreDecider()
    /// Strong ref: `NSPasteboardItem` does NOT retain its data provider, so if
    /// this died the promise would break and the target would paste nothing.
    private var provider: LazyTranscriptProvider?
    private var armedAt: ContinuousClock.Instant?
    private var readCount = 0
    private var fallbackTask: Task<Void, Never>?

    init(
        snapshot: PasteboardSnapshot,
        pasteboard: NSPasteboard,
        readGrace: Duration,
        fallback: Duration,
        logger: Logger
    ) {
        self.snapshot = snapshot
        self.pasteboard = pasteboard
        self.readGrace = readGrace
        self.fallback = fallback
        self.logger = logger
    }

    /// The item to write: markers eagerly (a clipboard manager can see them
    /// without triggering our read signal), the text lazily.
    func makeItem(text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: Self.transientType)
        let provider = LazyTranscriptProvider(text: text) { [weak self] in
            // Arbitrary thread → main actor. Nothing blocks the callback.
            Task { @MainActor in self?.pasteboardWasRead() }
        }
        self.provider = provider
        item.setDataProvider(provider, forTypes: [.string])
        return item
    }

    /// Cmd-V has been posted: reads from now on mean the target consumed the
    /// text. Also starts the fallback ceiling for targets that never read.
    func arm() {
        armedAt = ContinuousClock.now
        apply(decider.handle(.armed), trigger: "armed")
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.fallback)
            self.apply(self.decider.handle(.fallbackElapsed), trigger: "fallback")
        }
    }

    /// Restore now (a new paste is starting, or we're flushing a stale promise).
    func supersede() {
        apply(decider.handle(.superseded), trigger: "superseded")
    }

    private func pasteboardWasRead() {
        readCount += 1
        apply(decider.handle(.pasteboardRead), trigger: "read")
    }

    private func apply(_ action: PasteRestoreDecider.Action, trigger: StaticString) {
        switch action {
        case .ignore:
            return
        case .startReadGrace:
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.readGrace)
                self.apply(self.decider.handle(.readGraceElapsed), trigger: "read")
            }
        case .restore:
            restore(trigger: trigger)
        }
    }

    private func restore(trigger: StaticString) {
        fallbackTask?.cancel()
        fallbackTask = nil
        provider = nil
        snapshot?.restore(to: pasteboard)
        snapshot = nil
        // Content-free diagnostics (info level so it reaches the diagnostics
        // export): how the restore was triggered, how long the user's clipboard
        // was displaced, how many reads the target made.
        let afterMs = armedAt.map { Self.milliseconds($0.duration(to: ContinuousClock.now)) } ?? 0
        logger.info("""
            clipboard restored: trigger=\(trigger, privacy: .public) \
            after-ms=\(afterMs, format: .fixed(precision: 1), privacy: .public) \
            reads=\(self.readCount, privacy: .public)
            """)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
