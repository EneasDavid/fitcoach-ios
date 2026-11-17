import Foundation
import Testing
@testable import Domain

actor InMemoryTrainerProfiles: TrainerProfileRepository {
    private(set) var stored: [UserID: TrainerProfile] = [:]
    private(set) var saves = 0
    func save(_ profile: TrainerProfile) async throws -> TrainerProfile {
        saves += 1
        var saved = profile
        saved.meta.version += 1
        stored[profile.id] = saved
        return saved
    }
    func profile(trainerID: UserID) async throws -> TrainerProfile? { stored[trainerID] }
    nonisolated func observeProfile(trainerID: UserID) -> AsyncStream<TrainerProfile?> { AsyncStream { $0.finish() } }
}

@Suite("TrainerProfile")
struct TrainerProfileTests {
    func profile(_ configure: (inout TrainerProfile) -> Void = { _ in }) -> TrainerProfile {
        var p = TrainerProfile(id: "t1", displayName: "Personal Demo", meta: Fx.meta())
        configure(&p)
        return p
    }

    @Test("A CREF is normalised to NNNNNN-G/UF however it was typed, and printed as 'CREF …'")
    func crefNormalised() throws {
        for typed in ["012345-G/AL", "12345 g/al", "cref 012345-g/al", "  012345-G/AL "] {
            let valid = try profile { $0.cref = typed }.validated()
            #expect(valid.cref == "012345-G/AL", "\(typed)")
        }
        #expect(try profile { $0.cref = "1234-P/SP" }.validated().cref == "001234-P/SP")
        #expect(profile { $0.cref = "012345-G/AL" }.crefDisplay == "CREF 012345-G/AL")
        #expect(profile().crefDisplay == nil)
    }

    @Test("Anything that isn't a CREF is refused: wrong category, state, length, characters")
    func crefRefused() {
        for bad in ["", "abc", "012345-X/AL", "012345-G/XX", "123-G/AL", "1234567-G/AL", "01234A-G/AL", "012345-G", "390.533.447-05"] {
            #expect(throws: DomainError.self, "\(bad)") { try profile { $0.cref = bad }.validated() }
        }
    }

    @Test("The name is trimmed and collapsed, and bounded; the photo is bounded")
    func nameAndPhoto() throws {
        #expect(try profile { $0.displayName = "  Ana   Lima " }.validated().displayName == "Ana Lima")
        #expect(throws: DomainError.self) { try profile { $0.displayName = "   " }.validated() }
        #expect(throws: DomainError.self) { try profile { $0.displayName = String(repeating: "x", count: 121) }.validated() }
        _ = try profile { $0.photo = Data(count: TrainerProfile.maxPhotoBytes) }.validated()
        #expect(throws: DomainError.self) { try profile { $0.photo = Data(count: TrainerProfile.maxPhotoBytes + 1) }.validated() }
    }
}

@Suite("PublishTrainerProfileUseCase")
struct PublishTrainerProfileTests {
    func useCase(_ repo: InMemoryTrainerProfiles) -> PublishTrainerProfileUseCase {
        PublishTrainerProfileUseCase(repository: repo, deviceID: "d", now: { Fx.date(day: 2) })
    }

    @Test("The first sign-in creates the profile with the name, the CREF typed at sign-in and the photo")
    func creates() async throws {
        let repo = InMemoryTrainerProfiles()
        let saved = try await useCase(repo).execute(trainerID: "t1", displayName: "Personal Demo") { $0.cref = "012345-g/al"; $0.photo = Data([1, 2]) }
        #expect(saved.displayName == "Personal Demo" && saved.cref == "012345-G/AL" && saved.photo == Data([1, 2]))
        #expect(await repo.stored["t1"] != nil)
    }

    @Test("Signing in again changes nothing and writes nothing (no version bump, no photo re-upload)")
    func idempotent() async throws {
        let repo = InMemoryTrainerProfiles()
        let uc = useCase(repo)
        _ = try await uc.execute(trainerID: "t1", displayName: "Personal Demo") { $0.cref = "012345-G/AL" }
        _ = try await uc.execute(trainerID: "t1", displayName: "Personal Demo")
        _ = try await uc.execute(trainerID: "t1", displayName: "Personal Demo") { $0.cref = "012345-G/AL" }
        #expect(await repo.saves == 1)
    }

    @Test("A real change is saved; the name follows the account; a bad CREF is refused and nothing is stored")
    func changes() async throws {
        let repo = InMemoryTrainerProfiles()
        let uc = useCase(repo)
        _ = try await uc.execute(trainerID: "t1", displayName: "Personal Demo")
        let renamed = try await uc.execute(trainerID: "t1", displayName: "Personal Demo Silva")
        #expect(renamed.displayName == "Personal Demo Silva")
        let withCREF = try await uc.execute(trainerID: "t1", displayName: "Personal Demo Silva") { $0.cref = "000123-P/SP" }
        #expect(withCREF.cref == "000123-P/SP")
        await #expect(throws: DomainError.self) { try await uc.execute(trainerID: "t1", displayName: "Personal Demo Silva") { $0.cref = "nope" } }
        #expect(await repo.stored["t1"]?.cref == "000123-P/SP")
        let cleared = try await uc.execute(trainerID: "t1", displayName: "Personal Demo Silva") { $0.cref = nil; $0.photo = nil }
        #expect(cleared.cref == nil && cleared.photo == nil)
        #expect(await repo.saves == 4)
    }
}

@Suite("Credentials: normalized CREF")
struct NormalizedCREFTests {
    @Test("The public helper accepts what the sign-in recognizer accepts")
    func helper() {
        #expect(BrazilianCredentialRecognizer.normalizedCREF("cref 12345 g/al") == "012345-G/AL")
        #expect(BrazilianCredentialRecognizer.normalizedCREF("390.533.447-05") == nil)
        #expect(BrazilianCredentialRecognizer().recognize("012345-G/AL") == .cref("012345-G/AL"))
    }

    @Test("A signed-in trainer can carry the CREF typed at sign-in; a student never does")
    func signedInUser() {
        #expect(SignedInUser(userID: "t", role: .trainer, displayName: "P", cref: "012345-G/AL").cref == "012345-G/AL")
        #expect(SignedInUser(userID: "s", role: .student, displayName: "A").cref == nil)
    }
}
