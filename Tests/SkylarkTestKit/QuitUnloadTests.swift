import Foundation
import Testing
import SkylarkCore

/// The quit-time unload of a Qwen backend (C1: quitting after Qwen has loaded
/// aborted in llama.cpp's Metal static destructor).
///
/// The first test is model-free and runs every time: it proves the mechanism
/// behind the crash — a `Task {}` spawned from the main actor cannot run while
/// the main thread is parked on a semaphore, so the old
/// `applicationWillTerminate` hook always timed out and the process exited with
/// the model resident.
///
/// The two `SKYLARK_QUIT_RIG` tests are the live proof and need a GGUF:
///
///     SKYLARK_QUIT_RIG=leak   SKYLARK_LLAMA_GGUF=/path/to.gguf make test TESTFLAGS='--filter quitRig'
///     SKYLARK_QUIT_RIG=unload SKYLARK_LLAMA_GGUF=/path/to.gguf make test TESTFLAGS='--filter quitRig'
///
/// `leak` loads the model and calls `exit(0)` with it resident — the runner
/// must die with SIGABRT (exit 134), reproducing the crash. `unload` runs
/// `QuitUnload.blockingUnload` first and then `exit(0)` — the runner must exit
/// 0. Both end the process on purpose, so they never print a test summary.
@Suite("Quit unload", .serialized)
struct QuitUnloadTests {
    private static var gguf: URL? {
        ProcessInfo.processInfo.environment["SKYLARK_LLAMA_GGUF"].map { URL(fileURLWithPath: $0) }
    }

    private static var rig: String? { ProcessInfo.processInfo.environment["SKYLARK_QUIT_RIG"] }

    /// The v0.20.x hook's shape, verbatim: a main-actor `Task` awaited through
    /// a semaphore held by the main thread. It cannot complete.
    @MainActor
    @Test("A main-actor Task cannot signal a semaphore the main thread is waiting on")
    func inheritedTaskDeadlocks() {
        let backend = QwenCleanupBackend(model: .qwen3_1_7B)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await backend.unload()
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + .milliseconds(400)) == .timedOut)
    }

    @MainActor
    @Test("QuitUnload finishes from the main actor with nothing loaded")
    func detachedUnloadCompletes() {
        let backend = QwenCleanupBackend(model: .qwen3_1_7B)
        let outcome = QuitUnload.blockingUnload(backend, timeout: .seconds(2))
        #expect(outcome == .nothingToUnload)
    }

    @Test("QuitUnload times out instead of hanging", .timeLimit(.minutes(1)))
    func timesOut() async {
        let backend = QwenCleanupBackend(model: .qwen3_1_7B)
        // A zero budget can never be met, even for a no-op unload.
        let outcome = QuitUnload.blockingUnload(backend, timeout: .zero)
        #expect(outcome == .timedOut || outcome == .nothingToUnload)
    }

    @MainActor
    @Test("LIVE quit rig", .enabled(if: QuitUnloadTests.rig != nil && QuitUnloadTests.gguf != nil))
    func quitRig() async throws {
        let model = LocalCleanupModel.custom(fileURL: Self.gguf!, suppressesThinking: true)
        let backend = QwenCleanupBackend(model: model)
        await backend.preload()
        let loaded = await backend.isModelLoaded()
        #expect(loaded)
        print("[quit-rig] model loaded: \(loaded); mode=\(Self.rig!)")
        switch Self.rig {
        case "leak":
            print("[quit-rig] calling exit(0) with the model resident — expect SIGABRT")
            fflush(stdout)
            exit(0)
        case "unload":
            let outcome = QuitUnload.blockingUnload(backend, timeout: .seconds(3))
            let stillLoaded = await backend.isModelLoaded()
            print("[quit-rig] blockingUnload → \(outcome); still loaded: \(stillLoaded); calling exit(0) — expect exit 0")
            fflush(stdout)
            #expect(outcome == .unloaded)
            #expect(!stillLoaded)
            exit(0)
        default:
            Issue.record("unknown SKYLARK_QUIT_RIG mode")
        }
    }
}
