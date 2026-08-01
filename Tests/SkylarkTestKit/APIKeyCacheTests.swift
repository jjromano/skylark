import Foundation
import Testing
import SkylarkCore

/// The in-memory key cache that keeps `SecItemCopyMatching` off the dictation
/// path. The keychain read is synchronous and can block on the Security
/// framework's mutex (or an authorization prompt) for longer than the cloud
/// request's own timeout — nothing is timing it, because the request hasn't been
/// built yet.
@Suite("API key cache")
struct APIKeyCacheTests {
    /// Counts keychain reads so "the request path never reads" is checkable.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        var value: String?
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        init(value: String?) { self.value = value }
        func read() -> String? { lock.lock(); _reads += 1; lock.unlock(); return value }
    }

    @Test("Once warmed, request-time lookups never touch the keychain")
    func warmCacheDoesNotReRead() {
        let reader = Reader(value: "sk-or-test")
        let cache = APIKeyCache(read: { reader.read() })

        cache.reload()
        #expect(reader.reads == 1)
        for _ in 0..<10 { #expect(cache.current() == "sk-or-test") }
        #expect(reader.reads == 1)
    }

    /// "No key stored" is a cached answer too — otherwise every keyless cloud
    /// request would re-run the blocking read it is meant to avoid.
    @Test("A cached absent key is still cached")
    func absentKeyIsCached() {
        let reader = Reader(value: nil)
        let cache = APIKeyCache(read: { reader.read() })

        cache.reload()
        #expect(cache.current() == nil)
        #expect(cache.current() == nil)
        #expect(reader.reads == 1)
    }

    /// A cold cache (a cloud request that beats the launch refresh) reads once,
    /// then stays warm.
    @Test("A cold cache reads exactly once")
    func coldCacheReadsOnce() {
        let reader = Reader(value: "sk-or-test")
        let cache = APIKeyCache(read: { reader.read() })

        #expect(cache.current() == "sk-or-test")
        #expect(cache.current() == "sk-or-test")
        #expect(reader.reads == 1)
    }

    /// Saving or removing a key in Settings publishes it, so the very next
    /// request (including the validation call) uses the new key.
    @Test("A published key takes effect without a reload")
    func publishOverridesCache() {
        let reader = Reader(value: "sk-or-old")
        let cache = APIKeyCache(read: { reader.read() })
        cache.reload()

        cache.publish("sk-or-new")
        #expect(cache.current() == "sk-or-new")
        cache.publish(nil)
        #expect(cache.current() == nil)
        #expect(reader.reads == 1)
    }

    @Test("Reload picks up a key changed underneath us")
    func reloadRefreshes() {
        let reader = Reader(value: nil)
        let cache = APIKeyCache(read: { reader.read() })
        #expect(cache.current() == nil)

        reader.value = "sk-or-new"
        #expect(cache.reload() == "sk-or-new")
        #expect(cache.current() == "sk-or-new")
        #expect(reader.reads == 2)
    }
}
