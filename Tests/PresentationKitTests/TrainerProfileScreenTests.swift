import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

final class FakeTrainerProfiles: TrainerProfileRepository, @unchecked Sendable {
    let pipe = Pipe<TrainerProfile?>()
    func save(_ profile: TrainerProfile) async throws -> TrainerProfile { profile }
    func profile(trainerID: UserID) async throws -> TrainerProfile? { nil }
    func observeProfile(trainerID: UserID) -> AsyncStream<TrainerProfile?> { pipe.stream() }
}

@Suite("Trainer details (CREF) and the student's 'Your trainer'")
@MainActor
struct TrainerProfileScreenTests {
    final class Store { var saved: [String?] = []; var succeed = true }

    func trainerModel(_ store: Store = Store(), cref: String? = nil) -> ProfileViewModel {
        ProfileViewModel(name: "Personal Demo", role: .trainer, cref: cref, pendingChanges: { 0 }, signOut: {},
                         saveCREF: { store.saved.append($0); return store.succeed })
    }

    @Test("Only trainers get a CREF field")
    func onlyTrainers() {
        let student = ProfileViewModel(name: "Aluno", role: .student, pendingChanges: { 0 }, signOut: {})
        #expect(!student.canEditCREF && trainerModel().canEditCREF)
    }

    @Test("A CREF is cleaned up before it is saved, whatever way it was typed")
    func normalises() async {
        let store = Store()
        let model = trainerModel(store)
        await model.setCREF("  cref 12345 g/al ")
        #expect(model.cref == "012345-G/AL" && model.crefError == nil && store.saved == ["012345-G/AL"])
    }

    @Test("A wrong CREF is refused with a message, nothing is saved, and the old one stays")
    func refuses() async {
        let store = Store()
        let model = trainerModel(store, cref: "012345-G/AL")
        await model.setCREF("123")
        #expect(model.cref == "012345-G/AL" && model.crefError != nil && store.saved.isEmpty)
        await model.setCREF("390.533.447-05")                         // a CPF is not a CREF
        #expect(store.saved.isEmpty && model.crefError != nil)
    }

    @Test("Blank removes the CREF; a failed save is reported and keeps the old value")
    func removesAndFails() async {
        let store = Store()
        let model = trainerModel(store, cref: "012345-G/AL")
        store.succeed = false
        await model.setCREF("000999-P/SP")
        #expect(model.cref == "012345-G/AL" && model.crefError != nil)
        store.succeed = true
        await model.setCREF("   ")
        #expect(model.cref == nil && model.crefError == nil && store.saved.last == .some(nil))
    }

    @Test("The student sees the trainer's name, CREF and photo as they change, and nothing before the trainer has published")
    func studentSeesTrainer() async {
        let repo = FakeTrainerProfiles()
        let model = StudentTrainerViewModel(trainerID: "t1", repository: repo)
        let task = Task { await model.run() }
        defer { task.cancel() }
        repo.pipe.send(nil)
        #expect(await FeedFx.wait { model.isLoaded })
        #expect(model.profile == nil)
        repo.pipe.send(TrainerProfile(id: "t1", displayName: "Personal Demo", cref: "012345-G/AL", photo: Data([1]), meta: PFx.meta()))
        #expect(await FeedFx.wait { model.profile?.crefDisplay == "CREF 012345-G/AL" })
        #expect(model.initials == "PD")
        repo.pipe.send(TrainerProfile(id: "t1", displayName: "Personal Demo", cref: nil, meta: PFx.meta()))
        #expect(await FeedFx.wait { model.profile?.cref == nil })
    }

    @Test("The settings screen renders for a trainer, and for a student with and without a published trainer")
    func renders() async {
        _ = ProfileView(model: trainerModel(cref: "012345-G/AL")).body
        let student = ProfileViewModel(name: "Aluno", role: .student, pendingChanges: { 0 }, signOut: {})
        let repo = FakeTrainerProfiles()
        let trainer = StudentTrainerViewModel(trainerID: "t1", repository: repo)
        _ = ProfileView(model: student, trainerModel: trainer).body
        let task = Task { await trainer.run() }
        defer { task.cancel() }
        repo.pipe.send(TrainerProfile(id: "t1", displayName: "Personal Demo", cref: "012345-G/AL", photo: Data([1]), meta: PFx.meta()))
        #expect(await FeedFx.wait { trainer.profile != nil })
        _ = ProfileView(model: student, trainerModel: trainer).body
    }
}
