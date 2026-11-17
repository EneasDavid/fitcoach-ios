import Foundation
import Domain
import SecurityKit
import SyncKit
@testable import DataKit

// MARK: - Fixtures

enum DFx {
    static let student: UserID = "s1"
    static let trainer: UserID = "t1"
    static let t0 = Date(timeIntervalSince1970: 1_704_067_200)   // Monday 2024-01-01 UTC

    static func meta(_ version: Int = 0) -> SyncMetadata {
        SyncMetadata(version: version, updatedAt: t0, lastWriterDeviceID: "seed", state: .synced)
    }

    static func log(id: String = UUID().uuidString.lowercased(), plan: PlanID = "p1", student: UserID = student,
                    start: Date = t0, sets: Int = 0) -> WorkoutLog {
        var log = WorkoutLog(id: LogID(id), planID: plan, templateID: "tpl-a", templateLabel: "A", studentID: student,
                             startedAt: start, meta: meta())
        if sets > 0 {
            log.record(.resistance(ResistanceLog(blockID: "b1", exercise: ExerciseRef(id: "ex1", name: "Squat"),
                                                 sets: (1...sets).map { SetLog(index: $0, weightKg: 100, reps: 5, completedAt: start) })))
        }
        return log
    }

    static func plan(id: String = "p1", active: Bool = true, start: Date = t0) -> WorkoutPlan {
        WorkoutPlan(id: PlanID(id), trainerID: trainer, studentID: student, name: "Plan \(id)",
                    templates: [WorkoutTemplate(id: "tpl-a", label: "A", order: 0, blocks: [])],
                    targetSessionsPerWeek: 3, startDate: start, isActive: active, meta: meta())
    }

    static let venue = GymVenue(id: "gym-1", name: "Smart Fit", latitude: -9.6, longitude: -35.7)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = DFx.t0
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

// MARK: - Loopback server (same contract as the Firestore gateway)

actor LoopbackServer: RemoteGateway {
    struct Doc { var fields: [String: JSONValue]; var rev: Int; var mutationID: UUID? }
    private(set) var docs: [DocumentPath: Doc] = [:]

    func seed(_ path: DocumentPath, fields: [String: JSONValue], rev: Int) {
        docs[path] = Doc(fields: fields, rev: rev, mutationID: nil)
    }

    func apply(_ mutation: Mutation) async throws -> RemoteApplyResult {
        let existing = docs[mutation.path]
        if let existing, existing.mutationID == mutation.id { return RemoteApplyResult(version: existing.rev, alreadyApplied: true) }
        let current = existing?.rev ?? 0
        if let base = mutation.baseVersion, base != current { throw RemoteError.conflict(serverVersion: current) }
        switch mutation.kind {
        case .upsert, .patch:
            docs[mutation.path] = Doc(fields: (existing?.fields ?? [:]).merging(mutation.payload) { _, new in new },
                                      rev: current + 1, mutationID: mutation.id)
        case .delete:
            docs[mutation.path] = nil
        }
        return RemoteApplyResult(version: current + 1)
    }

    func fetch(_ path: DocumentPath) async throws -> RemoteDocument? {
        docs[path].map { RemoteDocument(fields: $0.fields, version: $0.rev, updatedAt: nil) }
    }
}

actor FailingQueueStore: MutationStore {
    func loadAll() async throws -> [Mutation] { [] }
    func save(_ mutation: Mutation) async throws { throw Failure() }
    func remove(ids: [UUID]) async throws {}
    struct Failure: Error {}
}

// MARK: - Full offline-first stack, wired the way the app's composition root wires it

struct Stack {
    let clock = TestClock()
    let secrets = InMemorySecureStore()
    let backing = InMemoryRecordStore()
    let records: SealedRecordStore
    let queueStore = InMemoryMutationStore()
    let queue: MutationQueue
    let server = LoopbackServer()
    let network: ControllableNetworkMonitor
    let dispatcher: SyncDispatcher
    let logs: OfflineFirstStore<WorkoutLog>
    let plans: OfflineFirstStore<WorkoutPlan>

    init(online: Bool = true, resolver: any ConflictResolving = PolicyConflictResolver.fitCoach) {
        let clock = self.clock
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: secrets), purpose: "records")
        let records = SealedRecordStore(inner: backing, cipher: cipher)
        let queue = MutationQueue(store: queueStore, now: { clock.now() })
        let network = ControllableNetworkMonitor(online: online)
        let trigger = DeferredSyncTrigger()

        let logs = OfflineFirstStore(descriptor: .workoutLog, store: records, queue: queue, trigger: trigger,
                                     deviceID: "iphone", now: { clock.now() })
        let plans = OfflineFirstStore(descriptor: .workoutPlan, store: records, queue: queue, trigger: trigger,
                                      deviceID: "iphone", now: { clock.now() })
        let updater = LocalSyncStateUpdater(store: records, queue: queue,
                                            appliers: ["workoutLogs": logs, "plans": plans], gateway: server)
        let dispatcher = SyncDispatcher(queue: queue, gateway: server, network: network, resolver: resolver,
                                        observer: updater, backoff: BackoffPolicy(jitter: 0),
                                        now: { clock.now() },
                                        sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) },
                                        random: { 0.5 })
        trigger.bind(dispatcher)

        self.records = records
        self.queue = queue
        self.network = network
        self.dispatcher = dispatcher
        self.logs = logs
        self.plans = plans
    }
}
