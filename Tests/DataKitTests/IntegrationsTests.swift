import Foundation
import Testing
import Domain
import SecurityKit
import SyncKit
@testable import DataKit

actor ScriptedHTTP: HTTPRequesting {
    private var responses: [(status: Int, body: String, headers: [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String)], headers: [String: String] = [:]) { self.responses = responses.map { ($0.0, $0.1, headers) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.isEmpty ? (status: 500, body: "", headers: [:]) : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        return (Data(next.body.utf8), response)
    }
}

struct FixedToken: AccessTokenProviding {
    let token: String?
    func accessToken() async throws -> String? { token }
}

struct FixedHeaders: BackendCredentialProviding {
    func headers() async throws -> [String: String] { ["Authorization": "Bearer id-token", "X-Firebase-AppCheck": "ac-token"] }
}

enum SpotifyFixtures {
    /// Shape of a real `recently-played` response, trimmed to the fields we read (+ an episode and a local file to skip).
    static let page = """
    {"items":[
      {"track":{"id":"4uLU6hMCjMI75M1A2tKUQC","name":"Never Gonna Give You Up","type":"track","duration_ms":213573,
                "artists":[{"name":"Rick Astley"}]},"played_at":"2024-01-01T18:10:00.000Z"},
      {"track":{"id":"7ouMYWpwJ422jRcDASZB7P","name":"Eye of the Tiger","type":"track","duration_ms":244000,
                "artists":[{"name":"Survivor"},{"name":"Guest"},{"name":"Third"}]},"played_at":"2024-01-01T18:20:30Z"},
      {"track":{"id":"ep1","name":"A podcast episode","type":"episode","duration_ms":1000000},"played_at":"2024-01-01T18:30:00.000Z"},
      {"track":{"id":null,"name":"Local file","type":"track","duration_ms":1000,"artists":[]},"played_at":"2024-01-01T18:31:00.000Z"}
    ]}
    """
}

@Suite("SpotifyHistoryClient")
struct SpotifyHistoryClientTests {
    let since = DFx.t0

    @Test("Maps tracks only, derives the start from the end time, sends the cursor in milliseconds")
    func parsesAndRequests() async throws {
        let http = ScriptedHTTP([(200, SpotifyFixtures.page)])
        let plays = try await SpotifyHistoryClient(tokens: FixedToken(token: "tok"), http: http).recentlyPlayed(after: since)

        #expect(plays.map(\.title) == ["Never Gonna Give You Up", "Eye of the Tiger"])      // episode + local file skipped
        let first = plays[0]
        let ended = ISO8601DateFormatter().date(from: "2024-01-01T18:10:00Z")!
        #expect(first.durationSeconds == 213)
        #expect(first.startedAt == ended.addingTimeInterval(-213))
        #expect(first.artist == "Rick Astley")
        #expect(plays[1].artist == "Survivor, Guest")                                       // at most two artists
        #expect(plays[1].provider == .spotify && plays[1].trackID == "7ouMYWpwJ422jRcDASZB7P")

        let request = try #require(await http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "after" }?.value == String(Int64(since.timeIntervalSince1970 * 1_000)))
        #expect(items.first { $0.name == "limit" }?.value == "50")
        #expect(request.url!.path.hasSuffix("/me/player/recently-played"))
    }

    @Test("If played_at marks the start, the start is not shifted")
    func startSemantics() async throws {
        let http = ScriptedHTTP([(200, SpotifyFixtures.page)])
        let plays = try await SpotifyHistoryClient(tokens: FixedToken(token: "t"), http: http, playedAtMarksEnd: false).recentlyPlayed(after: since)
        #expect(plays[0].startedAt == ISO8601DateFormatter().date(from: "2024-01-01T18:10:00Z"))
    }

    @Test("No token → unauthorized, without touching the network; also reflected in isConnected")
    func notConnected() async throws {
        let http = ScriptedHTTP([])
        let client = SpotifyHistoryClient(tokens: FixedToken(token: nil), http: http)
        #expect(await client.isConnected == false)
        await #expect(throws: IntegrationError.unauthorized) { try await client.recentlyPlayed(after: since) }
        #expect(await http.requests.isEmpty)
        #expect(await SpotifyHistoryClient(tokens: FixedToken(token: "x"), http: http).isConnected)
    }

    @Test("HTTP failures map to the right errors", arguments: [
        (401, IntegrationError.unauthorized), (403, .unauthorized), (500, .server(status: 500)), (503, .server(status: 503)),
    ])
    func errorMapping(status: Int, expected: IntegrationError) async {
        let client = SpotifyHistoryClient(tokens: FixedToken(token: "t"), http: ScriptedHTTP([(status, "{}")]))
        await #expect(throws: expected) { try await client.recentlyPlayed(after: since) }
    }

    @Test("429 carries Retry-After")
    func rateLimited() async {
        let client = SpotifyHistoryClient(tokens: FixedToken(token: "t"), http: ScriptedHTTP([(429, "")], headers: ["Retry-After": "7"]))
        await #expect(throws: IntegrationError.rateLimited(retryAfter: 7)) { try await client.recentlyPlayed(after: since) }
    }

    @Test("Garbage is reported, not crashed on")
    func malformed() async {
        let client = SpotifyHistoryClient(tokens: FixedToken(token: "t"), http: ScriptedHTTP([(200, "<html>")]))
        await #expect(throws: IntegrationError.malformedResponse) { try await client.recentlyPlayed(after: since) }
    }
}

@Suite("PlacesProxyGymLocator & backend client")
struct BackendClientTests {
    let endpoint = URL(string: "https://example.cloudfunctions.net/searchGyms")!

    @Test("Sends the Firebase credentials (never a Google key) and maps places to venues with the standard radius")
    func findsGyms() async throws {
        let body = """
        {"gyms":[{"id":"ChIJabc","name":"Smart Fit Centro","latitude":-9.66,"longitude":-35.73},
                 {"id":"","name":"No id","latitude":0,"longitude":0},
                 {"id":"ChIJbad","name":"Bad coords","latitude":123,"longitude":0}]}
        """
        let http = ScriptedHTTP([(200, body)])
        let locator = PlacesProxyGymLocator(endpoint: endpoint, credentials: FixedHeaders(), http: http, defaultRadiusMeters: 150)
        let gyms = try await locator.gyms(near: -9.6, longitude: -35.7, radiusMeters: 99_999)

        #expect(gyms == [GymVenue(id: "place:ChIJabc", name: "Smart Fit Centro", latitude: -9.66, longitude: -35.73, radiusMeters: 150)])
        let request = try #require(await http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer id-token")
        #expect(request.value(forHTTPHeaderField: "X-Firebase-AppCheck") == "ac-token")
        #expect(request.url?.query == nil)                                    // no data in the URL
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Double]
        #expect(sent?["radiusMeters"] == 5_000)                               // clamped
    }

    @Test("Rejected credentials surface as unauthorized")
    func unauthorized() async {
        let locator = PlacesProxyGymLocator(endpoint: endpoint, credentials: FixedHeaders(), http: ScriptedHTTP([(401, "{}")]))
        await #expect(throws: IntegrationError.unauthorized) { try await locator.gyms(near: 0, longitude: 0, radiusMeters: 500) }
    }

    @Test("Only a Strava https URL from the backend is accepted for the connect flow")
    func stravaURLIsVetted() async throws {
        let base = URL(string: "https://example.cloudfunctions.net")!
        func client(_ body: String) -> IntegrationBackendClient {
            IntegrationBackendClient(baseURL: base, credentials: FixedHeaders(), http: ScriptedHTTP([(200, body)]))
        }
        let good = try await client(#"{"url":"https://www.strava.com/oauth/authorize?client_id=1&state=abc"}"#).stravaAuthorizationURL()
        #expect(good.host == "www.strava.com")
        await #expect(throws: IntegrationError.malformedResponse) { try await client(#"{"url":"https://evil.example/strava.com"}"#).stravaAuthorizationURL() }
        await #expect(throws: IntegrationError.malformedResponse) { try await client(#"{"url":"http://www.strava.com/x"}"#).stravaAuthorizationURL() }
        await #expect(throws: IntegrationError.malformedResponse) { try await client(#"{"url":"javascript:alert(1)"}"#).stravaAuthorizationURL() }
    }

    @Test("Disconnect calls the backend with credentials")
    func disconnect() async throws {
        let http = ScriptedHTTP([(200, "{}")])
        try await IntegrationBackendClient(baseURL: URL(string: "https://example.cloudfunctions.net")!, credentials: FixedHeaders(), http: http).disconnectStrava()
        let request = try #require(await http.requests.first)
        #expect(request.url?.lastPathComponent == "stravaDisconnect" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer id-token")
    }
}

@Suite("Device-local stores")
struct DeviceLocalStoreTests {
    func sealed() -> (SealedRecordStore, InMemoryRecordStore) {
        let backing = InMemoryRecordStore()
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "records")
        return (SealedRecordStore(inner: backing, cipher: cipher), backing)
    }

    func play(_ id: String, at date: Date, seconds: Int = 200) -> TrackPlay {
        TrackPlay(provider: .spotify, trackID: id, title: "Title \(id)", artist: "Artist", startedAt: date, durationSeconds: seconds)
    }

    @Test("Plays are stored once, queried by time, and stay encrypted at rest")
    func plays() async throws {
        let (store, backing) = sealed()
        let repo = TrackPlayRepositoryImpl(local: store, owner: "s1", now: { DFx.t0.addingTimeInterval(86_400) })
        let a = play("a", at: DFx.t0), b = play("b", at: DFx.t0.addingTimeInterval(3_600))
        try await repo.save([a, b])
        try await repo.save([a])                                              // re-import: no duplicate

        let found = try await repo.plays(studentID: "s1", from: DFx.t0, to: DFx.t0.addingTimeInterval(1_800))
        #expect(found == [a])
        #expect(try await repo.plays(studentID: "s1", from: DFx.t0, to: DFx.t0.addingTimeInterval(7_200)).count == 2)
        #expect(try await repo.plays(studentID: "someone-else", from: DFx.t0, to: DFx.t0.addingTimeInterval(7_200)).isEmpty)

        let raw = try #require(try await backing.records(collection: "trackPlays", ownerID: "s1").first)
        #expect(!String(decoding: raw.payload, as: UTF8.self).contains("Title"))   // title is not readable on disk
        #expect(raw.syncState == .synced)                                     // never queued for sync
    }

    @Test("Old plays are pruned after the retention window")
    func retention() async throws {
        let (store, backing) = sealed()
        let now = DFx.t0.addingTimeInterval(200 * 86_400)
        let repo = TrackPlayRepositoryImpl(local: store, owner: "s1", retention: 90 * 86_400, now: { now })
        let old = play("old", at: now.addingTimeInterval(-100 * 86_400)), recent = play("recent", at: now.addingTimeInterval(-3_600))
        // Seed an old row as if it had been stored long ago, then save a fresh play.
        try await store.upsert(LocalRecord(collection: "trackPlays", id: old.id, ownerID: "s1", sortDate: old.startedAt, syncState: .synced,
                                           localVersion: 0, remoteVersion: 0, payload: try SyncCoding.data(old)))
        try await repo.save([recent, old])                                    // `old` is dropped on the way in too
        #expect(try await backing.records(collection: "trackPlays", ownerID: "s1").count == 1)
        #expect(try await repo.plays(studentID: "s1", from: .distantPast, to: .distantFuture) == [recent])
    }

    @Test("Pending visits round-trip, persist across instances, and clear when empty")
    func visits() async throws {
        let (store, backing) = sealed()
        let visit = PendingVisit(venue: DFx.venue, enteredAt: DFx.t0, provider: .geofence)
        try await PendingVisitStoreImpl(local: store, owner: "s1").save([visit])
        #expect(try await PendingVisitStoreImpl(local: store, owner: "s1").load() == [visit])     // "relaunch"
        #expect(try await PendingVisitStoreImpl(local: store, owner: "s2").load().isEmpty)
        #expect(!String(decoding: try #require(try await backing.record(collection: "presence", id: "pending-visits")).payload, as: UTF8.self).contains("Smart Fit"))

        try await PendingVisitStoreImpl(local: store, owner: "s1").save([])
        #expect(try await PendingVisitStoreImpl(local: store, owner: "s1").load().isEmpty)
        #expect(try await backing.record(collection: "presence", id: "pending-visits") == nil)
    }
}

@Suite("SimulatedGymPresenceProvider")
struct SimulatedPresenceTests {
    @Test("Events flow only while monitoring, to every subscriber")
    func delivers() async throws {
        let provider = SimulatedGymPresenceProvider()
        var stream = provider.presenceEvents().makeAsyncIterator()
        provider.simulate(.entered, venue: DFx.venue, at: DFx.t0)               // not monitoring yet: dropped

        try await provider.startMonitoring()
        provider.simulate(.entered, venue: DFx.venue, at: DFx.t0)
        provider.simulate(.exited, venue: DFx.venue, at: DFx.t0.addingTimeInterval(60))
        let first = await stream.next(), second = await stream.next()
        #expect(first == GymPresenceEvent(kind: .entered, venue: DFx.venue, at: DFx.t0, provider: .simulated))
        #expect(second?.kind == .exited)

        await provider.stopMonitoring()
        provider.simulate(.entered, venue: DFx.venue)
    }
}
