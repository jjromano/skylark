import Foundation

/// Which on-device model serves the LOCAL cleanup tier.
///
/// Apple's Foundation Models stays the DEFAULT — the llama.cpp/Qwen engines are
/// opt-in, need a ~1–2.5 GB download, and cost more memory. The user's choice is
/// persisted as a plain string (`defaultsKey`) so the Settings picker and the
/// composition root agree on one representation.
public enum LocalCleanupEngine: Sendable, Equatable, Hashable {
    /// Apple on-device Foundation Models (default; no download).
    case appleFoundationModels
    /// A local GGUF run through llama.cpp, identified by `LocalCleanupModel.id`.
    case llama(modelID: String)

    /// UserDefaults key holding the persisted choice.
    public static let defaultsKey = "localCleanupEngine"

    /// Value persisted in UserDefaults. `"apple"` for the default; otherwise
    /// `"llama:<model id>"`.
    public var persistedValue: String {
        switch self {
        case .appleFoundationModels: return "apple"
        case .llama(let modelID): return "llama:\(modelID)"
        }
    }

    public init(persistedValue: String?) {
        guard let persistedValue, persistedValue.hasPrefix("llama:") else {
            self = .appleFoundationModels
            return
        }
        self = .llama(modelID: String(persistedValue.dropFirst("llama:".count)))
    }

    /// The model backing a `.llama` choice, or nil for Apple / an unknown id.
    public var model: LocalCleanupModel? {
        guard case .llama(let modelID) = self else { return nil }
        return LocalCleanupModel.model(id: modelID)
    }

    /// GATING: a `.llama` choice only stands when its GGUF is actually on disk
    /// (and is a model this build knows). Anything else resolves to Apple, so a
    /// deleted or half-downloaded model silently keeps cleanup working instead of
    /// failing every dictation.
    public var resolved: LocalCleanupEngine {
        guard let model, model.isInstalled else { return .appleFoundationModels }
        return .llama(modelID: model.id)
    }

    /// Read the persisted choice and apply the on-disk gate.
    public static func resolvedFromDefaults(
        _ defaults: UserDefaults = .standard
    ) -> LocalCleanupEngine {
        LocalCleanupEngine(persistedValue: defaults.string(forKey: defaultsKey)).resolved
    }

    /// Build the backend for this (already resolved) choice.
    public func makeBackend() -> any LocalCleanupBackend {
        switch resolved {
        case .appleFoundationModels:
            return LocalCleaner.makeDefaultBackend()
        case .llama(let modelID):
            guard let model = LocalCleanupModel.model(id: modelID) else {
                return LocalCleaner.makeDefaultBackend()
            }
            return QwenCleanupBackend(model: model)
        }
    }
}

public extension CleanerRegistry {
    /// The local-tier cleaner for the user's engine choice — the value to pass as
    /// `CleanerRegistry(local:)`. Falls back to Apple Foundation Models whenever
    /// the chosen GGUF isn't installed, which is also the behavior for a fresh
    /// install (nothing downloaded, Apple is the default).
    static func localCleaner(engine: LocalCleanupEngine = .resolvedFromDefaults()) -> LocalCleaner {
        LocalCleaner(backend: engine.makeBackend())
    }
}
