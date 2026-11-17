import CryptoKit
import Domain
import Foundation
import SecurityKit

// Spotify authorisation: Authorization Code + PKCE (RFC 7636). A mobile app can't keep a client secret, and PKCE is
// the flow Spotify prescribes for that — nothing secret ships in the app. Tokens live in the Keychain.

public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// `challenge = BASE64URL(SHA256(verifier))`, no padding.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes → a 43-character verifier (RFC 7636 allows 43–128).
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "no secure randomness")
        return PKCE(verifier: base64URL(Data(bytes)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct SpotifyTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
}

public enum SpotifyOAuth {
    public static let scope = "user-read-recently-played"
    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    /// The page to show in `ASWebAuthenticationSession`. Only the one read-only scope is requested.
    public static func authorizationURL(clientID: String, redirectURI: String, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
        ]
        return components.url!
    }

    /// Reads the redirect. The `state` must match what we sent (CSRF defence) and there must be a `code`.
    public static func authorizationCode(from callback: URL, expectedState: String) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState,
              items.first(where: { $0.name == "error" }) == nil,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    static func tokenRequest(_ form: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = Data(form.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        return request
    }

    public static func exchangeRequest(clientID: String, code: String, redirectURI: String, verifier: String) -> URLRequest {
        tokenRequest([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                      ("client_id", clientID), ("code_verifier", verifier)])
    }

    public static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)])
    }

    /// Spotify may omit `refresh_token` on a refresh: keep the one we had.
    static func parse(_ data: Data, previousRefreshToken: String?, now: Date) -> SpotifyTokens? {
        struct Body: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double? }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), !body.access_token.isEmpty,
              let refresh = body.refresh_token ?? previousRefreshToken else { return nil }
        return SpotifyTokens(accessToken: body.access_token, refreshToken: refresh, expiresAt: now.addingTimeInterval(body.expires_in ?? 3_600))
    }
}

/// Keychain-backed tokens with transparent refresh. `accessToken()` is `nil` when not connected — and when Spotify says the
/// refresh token is no longer valid (user revoked access), which also disconnects locally so the UI shows the truth.
public actor SpotifyTokenStore: AccessTokenProviding {
    static let key = "spotify.tokens"

    private let clientID: String
    private let secrets: any SecureStoring
    private let http: any HTTPRequesting
    private let now: @Sendable () -> Date

    public init(clientID: String, secrets: any SecureStoring, http: any HTTPRequesting = URLSessionRequester(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientID = clientID
        self.secrets = secrets
        self.http = http
        self.now = now
    }

    public var isConnected: Bool { (try? load()) != nil }

    /// Completes the connect flow: trade the authorisation code for tokens.
    public func connect(code: String, redirectURI: String, verifier: String) async throws {
        let (data, response) = try await http.send(SpotifyOAuth.exchangeRequest(clientID: clientID, code: code, redirectURI: redirectURI, verifier: verifier))
        guard (200..<300).contains(response.statusCode), let tokens = SpotifyOAuth.parse(data, previousRefreshToken: nil, now: now()) else {
            throw IntegrationError.unauthorized
        }
        try secrets.set(try JSONEncoder().encode(tokens), forKey: Self.key)
    }

    public func disconnect() { try? secrets.remove(forKey: Self.key) }

    public func accessToken() async throws -> String? {
        guard let tokens = try load() else { return nil }
        if tokens.expiresAt.timeIntervalSince(now()) > 60 { return tokens.accessToken }

        let (data, response) = try await http.send(SpotifyOAuth.refreshRequest(clientID: clientID, refreshToken: tokens.refreshToken))
        if response.statusCode == 400 || response.statusCode == 401 {      // revoked / invalid grant
            disconnect()
            return nil
        }
        guard (200..<300).contains(response.statusCode) else { throw IntegrationError.server(status: response.statusCode) }
        guard let refreshed = SpotifyOAuth.parse(data, previousRefreshToken: tokens.refreshToken, now: now()) else { throw IntegrationError.malformedResponse }
        try secrets.set(try JSONEncoder().encode(refreshed), forKey: Self.key)
        return refreshed.accessToken
    }

    private func load() throws -> SpotifyTokens? {
        guard let data = try secrets.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }
}
