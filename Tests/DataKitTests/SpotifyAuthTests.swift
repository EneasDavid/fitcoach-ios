import Foundation
import Testing
import Domain
import SecurityKit
@testable import DataKit

@Suite("Spotify authorisation (PKCE)")
struct SpotifyAuthTests {
    @Test("The challenge is BASE64URL(SHA-256(verifier)) — RFC 7636 appendix B vector")
    func rfcVector() {
        #expect(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Generated verifiers are unique, URL-safe and within the RFC's 43–128 characters")
    func generation() {
        let a = PKCE.generate(), b = PKCE.generate()
        #expect(a.verifier != b.verifier && a.challenge != b.challenge)
        #expect((43...128).contains(a.verifier.count))
        #expect(a.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(a.challenge == PKCE(verifier: a.verifier).challenge)
    }

    @Test("The authorisation URL asks for the read-only scope with PKCE and state, and nothing else")
    func authorizationURL() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = SpotifyOAuth.authorizationURL(clientID: "cid", redirectURI: "fitcoach://spotify", pkce: pkce, state: "xyz")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.spotify.com" && url.path == "/authorize")
        #expect(items["scope"] == "user-read-recently-played")
        #expect(items["code_challenge_method"] == "S256" && items["code_challenge"] == pkce.challenge)
        #expect(items["state"] == "xyz" && items["response_type"] == "code" && items["client_id"] == "cid")
        #expect(items["client_secret"] == nil)
    }

    @Test("The callback is only accepted with the matching state and a code")
    func callback() {
        func code(_ url: String) -> String? { SpotifyOAuth.authorizationCode(from: URL(string: url)!, expectedState: "xyz") }
        #expect(code("fitcoach://spotify?code=abc&state=xyz") == "abc")
        #expect(code("fitcoach://spotify?code=abc&state=other") == nil)          // forged / replayed callback
        #expect(code("fitcoach://spotify?code=abc") == nil)
        #expect(code("fitcoach://spotify?error=access_denied&state=xyz") == nil)
        #expect(code("fitcoach://spotify?code=&state=xyz") == nil)
    }

