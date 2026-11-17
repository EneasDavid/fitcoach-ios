import CryptoKit
import Foundation
import Security

/// Computes the same pin as the well-known
/// `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`:
/// SHA-256 over the DER SubjectPublicKeyInfo. Pinning the *key* (not the certificate) survives
/// routine certificate renewals as long as the key pair is reused.
public enum SPKIHasher {
    public static func pin(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String,
              let bits = attributes[kSecAttrKeySizeInBits] as? Int,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let header = asn1Header(keyType: type, bits: bits) else { return nil }
        return Data(SHA256.hash(data: header + raw)).base64EncodedString()
    }

    // SecKeyCopyExternalRepresentation returns the bare key; the SPKI wrapper has to be re-created.
    private static func asn1Header(keyType: String, bits: Int) -> Data? {
        let rsa = keyType == (kSecAttrKeyTypeRSA as String)
        let ec = keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)
        if rsa && bits == 2048 {
            return Data([0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
                         0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00])
        }
        if rsa && bits == 4096 {
            return Data([0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
                         0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00])
        }
        if ec && bits == 256 {
            return Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06,
                         0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
        }
        if ec && bits == 384 {
            return Data([0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06,
                         0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00])
        }
        return nil   // unsupported key type/size: fail closed rather than guess
    }
}

public enum PinDecision: Equatable, Sendable {
    /// No pins configured for this host.
    case notPinned
    case match
    case mismatch
}

/// Which SPKI pins are acceptable for which host.
///
/// Always configure at least two pins per host — the live key *and* a backup you hold offline —
/// otherwise a key rotation bricks every installed copy of the app until the next App Store release.
///
/// Scope: this protects **our own `URLSession` traffic** (the exercise-catalogue proxy on a custom
/// Cloud Functions domain, partner APIs). The Firebase SDKs use their own gRPC/TLS stack: they cannot
/// be pinned through `URLSessionDelegate`, and Google rotates its certificates too often to pin
/// safely. For Firebase, rely on ATS + Firebase App Check (attestation) instead.
public struct PinningPolicy: Sendable {
    public var pinsByHost: [String: Set<String>]
    public var includeSubdomains: Bool
    /// When true, a host without configured pins is rejected (default-deny for first-party APIs).
    public var rejectUnpinnedHosts: Bool

    public init(pinsByHost: [String: Set<String>], includeSubdomains: Bool = true, rejectUnpinnedHosts: Bool = false) {
        self.pinsByHost = pinsByHost
        self.includeSubdomains = includeSubdomains
        self.rejectUnpinnedHosts = rejectUnpinnedHosts
    }

    public func pins(for host: String) -> Set<String>? {
        let host = host.lowercased()
        if let exact = pinsByHost[host] { return exact }
        guard includeSubdomains else { return nil }
        return pinsByHost.first { host.hasSuffix("." + $0.key.lowercased()) }?.value
    }

    /// `chainPins` are the SPKI pins of every certificate in the server's validated chain (leaf → root).
    /// Matching *any* of them is enough, so teams can pin an intermediate CA instead of the leaf.
    public func evaluate(host: String, chainPins: [String]) -> PinDecision {
        guard let expected = pins(for: host) else { return rejectUnpinnedHosts ? .mismatch : .notPinned }
        return chainPins.contains(where: expected.contains) ? .match : .mismatch
    }
}

public enum PinnedTrustEvaluator {
    /// System trust is always evaluated first — pinning *narrows* trust, it never replaces it.
    public static func isTrusted(_ trust: SecTrust, host: String, policy: PinningPolicy) -> Bool {
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return false }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return policy.evaluate(host: host, chainPins: chain.compactMap(SPKIHasher.pin(for:))) != .mismatch
    }
}

/// Plug into `URLSession(configuration:delegate:delegateQueue:)` for every first-party API client.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: PinningPolicy

    public init(policy: PinningPolicy) {
        self.policy = policy
    }

    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if PinnedTrustEvaluator.isTrusted(trust, host: challenge.protectionSpace.host, policy: policy) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)   // fail closed
        }
    }
}
