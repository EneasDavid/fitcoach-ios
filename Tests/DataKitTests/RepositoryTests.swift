import Foundation
import Testing
import Domain
import SyncKit
@testable import DataKit

@Suite("Repositories")
struct RepositoryTests {
    func repos(_ stack: Stack) -> (logs: WorkoutLogRepositoryImpl, plans: WorkoutPlanRepositoryImpl) {
        (WorkoutLogRepositoryImpl(store: stack.logs), WorkoutPlanRepositoryImpl(store: stack.plans))
    }

    @Test("Log repository filters by plan and date, and never leaks another student's log")
    func logQueries() async throws {
        let stack = Stack(online: false)
        let repo = repos(stack).logs
        try await repo.save(DFx.log(id: "a", plan: "p1", start: DFx.t0))
        try await repo.save(DFx.log(id: "b", plan: "p2", start: DFx.t0.addingTimeInterval(86_400)))
        try await repo.save(DFx.log(id: "c", plan: "p1", start: DFx.t0.addingTimeInterval(2 * 86_400)))

        #expect(try await repo.logs(studentID: "s1", planID: nil, since: nil).map(\.id.rawValue) == ["c", "b", "a"])
        #expect(try await repo.logs(studentID: "s1", planID: "p1", since: nil).map(\.id.rawValue) == ["c", "a"])
        #expect(try await repo.logs(studentID: "s1", planID: nil, since: DFx.t0.addingTimeInterval(86_400)).map(\.id.rawValue) == ["c", "b"])
        #expect(try await repo.log(id: "a", studentID: "s1")?.id == "a")
        #expect(try await repo.log(id: "a", studentID: "someone-else") == nil)
        #expect(try await repo.log(id: "ghost", studentID: "s1") == nil)
    }

    @Test("Deleted logs disappear from reads")
    func deletedLogsHidden() async throws {
        let stack = Stack(online: false)
        let repo = repos(stack).logs
        let saved = try await repo.save(DFx.log(id: "a"))
        try await stack.logs.delete(saved)
        #expect(try await repo.log(id: "a", studentID: "s1") == nil)
        #expect(try await repo.logs(studentID: "s1", planID: nil, since: nil).isEmpty)
    }

    @Test("Observing logs streams updates to the UI")
    func observeLogs() async throws {
        let stack = Stack(online: false)
        let repo = repos(stack).logs
        var iterator = repo.observeLogs(studentID: "s1").makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await repo.save(DFx.log(id: "a"))
        #expect(await iterator.next()?.count == 1)
    }

    @Test("The active plan is the newest active one; inactive and deleted plans are ignored")
    func activePlan() async throws {
        let stack = Stack(online: false)
        let repo = repos(stack).plans
        try await repo.save(DFx.plan(id: "old", active: true, start: DFx.t0))
        try await repo.save(DFx.plan(id: "new", active: true, start: DFx.t0.addingTimeInterval(86_400)))
        try await repo.save(DFx.plan(id: "paused", active: false, start: DFx.t0.addingTimeInterval(2 * 86_400)))
        #expect(try await repo.activePlan(studentID: "s1")?.id == "new")
        #expect(try await repo.plans(studentID: "s1").count == 3)

        let newest = try #require(try await stack.plans.get(id: "new"))
        try await stack.plans.delete(newest)
        #expect(try await repo.activePlan(studentID: "s1")?.id == "old")
        #expect(try await repo.activePlan(studentID: "nobody") == nil)
    }

    @Test("Observing the active plan emits as the trainer's updates arrive")
    func observeActivePlan() async throws {
        let stack = Stack(online: false)
        let repo = repos(stack).plans
        var iterator = repo.observeActivePlan(studentID: "s1").makeAsyncIterator()
        #expect(await iterator.next() == .some(nil))
        try await repo.save(DFx.plan(id: "p1"))
        #expect(await iterator.next()??.id == "p1")
    }

    @Test("Check-ins and body-composition checkpoints persist; invalid measurements never reach storage")
    func otherAggregates() async throws {
        let stack = Stack(online: false)
        let trigger = DeferredSyncTrigger()
        let checkIns = CheckInRepositoryImpl(store: OfflineFirstStore(descriptor: .checkIn, store: stack.records, queue: stack.queue,
                                                                      trigger: trigger, deviceID: "d"))
        let body = BodyCompositionRepositoryImpl(store: OfflineFirstStore(descriptor: .bodyCheckpoint, store: stack.records,
                                                                          queue: stack.queue, trigger: trigger, deviceID: "d"))

        try await checkIns.save(GymCheckIn(studentID: "s1", provider: .geofence, venue: DFx.venue, arrivedAt: DFx.t0, meta: DFx.meta()))
        try await checkIns.save(GymCheckIn(studentID: "s1", provider: .manual, venue: DFx.venue, arrivedAt: DFx.t0.addingTimeInterval(7_200), meta: DFx.meta()))
        #expect(try await checkIns.checkIns(studentID: "s1", since: nil).count == 2)
        #expect(try await checkIns.checkIns(studentID: "s1", since: DFx.t0.addingTimeInterval(3_600)).map(\.provider) == [.manual])

        let valid = BodyCompositionCheckpoint(studentID: "s1", trainerID: "t1", recordedAt: DFx.t0, bodyWeightKg: 80, bodyFatPercent: 18, meta: DFx.meta())
        try await body.save(valid)
        var impossible = valid
        impossible.id = "other"
        impossible.bodyFatPercent = 90
        await #expect(throws: DomainError.self) { try await body.save(impossible) }
        #expect(try await body.checkpoints(studentID: "s1").count == 1)
    }

