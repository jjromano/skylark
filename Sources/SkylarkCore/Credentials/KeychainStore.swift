import Foundation
import Security

/// Errors from Keychain access. `interactionNotAllowed` maps
/// `errSecInteractionNotAllowed` (locked keychain in a headless/CI context) so
/// callers — notably tests — can detect and skip gracefully instead of failing.
public enum KeychainError: Error, Sendable, Equatable {
    case encoding
    case interactionNotAllowed
    case osStatus(OSStatus)
}

/// Generic-password Keychain item for the OpenRouter API key (phase-3 spec):
/// service `com.jjromano.skylark`, account `openrouter-api-key`,
/// `kSecAttrAccessibleWhenUnlocked`. Never caches the key elsewhere; never logs
/// it.
public struct KeychainStore: Sendable {
    private static let service = "com.jjromano.skylark"
    private static let account = "openrouter-api-key"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    /// Returns the stored key, or `nil` if none is set — or if the read fails
    /// for any reason (never found, locked keychain, decoding). A missing key
    /// is a normal, expected state at first launch, and the pipeline must
    /// never crash on a read; use `getStrict()` where the distinction between
    /// "unset" and "unreadable" matters (e.g. tests).
    public func get() -> String? {
        try? getStrict()
    }

    /// Same as `get()`, but surfaces *why* there's no value — in particular
    /// `KeychainError.interactionNotAllowed` for a locked keychain, so callers
    /// (tests) can skip gracefully instead of misreading it as "unset".
    public func getStrict() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.encoding
            }
            return string
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Upserts the key.
    public func set(_ value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }

        let query = baseQuery
        var probe = query
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        let probeStatus = SecItemCopyMatching(probe as CFDictionary, nil)

        switch probeStatus {
        case errSecSuccess:
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw Self.error(for: status) }
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Self.error(for: status) }
        default:
            throw Self.error(for: probeStatus)
        }
    }

    /// Whether a key is currently stored.
    public func exists() -> Bool {
        SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess
    }

    /// When the stored key was first added (Keychain creation date), or nil if
    /// none is stored / the attribute is unavailable. Used to show "Added …" in
    /// Settings without keeping any extra copy of key metadata.
    public func createdAt() -> Date? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any],
              let date = attrs[kSecAttrCreationDate as String] as? Date
        else {
            return nil
        }
        return date
    }

    /// Removes the key. Succeeds silently if none was set.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    private static func error(for status: OSStatus) -> KeychainError {
        status == errSecInteractionNotAllowed ? .interactionNotAllowed : .osStatus(status)
    }
}
