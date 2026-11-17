import Foundation

public enum Gender: String, Codable, Sendable, CaseIterable {
    case female, male, other, preferNotToSay
}

public enum RegistrationStatus: String, Codable, Sendable {
    /// The personal registered the student; the student hasn't logged in yet.
    case invited
    /// The student completed their first access.
    case active
}

/// A student as the personal trainer registered them (CPF + name), and — once the student completes the first access —
/// what the student filled in. The CPF itself is never stored here: only a masked form for display, and an opaque `id`
/// (a server-side keyed hash of the CPF in production) so the same person can't be registered twice.
public struct StudentRegistration: Syncable, Equatable {
    public var id: String
    public var trainerID: UserID
    public var fullName: String
    public var cpfMasked: String
    public var status: RegistrationStatus
    /// Set when the student claims the registration.
    public var studentID: UserID?
    public var email: String?
    public var age: Int?
    public var gender: Gender?
    /// As the student typed them at first access. The weight is only the starting point: the trainer's measurements take over.
    public var heightCm: Double?
    public var weightKg: Double?
    public var createdAt: Date
    public var meta: SyncMetadata

    public init(id: String, trainerID: UserID, fullName: String, cpfMasked: String, status: RegistrationStatus = .invited,
                studentID: UserID? = nil, email: String? = nil, age: Int? = nil, gender: Gender? = nil,
                heightCm: Double? = nil, weightKg: Double? = nil, createdAt: Date, meta: SyncMetadata) {
        self.id = id
        self.trainerID = trainerID
        self.fullName = fullName
        self.cpfMasked = cpfMasked
        self.status = status
        self.studentID = studentID
        self.email = email
        self.age = age
        self.gender = gender
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.createdAt = createdAt
        self.meta = meta
    }
}

public struct NewStudentProfile: Equatable, Sendable {
    public var email: String
    public var age: Int
    public var gender: Gender
    public var heightCm: Double
    public var weightKg: Double

    public init(email: String, age: Int, gender: Gender, heightCm: Double, weightKg: Double) {
        self.email = email
        self.age = age
        self.gender = gender
        self.heightCm = heightCm
        self.weightKg = weightKg
    }
}

public enum RegistrationError: Error, Equatable, Sendable {
    case invalidCPF, invalidName
    /// The trainer already registered this CPF.
    case duplicate
    /// No registration matches this CPF **and** name. Deliberately the same answer for "unknown CPF" and "wrong name", so the
    /// first-access screen can't be used to find out which CPFs are registered.
    case notFound
    case alreadyClaimed
    case invalidEmail, invalidAge, invalidHeight, invalidWeight, weakPassword
    /// The reset code is wrong, expired or already used (all the same answer on purpose).
    case invalidCode
    case notConfigured, offline
    /// Too many first-access attempts (the backend rate-limits them so CPFs can't be guessed).
    case tooManyAttempts
}

/// Proof that step 1 of the first access (CPF + name) matched, to be redeemed in step 2 (profile + password).
public struct ClaimTicket: Equatable, Sendable {
    public let registrationID: String
    public let trainerName: String?
    /// Opaque; issued by whoever verified the match.
    public let token: String

    public init(registrationID: String, trainerName: String?, token: String) {
        self.registrationID = registrationID
        self.trainerName = trainerName
        self.token = token
    }
}

/// Trainer side: register students (CPF + name) and list them.
public protocol StudentRegistering: Sendable {
    func register(cpf: String, fullName: String, trainerID: UserID) async throws -> StudentRegistration
    func registrations(trainerID: UserID) async throws -> [StudentRegistration]
}

/// Student side: first access. Step 1 proves the CPF + name match a registration; step 2 creates the account.
public protocol FirstAccessService: Sendable {
    func claim(cpf: String, fullName: String) async throws -> ClaimTicket
    func complete(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> SignedInUser
}

/// Forgot password. The student proves who they are with the CPF and the e-mail they registered at first access; a one-time code goes to that
/// e-mail, and the code plus a new password finish the job.
public protocol PasswordResetting: Sendable {
    /// Returns normally for any well-formed CPF and e-mail, matching a registration or not, so the screen can't be used to find out who is
    /// registered. A code is only sent (to the *registered* address) when they match.
    func requestReset(cpf: String, email: String) async throws
    /// Wrong, expired and unknown all fail the same way (`invalidCode`); too many misses lock the code (`tooManyAttempts`).
    func confirmReset(cpf: String, code: String, newPassword: String) async throws
    /// Demo and UI-test builds have no mailbox, so the screen tells the tester the code. `nil` in production.
    var demoCode: String? { get }
}

/// Turns a CPF/CREF into the opaque login name used with the authentication provider. The backend computes it with a secret (HMAC) for
/// *any* input — it never looks anything up — so asking for an alias reveals nothing about who is registered; only the password check does.
public protocol LoginAliasing: Sendable {
    func alias(for credential: CredentialKind) async throws -> String
}

/// Opaque registration key for a CPF. Production derives it with a secret held by the backend, so it can't be brute-forced
/// from the (small) CPF space; demo and tests use a plain hash.
public protocol RegistrationKeying: Sendable {
    func key(forCPF digits: String) -> String
}

public enum RegistrationRules {
    public static let minimumPasswordLength = 8
    public static let ageRange = 12...100
    public static let heightRangeCm = 100.0...250.0
    public static let weightRangeKg = 20.0...400.0

