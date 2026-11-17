import Foundation

/// Build-time configuration for the integrations, read from Info.plist (filled from build settings, see project.yml).
/// Nothing here is a secret — client ids are public by design (Spotify uses PKCE, Strava's secret lives in a Cloud Function).
/// A missing value simply switches that integration off: the screen says "Not set up in this build".
struct AppConfig: Equatable {
    var spotifyClientID: String?
    var backendBaseURL: URL?
    /// Instagram Stories sharing needs the app's Facebook (Meta) App ID.
    var facebookAppID: String?

    static let spotifyRedirectURI = "fitcoach://spotify"

    static func load(from info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> AppConfig {
        func value(_ key: String) -> String? {
            guard let raw = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !raw.hasPrefix("$(") else { return nil }
            return raw
        }
        let backend = value("BackendBaseURL").flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return AppConfig(spotifyClientID: value("SpotifyClientID"), backendBaseURL: backend, facebookAppID: value("FacebookAppID"))
    }
}
