import Foundation
import os

/// Bounded, synchronous unload of Qwen backends for process exit.
///
/// llama.cpp's Metal backend aborts inside a static destructor
/// (`GGML_ASSERT([rsets->data count] == 0)`, ggml-metal-device.m) when a
/// context is still alive while `exit()` runs — so `applicationWillTerminate`
/// must free every loaded model BEFORE returning, and it can only do that by
/// blocking the main thread until the actors have finished.
///
/// The trap this type exists to avoid: a `Task { await backend.unload() }`
/// created from a `@MainActor` method INHERITS main-actor isolation, so its
/// first step needs the main thread — which is parked on the semaphore. The
/// task never starts, the wait times out, and the process exits with the model
/// resident (the v0.20.x "quit after Qwen aborts" crash). The unload therefore
/// runs in a detached task; `LlamaRunner` executes on its own serial queue, so
/// nothing here needs the main thread.
public enum QuitUnload {
    public enum Outcome: Sendable, Equatable {
        /// Every backend reported its weights freed.
        case unloaded
        /// Nothing was resident; nothing to do.
        case nothingToUnload
        /// The unload did not finish inside `timeout`. A model may still be
        /// resident: the caller must not let `exit()` run static destructors.
        case timedOut
    }

    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "cleanup.llama")

    /// Block the calling thread until `backends` have unloaded, or `timeout`
    /// elapses. Safe to call from the main thread: the work is detached.
    public static func blockingUnload(
        _ backends: [QwenCleanupBackend], timeout: Duration = .seconds(3)
    ) -> Outcome {
        guard !backends.isEmpty else { return .nothingToUnload }
        let semaphore = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Outcome?>(initialState: nil)
        Task.detached(priority: .userInitiated) {
            var anyLoaded = false
            for backend in backends {
                if await backend.isModelLoaded() { anyLoaded = true }
                await backend.unload()
            }
            let outcome: Outcome = anyLoaded ? .unloaded : .nothingToUnload
            result.withLock { $0 = outcome }
            semaphore.signal()
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(timeout.milliseconds))
        guard semaphore.wait(timeout: deadline) == .success else {
            logger.error("quit: llama unload did not finish within \(Int(timeout.milliseconds), privacy: .public) ms")
            return .timedOut
        }
        return result.withLock { $0 } ?? .nothingToUnload
    }

    public static func blockingUnload(_ backend: QwenCleanupBackend, timeout: Duration = .seconds(3)) -> Outcome {
        blockingUnload([backend], timeout: timeout)
    }
}

private extension Duration {
    /// Whole milliseconds, for `DispatchTime` arithmetic.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
