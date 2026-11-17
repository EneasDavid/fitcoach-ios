import Foundation
import Testing
import Domain
import SecurityKit
import SyncKit
@testable import DataKit

@Suite("RegistrationDirectory (trainer registers → student first access)")
struct RegistrationDirectoryTests {
    let trainer: UserID = "t1"
    func directory() -> RegistrationDirectory { RegistrationDirectory(trainerNames: [trainer: "Personal Demo"], now: { DFx.t0 }) }

    @Test("The trainer registers a student by CPF + name; only a masked CPF is kept; the list is theirs alone")
    func register() async throws {
        let dir = directory()
        let maria = try await dir.register(cpf: "529.982.247-25", fullName: "  Maria   Souza ", trainerID: trainer)
        #expect(maria.fullName == "Maria Souza" && maria.status == .invited && maria.studentID == nil)
        #expect(maria.cpfMasked == "***.982.247-**" && !maria.id.contains("52998224725"))
        _ = try await dir.register(cpf: "111.444.777-35", fullName: "João Lima", trainerID: trainer)
        _ = try await dir.register(cpf: "390.533.447-05", fullName: "Outra Pessoa", trainerID: "t2")
        #expect(try await dir.registrations(trainerID: trainer).count == 2)
        #expect(try await dir.registrations(trainerID: "t2").count == 1)
    }