    public static func cpf(_ input: String) throws -> String {
        guard let digits = BrazilianCredentialRecognizer.normalizedCPF(input) else { throw RegistrationError.invalidCPF }
        return digits
    }

    /// At least two words, letters only (plus spaces, apostrophes, hyphens), at most 120 characters.
    public static func fullName(_ input: String) throws -> String {
        let collapsed = input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let words = collapsed.split(separator: " ")
        let allowed = collapsed.allSatisfy { $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" || $0 == "’" }
        guard words.count >= 2, collapsed.count <= 120, allowed else { throw RegistrationError.invalidName }
        return collapsed
    }

    /// Trimmed and lower-cased, or `invalidEmail`.
    public static func email(_ input: String) throws -> String {
        let email = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil, email.count <= 254 else { throw RegistrationError.invalidEmail }
        return email
    }

    public static let resetCodeLength = 6

    /// The six digits of a reset code, however the student typed them ("123 456", "123-456").
    public static func resetCode(_ input: String) throws -> String {
        let digits = input.filter(\.isASCII).filter(\.isNumber)
        guard digits.count == resetCodeLength, input.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { throw RegistrationError.invalidCode }
        return digits
    }

    public static func newPassword(_ password: String) throws {
        guard password.count >= minimumPasswordLength, password.count <= 128 else { throw RegistrationError.weakPassword }
    }

    public static func profile(_ profile: NewStudentProfile, password: String) throws -> NewStudentProfile {
        let email = try email(profile.email)
        guard ageRange.contains(profile.age) else { throw RegistrationError.invalidAge }
        guard heightRangeCm.contains(profile.heightCm) else { throw RegistrationError.invalidHeight }
        guard weightRangeKg.contains(profile.weightKg) else { throw RegistrationError.invalidWeight }
        guard password.count >= minimumPasswordLength else { throw RegistrationError.weakPassword }
        return NewStudentProfile(email: email, age: profile.age, gender: profile.gender,
                                 heightCm: (profile.heightCm * 10).rounded() / 10, weightKg: (profile.weightKg * 10).rounded() / 10)
    }

    /// "***.982.247-**": enough for the trainer to recognise the student, not enough to use the CPF.
    public static func masked(cpf digits: String) -> String {
        guard digits.count == 11 else { return "***" }
        let d = Array(digits)
        return "***.\(String(d[3..<6])).\(String(d[6..<9]))-**"
    }

    /// Lower-case, accents folded, whitespace collapsed — so "JOSÉ  da Silva" matches "jose da silva".
    public static func normalizedName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func namesMatch(_ a: String, _ b: String) -> Bool { normalizedName(a) == normalizedName(b) }
}

// MARK: - Trainer-only nickname

/// A private label the personal gives a student ("Maria da 7h"), in addition to their name. It lives in the trainer's own
/// namespace (`trainers/{id}/nicknames`), which the student's account cannot read — it never appears anywhere in the student's app.
public struct StudentNickname: Syncable, Equatable {
    /// The student's registration id.
    public var id: String
    public var trainerID: UserID
    public var nickname: String
    public var meta: SyncMetadata

    public init(id: String, trainerID: UserID, nickname: String, meta: SyncMetadata) {
        self.id = id
        self.trainerID = trainerID
        self.nickname = nickname
        self.meta = meta
    }
}

public protocol NicknameRepository: Sendable {
    /// registration id → nickname, for one trainer.
    func nicknames(trainerID: UserID) async throws -> [String: String]
    /// An empty/blank nickname removes it.
    func setNickname(_ nickname: String, forRegistration id: String, trainerID: UserID) async throws
}

public enum NicknameRules {
    public static let maxLength = 30

    /// Trimmed, collapsed whitespace, no control characters, at most 30 characters. Blank → `nil` (meaning "remove").
    public static func clean(_ raw: String) throws -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count <= maxLength, !collapsed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RegistrationError.invalidName
        }
        return collapsed
    }
}
