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

/// Pure guards around the restore WRITE itself (the decider above only answers
/// "when"; these answer "is it still safe, and how long must we hold off?").
/// Kept free of AppKit so both are unit-tested directly.
public enum PasteRestoreGuards: Sendable {
    /// True when the pasteboard still holds exactly what Skylark put there, so
    /// putting the user's snapshot back destroys nothing.
    ///
    /// `expected` is the `changeCount` produced by our own write; `current` is
    /// the value at restore time. Any difference means somebody else owns the
    /// clipboard now — most commonly the user hitting Cmd-C during the ~120 ms
    /// restore window — and their copy must win. Restoring on top of it would
    /// silently eat the thing they just copied (P1-1, confirmed live 4/4).
    ///
    /// Fulfilling our lazy promise does NOT bump `changeCount` (the provider
    /// fills in a type that was already declared) — see
    /// `PasteRestoreGuardTests.promiseFulfillmentDoesNotBumpChangeCount`, which
    /// pins that assumption, because if it ever changed every restore would be
    /// skipped and the user's clipboard would stay displaced.
    public static func restoreIsSafe(expectedChangeCount: Int, currentChangeCount: Int) -> Bool {
        expectedChangeCount == currentChangeCount
    }

    /// How long to wait after the FIRST read before restoring.
    ///
    /// Normally the read grace (covers apps that read twice). The floor exists
    /// because the promise callback cannot tell us WHO read (see U2 note on
    /// `LazyTranscriptProvider`): a clipboard manager or Universal Clipboard
    /// reading a few ms after Cmd-V looks exactly like the target pasting, and
    /// restoring on that signal before the real target reads would make the
    /// target paste the user's OLD clipboard. Holding the restore until at least
    /// `minimumRestoreDelay` after arming keeps that window open for the target
    /// (observed real reads land ~15-40 ms after arm) at the cost of a few ms of
    /// extra clipboard displacement — and never at the cost of a false "the
    /// paste didn't land", which ignoring early reads would have caused.
    public static func readGraceDelay(
        readGrace: Duration,
        sinceArm: Duration,
        minimumRestoreDelay: Duration
    ) -> Duration {
        max(readGrace, max(.zero, minimumRestoreDelay - sinceArm))
    }
}

/// Serves the transcript to the pasteboard on demand and reports the read.
///
/// `NSPasteboardItemDataProvider` is declared `NS_SWIFT_NONISOLATED`: AppKit
/// calls this on an arbitrary thread. So the callback does the minimum — hand
/// over the data synchronously (that's the promise contract; blocking here
/// blocks the *pasting* app) and hop the signal to the main actor.
///
/// U2 (audit): the callback is ANONYMOUS — it carries the pasteboard, the item
/// and the type, and nothing whatsoever about the reader. There is no AppKit or
/// pasteboard-server API that names the reading process, so a clipboard manager
/// (Maccy/Paste/Alfred), a Universal Clipboard sync, or Spotlight indexing is
/// indistinguishable from the target consuming our Cmd-V. Three things bound the
/// damage instead of identifying the reader: the eager transient marker
/// (well-behaved managers skip transient content without reading it), the
/// unarmed-phase rule in the decider (reads before Cmd-V are never the paste),
/// and `PasteRestoreGuards.readGraceDelay`'s floor (a read accepted implausibly
/// early still can't restore before the target has had its window).
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

