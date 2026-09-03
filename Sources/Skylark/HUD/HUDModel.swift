import Foundation
import SkylarkCore
import SwiftUI

/// Recording-indicator style (Settings → General), à la Superwhisper's
/// Classic/Mini/None. Persisted by raw value.
enum HUDStyle: String, CaseIterable, Identifiable {
    case standard, minimal, hidden
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .minimal: return "Minimal"
        case .hidden: return "Hidden"
        }
    }
}

/// Observable snapshot the HUD SwiftUI view renders from.
@MainActor
@Observable
final class HUDModel {
    /// Number of waveform bars in the listening pill.
    static let barCount = 24

    var state: HUDState = .idle
    var isHovering = false
    /// Indicator style + whether the small idle pill stays visible between
    /// dictations. Both persisted by AppController.
    var style: HUDStyle = .standard
    var showIdlePill = true
    /// True while global Whisper Mode is on — the listening dot goes hollow as a
    /// subtle cue (phase-4 spec §5).
    var isWhisperMode = false
    /// True while the speech model is still downloading/loading — the idle dot
    /// pulses to signal "not ready yet".
    var isPreparing = false

    /// Interim live-transcription text to show in the listening pill (prototype,
    /// behind a default-off setting). nil the vast majority of the time. Set from
    /// the `.listening` HUD state; cleared when a recording ends.
    var preview: TranscriptPreview?

    /// The transient status note ("Mic interrupted — text may be incomplete",
    /// "No speech detected", …) mirrored from `AppController.statusNote` so the
    /// pill can show it where the user is actually looking. The menu-bar
    /// dropdown keeps rendering the same string; this is an additional surface.
    /// Rendered inside `HUDMetrics.noteSize`, never by growing the panel.
    var note: String?

    /// Whether the listening pill should render its preview text region.
    var hasPreview: Bool {
        if let preview, !preview.isEmpty { return true }
        return false
    }

    /// Whole seconds left before the 2-minute recording cap, or nil while
    /// there's plenty of headroom (the normal case). Read straight off the
    /// state — the orchestrator is the only writer, exactly like `level`.
    var capSecondsRemaining: Int? {
        guard case let .listening(_, _, remaining) = state, let remaining else { return nil }
        return max(0, Int(remaining.rounded(.up)))
    }

    /// Auto-learn notice ("Learned "word"" + Undo), mirrored from
    /// `bannerController` so SwiftUI observes it like any other stored
    /// property. Set via `noteLearned`; dismissed via `undoLearnedBanner` or
    /// `dismissLearnedBanner`. The state machine (combining, auto-dismiss,
    /// undo) lives in SkylarkCore's `LearnedBannerController` — testable
    /// there without SwiftUI.
    private(set) var learnedBanner: LearnedBanner?

    /// Fired whenever `learnedBanner` changes, so `HUDBannerPanelController`
    /// can grow/reposition/order its own panel in step.
    @ObservationIgnored var onLearnedBannerChange: (() -> Void)?

    @ObservationIgnored private let bannerController: LearnedBannerController

    /// Rolling window of recent RMS levels; newest is last. Newest bar enters
    /// from the trailing edge. Seeded flat so the idle placeholder never pops.
    private(set) var waveform: [Float] = Array(repeating: 0, count: HUDModel.barCount)

    var isRecording: Bool {
        switch state {
        case .listening, .commandListening: return true
        default: return false
        }
    }

    /// True while the active recording is a Voice Command Mode instruction (the
    /// pill renders a distinct tint + label).
    var isCommand: Bool {
        if case .commandListening = state { return true }
        return false
    }

    init(bannerController: LearnedBannerController = LearnedBannerController()) {
        self.bannerController = bannerController
        bannerController.onChange = { [weak self] banner in
            self?.learnedBanner = banner
            self?.onLearnedBannerChange?()
        }
    }

    /// Push a new level onto the waveform (FIFO, fixed width).
    func pushLevel(_ level: Float) {
        waveform.removeFirst()
        waveform.append(level)
    }

    /// Reset the waveform to flat (leaving a recording session).
    func resetWaveform() {
        waveform = Array(repeating: 0, count: Self.barCount)
    }

    /// Wires the actual dictionary delete Undo needs. Deferred until
    /// `AppController.start()` knows whether persistence is available (this
    /// model is constructed before that's known); before it's called, Undo
    /// harmlessly reports "already gone" and just dismisses.
    func configureAutoLearnDelete(_ delete: @escaping @Sendable (Int64) async -> Bool) {
        bannerController.delete = delete
    }

    /// A word was auto-learned; show (or fold into) the banner.
    func noteLearned(word: String, entryID: Int64) {
        bannerController.learned(word: word, entryID: entryID)
    }

    /// Undo tapped on the banner.
    func undoLearnedBanner() {
        bannerController.undo()
    }

    /// Dismiss early — used when a new dictation starts so the banner never
    /// competes with the listening pill for attention.
    func dismissLearnedBanner() {
        bannerController.dismiss()
    }
}
