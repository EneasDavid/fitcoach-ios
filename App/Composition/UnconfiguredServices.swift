import Domain
import Foundation

/// Production without a backend URL: say so instead of pretending.
struct UnconfiguredRegistering: StudentRegistering {
    func register(cpf: String, fullName: String, trainerID: UserID) async throws -> StudentRegistration { throw RegistrationError.notConfigured }
    func registrations(trainerID: UserID) async throws -> [StudentRegistration] { [] }
}

struct UnconfiguredPasswordReset: PasswordResetting {
    func requestReset(cpf: String, email: String) async throws { throw RegistrationError.notConfigured }
    func confirmReset(cpf: String, code: String, newPassword: String) async throws { throw RegistrationError.notConfigured }
    var demoCode: String? { nil }
}

struct UnconfiguredFirstAccess: FirstAccessService {
    func claim(cpf: String, fullName: String) async throws -> ClaimTicket { throw RegistrationError.notConfigured }
    func complete(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> SignedInUser { throw RegistrationError.notConfigured }
}