/// One-shot async answer to "did the target actually consume our paste?".
///
/// Posting Cmd-V proves nothing (P1-9): the events go to the HID tap and the
/// target may ignore them entirely. The pasteboard read is the only evidence we
/// get, and it arrives tens of ms AFTER `insert` has already returned — so the
/// injector hands the caller this handle instead of blocking the paste path on
/// it. Callers that need the truth (history, command-mode replace) await it;
/// callers that must be immediate (press-Return) don't. Resolution is
/// guaranteed: the coordinator resolves on read, on restore, and from `deinit`,
/// so an awaiting caller can never hang.
actor PasteLandingSignal {
    private var resolved: InsertionToken.PasteLanding?
    private var waiters: [CheckedContinuation<InsertionToken.PasteLanding, Never>] = []

    /// First writer wins: a later fallback/deinit can't downgrade a confirmed read.
    func resolve(_ landing: InsertionToken.PasteLanding) {
        guard resolved == nil else { return }
        resolved = landing
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: landing) }
    }

    func value() async -> InsertionToken.PasteLanding {
        if let resolved { return resolved }
        return await withCheckedContinuation { waiters.append($0) }
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

    /// Never restore earlier than this after arming, whoever the reader was
    /// (see `PasteRestoreGuards.readGraceDelay` and the U2 note above).
    static let minimumRestoreDelay: Duration = .milliseconds(120)

    /// Released the moment it is put back: the user's clipboard can be megabytes
    /// (images), and the injector keeps this coordinator around until the next
    /// paste. nil = already restored (or deliberately abandoned, P1-1).
    private var snapshot: PasteboardSnapshot?
    private let pasteboard: NSPasteboard
    private let readGrace: Duration
    private let fallback: Duration
    private let minimumRestoreDelay: Duration
    private let logger: Logger

    /// `nonisolated` so `deinit` can resolve it without touching main-actor state.
    nonisolated let landingSignal = PasteLandingSignal()

    private var decider = PasteRestoreDecider()
    /// Strong ref: `NSPasteboardItem` does NOT retain its data provider, so if
    /// this died the promise would break and the target would paste nothing.
    private var provider: LazyTranscriptProvider?
    private var armedAt: ContinuousClock.Instant?
    private var readCount = 0
    private var fallbackTask: Task<Void, Never>?
    /// The `changeCount` our own write produced. Restoring is only safe while the
    /// pasteboard still reads back this value (P1-1).
    private var writtenChangeCount: Int?
    /// True once a read was ACCEPTED as the paste (post-arm). Pre-arm reads are
    /// clipboard managers and prove nothing about the target.
    private var sawAcceptedRead = false

    init(
        snapshot: PasteboardSnapshot,
        pasteboard: NSPasteboard,
        readGrace: Duration,
        fallback: Duration,
        minimumRestoreDelay: Duration = PasteRestoreCoordinator.minimumRestoreDelay,
        logger: Logger
    ) {
        self.snapshot = snapshot
        self.pasteboard = pasteboard
        self.readGrace = readGrace
        self.fallback = fallback
        self.minimumRestoreDelay = minimumRestoreDelay
        self.logger = logger
    }

    /// Belt-and-braces: if this coordinator is torn down without ever restoring
    /// (the fallback task holds only a weak ref), anyone awaiting the landing
    /// would wait forever. Resolve conservatively — posted, never confirmed.
    deinit {
        let signal = landingSignal
        Task { await signal.resolve(.posted) }
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

    /// Record the `changeCount` our write left on the pasteboard. Call after the
    /// write has committed and before Cmd-V; the restore compares against it and
    /// stands down if anyone else has written since.
    func recordWrite(changeCount: Int) {
        writtenChangeCount = changeCount
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
            // The target consumed our text: that is the ONLY evidence the paste
            // landed, so publish it before waiting out the grace.
            sawAcceptedRead = true
            let signal = landingSignal
            Task { await signal.resolve(.readConfirmed) }
            let delay = PasteRestoreGuards.readGraceDelay(
                readGrace: readGrace,
                sinceArm: armedAt.map { $0.duration(to: ContinuousClock.now) } ?? .zero,
                minimumRestoreDelay: minimumRestoreDelay
            )
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: delay)
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
        // Final word on the landing: a read we accepted means it landed, no read
        // by the time we put the clipboard back means we never got evidence and
        // must say so (P1-9). Resolved before the restore write so a caller
        // awaiting the verdict isn't gated on a multi-megabyte clipboard copy.
        let signal = landingSignal
        Task { await signal.resolve(sawAcceptedRead ? .readConfirmed : .posted) }

        let afterMs = armedAt.map { Self.milliseconds($0.duration(to: ContinuousClock.now)) } ?? 0
        // P1-1: somebody else wrote to the pasteboard while our transcript sat on
        // it (the user hitting Cmd-C is the live-confirmed case). Their content is
        // what the clipboard means now — putting our pre-dictation snapshot back
        // would destroy the copy they just made. Stand down: drop the snapshot,
        // leave the pasteboard alone.
        if let expected = writtenChangeCount,
           !PasteRestoreGuards.restoreIsSafe(expectedChangeCount: expected, currentChangeCount: pasteboard.changeCount) {
            snapshot = nil
            logger.info("""
                clipboard restore skipped: another writer took the pasteboard \
                (trigger=\(trigger, privacy: .public) \
                after-ms=\(afterMs, format: .fixed(precision: 1), privacy: .public) \
                reads=\(self.readCount, privacy: .public))
                """)
            return
        }

        snapshot?.restore(to: pasteboard)
        snapshot = nil
        // Content-free diagnostics (info level so it reaches the diagnostics
        // export): how the restore was triggered, how long the user's clipboard
        // was displaced, how many reads the target made.
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
