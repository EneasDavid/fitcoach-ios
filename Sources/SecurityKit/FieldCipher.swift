import CryptoKit
import Foundation

public enum CipherError: Error, Equatable {
    case malformed
    case unknownKeyVersion(UInt8)
    /// Wrong key, tampered ciphertext, or ciphertext bound to a different record.
    case authenticationFailed
}

/// Supplies versioned symmetric keys. Versioning is what makes key rotation possible: new data is
/// sealed with `currentVersion`, old data still opens with the key version recorded in its header.
public protocol KeyProviding: Sendable {
    var currentVersion: UInt8 { get }
    func key(version: UInt8, purpose: String) throws -> SymmetricKey
}

/// Master key lives in the Keychain; per-purpose subkeys are derived with HKDF, so the key that
/// protects the SwiftData records is never the one that protects the mutation queue.
public final class KeychainKeyProvider: KeyProviding, @unchecked Sendable {
    public let currentVersion: UInt8 = 1
    private let store: any SecureStoring
    private let lock = NSLock()

    public init(store: any SecureStoring) {
        self.store = store
    }

    public func key(version: UInt8, purpose: String) throws -> SymmetricKey {
        let master = try masterKey(version: version)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: master,
                                      salt: Data("fitcoach.fieldcipher.v1".utf8),
                                      info: Data(purpose.utf8),
                                      outputByteCount: 32)
    }

    private func masterKey(version: UInt8) throws -> SymmetricKey {
        try lock.withLock {
            let account = "fieldcipher.master.v\(version)"
            if let existing = try store.data(forKey: account) {
                return SymmetricKey(data: existing)
            }
            guard version == currentVersion else { throw CipherError.unknownKeyVersion(version) }
            let fresh = SymmetricKey(size: .bits256)
            try store.set(fresh.withUnsafeBytes { Data($0) }, forKey: account)
            return fresh
        }
    }

    /// Crypto-shredding: deleting the master key renders every sealed record on disk unreadable,
    /// which is a stronger "delete my data" guarantee than deleting rows. Call on logout / account deletion.
    public func destroyKeys() throws {
        try lock.withLock { try store.remove(forKey: "fieldcipher.master.v\(currentVersion)") }
    }
}

/// AES-256-GCM field encryption for sensitive local data (OWASP M9 / M10).
///
/// Layout: `[1 byte key version][12 byte nonce][ciphertext][16 byte tag]`.
/// `context` (e.g. `"workoutLogs/<id>"`) is bound as authenticated data, so a ciphertext copied into
/// another row fails authentication instead of silently decrypting into the wrong record.
public struct FieldCipher: Sendable {
    private static let overhead = 12 + 16
    private let keys: any KeyProviding
    private let purpose: String

    public init(keys: any KeyProviding, purpose: String) {
        self.keys = keys
        self.purpose = purpose
    }

    public func seal(_ plaintext: Data, context: String) throws -> Data {
        let version = keys.currentVersion
        let key = try keys.key(version: version, purpose: purpose)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw CipherError.malformed }
        return Data([version]) + combined
    }

    public func open(_ sealed: Data, context: String) throws -> Data {
        guard sealed.count > 1 + Self.overhead, let version = sealed.first else { throw CipherError.malformed }
        let key = try keys.key(version: version, purpose: purpose)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw CipherError.authenticationFailed
        }
    }
}
