import CryptoKit
import Foundation
import Security
import Testing
@testable import SecurityKit

// MARK: - Keychain

enum KeychainProbe {
    /// The Keychain is always available in an app/simulator test host. In headless `swift test` runs on macOS
    /// (CI without an unlocked login keychain) it may not be, so those tests skip instead of failing.
    static let available: Bool = {
        let probe = KeychainStore(service: "com.fitcoach.tests.probe.\(UUID().uuidString)")
        defer { try? probe.removeAll() }
        do {
            try probe.set(Data([1]), forKey: "probe")
            return try probe.data(forKey: "probe") == Data([1])
        } catch {
            return false
        }
    }()
}

@Suite("Keychain", .enabled(if: KeychainProbe.available, "Keychain not usable in this environment"))
struct KeychainStoreTests {
    let store = KeychainStore(service: "com.fitcoach.tests.\(UUID().uuidString)")

    @Test("Round-trips, overwrites in place, and removes")
    func lifecycle() throws {
        defer { try? store.removeAll() }
        #expect(try store.data(forKey: "k") == nil)
        try store.set(Data("one".utf8), forKey: "k")
        #expect(try store.data(forKey: "k") == Data("one".utf8))
        try store.set(Data("two".utf8), forKey: "k")                    // add-or-update: no duplicate item
        #expect(try store.data(forKey: "k") == Data("two".utf8))
        try store.remove(forKey: "k")
        #expect(try store.data(forKey: "k") == nil)
        try store.remove(forKey: "k")                                   // removing a missing item is not an error
    }

    @Test("removeAll wipes everything this service stored, and only that")
    func removeAll() throws {
        let other = KeychainStore(service: "com.fitcoach.tests.other.\(UUID().uuidString)")
        defer { try? store.removeAll(); try? other.removeAll() }
        try store.set(Data([1]), forKey: "a")
        try store.set(Data([2]), forKey: "b")
        try other.set(Data([3]), forKey: "a")
        try store.removeAll()
        #expect(try store.data(forKey: "a") == nil && store.data(forKey: "b") == nil)
        #expect(try other.data(forKey: "a") == Data([3]))
    }

    @Test("Both accessibility classes are accepted")
    func accessibilityClasses() throws {
        let locked = KeychainStore(service: "com.fitcoach.tests.acl.\(UUID().uuidString)", accessibility: .whenUnlockedThisDeviceOnly)
        defer { try? locked.removeAll() }
        try locked.set(Data([9]), forKey: "x")
        #expect(try locked.data(forKey: "x") == Data([9]))
    }
}

@Suite("InMemorySecureStore & TokenStore")
struct TokenStoreTests {
    let backing = InMemorySecureStore()

