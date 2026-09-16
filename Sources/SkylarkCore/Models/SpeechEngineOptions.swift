import Foundation

/// What the Speech Engine pickers (menu bar and Settings) offer right now.
///
/// Pure, so the whole availability matrix (keys present or not, local models
/// downloaded or not) is unit-tested instead of discovered by a user opening a
/// menu full of engines that cannot run. Rules:
/// - An on-device engine is offered once it is on disk, and always while it is
///   the current selection, so the menu never loses its checkmark.
/// - Groq direct is offered only with a Groq key. It is optional and most users
///   never add one, so without a key it leaves no trace.
/// - OpenRouter models are offered only with an OpenRouter key. Without one the
///   pickers show a single "add key" affordance instead (`needsOpenRouterKey`),
///   because OpenRouter is where nearly every cloud model lives.
public struct SpeechEngineOptions: Sendable, Equatable {
    public let onDevice: [STTChoice]
    public let groqDirect: Bool
    public let openRouter: [ModelRegistryEntry]
    public let needsOpenRouterKey: Bool

    public init(
        current: STTChoice,
        parakeetAvailable: Bool,
        whisperAvailable: Bool,
        appleSpeechAvailable: Bool,
        hasGroqKey: Bool,
        hasOpenRouterKey: Bool,
        cloudModels: [ModelRegistryEntry]
    ) {
        let local: [(STTChoice, Bool)] = [
            (.localParakeet, parakeetAvailable),
            (.localWhisper, whisperAvailable),
            (.localApple, appleSpeechAvailable),
        ]
        onDevice = local.filter { choice, available in available || choice == current }.map(\.0)
        groqDirect = hasGroqKey
        openRouter = hasOpenRouterKey ? cloudModels.filter { $0.kind == .stt } : []
        needsOpenRouterKey = !hasOpenRouterKey
    }

    /// Row label for an on-device engine. The section header already says
    /// "On this Mac", so the row names only the model.
    public static func onDeviceLabel(_ choice: STTChoice) -> String {
        switch choice {
        case .localWhisper: return "Whisper large-v3-turbo"
        case .localApple: return "Apple Speech (macOS)"
        default: return "Parakeet"
        }
    }
}
