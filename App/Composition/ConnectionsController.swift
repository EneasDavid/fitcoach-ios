import DataKit
import Domain
import Foundation
import PresentationKit

/// The app-side half of the Connections screen: CoreLocation, the OAuth sheets, the Keychain and the backend.
@MainActor
final class ConnectionsController: ConnectionsActions {
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    func status() async -> ConnectionStatus {
        let gyms = await container.selectedGyms()?.load() ?? []
        let spotifyConnected = await container.spotifyTokens?.isConnected ?? false
        return ConnectionStatus(gymDetectionOn: container.gymDetectionEnabled && !gyms.isEmpty,
                                gymName: gyms.last?.name,
                                spotifyAvailable: container.spotifyTokens != nil,
                                spotifyConnected: spotifyConnected,
                                stravaAvailable: container.backend != nil)
    }

    func setGymDetection(enabled: Bool) async throws {
        if enabled {
            guard let gyms = await container.selectedGyms()?.load(), !gyms.isEmpty else { throw ConnectionFailure.notConfigured }
            if CurrentLocation.isDenied { throw ConnectionFailure.permissionDenied }
        }
        container.gymDetectionEnabled = enabled
        await container.restartGymMonitoring()
    }

    // MARK: Spotify (Authorization Code + PKCE; tokens in the Keychain)

    func connectSpotify() async throws {
        guard let clientID = container.config.spotifyClientID, let tokens = container.spotifyTokens else { throw ConnectionFailure.notConfigured }
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let url = SpotifyOAuth.authorizationURL(clientID: clientID, redirectURI: AppConfig.spotifyRedirectURI, pkce: pkce, state: state)
        let callback = try await WebAuthSession.start(url: url, callbackScheme: "fitcoach")
        guard let code = SpotifyOAuth.authorizationCode(from: callback, expectedState: state) else { throw ConnectionFailure.signInFailed }
        do {
            try await tokens.connect(code: code, redirectURI: AppConfig.spotifyRedirectURI, verifier: pkce.verifier)
        } catch { throw ConnectionFailure.signInFailed }
        await container.syncListening()
    }

    func disconnectSpotify() async { await container.spotifyTokens?.disconnect() }

    // MARK: Strava (OAuth happens on our backend; the app only opens the page it vouches for)

    func connectStrava() async throws {
        guard let backend = container.backend else { throw ConnectionFailure.notConfigured }
        let url = try await backend.stravaAuthorizationURL()
        let callback = try await WebAuthSession.start(url: url, callbackScheme: "fitcoach")
        let status = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "status" }?.value
        switch status {
        case "connected": return                          // the server-written link arrives through the inbound listener
        case "denied": throw ConnectionFailure.cancelled
        default: throw ConnectionFailure.signInFailed
        }
    }

    func disconnectStrava() async throws {
        guard let backend = container.backend else { throw ConnectionFailure.notConfigured }
        try await backend.disconnectStrava()
    }
}