    @Test("Tokens persist, expire (with leeway) and clear")
    func tokenLifecycle() throws {
        let store = TokenStore(store: backing, namespace: "wellhub")
        #expect(try store.load() == nil)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = AuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3_600))
        try store.save(tokens)
        #expect(try store.load() == tokens)
        #expect(!tokens.isExpired(at: now))
        #expect(tokens.isExpired(at: now.addingTimeInterval(3_550)))        // inside the 60 s leeway
        #expect(!tokens.isExpired(at: now.addingTimeInterval(3_550), leeway: 0))

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test("Namespaces are isolated, and unreadable data is treated as signed-out rather than crashing")
    func isolationAndCorruption() throws {
        let a = TokenStore(store: backing, namespace: "a")
        let b = TokenStore(store: backing, namespace: "b")
        try a.save(AuthTokens(accessToken: "x", expiresAt: .distantFuture))
        #expect(try b.load() == nil)

        try backing.set(Data("{not json".utf8), forKey: "auth.tokens.v1.a")
        #expect(try a.load() == nil)
        #expect(backing.keys == ["auth.tokens.v1.a"])
        try backing.removeAll()
        #expect(backing.keys.isEmpty)
    }
}

// MARK: - Field encryption

/// Test double that proves key rotation: v1 data stays readable after the provider moves to v2.
final class RotatingKeys: KeyProviding, @unchecked Sendable {
    let currentVersion: UInt8
    init(currentVersion: UInt8) { self.currentVersion = currentVersion }
    func key(version: UInt8, purpose: String) throws -> SymmetricKey {
        guard version == 1 || version == 2 else { throw CipherError.unknownKeyVersion(version) }
        return SymmetricKey(data: SHA256.hash(data: Data("key-\(version)-\(purpose)".utf8)))
    }
}

@Suite("FieldCipher")
struct FieldCipherTests {
    let secrets = InMemorySecureStore()
    var cipher: FieldCipher { FieldCipher(keys: KeychainKeyProvider(store: secrets), purpose: "records") }
    let plaintext = Data(#"{"bodyFatPercent":18.5}"#.utf8)

    @Test("Seals and opens; every seal uses a fresh nonce")
    func roundTrip() throws {
        let sealed = try cipher.seal(plaintext, context: "bodyCheckpoints/1")
        #expect(sealed != plaintext && !sealed.contains(plaintext))
        #expect(try cipher.open(sealed, context: "bodyCheckpoints/1") == plaintext)
        #expect(try cipher.seal(plaintext, context: "bodyCheckpoints/1") != sealed)
        #expect(sealed.first == 1)                                      // key-version header
    }

    @Test("A ciphertext moved into another record does not decrypt (context is authenticated)")
    func contextBinding() throws {
        let sealed = try cipher.seal(plaintext, context: "bodyCheckpoints/1")
        #expect(throws: CipherError.authenticationFailed) { try cipher.open(sealed, context: "bodyCheckpoints/2") }
    }

    @Test("Tampering is detected")
    func tamper() throws {
        var sealed = try cipher.seal(plaintext, context: "c")
        sealed[sealed.count / 2] ^= 0x01
        #expect(throws: CipherError.authenticationFailed) { try cipher.open(sealed, context: "c") }
    }

    @Test("Truncated or empty input is rejected as malformed")
    func malformed() {
        #expect(throws: CipherError.malformed) { try cipher.open(Data(), context: "c") }
        #expect(throws: CipherError.malformed) { try cipher.open(Data(repeating: 1, count: 20), context: "c") }
    }

    @Test("Purposes derive independent keys")
    func purposeSeparation() throws {
        let provider = KeychainKeyProvider(store: secrets)
        let sealed = try FieldCipher(keys: provider, purpose: "records").seal(plaintext, context: "c")
        #expect(throws: CipherError.authenticationFailed) {
            try FieldCipher(keys: provider, purpose: "mutation-queue").open(sealed, context: "c")
        }
    }

    @Test("The master key is created once, persisted, and shared by new provider instances")
    func masterKeyPersistence() throws {
        let sealed = try FieldCipher(keys: KeychainKeyProvider(store: secrets), purpose: "records").seal(plaintext, context: "c")
        #expect(secrets.keys == ["fieldcipher.master.v1"])
        let reopened = try FieldCipher(keys: KeychainKeyProvider(store: secrets), purpose: "records").open(sealed, context: "c")
        #expect(reopened == plaintext)
    }

    @Test("Crypto-shredding: after destroying the key, previously sealed data can never be read again")
    func cryptoShredding() throws {
        let provider = KeychainKeyProvider(store: secrets)
        let sealed = try FieldCipher(keys: provider, purpose: "records").seal(plaintext, context: "c")
        try provider.destroyKeys()
        #expect(secrets.keys.isEmpty)
        #expect(throws: CipherError.authenticationFailed) { try FieldCipher(keys: provider, purpose: "records").open(sealed, context: "c") }
    }

    @Test("Unknown key versions are refused rather than silently re-keyed")
    func unknownVersion() throws {
        let provider = KeychainKeyProvider(store: secrets)
        var sealed = try FieldCipher(keys: provider, purpose: "records").seal(plaintext, context: "c")
        sealed[0] = 9
        #expect(throws: CipherError.unknownKeyVersion(9)) { try FieldCipher(keys: provider, purpose: "records").open(sealed, context: "c") }
    }

    @Test("Key rotation: data sealed under v1 still opens once v2 is current, and new data uses v2")
    func rotation() throws {
        let old = FieldCipher(keys: RotatingKeys(currentVersion: 1), purpose: "p")
        let new = FieldCipher(keys: RotatingKeys(currentVersion: 2), purpose: "p")
        let sealedV1 = try old.seal(plaintext, context: "c")
        let sealedV2 = try new.seal(plaintext, context: "c")
        #expect(sealedV1.first == 1 && sealedV2.first == 2)
        #expect(try new.open(sealedV1, context: "c") == plaintext)
        #expect(try new.open(sealedV2, context: "c") == plaintext)
    }
}

// MARK: - Certificate pinning

@Suite("Certificate pinning")
struct CertificatePinningTests {
    func certificate(_ der: Data) throws -> SecCertificate {
        try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    func trust(for certificate: SecCertificate, anchored: Bool = true) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, PinningFixtures.host as CFString), &trust)
        #expect(status == errSecSuccess)
        let created = try #require(trust)
        if anchored {
            SecTrustSetAnchorCertificates(created, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(created, true)
        }
        SecTrustSetVerifyDate(created, PinningFixtures.verificationDate as CFDate)
        return created
    }