    @Test("First access keeps the height and weight the student typed, rounded to a tenth, and refuses impossible ones")
    func bodyNumbers() async throws {
        let dir = directory()
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "Maria Souza", trainerID: trainer)
        let ticket = try await dir.claim(cpf: "52998224725", fullName: "Maria Souza")
        for (height, weight, expected) in [(99.0, 70.0, RegistrationError.invalidHeight), (251, 70, .invalidHeight), (170, 19, .invalidWeight), (170, 401, .invalidWeight)] {
            await #expect(throws: expected) {
                try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: height, weightKg: weight), password: "longenough")
            }
        }
        _ = try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 165.54, weightKg: 61.26), password: "longenough")
        let saved = try #require(await dir.registrations(trainerID: trainer).first)
        #expect(saved.heightCm == 165.5 && saved.weightKg == 61.3)
        #expect(await dir.registration(forStudent: try #require(saved.studentID))?.id == saved.id)
        #expect(await dir.registration(forStudent: "nobody") == nil)
    }

    func activeStudent(_ dir: RegistrationDirectory, email: String = "Maria@Example.com") async throws {
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "Maria Souza", trainerID: trainer)
        let ticket = try await dir.claim(cpf: "52998224725", fullName: "Maria Souza")
        _ = try await dir.complete(ticket, profile: NewStudentProfile(email: email, age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "first-password")
    }

    @Test("Forgot password: CPF + the registered e-mail, a code, then a new password that really replaces the old one")
    func passwordReset() async throws {
        let dir = directory()
        try await activeStudent(dir)
        #expect(try await dir.signIn(cpf: "529.982.247-25", password: "first-password") != nil)

        try await dir.requestReset(cpf: "529.982.247-25", email: " MARIA@example.COM ")           // case and spaces don't matter
        try await dir.confirmReset(cpf: "52998224725", code: dir.demoCode ?? "", newPassword: "second-password")
        await #expect(throws: AuthenticationError.invalidCredentials) { try await dir.signIn(cpf: "529.982.247-25", password: "first-password") }
        #expect(try await dir.signIn(cpf: "529.982.247-25", password: "second-password")?.displayName == "Maria Souza")
        await #expect(throws: RegistrationError.invalidCode) { try await dir.confirmReset(cpf: "529.982.247-25", code: dir.demoCode ?? "", newPassword: "third-password") }   // one use
    }

    @Test("A wrong e-mail, an unknown CPF and a student who never finished first access all look exactly like success — and send no code")
    func resetNoEnumeration() async throws {
        let dir = directory()
        try await activeStudent(dir)
        _ = try await dir.register(cpf: "111.444.777-35", fullName: "João Lima", trainerID: trainer)          // invited, never claimed
        try await dir.requestReset(cpf: "529.982.247-25", email: "wrong@example.com")
        try await dir.requestReset(cpf: "390.533.447-05", email: "maria@example.com")                          // unknown CPF
        try await dir.requestReset(cpf: "111.444.777-35", email: "maria@example.com")                          // not active
        for cpf in ["529.982.247-25", "390.533.447-05", "111.444.777-35"] {
            await #expect(throws: RegistrationError.invalidCode) { try await dir.confirmReset(cpf: cpf, code: dir.demoCode ?? "", newPassword: "second-password") }
        }
        #expect(try await dir.signIn(cpf: "529.982.247-25", password: "first-password") != nil)               // nothing changed
    }

    @Test("Malformed input is refused locally; the code has to be six digits; the new password has to be strong enough")
    func resetValidation() async throws {
        let dir = directory()
        try await activeStudent(dir)
        await #expect(throws: RegistrationError.invalidCPF) { try await dir.requestReset(cpf: "123", email: "maria@example.com") }
        await #expect(throws: RegistrationError.invalidEmail) { try await dir.requestReset(cpf: "529.982.247-25", email: "maria") }
        try await dir.requestReset(cpf: "529.982.247-25", email: "maria@example.com")
        await #expect(throws: RegistrationError.invalidCode) { try await dir.confirmReset(cpf: "529.982.247-25", code: "12345", newPassword: "second-password") }
        await #expect(throws: RegistrationError.invalidCode) { try await dir.confirmReset(cpf: "529.982.247-25", code: "abcdef", newPassword: "second-password") }
        await #expect(throws: RegistrationError.weakPassword) { try await dir.confirmReset(cpf: "529.982.247-25", code: "123456", newPassword: "short") }
        try await dir.confirmReset(cpf: "529.982.247-25", code: "123 456", newPassword: "second-password")       // spaces typed by the user are fine
    }

    @Test("Five wrong codes lock the reset, even for the right code; a new request unlocks it")
    func lockout() async throws {
        let dir = directory()
        try await activeStudent(dir)
        try await dir.requestReset(cpf: "529.982.247-25", email: "maria@example.com")
        for _ in 0..<RegistrationDirectory.maxCodeAttempts {
            await #expect(throws: RegistrationError.invalidCode) { try await dir.confirmReset(cpf: "529.982.247-25", code: "000000", newPassword: "second-password") }
        }
        await #expect(throws: RegistrationError.tooManyAttempts) { try await dir.confirmReset(cpf: "529.982.247-25", code: "123456", newPassword: "second-password") }
        try await dir.requestReset(cpf: "529.982.247-25", email: "maria@example.com")
        try await dir.confirmReset(cpf: "529.982.247-25", code: "123456", newPassword: "second-password")
    }

    @Test("A code stops working after 15 minutes")
    func expiry() async throws {
        let clock = TestClock()
        let dir = RegistrationDirectory(trainerNames: [trainer: "Personal Demo"], now: { clock.now() })
        try await activeStudent(dir)
        try await dir.requestReset(cpf: "529.982.247-25", email: "maria@example.com")
        clock.advance(RegistrationDirectory.resetLifetime + 1)
        await #expect(throws: RegistrationError.invalidCode) { try await dir.confirmReset(cpf: "529.982.247-25", code: "123456", newPassword: "second-password") }
    }

    @Test("Bad input and duplicates are refused")
    func refusals() async throws {
        let dir = directory()
        await #expect(throws: RegistrationError.invalidCPF) { try await dir.register(cpf: "123.456.789-00", fullName: "Maria Souza", trainerID: trainer) }
        await #expect(throws: RegistrationError.invalidName) { try await dir.register(cpf: "529.982.247-25", fullName: "Maria", trainerID: trainer) }
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "Maria Souza", trainerID: trainer)
        await #expect(throws: RegistrationError.duplicate) { try await dir.register(cpf: "52998224725", fullName: "Maria Souza", trainerID: "t2") }   // even another trainer
    }

    @Test("First access: CPF + name (case/accents ignored) → ticket → profile + password → an active student")
    func firstAccess() async throws {
        let dir = directory()
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "José da Silva", trainerID: trainer)

        let ticket = try await dir.claim(cpf: "52998224725", fullName: "JOSE  DA SILVA")
        #expect(ticket.trainerName == "Personal Demo")
        let user = try await dir.complete(ticket, profile: NewStudentProfile(email: "Jose@Example.com", age: 34, gender: .male, heightCm: 170, weightKg: 70), password: "supersecret")
        #expect(user.role == .student && user.displayName == "José da Silva")

        let stored = try #require(try await dir.registrations(trainerID: trainer).first)
        #expect(stored.status == .active && stored.studentID == user.userID)
        #expect(stored.email == "jose@example.com" && stored.age == 34 && stored.gender == .male)
    }

    @Test("A wrong CPF and a wrong name get the very same answer (no way to probe which CPFs exist)")
    func noEnumeration() async throws {
        let dir = directory()
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "Maria Souza", trainerID: trainer)
        await #expect(throws: RegistrationError.notFound) { try await dir.claim(cpf: "111.444.777-35", fullName: "Maria Souza") }     // unknown CPF
        await #expect(throws: RegistrationError.notFound) { try await dir.claim(cpf: "529.982.247-25", fullName: "Maria Sousa") }     // wrong name
        await #expect(throws: RegistrationError.notFound) { try await dir.claim(cpf: "123", fullName: "Maria Souza") }                // not even a CPF
    }

    @Test("A registration can be claimed once; a ticket works once; the profile is validated")
    func oneShot() async throws {
        let dir = directory()
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "Maria Souza", trainerID: trainer)
        let ticket = try await dir.claim(cpf: "529.982.247-25", fullName: "Maria Souza")

        await #expect(throws: RegistrationError.weakPassword) { try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "short") }
        await #expect(throws: RegistrationError.invalidAge) { try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 5, gender: .female, heightCm: 170, weightKg: 70), password: "longenough") }
        _ = try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "longenough")

        await #expect(throws: RegistrationError.notFound) { try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "longenough") }
        await #expect(throws: RegistrationError.alreadyClaimed) { try await dir.claim(cpf: "529.982.247-25", fullName: "Maria Souza") }
        let forged = ClaimTicket(registrationID: ticket.registrationID, trainerName: nil, token: "forged")
        await #expect(throws: RegistrationError.notFound) { try await dir.complete(forged, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "longenough") }
    }

    @Test("The demo key is stable and never contains the CPF")
    func keying() {
        let keying = SHA256RegistrationKeying()
        #expect(keying.key(forCPF: "52998224725") == keying.key(forCPF: "52998224725"))
        #expect(keying.key(forCPF: "52998224725") != keying.key(forCPF: "11144477735"))
        #expect(keying.key(forCPF: "52998224725").count == 64)
    }
}

