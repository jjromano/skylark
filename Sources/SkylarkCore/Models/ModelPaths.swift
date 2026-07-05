import Foundation

/// Where Skylark keeps downloaded CoreML models. Shared by every local engine
/// (Parakeet ASR, Silero VAD) so all model state lives under one directory the
/// user can inspect or delete. Never travels between git worktrees (gitignored
/// runtime state, per CLAUDE.md).
public enum ModelPaths {
    /// `~/Library/Application Support/Skylark`.
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Skylark", isDirectory: true)
    }

    /// `~/Library/Application Support/Skylark/Models` — the base directory passed
    /// to FluidAudio's loaders (ASR downloads its repo folder beneath this; VAD
    /// appends its own `Models` subfolder from this base).
    public static var models: URL {
        appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// Ensure the models directory exists; ignore if it already does.
    public static func ensureModelsDirectory() {
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    }
}
