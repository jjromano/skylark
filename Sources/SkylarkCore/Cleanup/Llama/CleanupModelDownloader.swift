import Foundation
import os

/// Runtime downloader for `LocalCleanupModel` GGUF files.
///
/// The STT engines (Parakeet/WhisperKit) never needed a Skylark-owned
/// downloader — FluidAudio's `ModelHub`/`AsrModels` and WhisperKit's own
/// `download(variant:)` do the fetching, and Skylark only supplies a progress
/// callback. GGUF cleanup models have no such library, so this actor plays
/// that role itself: one `URLSessionDownloadTask` per model, reporting through
/// the SAME `ModelPreparationState` enum the STT model manager uses (so the
/// Settings row renders both with one shared component).
///
/// Atomicity: `URLSessionDownloadTask` already stages the download at a
/// system-owned temporary location and only calls `didFinishDownloadingTo`
/// once the transfer completes; this type then verifies the byte count
/// against `LocalCleanupModel.downloadBytes` (the same check
/// `LocalCleanupModel.isInstalled` uses) BEFORE the atomic
/// `FileManager.moveItem` into the final `Cleanup/` path. A short/interrupted
/// transfer is deleted rather than moved, so a half-downloaded file can never
/// read as installed.
///
/// Resume-or-restart: a failed transfer's resume data (if the server
/// supports it) is kept in memory and consumed by the NEXT `start` call for
/// that model; otherwise the download restarts from byte zero. An explicit
/// `cancel` discards any resume data — cancel means "stop", not "pause".
public actor CleanupModelDownloader {
    private final class ActiveDownload {
        let session: URLSession
        init(session: URLSession) { self.session = session }
    }

    private var active: [String: ActiveDownload] = [:]
    private var resumeData: [String: Data] = [:]
    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "cleanup.download")

    public init() {}

    /// Whether `model` currently has a download in flight.
    public func isDownloading(_ model: LocalCleanupModel) -> Bool {
        active[model.id] != nil
    }

    /// Start (or no-op if already running) downloading `model`. `progress`
    /// receives every state change; the terminal call is always `.ready` or
    /// `.failed`. Off the paste path — a Settings action.
    public func start(_ model: LocalCleanupModel, progress: @escaping @Sendable (ModelPreparationState) -> Void) {
        guard active[model.id] == nil else { return }
        guard let remoteURL = model.remoteURL else {
            progress(.failed(message: "\(model.displayName) has no download source"))
            return
        }
        ModelPaths.ensureCleanupModelsDirectory()
        progress(.checking)

        let delegate = DownloadDelegate(
            model: model,
            progress: progress,
            onFinished: { [weak self] in Task { await self?.clear(model.id) } },
            recordResumeData: { [weak self] data in Task { await self?.store(data, for: model.id) } }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        active[model.id] = ActiveDownload(session: session)

        if let data = resumeData.removeValue(forKey: model.id) {
            session.downloadTask(withResumeData: data).resume()
        } else {
            session.downloadTask(with: URLRequest(url: remoteURL)).resume()
        }
    }

    /// Cancel an in-flight download and drop any partial bytes/resume data —
    /// the next `start` begins fresh.
    public func cancel(_ model: LocalCleanupModel) {
        guard let download = active[model.id] else { return }
        active[model.id] = nil
        resumeData[model.id] = nil
        download.session.invalidateAndCancel()
    }

    private func clear(_ modelID: String) {
        active[modelID] = nil
    }

    private func store(_ data: Data, for modelID: String) {
        resumeData[modelID] = data
        Self.logger.notice("cleanup model download failed — resume data kept for next attempt")
    }
}

/// `URLSessionDownloadDelegate` bridge. Delegate callbacks arrive on an
/// arbitrary background queue; every one of them just forwards through a
/// `@Sendable` closure (mirroring how `FluidAudioParakeet`/`WhisperKitWhisper`
/// bridge their own progress callbacks), so no actor isolation is needed here
/// — `@unchecked Sendable` is sound because the class holds no mutable state
/// of its own past `init`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: LocalCleanupModel
    private let progress: @Sendable (ModelPreparationState) -> Void
    private let onFinished: @Sendable () -> Void
    private let recordResumeData: @Sendable (Data) -> Void

    init(
        model: LocalCleanupModel,
        progress: @escaping @Sendable (ModelPreparationState) -> Void,
        onFinished: @escaping @Sendable () -> Void,
        recordResumeData: @escaping @Sendable (Data) -> Void
    ) {
        self.model = model
        self.progress = progress
        self.onFinished = onFinished
        self.recordResumeData = recordResumeData
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = model.downloadBytes
        guard expected > 0 else { return }
        progress(.downloading(progress: min(1.0, Double(totalBytesWritten) / Double(expected))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move SYNCHRONOUSLY: the OS deletes `location` as soon as this method
        // returns, so verification + the atomic move both have to happen here.
        defer { onFinished() }
        do {
            if FileManager.default.fileExists(atPath: model.fileURL.path) {
                try FileManager.default.removeItem(at: model.fileURL)
            }
            try FileManager.default.moveItem(at: location, to: model.fileURL)
        } catch {
            progress(.failed(message: error.localizedDescription))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: model.fileURL.path)[.size] as? Int64) ?? 0
        guard size >= model.downloadBytes else {
            try? FileManager.default.removeItem(at: model.fileURL)
            progress(.failed(message: "download was incomplete (\(size)/\(model.downloadBytes) bytes)"))
            return
        }
        progress(.ready)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return } // success is reported from didFinishDownloadingTo
        defer { onFinished() }
        let nsError = error as NSError
        // An explicit `cancel()` already resolved the UI state on the caller's
        // side — don't flash a "failed" status on top of it.
        guard nsError.code != NSURLErrorCancelled else { return }
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            recordResumeData(resumeData)
        }
        progress(.failed(message: error.localizedDescription))
    }
}