    @Test("Collections are laid out exactly as the Firestore rules expect")
    func firestorePaths() {
        let log = DFx.log(id: "l1")
        #expect(EntityDescriptor<WorkoutLog>.workoutLog.path(log).description == "students/s1/workoutLogs/l1")
        #expect(EntityDescriptor<WorkoutPlan>.workoutPlan.path(DFx.plan(id: "p1")).description == "plans/p1")
        let checkIn = GymCheckIn(id: "c1", studentID: "s1", provider: .manual, venue: DFx.venue, arrivedAt: DFx.t0, meta: DFx.meta())
        #expect(EntityDescriptor<GymCheckIn>.checkIn.path(checkIn).description == "students/s1/checkIns/c1")
        let checkpoint = BodyCompositionCheckpoint(id: "b1", studentID: "s1", trainerID: "t1", recordedAt: DFx.t0, bodyWeightKg: 80, bodyFatPercent: 18, meta: DFx.meta())
        #expect(EntityDescriptor<BodyCompositionCheckpoint>.bodyCheckpoint.path(checkpoint).description == "students/s1/bodyCheckpoints/b1")
    }

    @Test("Conflict policy: students own their logs, the server owns role/trainer fields")
    func policies() {
        let resolver = PolicyConflictResolver.fitCoach
        func resolve(_ collection: String, kind: MutationKind = .upsert) -> ConflictDecision {
            let mutation = Mutation(path: DocumentPath(collection: collection, documentID: "x"), kind: kind,
                                    payload: ["role": .string("trainer"), "name": .string("n")], createdAt: DFx.t0)
            return resolver.resolve(local: mutation, remote: RemoteDocument(fields: ["role": .string("student")], version: 2, updatedAt: DFx.t0.addingTimeInterval(1)))
        }
        #expect(resolve("students/s1/workoutLogs") == .keepLocal)
        #expect(resolve("plans") == .keepRemote)                            // server edited after the local edit → server wins LWW
        #expect(resolve("users") == .merged(["role": .string("student"), "name": .string("n")]))
    }
}

@Suite("Exercise catalogue")
struct ExerciseCatalogTests {
    final class FakeAPI: RemoteExerciseAPI, @unchecked Sendable {
        let lock = NSLock()
        var online = true
        var results: [Exercise] = []
        var suggestions: [ExerciseSubstitution] = []
        struct Down: Error {}

