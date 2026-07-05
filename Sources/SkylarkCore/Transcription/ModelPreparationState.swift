import Foundation

/// Progress of a local model's one-time preparation (download + compile + load).
/// Reported by `FluidAudioParakeet.warmUp` through an injected callback so the
/// UI can show a menu-bar status line and a pulsing HUD dot while preparing.
///
/// Deviation from the spec's `.failed(Error)`: the failure carries the error's
/// localized message as a `String` so the whole enum stays `Sendable`/`Equatable`
/// and can cross into `@MainActor` UI. Never contains audio or transcript text.
public enum ModelPreparationState: Sendable, Equatable {
    case checking
    case downloading(progress: Double)
    case loading
    case ready
    case failed(message: String)

    /// True while preparation is still in flight (HUD shows the preparing dot).
    public var isPreparing: Bool {
        switch self {
        case .checking, .downloading, .loading: return true
        case .ready, .failed: return false
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