    @Test("Token requests are form-encoded with the verifier — and never carry a client secret")
    func requests() throws {
        let exchange = SpotifyOAuth.exchangeRequest(clientID: "cid", code: "a b&c", redirectURI: "fitcoach://spotify", verifier: "ver")
        let body = String(decoding: try #require(exchange.httpBody), as: UTF8.self)
        #expect(exchange.httpMethod == "POST" && exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(body.contains("grant_type=authorization_code") && body.contains("code_verifier=ver") && body.contains("client_id=cid"))
        #expect(body.contains("code=a%20b%26c"))                                   // special characters are escaped
        #expect(!body.contains("secret"))
        let refresh = String(decoding: try #require(SpotifyOAuth.refreshRequest(clientID: "cid", refreshToken: "r").httpBody), as: UTF8.self)
        #expect(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=r"))
    }
}

@Suite("SpotifyTokenStore")
struct SpotifyTokenStoreTests {
    func token(_ access: String, refresh: String? = "refresh-1", expires: Int = 3_600) -> String {
        let refreshField = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
        return #"{"access_token":"\#(access)","token_type":"Bearer","expires_in":\#(expires)\#(refreshField)}"#
    }

    @Test("Connect stores tokens in the secure store; a fresh token is returned without a network call")
    func connectAndUse() async throws {
        let secrets = InMemorySecureStore()
        let http = ScriptedHTTP([(200, token("access-1"))])
        let store = SpotifyTokenStore(clientID: "cid", secrets: secrets, http: http, now: { DFx.t0 })
        #expect(await store.isConnected == false)
        #expect(try await store.accessToken() == nil)

        try await store.connect(code: "code", redirectURI: "fitcoach://spotify", verifier: "ver")
        #expect(await store.isConnected)
        #expect(try await store.accessToken() == "access-1")
        #expect(await http.requests.count == 1)                                     // only the exchange
        #expect(try secrets.data(forKey: "spotify.tokens") != nil)
    }

    @Test("An expired token is refreshed; a missing new refresh token keeps the old one")
    func refresh() async throws {
        let clock = TestClock()
        let http = ScriptedHTTP([(200, token("access-1", expires: 3_600)), (200, token("access-2", refresh: nil)), (200, token("access-3", refresh: nil))])
        let store = SpotifyTokenStore(clientID: "cid", secrets: InMemorySecureStore(), http: http, now: { clock.now() })
        try await store.connect(code: "c", redirectURI: "r", verifier: "v")

        clock.advance(3_600)                                                       // expired
        #expect(try await store.accessToken() == "access-2")
        clock.advance(3_600)
        #expect(try await store.accessToken() == "access-3")
        let last = try #require(await http.requests.last)
        #expect(String(decoding: try #require(last.httpBody), as: UTF8.self).contains("refresh_token=refresh-1"))   // original kept
    }

    @Test("A revoked refresh token disconnects locally instead of erroring forever")
    func revoked() async throws {
        let clock = TestClock()
        let http = ScriptedHTTP([(200, token("access-1")), (400, #"{"error":"invalid_grant"}"#)])
        let store = SpotifyTokenStore(clientID: "cid", secrets: InMemorySecureStore(), http: http, now: { clock.now() })
        try await store.connect(code: "c", redirectURI: "r", verifier: "v")
        clock.advance(7_200)
        #expect(try await store.accessToken() == nil)
        #expect(await store.isConnected == false)
    }

    @Test("A failed exchange stores nothing; transient refresh errors keep the tokens")
    func failures() async throws {
        let clock = TestClock()
        let secrets = InMemorySecureStore()
        let failing = SpotifyTokenStore(clientID: "cid", secrets: secrets, http: ScriptedHTTP([(400, "{}")]), now: { clock.now() })
        await #expect(throws: IntegrationError.unauthorized) { try await failing.connect(code: "c", redirectURI: "r", verifier: "v") }
        #expect(try secrets.data(forKey: "spotify.tokens") == nil)

        let http = ScriptedHTTP([(200, token("a")), (503, "")])
        let store = SpotifyTokenStore(clientID: "cid", secrets: InMemorySecureStore(), http: http, now: { clock.now() })
        try await store.connect(code: "c", redirectURI: "r", verifier: "v")
        clock.advance(7_200)
        await #expect(throws: IntegrationError.server(status: 503)) { _ = try await store.accessToken() }
        #expect(await store.isConnected)
    }

    @Test("Disconnect removes the tokens")
    func disconnect() async throws {
        let store = SpotifyTokenStore(clientID: "cid", secrets: InMemorySecureStore(), http: ScriptedHTTP([(200, token("a"))]), now: { DFx.t0 })
        try await store.connect(code: "c", redirectURI: "r", verifier: "v")
        await store.disconnect()
        #expect(try await store.accessToken() == nil)
    }
}

@Suite("SelectedGymsStore")
struct SelectedGymsStoreTests {
    func venue(_ id: String) -> GymVenue { GymVenue(id: id, name: "Gym \(id)", latitude: -9.6, longitude: -35.7) }

    @Test("Adds, deduplicates, caps at the limit (newest kept) and clears")
    func lifecycle() async throws {
        let store = SelectedGymsStore(local: InMemoryRecordStore(), owner: "s1", limit: 2)
        #expect(await store.load().isEmpty)
        try await store.add(venue("a"))
        try await store.add(venue("b"))
        #expect(try await store.add(venue("a")).map(\.id) == ["b", "a"])            // re-adding moves it to the newest slot
        #expect(try await store.add(venue("c")).map(\.id) == ["a", "c"])            // over the limit: oldest dropped
        #expect(await store.load().map(\.id) == ["a", "c"])
        try await store.clear()
        #expect(await store.load().isEmpty)
    }

    @Test("Another student never sees it")
    func ownership() async throws {
        let local = InMemoryRecordStore()
        try await SelectedGymsStore(local: local, owner: "s1").add(venue("a"))
        #expect(await SelectedGymsStore(local: local, owner: "s2").load().isEmpty)
    }
}
