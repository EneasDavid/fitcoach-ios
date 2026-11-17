import DataKit
import FirebaseAppCheck
import FirebaseAuth
import Foundation

/// Credentials for calls to our own Cloud Functions: the user's Firebase ID token plus an App Check token (proves the call
/// comes from a genuine build of this app). No third-party key is ever involved.
struct FirebaseBackendCredentials: BackendCredentialProviding {
    func headers() async throws -> [String: String] {
        guard let user = Auth.auth().currentUser else { throw IntegrationError.unauthorized }
        let idToken = try await user.getIDToken()
        let appCheck = try await AppCheck.appCheck().token(forcingRefresh: false).token
        return ["Authorization": "Bearer \(idToken)", "X-Firebase-AppCheck": appCheck]
    }
}

/// For calls made *before an account exists* (first access, login alias): App Check only. The backend rate-limits them.
struct FirebaseAppCheckCredentials: BackendCredentialProviding {
    func headers() async throws -> [String: String] {
        ["X-Firebase-AppCheck": try await AppCheck.appCheck().token(forcingRefresh: false).token]
    }
}