    @Test("Our SPKI pin equals the one OpenSSL computes — for EC P-256 and RSA-2048 keys")
    func matchesOpenSSL() throws {
        #expect(SPKIHasher.pin(for: try certificate(PinningFixtures.ecCertificateDER)) == PinningFixtures.ecPin)
        #expect(SPKIHasher.pin(for: try certificate(PinningFixtures.rsaCertificateDER)) == PinningFixtures.rsaPin)
    }

    @Test("Policy: exact host, subdomains, unknown hosts and default-deny")
    func policyDecisions() {
        let policy = PinningPolicy(pinsByHost: ["api.fitcoach.app": ["pinA", "pinBackup"]])
        #expect(policy.evaluate(host: "api.fitcoach.app", chainPins: ["x", "pinBackup"]) == .match)   // backup pin accepted
        #expect(policy.evaluate(host: "API.FitCoach.app", chainPins: ["pinA"]) == .match)
        #expect(policy.evaluate(host: "eu.api.fitcoach.app", chainPins: ["pinA"]) == .match)         // subdomain
        #expect(policy.evaluate(host: "api.fitcoach.app", chainPins: ["evil"]) == .mismatch)
        #expect(policy.evaluate(host: "api.fitcoach.app", chainPins: []) == .mismatch)
        #expect(policy.evaluate(host: "example.com", chainPins: ["evil"]) == .notPinned)
        #expect(policy.evaluate(host: "notapi.fitcoach.app", chainPins: ["x"]) == .notPinned)        // suffix must be a label boundary

        var strict = policy
        strict.rejectUnpinnedHosts = true
        #expect(strict.evaluate(host: "example.com", chainPins: ["anything"]) == .mismatch)
        strict.includeSubdomains = false
        #expect(strict.evaluate(host: "eu.api.fitcoach.app", chainPins: ["pinA"]) == .mismatch)
    }

    @Test("Trust evaluation: system trust AND a matching pin are both required")
    func trustEvaluation() throws {
        let cert = try certificate(PinningFixtures.ecCertificateDER)
        let host = PinningFixtures.host

        let good = PinningPolicy(pinsByHost: [host: [PinningFixtures.ecPin, "backupPin"]])
        #expect(PinnedTrustEvaluator.isTrusted(try trust(for: cert), host: host, policy: good))

        let wrongPin = PinningPolicy(pinsByHost: [host: [PinningFixtures.rsaPin]])
        #expect(!PinnedTrustEvaluator.isTrusted(try trust(for: cert), host: host, policy: wrongPin))

        // Pinning never *widens* trust: a matching pin on a chain the system rejects is still rejected.
        #expect(!PinnedTrustEvaluator.isTrusted(try trust(for: cert, anchored: false), host: host, policy: good))

        let otherHost = PinningPolicy(pinsByHost: ["other.example": ["x"]])
        #expect(PinnedTrustEvaluator.isTrusted(try trust(for: cert), host: host, policy: otherHost))
        let strict = PinningPolicy(pinsByHost: ["other.example": ["x"]], rejectUnpinnedHosts: true)
        #expect(!PinnedTrustEvaluator.isTrusted(try trust(for: cert), host: host, policy: strict))
    }

    @Test("The URLSession delegate hands non-trust challenges back to the system")
    func delegateIgnoresOtherChallenges() {
        let delegate = PinnedSessionDelegate(policy: PinningPolicy(pinsByHost: [:]))
        let space = URLProtectionSpace(host: "api.fitcoach.test", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: NullSender())
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { result, _ in disposition = result }
        #expect(disposition == .performDefaultHandling)

        // A server-trust challenge without a trust object is likewise left to the system.
        let trustSpace = URLProtectionSpace(host: "api.fitcoach.test", port: 443, protocol: "https", realm: nil,
                                            authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let trustChallenge = URLAuthenticationChallenge(protectionSpace: trustSpace, proposedCredential: nil, previousFailureCount: 0,
                                                        failureResponse: nil, error: nil, sender: NullSender())
        var second: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: trustChallenge) { result, _ in second = result }
        #expect(second == .performDefaultHandling)
    }
}

final class NullSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