@Suite("BackendRegistrationClient")
struct BackendRegistrationClientTests {
    struct Anonymous: BackendCredentialProviding {
        func headers() async throws -> [String: String] { ["X-Firebase-AppCheck": "ac"] }
    }
    let base = URL(string: "https://fn.example")!

    func client(_ http: ScriptedHTTP) -> BackendRegistrationClient {
        BackendRegistrationClient(baseURL: base, trainerCredentials: FixedHeaders(), anonymousCredentials: Anonymous(), http: http, now: { DFx.t0 })
    }

    @Test("Registering sends the digits and name with the trainer's credentials and returns the server's masked record")
    func register() async throws {
        let http = ScriptedHTTP([(200, #"{"id":"abc123","fullName":"Maria Souza","cpfMasked":"***.982.247-**","createdAt":1704067200}"#)])
        let registration = try await client(http).register(cpf: "529.982.247-25", fullName: "Maria  Souza", trainerID: "t1")
        #expect(registration.id == "abc123" && registration.cpfMasked == "***.982.247-**" && registration.trainerID == "t1")
        let request = try #require(await http.requests.first)
        #expect(request.url?.lastPathComponent == "registerStudent")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer id-token")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(sent == ["cpf": "52998224725", "fullName": "Maria Souza"])
        #expect(request.url?.query == nil)
    }

    @Test("First access uses App Check only (there is no account yet) and maps the three-step answers")
    func firstAccess() async throws {
        let http = ScriptedHTTP([(200, #"{"registrationId":"r1","trainerName":"Personal Demo","token":"tok"}"#),
                                 (200, #"{"userId":"u1","displayName":"Maria Souza"}"#)])
        let service = client(http)
        let ticket = try await service.claim(cpf: "529.982.247-25", fullName: "Maria Souza")
        #expect(ticket == ClaimTicket(registrationID: "r1", trainerName: "Personal Demo", token: "tok"))
        let user = try await service.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "longenough")
        #expect(user == SignedInUser(userID: "u1", role: .student, displayName: "Maria Souza"))

        let first = try #require(await http.requests.first)
        #expect(first.value(forHTTPHeaderField: "Authorization") == nil && first.value(forHTTPHeaderField: "X-Firebase-AppCheck") == "ac")
    }

    @Test("Status codes become the errors the screens understand", arguments: [
        (404, RegistrationError.notFound), (409, .duplicate),
    ])
    func statusMapping(status: Int, expected: RegistrationError) async {
        let service = client(ScriptedHTTP([(status, #"{"error":"duplicate"}"#)]))
        await #expect(throws: expected) { try await service.claim(cpf: "529.982.247-25", fullName: "Maria Souza") }
    }

    @Test("409 with 'already-claimed' is its own error; rate limiting and offline are reported")
    func otherStatuses() async {
        await #expect(throws: RegistrationError.alreadyClaimed) { try await client(ScriptedHTTP([(409, #"{"error":"already-claimed"}"#)])).claim(cpf: "529.982.247-25", fullName: "Maria Souza") }
        await #expect(throws: RegistrationError.tooManyAttempts) {
            try await client(ScriptedHTTP([(429, "{}")], headers: ["Retry-After": "30"])).claim(cpf: "529.982.247-25", fullName: "Maria Souza")
        }
        await #expect(throws: IntegrationError.malformedResponse) { try await client(ScriptedHTTP([(200, "nope")])).claim(cpf: "529.982.247-25", fullName: "Maria Souza") }
    }

    @Test("Nothing is sent when the input is invalid")
    func validatesFirst() async {
        let http = ScriptedHTTP([])
        await #expect(throws: RegistrationError.invalidCPF) { try await client(http).claim(cpf: "111", fullName: "Maria Souza") }
        await #expect(throws: RegistrationError.weakPassword) {
            try await client(http).complete(ClaimTicket(registrationID: "r", trainerName: nil, token: "t"), profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "x")
        }
        #expect(await http.requests.isEmpty)
    }

    @Test("Password reset talks to the two App Check-only endpoints and sends only the digits, the lower-cased e-mail and the code")
    func passwordReset() async throws {
        let http = ScriptedHTTP([(200, #"{"ok":true}"#), (200, #"{"ok":true}"#)])
        let service = client(http)
        try await service.requestReset(cpf: "529.982.247-25", email: " Maria@Example.COM ")
        try await service.confirmReset(cpf: "529.982.247-25", code: "123 456", newPassword: "longenough")
        let requests = await http.requests
        #expect(requests.map { $0.url?.lastPathComponent } == ["requestPasswordReset", "confirmPasswordReset"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "X-Firebase-AppCheck") == "ac" })
        let firstBody = try #require(requests[0].httpBody), secondBody = try #require(requests[1].httpBody)
        let first = try JSONSerialization.jsonObject(with: firstBody) as? [String: String]
        #expect(first == ["cpf": "52998224725", "email": "maria@example.com"])
        let second = try JSONSerialization.jsonObject(with: secondBody) as? [String: String]
        #expect(second == ["cpf": "52998224725", "code": "123456", "password": "longenough"])
        #expect(service.demoCode == nil)                                  // production never hands out a code
        #expect(requests[0].url?.query == nil && requests[1].url?.query == nil)       // nothing personal in a URL
    }

    @Test("The reset answers map to what the screen says: bad code, bad password, rate limit, offline")
    func resetErrors() async {
        func attempt(_ status: Int, _ body: String) async -> Error? {
            do { try await client(ScriptedHTTP([(status, body)])).confirmReset(cpf: "529.982.247-25", code: "123456", newPassword: "longenough"); return nil } catch { return error }
        }
        #expect(await attempt(400, #"{"error":"invalid-code"}"#) as? RegistrationError == .invalidCode)
        #expect(await attempt(400, #"{"error":"invalid-password"}"#) as? RegistrationError == .weakPassword)
        #expect(await attempt(429, #"{"error":"locked"}"#) as? RegistrationError == .tooManyAttempts)
        #expect(await attempt(429, "{}") as? RegistrationError == .tooManyAttempts)
        #expect(await attempt(200, #"{"ok":true}"#) == nil)
    }

    @Test("Nothing is sent when the reset input is invalid")
    func resetValidatesFirst() async {
        let http = ScriptedHTTP([])
        await #expect(throws: RegistrationError.invalidCPF) { try await client(http).requestReset(cpf: "1", email: "m@x.co") }
        await #expect(throws: RegistrationError.invalidEmail) { try await client(http).requestReset(cpf: "529.982.247-25", email: "m") }
        await #expect(throws: RegistrationError.invalidCode) { try await client(http).confirmReset(cpf: "529.982.247-25", code: "12", newPassword: "longenough") }
        await #expect(throws: RegistrationError.weakPassword) { try await client(http).confirmReset(cpf: "529.982.247-25", code: "123456", newPassword: "x") }
        #expect(await http.requests.isEmpty)
    }

    @Test("First access sends the height and weight too")
    func sendsBodyNumbers() async throws {
        let http = ScriptedHTTP([(200, #"{"userId":"u1","displayName":"Maria Souza"}"#)])
        _ = try await client(http).complete(ClaimTicket(registrationID: "r", trainerName: nil, token: "t"),
                                            profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 165.5, weightKg: 61.3), password: "longenough")
        let sentBody = try #require(await http.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(sent["heightCm"] as? Double == 165.5 && sent["weightKg"] as? Double == 61.3)
    }

    @Test("The roster comes from the inbound store (server-written), newest first")
    func roster() async throws {
        let clock = TestClock()
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "records")
        let store = OfflineFirstStore(descriptor: EntityDescriptor<StudentRegistration>.registration,
                                      store: SealedRecordStore(inner: InMemoryRecordStore(), cipher: cipher),
                                      queue: MutationQueue(store: InMemoryMutationStore(), now: { clock.now() }), trigger: DeferredSyncTrigger(), deviceID: "d", now: { clock.now() })
        for (index, name) in ["Ana Lima", "Bia Costa"].enumerated() {
            let registration = StudentRegistration(id: "k\(index)", trainerID: "t1", fullName: name, cpfMasked: "***", createdAt: DFx.t0.addingTimeInterval(Double(index) * 60), meta: DFx.meta())
            _ = try await store.applyRemote(RemoteDocument(fields: try SyncCoding.fields(registration), version: 1))
        }
        let service = BackendRegistrationClient(baseURL: base, trainerCredentials: FixedHeaders(), anonymousCredentials: Anonymous(), reader: StudentRegistrationReader(store: store))
        #expect(try await service.registrations(trainerID: "t1").map(\.fullName) == ["Bia Costa", "Ana Lima"])
        #expect(try await service.registrations(trainerID: "t2").isEmpty)
    }
}

@Suite("Trainer nicknames (private to the personal)")
struct NicknameTests {
    func repo() -> (NicknameRepositoryImpl, OfflineFirstStore<StudentNickname>) {
        let clock = TestClock()
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "records")
        let store = OfflineFirstStore(descriptor: EntityDescriptor<StudentNickname>.nickname, store: SealedRecordStore(inner: InMemoryRecordStore(), cipher: cipher),
                                      queue: MutationQueue(store: InMemoryMutationStore(), now: { clock.now() }), trigger: DeferredSyncTrigger(), deviceID: "d", now: { clock.now() })
        return (NicknameRepositoryImpl(store: store, now: { clock.now() }), store)
    }

    @Test("Set, rename, clear — per student, per trainer")
    func lifecycle() async throws {
        let (repo, _) = repo()
        try await repo.setNickname("  Maria   da 7h ", forRegistration: "r1", trainerID: "t1")
        try await repo.setNickname("Zé", forRegistration: "r2", trainerID: "t1")
        try await repo.setNickname("Other trainer's label", forRegistration: "r9", trainerID: "t2")
        #expect(try await repo.nicknames(trainerID: "t1") == ["r1": "Maria da 7h", "r2": "Zé"])
        #expect(try await repo.nicknames(trainerID: "t2") == ["r9": "Other trainer's label"])

        try await repo.setNickname("Maria 7h", forRegistration: "r1", trainerID: "t1")
        #expect(try await repo.nicknames(trainerID: "t1")["r1"] == "Maria 7h")
        try await repo.setNickname("   ", forRegistration: "r1", trainerID: "t1")                       // blank removes it
        #expect(try await repo.nicknames(trainerID: "t1") == ["r2": "Zé"])
        try await repo.setNickname("Maria de volta", forRegistration: "r1", trainerID: "t1")            // …and it can come back
        #expect(try await repo.nicknames(trainerID: "t1")["r1"] == "Maria de volta")
    }

    @Test("Too long or control characters are refused; the path is in the trainer's own namespace")
    func rules() async throws {
        let (repo, _) = repo()
        await #expect(throws: RegistrationError.invalidName) { try await repo.setNickname(String(repeating: "a", count: 31), forRegistration: "r", trainerID: "t1") }
        await #expect(throws: RegistrationError.invalidName) { try await repo.setNickname("bad\u{0007}", forRegistration: "r", trainerID: "t1") }
        let nickname = StudentNickname(id: "r1", trainerID: "t1", nickname: "x", meta: DFx.meta())
        #expect(EntityDescriptor<StudentNickname>.nickname.path(nickname).description == "trainers/t1/nicknames/r1")
        #expect(EntityDescriptor<StudentRegistration>.registration.path(StudentRegistration(id: "k", trainerID: "t1", fullName: "A B", cpfMasked: "*", createdAt: DFx.t0, meta: DFx.meta())).description == "registrations/k")
    }
}

@Suite("Demo sign-in & login alias")
struct SignInAndAliasTests {
    @Test("After first access the student signs in with the CPF and the password they chose — and only that")
    func demoSignIn() async throws {
        let dir = RegistrationDirectory(now: { DFx.t0 })
        _ = try await dir.register(cpf: "529.982.247-25", fullName: "Maria Souza", trainerID: "t1")
        // Invited, not yet active: cannot sign in.
        await #expect(throws: AuthenticationError.invalidCredentials) { _ = try await dir.signIn(cpf: "52998224725", password: "whatever") }
        let ticket = try await dir.claim(cpf: "52998224725", fullName: "Maria Souza")
        let user = try await dir.complete(ticket, profile: NewStudentProfile(email: "m@x.co", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "longenough")

        #expect(try await dir.signIn(cpf: "529.982.247-25", password: "longenough") == user)
        await #expect(throws: AuthenticationError.invalidCredentials) { _ = try await dir.signIn(cpf: "52998224725", password: "wrong") }
        #expect(try await dir.signIn(cpf: "390.533.447-05", password: "x") == nil)                      // unknown CPF: not this directory's business
    }

    @Test("Seeded demo students are active with a known password")
    func seeded() async throws {
        let dir = RegistrationDirectory(now: { DFx.t0 })
        try await dir.seedActive(cpf: "390.533.447-05", fullName: "Ana Lima", trainerID: "t1", studentID: "stu-ana", email: "a@x.co", age: 25, gender: .female, heightCm: 165, weightKg: 60, password: "demo-pass")
        #expect(try await dir.signIn(cpf: "39053344705", password: "demo-pass")?.userID == "stu-ana")
        let row = try #require(try await dir.registrations(trainerID: "t1").first)
        #expect(row.status == .active && row.email == "a@x.co" && row.age == 25)
    }

    @Test("The backend returns an opaque alias for any CPF/CREF; unknown kinds never reach the network")
    func alias() async throws {
        let http = ScriptedHTTP([(200, #"{"alias":"3f9a1c@students.fitcoach.invalid"}"#)])
        let client = BackendRegistrationClient(baseURL: URL(string: "https://fn.example")!, trainerCredentials: FixedHeaders(),
                                               anonymousCredentials: BackendRegistrationClientTests.Anonymous(), http: http)
        #expect(try await client.alias(for: .cpf("52998224725")) == "3f9a1c@students.fitcoach.invalid")
        let request = try #require(await http.requests.first)
        #expect(request.url?.lastPathComponent == "loginAlias" && request.value(forHTTPHeaderField: "Authorization") == nil)
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(sent == ["identifier": "52998224725"])

        await #expect(throws: AuthenticationError.invalidCredentials) { _ = try await client.alias(for: .unknown) }
        let bad = BackendRegistrationClient(baseURL: URL(string: "https://fn.example")!, trainerCredentials: FixedHeaders(),
                                            anonymousCredentials: BackendRegistrationClientTests.Anonymous(), http: ScriptedHTTP([(200, #"{"alias":"no-at-sign"}"#)]))
        await #expect(throws: IntegrationError.malformedResponse) { _ = try await bad.alias(for: .cref("012345-G/AL")) }
    }
}
