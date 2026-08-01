import CryptoKit
import Foundation
import Testing
import SkylarkCore

/// Staged validation of a downloaded GGUF cleanup model. The invariant under
/// test: the model already on disk survives EVERY failure — a truncated or
/// corrupt transfer must never be able to leave the user with no local cleanup
/// model (the earlier code deleted the installed file first and validated
/// afterwards).
@Suite("Cleanup model installer — staged validation")
struct CleanupModelInstallerTests {
    /// A model rooted in a scratch directory, with a real digest for `bytes`.
    private func model(in directory: URL, bytes: Data, expectedSize: Int64? = nil, digest: String?) -> LocalCleanupModel {
        LocalCleanupModel(
            id: "test-model",
            displayName: "Test",
            fileName: "test.gguf",
            remoteURL: nil,
            downloadBytes: expectedSize ?? Int64(bytes.count),
            sha256: digest,
            suppressesThinking: false,
            directory: directory
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A complete, correctly-hashed download replaces the installed model")
    func goodDownloadInstalls() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("brand new weights".utf8)
        let target = model(in: dir, bytes: payload, digest: sha256(payload))
        try Data("old weights".utf8).write(to: target.fileURL)

        let incoming = dir.appendingPathComponent("download.tmp")
        try payload.write(to: incoming)
        try CleanupModelInstaller.install(downloaded: incoming, as: target)

        #expect(try Data(contentsOf: target.fileURL) == payload)
        #expect(!FileManager.default.fileExists(atPath: CleanupModelInstaller.stagingURL(for: target).path))
    }

    @Test("Installing with nothing already present still works")
    func installsOnEmptyDirectory() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("weights".utf8)
        let target = model(in: dir, bytes: payload, digest: sha256(payload))

        let incoming = dir.appendingPathComponent("download.tmp")
        try payload.write(to: incoming)
        try CleanupModelInstaller.install(downloaded: incoming, as: target)
        #expect(try Data(contentsOf: target.fileURL) == payload)
    }

    /// The regression: a short transfer used to delete the working model first.
    @Test("A truncated download fails and leaves the old model intact")
    func truncatedDownloadKeepsOldModel() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Data("old weights that still work".utf8)
        let truncated = Data("half".utf8)
        let target = model(in: dir, bytes: truncated, expectedSize: 4096, digest: nil)
        try old.write(to: target.fileURL)

        let incoming = dir.appendingPathComponent("download.tmp")
        try truncated.write(to: incoming)

        #expect(throws: CleanupModelInstaller.Failure.shortFile(got: 4, expected: 4096)) {
            try CleanupModelInstaller.install(downloaded: incoming, as: target)
        }
        #expect(try Data(contentsOf: target.fileURL) == old)
        #expect(!FileManager.default.fileExists(atPath: CleanupModelInstaller.stagingURL(for: target).path))
    }

    /// Full length, wrong bytes — a GGUF is executed as weights, so this must
    /// not be installed either.
    @Test("A digest mismatch fails and leaves the old model intact")
    func corruptDownloadKeepsOldModel() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Data("old weights that still work".utf8)
        let corrupt = Data("wrong bytes entirely!!".utf8)
        let target = model(in: dir, bytes: corrupt, digest: sha256(Data("the bytes we asked for".utf8)))
        try old.write(to: target.fileURL)

        let incoming = dir.appendingPathComponent("download.tmp")
        try corrupt.write(to: incoming)

        #expect(throws: CleanupModelInstaller.Failure.digestMismatch) {
            try CleanupModelInstaller.install(downloaded: incoming, as: target)
        }
        #expect(try Data(contentsOf: target.fileURL) == old)
        #expect(!FileManager.default.fileExists(atPath: CleanupModelInstaller.stagingURL(for: target).path))
    }

    /// A staging file left by an earlier crash must not block the next attempt.
    @Test("A leftover staging file is reclaimed, not fatal")
    func staleStagingFileIsReplaced() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("brand new weights".utf8)
        let target = model(in: dir, bytes: payload, digest: sha256(payload))
        try Data("junk from a crashed run".utf8).write(to: CleanupModelInstaller.stagingURL(for: target))

        let incoming = dir.appendingPathComponent("download.tmp")
        try payload.write(to: incoming)
        try CleanupModelInstaller.install(downloaded: incoming, as: target)
        #expect(try Data(contentsOf: target.fileURL) == payload)
    }

    /// Hashing only happens when there is a digest to check; the callback is the
    /// UI's cue that a multi-GB verify is under way.
    @Test("Verification is announced only for a model with a pinned digest")
    func verifyingCallbackFiresOnlyWhenPinned() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("weights".utf8)

        var announced = 0
        let pinned = model(in: dir, bytes: payload, digest: sha256(payload))
        let incoming = dir.appendingPathComponent("a.tmp")
        try payload.write(to: incoming)
        try CleanupModelInstaller.install(downloaded: incoming, as: pinned) { announced += 1 }
        #expect(announced == 1)

        let unpinned = LocalCleanupModel(
            id: "unpinned", displayName: "Unpinned", fileName: "unpinned.gguf",
            remoteURL: nil, downloadBytes: Int64(payload.count), sha256: nil,
            suppressesThinking: false, directory: dir
        )
        let second = dir.appendingPathComponent("b.tmp")
        try payload.write(to: second)
        try CleanupModelInstaller.install(downloaded: second, as: unpinned) { announced += 1 }
        #expect(announced == 1)
    }

    /// The shipped models are pinned to an immutable revision with a digest —
    /// `resolve/main` is a moving target that can't be integrity-checked at all.
    @Test("Shipped cleanup models pin a revision and a digest")
    func shippedModelsArePinned() throws {
        for model in LocalCleanupModel.all {
            let url = try #require(model.remoteURL)
            #expect(!url.path.contains("/resolve/main/"), "\(model.id) still points at a mutable revision")
            let digest = model.sha256 ?? ""
            #expect(digest.count == 64, "\(model.id) has no SHA-256 to verify against")
        }
    }
}
