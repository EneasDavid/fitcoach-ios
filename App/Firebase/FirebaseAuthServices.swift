import DataKit
import Domain
import FirebaseAuth
import FirebaseFirestore
import Foundation

// NOT EXERCISED against a real Firebase project in the authoring environment — see README → "Verification status".

/// CPF/CREF + password → Firebase Auth. The identifier is turned into an opaque login name by our backend (HMAC with a secret; no
/// lookup, so it reveals nothing about who is registered), then the *password* is checked by Firebase Auth itself.
struct FirebaseAuthenticationService: AuthenticationService {
    let aliasing: any LoginAliasing

    func signIn(_ credential: CredentialKind, password: String) async throws -> SignedInUser {
        let alias = try await aliasing.alias(for: credential)
        let result: AuthDataResult
        do {
            result = try await Auth.auth().signIn(withEmail: alias, password: password)
        } catch let error as NSError {
            guard error.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: error.code) else { throw AuthenticationError.offline }
            switch code {
            case .networkError: throw AuthenticationError.offline
            default: throw AuthenticationError.invalidCredentials           // wrong password, unknown account, disabled… all look the same
            }
        }
        let snapshot = try await Firestore.firestore().collection("users").document(result.user.uid).getDocument()
        guard let raw = snapshot.data()?["role"] as? String, let role = UserRole(rawValue: raw) else { throw AuthenticationError.invalidCredentials }
        var typedCREF: String?
        if case .cref(let registration) = credential { typedCREF = registration }        // offered as the trainer's professional details
        return SignedInUser(userID: UserID(result.user.uid), role: role,
                            displayName: (snapshot.data()?["displayName"] as? String) ?? result.user.displayName ?? "", cref: typedCREF)
    }
}

/// First access in production: the backend verifies CPF + name and creates the account; the app then trades the one-time token for a session.
struct FirebaseFirstAccessService: FirstAccessService {
    let client: BackendRegistrationClient

    func claim(cpf: String, fullName: String) async throws -> ClaimTicket { try await client.claim(cpf: cpf, fullName: fullName) }

    func complete(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> SignedInUser {
        let (user, token) = try await client.completeReturningToken(ticket, profile: profile, password: password)
        guard let token else { throw RegistrationError.notConfigured }
        _ = try await Auth.auth().signIn(withCustomToken: token)
        return user
    }
}
