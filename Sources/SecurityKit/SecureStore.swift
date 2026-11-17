import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Abstraction over secret storage so everything above it is testable without a real Keychain.
public protocol SecureStoring: Sendable {
    func set(_ data: Data, forKey key: String) throws
    func data(forKey key: String) throws -> Data?
    func remove(forKey key: String) throws
    /// Removes every item this store owns (logout / "delete my data").
    func removeAll() throws
}

public enum KeychainAccessibility: Sendable {
    /// Readable after the first unlock since boot. Required so BGTasks and arrival-triggered sync can
    /// run while the phone is locked in a pocket. Never leaves this device (no backup, no iCloud Keychain).
    case afterFirstUnlockThisDeviceOnly
    /// Readable only while the device is unlocked. Use for secrets that are never needed in the background.
    case whenUnlockedThisDeviceOnly

    var attribute: CFString {
        switch self {
        case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

/// Generic-password Keychain storage (OWASP M1 / M9).
///
///  * never synchronised to iCloud (`kSecAttrSynchronizable = false`);
///  * `…ThisDeviceOnly` accessibility classes: not included in backups or device migration;
///  * add-or-update semantics, so rotating a token never leaves a stale duplicate behind.
public struct KeychainStore: SecureStoring {
    public let service: String
    public let accessGroup: String?
    public let accessibility: KeychainAccessibility

    public init(service: String,
                accessGroup: String? = nil,
                accessibility: KeychainAccessibility = .afterFirstUnlockThisDeviceOnly) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    private func query(forKey key: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let key { query[kSecAttrAccount as String] = key }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func set(_ data: Data, forKey key: String) throws {
        var addQuery = query(forKey: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility.attribute

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessibility.attribute,
            ]
            status = SecItemUpdate(query(forKey: key) as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func data(forKey key: String) throws -> Data? {
        var lookup = query(forKey: key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func remove(forKey key: String) throws {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    /// On macOS `SecItemDelete` removes a single match per call, on iOS all of them — looping until
    /// "not found" is correct on both (and bounded, so a misbehaving Keychain can't spin forever).
    public func removeAll() throws {
        for _ in 0..<10_000 {
            let status = SecItemDelete(query() as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }
}

/// Volatile store for unit tests, previews and UI tests.
public final class InMemorySecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data, forKey key: String) throws { lock.withLock { storage[key] = data } }
    public func data(forKey key: String) throws -> Data? { lock.withLock { storage[key] } }
    public func remove(forKey key: String) throws { lock.withLock { storage[key] = nil } }
    public func removeAll() throws { lock.withLock { storage.removeAll() } }
    public var keys: [String] { lock.withLock { storage.keys.sorted() } }
}
