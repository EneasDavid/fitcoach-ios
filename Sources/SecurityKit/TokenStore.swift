import Foundation

public struct AuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// `leeway` refreshes slightly early so a token doesn't expire mid-request.
    public func isExpired(at date: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        date.addingTimeInterval(leeway) >= expiresAt
    }
}

/// Keychain-backed storage for third-party credentials (exercise-API proxy session, gym-partner
/// OAuth tokens, …). Firebase Auth manages its own Keychain item for the Firebase session; this
/// store is for everything else. Tokens are never written to `UserDefaults`, files or logs.
public struct TokenStore: Sendable {
    private let store: any SecureStoring
    private let namespace: String

    public init(store: any SecureStoring, namespace: String = "default") {
        self.store = store
        self.namespace = namespace
    }

    private var key: String { "auth.tokens.v1.\(namespace)" }

    public func save(_ tokens: AuthTokens) throws {
        try store.set(JSONEncoder().encode(tokens), forKey: key)
    }

    /// Returns nil when nothing is stored *or* the stored value can't be decoded (treated as signed out).
    public func load() throws -> AuthTokens? {
        guard let data = try store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func clear() throws {
        try store.remove(forKey: key)
    }
}
