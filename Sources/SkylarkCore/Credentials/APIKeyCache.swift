import Foundation

/// In-memory cache of the OpenRouter API key, so request-time key lookups never
/// touch the Keychain.
///
/// `OpenRouterClient` asks its `keyProvider` for the key while building every
/// request — including the cloud STT request on the dictation path. Reading it
/// straight from the Keychain there means a synchronous `SecItemCopyMatching`
/// on the pipeline: it takes the Security framework's keychain mutex (which a
/// background read can already be holding) and, on a self-signed dev build, can
/// raise an authorization prompt that blocks until someone answers it. None of
/// that is bounded by the request's own timeout — the request hasn't been made
/// yet — so the dictation just stops. Same failure mode as the main-thread hang
/// that made `AppController.hasAPIKey` a cached flag.
///
/// The Keychain remains the ONLY store. This is a process-lifetime copy in
/// memory, refreshed off the hot path (`reload()`), never written to disk or
/// UserDefaults, never logged.
public final class APIKeyCache: @unchecked Sendable {
    /// The app's cache. There is exactly one stored key (one Keychain item), so
    /// everything that reads or writes it shares this instance: the client's
    /// `keyProvider`, the launch/refresh path, and the Settings key editor
    /// (which publishes what it just wrote so validation doesn't race a reload).
    /// Tests construct their own instance with an injected reader.
    public static let shared = APIKeyCache()

    /// Cache for the DIRECT Groq key. Separate instance over a separate Keychain
    /// item, for the same reason `KeychainStore.groqAccount` is separate: two
    /// services, two credentials, and no path by which one is ever sent to the
    /// other.
    public static let groq = APIKeyCache(read: { KeychainStore(account: KeychainStore.groqAccount).get() })

    private let lock = NSLock()
    /// `nil` = never loaded; `.some(nil)` = loaded, no key stored.
    private var cached: String??
    private let read: @Sendable () -> String?

    public init(read: @escaping @Sendable () -> String? = { KeychainStore().get() }) {
        self.read = read
    }

    /// The key to sign a request with. Safe on any thread and, once the cache is
    /// warm, free. Falls back to a single blocking read if nothing has been
    /// cached yet (a cloud request that beats the launch refresh) — after which
    /// it stays warm for the life of the process.
    public func current() -> String? {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        return reload()
    }

    /// Re-read the Keychain and publish the result. BLOCKING — call it off the
    /// main actor and off the dictation path (launch, key changes, engine
    /// rebuilds). Returns the key so callers can derive presence from the same
    /// single read.
    @discardableResult
    public func reload() -> String? {
        let value = read()
        lock.lock()
        cached = .some(value)
        lock.unlock()
        return value
    }

    /// Publish a key the app just stored (or removed) itself, so the next
    /// request uses it without waiting for a reload.
    public func publish(_ key: String?) {
        lock.lock()
        cached = .some(key)
        lock.unlock()
    }
}
