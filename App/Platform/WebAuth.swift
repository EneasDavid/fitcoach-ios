import AuthenticationServices
import PresentationKit
import UIKit

/// `ASWebAuthenticationSession` as an `async` call, for the Spotify and Strava consent pages. The system browser sheet
/// keeps the user's password out of the app's reach (OWASP M1/M3) — the app only ever sees the redirect.
@MainActor
enum WebAuthSession {
    static func start(url: URL, callbackScheme: String) async throws -> URL {
        let runner = Runner()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                _ = runner                                            // keep the presenter alive until the sheet is done
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: ConnectionFailure.cancelled)
                } else {
                    continuation.resume(throwing: ConnectionFailure.signInFailed)
                }
            }
            session.presentationContextProvider = runner
            session.prefersEphemeralWebBrowserSession = false         // reuse the user's existing Spotify/Strava session in Safari
            if !session.start() { continuation.resume(throwing: ConnectionFailure.signInFailed) }
        }
    }

    private final class Runner: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
