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

    /// `~/Library/Application Support/Skylark/Audio` — retained-audio WAV files
    /// (phase-5a spec §2, opt-in, default off). Only ever written to when the
    /// user has turned on history-audio retention.
    public static var audioDirectory: URL {
        appSupport.appendingPathComponent("Audio", isDirectory: true)
    }

    /// Ensure the audio directory exists; ignore if it already does.
    public static func ensureAudioDirectory() {
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Per-engine model directories

    /// FluidAudio Parakeet TDT v3 repo folder. FluidAudio's v3 `folderName`
    /// strips the repo's `-coreml` suffix and resolves against the PARENT of
    /// the base we pass, so the repo lands beside `Models`, not inside it
    /// (verified on disk against 0.15.x downloads).
    public static var parakeetModelDir: URL {
        appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// FluidAudio Silero VAD repo folder (`VadManager` appends `Models/` to the
    /// app-support base; the repo folder drops the `-coreml` suffix — verified
    /// on disk).
    public static var vadModelDir: URL {
        models.appendingPathComponent("silero-vad", isDirectory: true)
    }

    /// WhisperKit download base — passed to WhisperKit as `downloadBase` so its
    /// HubApi cache lands here instead of the default `Documents/huggingface`.
    /// WhisperKit nests the model under `models/argmaxinc/whisperkit-coreml/<variant>`.
    public static var whisperKitBase: URL {
        models.appendingPathComponent("whisperkit", isDirectory: true)
    }

    // MARK: - On-disk size / removal (model manager)

    /// Total size on disk (bytes) of everything under `url`, or 0 if absent.
    /// Walks the directory; cheap enough for the settings model manager (not on
    /// any latency path). Never inspects file contents.
    public static func installedSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Whether a model directory is present and non-empty.
    public static func isPresent(at url: URL) -> Bool {
        installedSize(at: url) > 0
    }

    /// Delete a model directory from disk. Idempotent; throws only on a real
    /// filesystem error (a missing directory is a no-op).
    public static func removeFromDisk(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }
}
