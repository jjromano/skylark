import Foundation

// Companion to CorrectionWatcher.swift's auto-learn engine: once a word is
// learned, the HUD pill shows a transient notice with an Undo. This file is
// the pure, fully-testable state machine (combining, the 5 s auto-dismiss,
// Undo's delete + revert-phase linger) — off an injectable `WatchClock` so
// tests never sleep for real. The SwiftUI-facing `HUDModel`/`HUDView`
// (Sources/Skylark/HUD) just mirror `LearnedBannerController.banner` and
// render it; they own no state-machine logic of their own.

/// A transient notice the HUD shows when auto-learn adds a dictionary word,
/// with an Undo. Multiple learns from the same utterance (the auto-learn cap
/// is 2 — see CorrectionWatcher) are combined into one banner rather than
/// queued, so at most one banner is ever on screen at a time.
public struct LearnedBanner: Sendable, Equatable {
    /// One learned word plus the dictionary row id Undo needs to delete.
    public struct Entry: Sendable, Equatable {
        public let word: String
        public let entryID: Int64

        public init(word: String, entryID: Int64) {
            self.word = word
            self.entryID = entryID
        }
    }

    public enum Phase: Sendable, Equatable {
        /// Just learned; Undo is live.
        case learned
        /// Undo was pressed and the entries were removed; a short linger
        /// before the banner clears so the user sees it took effect.
        case reverted
    }

    public var entries: [Entry]
    public var phase: Phase

    public init(entries: [Entry], phase: Phase = .learned) {
        self.entries = entries
        self.phase = phase
    }

    /// `Learned "word"`, or combined: `Learned "A", "B"`.
    public var learnedText: String {
        "Learned \(quotedWords)"
    }

    /// `Removed "word"` — shown briefly after Undo.
    public var revertedText: String {
        "Removed \(quotedWords)"
    }

    private var quotedWords: String {
        entries.map { "\u{201C}\($0.word)\u{201D}" }.joined(separator: ", ")
    }
}

/// Owns the learned-banner's full lifecycle: combining new learns, timing the
/// 5 s auto-dismiss and the post-Undo "Removed" linger off an injectable
/// clock, and delegating the actual delete to a Sendable closure.
///
/// `@MainActor` (not an `actor`) so `HUDModel` — also main-actor — can read
/// `banner` synchronously for SwiftUI's `@Observable` machinery, but this
/// type itself has no SwiftUI/AppKit dependency and is fully testable with a
/// fake `WatchClock` and delete closure.
@MainActor
public final class LearnedBannerController {
    public static let autoDismiss = Duration.seconds(5)
    public static let revertedLinger = Duration.milliseconds(1500)

    /// Current banner, if any. `didSet` fires `onChange` so a UI-layer owner
    /// (e.g. `HUDModel`) can mirror it into its own `@Observable` property.
    public private(set) var banner: LearnedBanner? {
        didSet { onChange?(banner) }
    }

    /// Fired on every `banner` transition (show, combine, revert, dismiss).
    public var onChange: (@MainActor (LearnedBanner?) -> Void)?

    private let clock: any WatchClock
    /// Deletes one dictionary entry; reports whether a row actually existed
    /// to delete (`false` if it was already gone — e.g. the user deleted it
    /// in Settings while the banner was showing). Settable (not just
    /// init-only) because `HUDModel` is constructed before its owner knows
    /// whether persistence is available.
    public var delete: @Sendable (Int64) async -> Bool

    private var task: Task<Void, Never>?

    public init(
        clock: any WatchClock = RealWatchClock(),
        delete: @escaping @Sendable (Int64) async -> Bool = { _ in false }
    ) {
        self.clock = clock
        self.delete = delete
    }

    /// A new word was learned. Folds into the current banner if one is still
    /// in `.learned` phase (combine, not queue); otherwise starts fresh — a
    /// banner mid-`.reverted` linger is about to dismiss anyway, so a new
    /// learn always starts over rather than combining with it. Always
    /// (re)starts the 5 s auto-dismiss.
    public func learned(word: String, entryID: Int64) {
        let entry = LearnedBanner.Entry(word: word, entryID: entryID)
        if var current = banner, current.phase == .learned {
            current.entries.append(entry)
            banner = current
        } else {
            banner = LearnedBanner(entries: [entry])
        }
        task?.cancel()
        task = Task { [clock] in
            guard await clock.sleep(for: Self.autoDismiss) else { return }
            guard !Task.isCancelled else { return }
            self.banner = nil
        }
    }

    /// Undo: delete every entry the current banner is showing. If none of
    /// them actually existed (already deleted elsewhere), dismiss quietly;
    /// otherwise flip to `.reverted` for a short linger, then dismiss.
    /// A no-op if nothing is showing or it's already mid-revert.
    public func undo() {
        guard let current = banner, current.phase == .learned else { return }
        task?.cancel()
        let entries = current.entries
        task = Task { [delete, clock] in
            var anyDeleted = false
            for entry in entries {
                if await delete(entry.entryID) { anyDeleted = true }
            }
            guard !Task.isCancelled else { return }
            guard anyDeleted else {
                self.banner = nil
                return
            }
            self.banner = LearnedBanner(entries: entries, phase: .reverted)
            guard await clock.sleep(for: Self.revertedLinger) else { return }
            guard !Task.isCancelled else { return }
            self.banner = nil
        }
    }

    /// Dismiss immediately — e.g. a new dictation starting shouldn't compete
    /// with the banner for the user's attention on the pill.
    public func dismiss() {
        task?.cancel()
        banner = nil
    }
}
