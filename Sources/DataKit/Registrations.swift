import CryptoKit
import Domain
import Foundation
import SyncKit

// MARK: - Local / demo directory

/// Plain SHA-256 key — fine for demos and tests. **Production never uses this**: a CPF has only ~10⁹ possibilities, so an unkeyed
/// hash can be reversed by brute force. The backend derives the key with a secret (HMAC) that never leaves the server.
public struct SHA256RegistrationKeying: RegistrationKeying {
    public init() {}

    public func key(forCPF digits: String) -> String {
        SHA256.hash(data: Data("fitcoach-demo|\(digits)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Registration directory that lives in memory: the whole trainer-registers → student-first-access flow, runnable offline.
/// Used by demo builds and UI tests; the same protocols are implemented over HTTP by `BackendRegistrationClient`.
public actor RegistrationDirectory: StudentRegistering, FirstAccessService, PasswordResetting {
    private var items: [String: StudentRegistration] = [:]
    private var tickets: [String: String] = [:]                       // token → registration id
    private var passwordHashes: [String: String] = [:]                // registration id → hash (demo only)
    private var resetCodes: [String: (code: String, expires: Date, attempts: Int)] = [:]
    private var trainerNames: [UserID: String]
    private let keying: any RegistrationKeying
    private let now: @Sendable () -> Date

    public init(trainerNames: [UserID: String] = [:], keying: any RegistrationKeying = SHA256RegistrationKeying(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.trainerNames = trainerNames
        self.keying = keying
        self.now = now
    }

    // MARK: Trainer

    public func register(cpf: String, fullName: String, trainerID: UserID) async throws -> StudentRegistration {
        let digits = try RegistrationRules.cpf(cpf)
        let name = try RegistrationRules.fullName(fullName)
        let key = keying.key(forCPF: digits)
        guard items[key] == nil else { throw RegistrationError.duplicate }

        let moment = now()
        let registration = StudentRegistration(id: key, trainerID: trainerID, fullName: name, cpfMasked: RegistrationRules.masked(cpf: digits),
                                               createdAt: moment, meta: SyncMetadata(updatedAt: moment, lastWriterDeviceID: "directory", state: .synced))
        items[key] = registration
        return registration
    }

    public func registrations(trainerID: UserID) async throws -> [StudentRegistration] {
        items.values.filter { $0.trainerID == trainerID }.sorted { ($0.createdAt, $0.fullName) > ($1.createdAt, $1.fullName) }
    }

    // MARK: Student

    public func claim(cpf: String, fullName: String) async throws -> ClaimTicket {
        guard let digits = try? RegistrationRules.cpf(cpf), let registration = items[keying.key(forCPF: digits)],
              RegistrationRules.namesMatch(registration.fullName, fullName) else { throw RegistrationError.notFound }   // same answer for both
        guard registration.status == .invited else { throw RegistrationError.alreadyClaimed }
        let token = UUID().uuidString
        tickets[token] = registration.id
        return ClaimTicket(registrationID: registration.id, trainerName: trainerNames[registration.trainerID], token: token)
    }

    public func complete(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> SignedInUser {
        guard tickets[ticket.token] == ticket.registrationID, var registration = items[ticket.registrationID] else { throw RegistrationError.notFound }
        guard registration.status == .invited else { throw RegistrationError.alreadyClaimed }
        let valid = try RegistrationRules.profile(profile, password: password)

        let studentID = UserID("student-\(registration.id.prefix(12))")
        registration.status = .active
        registration.studentID = studentID
        registration.email = valid.email
        registration.age = valid.age
        registration.gender = valid.gender
        registration.heightCm = valid.heightCm
        registration.weightKg = valid.weightKg
        registration.meta.updatedAt = now()
        items[registration.id] = registration
        passwordHashes[registration.id] = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        tickets[ticket.token] = nil                                    // one use
        return SignedInUser(userID: studentID, role: .student, displayName: registration.fullName)
    }

    /// Demo sign-in with the CPF and password chosen at first access. `nil` = no registration for this CPF (the caller decides what that means).
    public func signIn(cpf: String, password: String) async throws -> SignedInUser? {
        guard let digits = try? RegistrationRules.cpf(cpf), let registration = items[keying.key(forCPF: digits)] else { return nil }
        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        guard registration.status == .active, let studentID = registration.studentID, passwordHashes[registration.id] == hash else {
            throw AuthenticationError.invalidCredentials
        }
        return SignedInUser(userID: studentID, role: .student, displayName: registration.fullName)
    }

    /// Seeds an already-active student (demo data).
    public func seedActive(cpf: String, fullName: String, trainerID: UserID, studentID: UserID, email: String, age: Int, gender: Gender,
                           heightCm: Double, weightKg: Double, password: String) throws {
        let digits = try RegistrationRules.cpf(cpf)
        let key = keying.key(forCPF: digits)
        let moment = now()
        items[key] = StudentRegistration(id: key, trainerID: trainerID, fullName: fullName, cpfMasked: RegistrationRules.masked(cpf: digits), status: .active,
                                         studentID: studentID, email: email, age: age, gender: gender, heightCm: heightCm, weightKg: weightKg,
                                         createdAt: moment,
                                         meta: SyncMetadata(updatedAt: moment, lastWriterDeviceID: "directory", state: .synced))
        passwordHashes[key] = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Forgot password (demo: no mailbox, so the code is a known constant the screen displays — production never does this)

    /// The code every demo reset uses. Production codes are random and e-mailed by the backend.
    public static let demoResetCode = "123456"
    public static let resetLifetime: TimeInterval = 15 * 60
    public static let maxCodeAttempts = 5

    public nonisolated var demoCode: String? { Self.demoResetCode }

    public func requestReset(cpf: String, email: String) async throws {
        let digits = try RegistrationRules.cpf(cpf)
        let address = try RegistrationRules.email(email)
        // Same outcome whether or not it matches: nothing to learn from the answer.
        guard let registration = items[keying.key(forCPF: digits)], registration.status == .active,
              registration.email?.lowercased() == address else { return }
        resetCodes[registration.id] = (Self.demoResetCode, now().addingTimeInterval(Self.resetLifetime), 0)
    }

    public func confirmReset(cpf: String, code: String, newPassword: String) async throws {
        try RegistrationRules.newPassword(newPassword)
        let typed = try RegistrationRules.resetCode(code)
        guard let digits = try? RegistrationRules.cpf(cpf), let registration = items[keying.key(forCPF: digits)], registration.status == .active,
              var entry = resetCodes[registration.id], entry.expires > now() else { throw RegistrationError.invalidCode }
        guard entry.attempts < Self.maxCodeAttempts else { throw RegistrationError.tooManyAttempts }
        guard entry.code == typed else {
            entry.attempts += 1
            resetCodes[registration.id] = entry
            throw RegistrationError.invalidCode
        }
        passwordHashes[registration.id] = SHA256.hash(data: Data(newPassword.utf8)).map { String(format: "%02x", $0) }.joined()
        resetCodes[registration.id] = nil                              // one use
    }

    /// The registration a student account belongs to (the student's own device uses it to show their height and weight).
    public func registration(forStudent id: UserID) -> StudentRegistration? { items.values.first { $0.studentID == id } }

    /// Lets the demo remember who the trainer is.
    public func setTrainerName(_ name: String, for id: UserID) { trainerNames[id] = name }
}

// MARK: - Read side for production (server-written, arrives through the inbound listener)

public extension EntityDescriptor where E == StudentRegistration {
    /// `registrations/{key}` — written ONLY by Cloud Functions; the trainer reads their own.
    static var registration: EntityDescriptor<StudentRegistration> {
        EntityDescriptor(collection: "registrations",
                         path: { DocumentPath(collection: "registrations", documentID: $0.id) },
                         ownerID: { $0.trainerID.rawValue },
                         sortDate: { $0.createdAt })
    }
}

public struct StudentRegistrationReader: Sendable {
    private let store: OfflineFirstStore<StudentRegistration>

    public init(store: OfflineFirstStore<StudentRegistration>) { self.store = store }

    public func registrations(trainerID: UserID) async throws -> [StudentRegistration] {
        try await store.list(ownerID: trainerID.rawValue)
    }

    public func observe(trainerID: UserID) -> AsyncStream<[StudentRegistration]> { store.observe(ownerID: trainerID.rawValue) }
}

// MARK: - Backend client

/// Registration over HTTPS to our Cloud Functions. The trainer calls are authenticated (Firebase ID token + App Check); the
/// student's first-access calls happen *before an account exists*, so they carry App Check only — and the backend rate-limits them
/// and answers "not found" for both a wrong CPF and a wrong name.
public struct BackendRegistrationClient: StudentRegistering, FirstAccessService, LoginAliasing, PasswordResetting {
    private let baseURL: URL
    private let trainerCredentials: any BackendCredentialProviding
    private let anonymousCredentials: any BackendCredentialProviding
    private let http: any HTTPRequesting
    private let reader: StudentRegistrationReader?
    private let now: @Sendable () -> Date

    public init(baseURL: URL, trainerCredentials: any BackendCredentialProviding, anonymousCredentials: any BackendCredentialProviding,
                http: any HTTPRequesting = URLSessionRequester(), reader: StudentRegistrationReader? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.trainerCredentials = trainerCredentials
        self.anonymousCredentials = anonymousCredentials
        self.http = http
        self.reader = reader
        self.now = now
    }

    public func register(cpf: String, fullName: String, trainerID: UserID) async throws -> StudentRegistration {
        let digits = try RegistrationRules.cpf(cpf)
        let name = try RegistrationRules.fullName(fullName)
        let data = try await post("registerStudent", ["cpf": digits, "fullName": name], credentials: trainerCredentials)
        guard let body = try? JSONDecoder().decode(RegisteredBody.self, from: data) else { throw IntegrationError.malformedResponse }
        let moment = Date(timeIntervalSince1970: body.createdAt ?? now().timeIntervalSince1970)
        return StudentRegistration(id: body.id, trainerID: trainerID, fullName: body.fullName, cpfMasked: body.cpfMasked,
                                   createdAt: moment, meta: SyncMetadata(updatedAt: moment, lastWriterDeviceID: "server", state: .synced))
    }

    public func registrations(trainerID: UserID) async throws -> [StudentRegistration] {
        try await reader?.registrations(trainerID: trainerID) ?? []
    }

    public func claim(cpf: String, fullName: String) async throws -> ClaimTicket {
        let digits = try RegistrationRules.cpf(cpf)
        let name = try RegistrationRules.fullName(fullName)
        let data = try await post("claimRegistration", ["cpf": digits, "fullName": name], credentials: anonymousCredentials)
        guard let body = try? JSONDecoder().decode(ClaimBody.self, from: data) else { throw IntegrationError.malformedResponse }
        return ClaimTicket(registrationID: body.registrationId, trainerName: body.trainerName, token: body.token)
    }

    public func complete(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> SignedInUser {
        try await completeReturningToken(ticket, profile: profile, password: password).user
    }

    /// Same as `complete`, also returning the one-time sign-in token the backend issued (the app trades it for a session).
    public func completeReturningToken(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> (user: SignedInUser, customToken: String?) {
        let valid = try RegistrationRules.profile(profile, password: password)
        let payload: [String: Any] = ["token": ticket.token, "email": valid.email, "age": valid.age, "gender": valid.gender.rawValue,
                                      "heightCm": valid.heightCm, "weightKg": valid.weightKg, "password": password]
        let data = try await post("completeRegistration", payload, credentials: anonymousCredentials)
        guard let body = try? JSONDecoder().decode(CompleteBody.self, from: data) else { throw IntegrationError.malformedResponse }
        return (SignedInUser(userID: UserID(body.userId), role: .student, displayName: body.displayName), body.customToken)
    }

    public func requestReset(cpf: String, email: String) async throws {
        let digits = try RegistrationRules.cpf(cpf)
        let address = try RegistrationRules.email(email)
        _ = try await post("requestPasswordReset", ["cpf": digits, "email": address], credentials: anonymousCredentials)
    }

    public func confirmReset(cpf: String, code: String, newPassword: String) async throws {
        try RegistrationRules.newPassword(newPassword)
        let typed = try RegistrationRules.resetCode(code)
        let digits = try RegistrationRules.cpf(cpf)
        _ = try await post("confirmPasswordReset", ["cpf": digits, "code": typed, "password": newPassword], credentials: anonymousCredentials)
    }

    public var demoCode: String? { nil }

    public func alias(for credential: CredentialKind) async throws -> String {
        let identifier: String
        switch credential {
        case .cpf(let digits): identifier = digits
        case .cref(let registration): identifier = registration
        case .unknown: throw AuthenticationError.invalidCredentials
        }
        let data = try await post("loginAlias", ["identifier": identifier], credentials: anonymousCredentials)
        guard let body = try? JSONDecoder().decode(AliasBody.self, from: data), body.alias.contains("@") else { throw IntegrationError.malformedResponse }
        return body.alias
    }

    private func post(_ function: String, _ payload: [String: Any], credentials: any BackendCredentialProviding) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(function), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await credentials.headers() { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await http.send(request) } catch is URLError { throw RegistrationError.offline }
        switch response.statusCode {
        case 200..<300: return data
        case 400:
            // The server re-validates; the client already did, so this is a mismatch of rules — except the reset flow, which names its reason.
            switch (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error {
            case "invalid-code": throw RegistrationError.invalidCode
            case "invalid-password": throw RegistrationError.weakPassword
            case "invalid": throw RegistrationError.invalidEmail
            default: throw RegistrationError.invalidName
            }
        case 404: throw RegistrationError.notFound
        case 409:
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw reason == "already-claimed" ? RegistrationError.alreadyClaimed : RegistrationError.duplicate
        case 401, 403: throw IntegrationError.unauthorized
        case 429: throw RegistrationError.tooManyAttempts
        default: throw IntegrationError.server(status: response.statusCode)
        }
    }

    private struct RegisteredBody: Decodable { let id: String; let fullName: String; let cpfMasked: String; let createdAt: Double? }
    private struct ClaimBody: Decodable { let registrationId: String; let trainerName: String?; let token: String }
    private struct CompleteBody: Decodable { let userId: String; let displayName: String; let customToken: String? }
    private struct ErrorBody: Decodable { let error: String }
    private struct AliasBody: Decodable { let alias: String }
}

// MARK: - Trainer-only nicknames

public extension EntityDescriptor where E == StudentNickname {
    /// `trainers/{trainerId}/nicknames/{registrationId}` — readable and writable only by that trainer; no student account can read it.
    static var nickname: EntityDescriptor<StudentNickname> {
        EntityDescriptor(collection: "nicknames",
                         path: { DocumentPath(collection: "trainers/\($0.trainerID)/nicknames", documentID: $0.id) },
                         ownerID: { $0.trainerID.rawValue },
                         sortDate: { $0.meta.updatedAt })
    }
}

public struct NicknameRepositoryImpl: NicknameRepository {
    private let store: OfflineFirstStore<StudentNickname>
    private let now: @Sendable () -> Date

    public init(store: OfflineFirstStore<StudentNickname>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func nicknames(trainerID: UserID) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try await store.list(ownerID: trainerID.rawValue).map { ($0.id, $0.nickname) })
    }

    public func setNickname(_ nickname: String, forRegistration id: String, trainerID: UserID) async throws {
        let existing = try await store.get(id: id).flatMap { $0.trainerID == trainerID ? $0 : nil }
        guard let clean = try NicknameRules.clean(nickname) else {
            if let existing, !existing.meta.isDeleted { _ = try await store.delete(existing) }
            return
        }
        var entity = existing ?? StudentNickname(id: id, trainerID: trainerID, nickname: clean, meta: SyncMetadata(updatedAt: now(), lastWriterDeviceID: ""))
        entity.nickname = clean
        entity.meta.deletedAt = nil
        _ = try await store.save(entity)
    }
}
