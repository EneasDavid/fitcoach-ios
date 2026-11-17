import Foundation
import Domain

// Network adapters for the three integrations. None of them holds a secret:
//   Spotify  — public client id + PKCE; the user's access token is supplied by the app (Keychain), never stored here.
//   Places   — the Google API key lives in a Cloud Function; the app only sends the user's Firebase ID token.
//   Strava   — client secret and tokens live in Cloud Functions; the app only asks the backend for a URL to open.

/// Seam over `URLSession` so every adapter is testable without a network.
public protocol HTTPRequesting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionRequester: HTTPRequesting {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum IntegrationError: Error, Equatable, Sendable {
    /// Not connected, or the token was rejected: the user has to connect again.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case malformedResponse
}

/// Supplies a fresh access token, refreshing it when needed; `nil` when the user hasn't connected.
public protocol AccessTokenProviding: Sendable {
    func accessToken() async throws -> String?
}

/// Extra headers for calls to our own backend: `Authorization: Bearer <Firebase ID token>` and `X-Firebase-AppCheck`.
public protocol BackendCredentialProviding: Sendable {
    func headers() async throws -> [String: String]
}

// MARK: - Spotify

/// Recently-played tracks from the Spotify Web API (`GET /v1/me/player/recently-played`, scope `user-read-recently-played`).
///
/// Verified limits (Spotify community/docs, 2026): the endpoint only reaches the **last 50 plays** — `after`/`before`
/// cursors move inside that window — so the app must import soon after a workout and keep what it imports.
/// Development Mode apps are capped at 5 authorised users and need Premium; production needs Extended Quota.
public struct SpotifyHistoryClient: MusicHistoryProviding {
    public let provider: MusicProvider = .spotify

    private let tokens: any AccessTokenProviding
    private let http: any HTTPRequesting
    private let baseURL: URL
    private let playedAtMarksEnd: Bool

    /// - Parameter playedAtMarksEnd: Spotify documents `played_at` only as "the date and time the track was played".
    ///   Observed behaviour is that it marks when the play *ended*, so the start is derived as `played_at − duration`.
    ///   This one flag is the only place that assumption lives — flip it if live data shows otherwise.
    public init(tokens: any AccessTokenProviding, http: any HTTPRequesting = URLSessionRequester(),
                baseURL: URL = URL(string: "https://api.spotify.com/v1")!, playedAtMarksEnd: Bool = true) {
        self.tokens = tokens
        self.http = http
        self.baseURL = baseURL
        self.playedAtMarksEnd = playedAtMarksEnd
    }

    public var isConnected: Bool {
        get async { ((try? await tokens.accessToken()) ?? nil) != nil }
    }

    public func recentlyPlayed(after date: Date) async throws -> [TrackPlay] {
        guard let token = try await tokens.accessToken() else { throw IntegrationError.unauthorized }

        var components = URLComponents(url: baseURL.appendingPathComponent("me/player/recently-played"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "50"),
                                 URLQueryItem(name: "after", value: String(Int64(date.timeIntervalSince1970 * 1_000)))]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw IntegrationError.unauthorized
        case 429: throw IntegrationError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw IntegrationError.server(status: response.statusCode)
        }
        return try parse(data)
    }

    func parse(_ data: Data) throws -> [TrackPlay] {
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw IntegrationError.malformedResponse }
        return page.items.compactMap { item in
            // Tracks only: podcast episodes and local files (no id) are skipped.
            guard let track = item.track, let id = track.id, track.type == nil || track.type == "track",
                  let playedAt = Self.date(item.played_at) else { return nil }
            let duration = max((track.duration_ms ?? 0) / 1_000, 0)
            let start = playedAtMarksEnd ? playedAt.addingTimeInterval(-TimeInterval(duration)) : playedAt
            let artist = track.artists?.map(\.name).prefix(2).joined(separator: ", ") ?? ""
            return TrackPlay(provider: .spotify, trackID: id, title: track.name, artist: artist, startedAt: start, durationSeconds: duration)
        }
    }

    private static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private struct Page: Decodable { let items: [Item] }
    private struct Item: Decodable { let track: Track?; let played_at: String }
    private struct Track: Decodable {
        let id: String?
        let name: String
        let type: String?
        let duration_ms: Int?
        let artists: [Artist]?
    }
    private struct Artist: Decodable { let name: String }
}

// MARK: - Gym finder (Google Places through our proxy)

/// Finds gyms near a coordinate by asking *our* Cloud Function, which calls the Google Places API (New) with a
/// server-side key. The app never sees or ships a Google key (OWASP M1/M9).
///
/// Google's terms may limit how long Places coordinates can be cached (check the current Maps Platform terms): keep the place id, refresh coordinates; the
/// monitored perimeter itself is the student's confirmed choice (see README → "Gym detection").
public struct PlacesProxyGymLocator: GymLocating {
    private let endpoint: URL
    private let credentials: any BackendCredentialProviding
    private let http: any HTTPRequesting
    private let defaultRadiusMeters: Double

    public init(endpoint: URL, credentials: any BackendCredentialProviding, http: any HTTPRequesting = URLSessionRequester(),
                defaultRadiusMeters: Double = 120) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.http = http
        self.defaultRadiusMeters = defaultRadiusMeters
    }

    public func gyms(near latitude: Double, longitude: Double, radiusMeters: Double) async throws -> [GymVenue] {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await credentials.headers() { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["latitude": latitude, "longitude": longitude,
                                                                       "radiusMeters": min(max(radiusMeters, 100), 5_000)])
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw IntegrationError.unauthorized
        case 429: throw IntegrationError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw IntegrationError.server(status: response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw IntegrationError.malformedResponse }
        return body.gyms.compactMap { gym in
            guard (-90...90).contains(gym.latitude), (-180...180).contains(gym.longitude), !gym.id.isEmpty else { return nil }
            return GymVenue(id: "place:\(gym.id)", name: gym.name, latitude: gym.latitude, longitude: gym.longitude, radiusMeters: defaultRadiusMeters)
        }
    }

    private struct Body: Decodable { let gyms: [Gym] }
    private struct Gym: Decodable { let id: String; let name: String; let latitude: Double; let longitude: Double }
}

// MARK: - Backend (Strava connection)

/// Talks to the app's own Cloud Functions for the Strava connection. The OAuth `state` is minted server-side and bound
/// to the signed-in user, so a callback can't be replayed for somebody else's account.
public struct IntegrationBackendClient: Sendable {
    private let baseURL: URL
    private let credentials: any BackendCredentialProviding
    private let http: any HTTPRequesting

    public init(baseURL: URL, credentials: any BackendCredentialProviding, http: any HTTPRequesting = URLSessionRequester()) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.http = http
    }

    /// The Strava authorisation page to show in `ASWebAuthenticationSession`.
    public func stravaAuthorizationURL() async throws -> URL {
        let data = try await post("stravaConnectStart")
        guard let body = try? JSONDecoder().decode(StartBody.self, from: data),
              let url = URL(string: body.url), url.scheme == "https", url.host?.hasSuffix("strava.com") == true else {
            throw IntegrationError.malformedResponse          // never open a URL the backend didn't (or couldn't) vouch for
        }
        return url
    }

    /// Revokes the token at Strava and deletes the stored tokens + imported activities.
    public func disconnectStrava() async throws {
        _ = try await post("stravaDisconnect")
    }

    private func post(_ function: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(function), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await credentials.headers() { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw IntegrationError.unauthorized
        case 429: throw IntegrationError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw IntegrationError.server(status: response.statusCode)
        }
    }

    private struct StartBody: Decodable { let url: String }
}
