import CryptoKit
import Foundation

/// Installs a freshly downloaded GGUF cleanup model: **validate while staged,
/// replace only on success**.
///
/// The order matters. Deleting the installed model first and validating the new
/// bytes afterwards means any short/corrupt transfer leaves the user with NO
/// local cleanup model at all (the pipeline silently degrades to Apple
/// Foundation Models or raw text, and the multi-GB download has to be repeated).
/// Here the incoming file is parked next to the final one, checked for length
/// and — when the model carries a pinned digest — SHA-256, and only then swapped
/// in. Every failure path deletes the staged file and leaves the previously
/// installed model exactly as it was.
///
/// Integrity is not paranoia here: a GGUF is parsed and executed as model
/// weights by llama.cpp, and the download is a plain HTTPS GET whose bytes we
/// otherwise never check.
public enum CleanupModelInstaller {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Fewer bytes than the model's published size — a truncated transfer.
        case shortFile(got: Int64, expected: Int64)
        /// Full length but the wrong bytes (corruption, or the pinned revision
        /// no longer serving what it served when the digest was recorded).
        case digestMismatch
        /// Staging/replacement failed (permissions, no space, …).
        case fileSystem(String)

        public var description: String {
            switch self {
            case .shortFile(let got, let expected):
                return "download was incomplete (\(got)/\(expected) bytes)"
            case .digestMismatch:
                return "download failed its integrity check — nothing was installed"
            case .fileSystem(let message):
                return message
            }
        }
    }

    /// Where an incoming file waits while it is verified. Deliberately in the
    /// model's own directory (same volume ⇒ the final swap is a rename, never a
    /// multi-GB copy) and dot-prefixed so a leftover never looks like a model.
    public static func stagingURL(for model: LocalCleanupModel) -> URL {
        model.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(model.fileName).incoming")
    }

    /// Move `downloaded` into staging, verify it, then atomically replace the
    /// installed model. Throws `Failure` (leaving the old model intact) if the
    /// bytes don't check out.
    ///
    /// `onVerifying` fires once the file is staged and hashing is about to
    /// start — hashing gigabytes takes a beat, so the UI can say so. Runs on the
    /// caller's thread; this whole call is synchronous and belongs on a
    /// background queue (never the paste path — it's a Settings action).
    public static func install(
        downloaded: URL,
        as model: LocalCleanupModel,
        onVerifying: () -> Void = {}
    ) throws {
        let staging = stagingURL(for: model)
        let fm = FileManager.default
        try? fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: staging) // a leftover from an earlier crash

        do {
            try fm.moveItem(at: downloaded, to: staging)
        } catch {
            throw Failure.fileSystem(error.localizedDescription)
        }

        do {
            let size = (try? fm.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? 0
            guard size >= model.downloadBytes else {
                throw Failure.shortFile(got: size, expected: model.downloadBytes)
            }
            if let expected = model.sha256 {
                onVerifying()
                guard try digest(of: staging).caseInsensitiveCompare(expected) == .orderedSame else {
                    throw Failure.digestMismatch
                }
            }
            try swapIn(staging: staging, final: model.fileURL)
        } catch {
            try? fm.removeItem(at: staging)
            throw (error as? Failure) ?? Failure.fileSystem(error.localizedDescription)
        }
    }

    /// Atomic-as-the-filesystem-allows install: `replaceItemAt` when something is
    /// already there (it swaps and only then unlinks the old inode, so a reader
    /// mid-load keeps the file it opened), a plain rename when nothing is.
    private static func swapIn(staging: URL, final: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: final.path) {
                _ = try fm.replaceItemAt(final, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: final)
            }
        } catch {
            throw Failure.fileSystem(error.localizedDescription)
        }
    }

    /// Streaming SHA-256 (lowercase hex) so a 2.5 GB GGUF never lands in memory.
    private static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