        var exerciseLookups = 0
        func exercise(id: ExerciseID) async throws -> Exercise? {
            guard lock.withLock({ online }) else { throw Down() }
            lock.withLock { exerciseLookups += 1 }
            return results.first { $0.id == id }
        }
        func search(query: String, limit: Int) async throws -> [Exercise] {
            guard lock.withLock({ online }) else { throw Down() }
            return results.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        }
        func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution] {
            guard lock.withLock({ online }) else { throw Down() }
            return suggestions
        }
        func setOnline(_ value: Bool) { lock.withLock { online = value } }
    }

    static let squat = Exercise(id: "squat", name: "Agachamento Búlgaro", primaryMuscles: [.quadriceps, .glutes], equipment: .dumbbell,
                                imageURL: URL(string: "https://cdn.example/squat.png"), videoURL: URL(string: "https://cdn.example/squat.mp4"))
    static let legPress = Exercise(id: "press", name: "Leg Press", primaryMuscles: [.quadriceps], equipment: .machine)
    static let curl = Exercise(id: "curl", name: "Rosca Direta", primaryMuscles: [.biceps], equipment: .barbell)

    func make(_ api: FakeAPI) -> CachedExerciseCatalogRepository {
        CachedExerciseCatalogRepository(remote: api, store: InMemoryRecordStore())
    }

    @Test("A lookup by id fetches through the catalogue once, then is served from the cache even offline")
    func lookupFetchesThroughAndCaches() async throws {
        let api = FakeAPI()
        api.results = [Self.squat]
        let catalog = make(api)
        #expect(try await catalog.exercise(id: "squat")?.name == "Agachamento Búlgaro")
        api.setOnline(false)
        #expect(try await catalog.exercise(id: "squat")?.name == "Agachamento Búlgaro")
        #expect(api.exerciseLookups == 1)
        #expect(try await catalog.exercise(id: "never-seen") == nil)            // offline and uncached → nil, not a crash
    }

    @Test("Online searches hydrate media and are cached for offline use")
    func cachesOnSearch() async throws {
        let api = FakeAPI()
        api.results = [Self.squat, Self.legPress]
        let catalog = make(api)

        let found = try await catalog.search(query: "leg", limit: 10)
        #expect(found.map(\.id.rawValue) == ["press"])
        _ = try await catalog.search(query: "agacha", limit: 10)
        #expect(try await catalog.exercise(id: "squat")?.videoURL?.absoluteString == "https://cdn.example/squat.mp4")
        #expect(try await catalog.exercise(id: "nope") == nil)
    }

    @Test("Offline search works from the cache — case- and accent-insensitive, prefix matches first")
    func offlineSearch() async throws {
        let api = FakeAPI()
        api.results = [Self.squat, Self.legPress, Self.curl, Exercise(id: "x", name: "Búlgaro Lunge", primaryMuscles: [.glutes], equipment: .bodyweight)]
        let catalog = make(api)
        _ = try await catalog.search(query: "", limit: 50)                  // warm the cache
        api.setOnline(false)

        #expect(try await catalog.search(query: "bulgaro", limit: 10).map(\.id.rawValue) == ["x", "squat"])   // prefix match first
        #expect(try await catalog.search(query: "ROSCA", limit: 10).map(\.id.rawValue) == ["curl"])
        #expect(try await catalog.search(query: "bulgaro", limit: 1).count == 1)
        #expect(try await catalog.search(query: "", limit: 50).count == 4)
        #expect(try await catalog.search(query: "zzz", limit: 10).isEmpty)
    }

    @Test("Substitutions: the API's ranking wins; offline they fall back to on-device muscle matching")
    func substitutions() async throws {
        let api = FakeAPI()
        api.results = [Self.squat, Self.legPress, Self.curl]
        let catalog = make(api)
        _ = try await catalog.search(query: "", limit: 50)

        api.suggestions = [ExerciseSubstitution(original: "squat", candidate: Self.curl, score: 0.9, reason: .equipmentBusy)]
        #expect(try await catalog.substitutions(for: Self.squat, reason: .equipmentBusy, limit: 3).map(\.candidate.id.rawValue) == ["curl"])

        api.suggestions = []
        let local = try await catalog.substitutions(for: Self.squat, reason: .equipmentBusy, limit: 3)
        #expect(local.map(\.candidate.id.rawValue) == ["press"])            // shares quads; the biceps curl is excluded

        api.setOnline(false)
        #expect(try await catalog.substitutions(for: Self.squat, reason: .equipmentBusy, limit: 3).map(\.candidate.id.rawValue) == ["press"])
    }
}

@Suite("Gym arrival providers")
struct GymProviderTests {
    @Test("The simulator only emits while monitoring, to every subscriber")
    func simulator() async throws {
        let provider = SimulatedGymArrivalProvider()
        var first = provider.arrivals().makeAsyncIterator()
        var second = provider.arrivals().makeAsyncIterator()

        provider.simulateArrival(at: DFx.venue)                              // not monitoring → ignored
        try await provider.startMonitoring()
        #expect(provider.isMonitoring)
        provider.simulateArrival(at: DFx.venue, date: DFx.t0)

        let a = await first.next()
        let b = await second.next()
        #expect(a?.venue == DFx.venue && a?.arrivedAt == DFx.t0 && a?.provider == .simulated)
        #expect(a?.externalReference == b?.externalReference)
        await provider.stopMonitoring()
        #expect(!provider.isMonitoring)
    }

    @Test("The factory builds only the sources that are registered and enabled, and merges their events")
    func factoryAndComposite() async throws {
        let geofence = SimulatedGymArrivalProvider(provider: .geofence)
        let partner = SimulatedGymArrivalProvider(provider: .wellhub)
        var factory = GymArrivalProviderFactory()
        factory.register(.geofence) { geofence }
        factory.register(.wellhub) { partner }

        let composite = factory.make(enabled: [.geofence, .wellhub, .smartFit])    // Smart Fit has no adapter in this build
        var iterator = composite.arrivals().makeAsyncIterator()
        try await composite.startMonitoring()
        #expect(geofence.isMonitoring && partner.isMonitoring)

        // Give the merge tasks a moment to subscribe to their children.
        try await Task.sleep(nanoseconds: 50_000_000)
        partner.simulateArrival(at: DFx.venue)
        #expect(await iterator.next()?.provider == .wellhub)
        geofence.simulateArrival(at: DFx.venue)
        #expect(await iterator.next()?.provider == .geofence)

        await composite.stopMonitoring()
        #expect(!geofence.isMonitoring && !partner.isMonitoring)
        #expect(factory.make(enabled: [.smartFit]).provider == .manual)
    }
}
