import Foundation
import Domain
import SyncKit

// MARK: - Descriptors: collection layout (mirrors firebase/firestore.rules and the README schema)

public extension EntityDescriptor where E == WorkoutLog {
    /// `students/{studentId}/workoutLogs/{logId}` — written only by the student.
    static var workoutLog: EntityDescriptor<WorkoutLog> {
        EntityDescriptor(collection: "workoutLogs",
                         path: { DocumentPath(collection: "students/\($0.studentID)/workoutLogs", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.startedAt })
    }
}

public extension EntityDescriptor where E == WorkoutLog {
    /// `students/{studentId}/coachedLogs/{logId}` — workouts the TRAINER ran next to the student. Written only by the linked trainer, read by both.
    /// A separate collection from `workoutLogs` so each document has exactly one writer (the sync gateway replaces whole documents).
    static var coachedLog: EntityDescriptor<WorkoutLog> {
        EntityDescriptor(collection: "coachedLogs",
                         path: { DocumentPath(collection: "students/\($0.studentID)/coachedLogs", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.startedAt })
    }
}

public extension EntityDescriptor where E == WorkoutPlan {
    /// `plans/{planId}` — written only by the owning trainer, readable by the assigned student.
    static var workoutPlan: EntityDescriptor<WorkoutPlan> {
        EntityDescriptor(collection: "plans",
                         path: { DocumentPath(collection: "plans", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.startDate })
    }
}

public extension EntityDescriptor where E == GymCheckIn {
    /// `students/{studentId}/checkIns/{id}`
    static var checkIn: EntityDescriptor<GymCheckIn> {
        EntityDescriptor(collection: "checkIns",
                         path: { DocumentPath(collection: "students/\($0.studentID)/checkIns", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.arrivedAt })
    }
}

public extension EntityDescriptor where E == BodyCompositionCheckpoint {
    /// `students/{studentId}/bodyCheckpoints/{id}` — written by the trainer, readable by the student.
    static var bodyCheckpoint: EntityDescriptor<BodyCompositionCheckpoint> {
        EntityDescriptor(collection: "bodyCheckpoints",
                         path: { DocumentPath(collection: "students/\($0.studentID)/bodyCheckpoints", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.recordedAt })
    }
}

public extension EntityDescriptor where E == ActivityPost {
    /// `students/{studentId}/posts/{postId}` — private to the student (the trainer cannot read posts).
    static var post: EntityDescriptor<ActivityPost> {
        EntityDescriptor(collection: "posts",
                         path: { DocumentPath(collection: "students/\($0.studentID)/posts", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.createdAt })
    }
}

public extension EntityDescriptor where E == TrainerProfile {
    /// `trainerProfiles/{trainerId}` — written by the trainer, readable by the trainer's own students.
    static var trainerProfile: EntityDescriptor<TrainerProfile> {
        EntityDescriptor(collection: "trainerProfiles",
                         path: { DocumentPath(collection: "trainerProfiles", documentID: $0.id.rawValue) },
                         ownerID: { $0.id.rawValue },
                         sortDate: { $0.meta.updatedAt })
    }
}

public extension EntityDescriptor where E == SharedPhoto {
    /// `students/{studentId}/sharedPhotos/{postId}` — written by the student, readable by their linked trainer. Cards stay private.
    static var sharedPhoto: EntityDescriptor<SharedPhoto> {
        EntityDescriptor(collection: "sharedPhotos",
                         path: { DocumentPath(collection: "students/\($0.studentID)/sharedPhotos", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.takenAt })
    }
}

public extension EntityDescriptor where E == ExternalActivity {
    /// `students/{studentId}/externalActivities/{id}` — written ONLY by the webhook's Cloud Function; read-only here.
    static var externalActivity: EntityDescriptor<ExternalActivity> {
        EntityDescriptor(collection: "externalActivities",
                         path: { DocumentPath(collection: "students/\($0.studentID)/externalActivities", documentID: $0.id.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.startedAt })
    }
}

public extension EntityDescriptor where E == IntegrationLink {
    /// `students/{studentId}/integrations/{provider}` — written ONLY by Cloud Functions (OAuth proves ownership); read-only here.
    static var integrationLink: EntityDescriptor<IntegrationLink> {
        EntityDescriptor(collection: "integrations",
                         path: { DocumentPath(collection: "students/\($0.studentID)/integrations", documentID: $0.provider.rawValue) },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.connectedAt ?? $0.meta.updatedAt })
    }
}

public extension EntityDescriptor where E == SharingPreferences {
    /// `students/{studentId}/sharing/preferences` — student-owned; the rules read it to gate trainer access to Strava data.
    static var sharingPreferences: EntityDescriptor<SharingPreferences> {
        EntityDescriptor(collection: "sharing",
                         path: { DocumentPath(collection: "students/\($0.studentID)/sharing", documentID: "preferences") },
                         ownerID: { $0.studentID.rawValue },
                         sortDate: { $0.meta.updatedAt })
    }
}

/// Conflict policy per collection — who is authoritative for what.
public extension PolicyConflictResolver {
    static var fitCoach: PolicyConflictResolver {
        PolicyConflictResolver(policies: [
            "workoutLogs": .clientWins,          // the student's device is the source of truth for their own workouts
            "coachedLogs": .clientWins,          // the trainer's device is the source of truth for the sessions they ran
            "checkIns": .clientWins,
            "plans": .lastWriteWins,             // one trainer, maybe two devices
            "bodyCheckpoints": .lastWriteWins,
            "posts": .clientWins,
            "sharedPhotos": .clientWins,         // the student's pictures; the trainer only reads
            "trainerProfiles": .clientWins,      // the trainer's own name / photo / CREF; students only read
            "nicknames": .clientWins,            // the trainer's private labels
            "registrations": .serverWins,        // created and updated by Cloud Functions only
            "externalActivities": .serverWins,
            "integrations": .serverWins,         // proof of who is connected is never the device's to edit
            "sharing": .clientWins,              // the student's own switches
            "users": .mergePreferringRemote(fields: ["role", "trainerID"]),   // server-owned fields
        ], defaultPolicy: .lastWriteWins)
    }
}

// MARK: - Repository implementations (thin adapters over OfflineFirstStore)

public struct WorkoutLogRepositoryImpl: WorkoutLogRepository {
    private let store: OfflineFirstStore<WorkoutLog>

    public init(store: OfflineFirstStore<WorkoutLog>) { self.store = store }

    public func save(_ log: WorkoutLog) async throws -> WorkoutLog { try await store.save(log) }

    public func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? {
        guard let log = try await store.get(id: id.rawValue), log.studentID == studentID, !log.meta.isDeleted else { return nil }
        return log
    }

    public func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] {
        try await store.list(ownerID: studentID.rawValue).filter { log in
            (planID == nil || log.planID == planID) && (since == nil || log.startedAt >= since!)
        }
    }

    public func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> {
        store.observe(ownerID: studentID.rawValue)
    }
}

public struct WorkoutPlanRepositoryImpl: WorkoutPlanRepository {
    private let store: OfflineFirstStore<WorkoutPlan>

    public init(store: OfflineFirstStore<WorkoutPlan>) { self.store = store }

    public func save(_ plan: WorkoutPlan) async throws -> WorkoutPlan { try await store.save(plan) }

    public func activePlan(studentID: UserID) async throws -> WorkoutPlan? {
        Self.active(in: try await store.list(ownerID: studentID.rawValue))
    }

    public func plans(studentID: UserID) async throws -> [WorkoutPlan] {
        try await store.list(ownerID: studentID.rawValue)
    }

    public func observeActivePlan(studentID: UserID) -> AsyncStream<WorkoutPlan?> {
        let source = store.observe(ownerID: studentID.rawValue)
        return AsyncStream { continuation in
            let task = Task {
                for await plans in source { continuation.yield(Self.active(in: plans)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The newest active plan wins if a trainer (mistakenly) leaves two active.
    private static func active(in plans: [WorkoutPlan]) -> WorkoutPlan? {
        plans.filter(\.isActive).max { $0.startDate < $1.startDate }
    }
}

public struct CheckInRepositoryImpl: CheckInRepository {
    private let store: OfflineFirstStore<GymCheckIn>

    public init(store: OfflineFirstStore<GymCheckIn>) { self.store = store }

    public func save(_ checkIn: GymCheckIn) async throws -> GymCheckIn { try await store.save(checkIn) }

    public func checkIns(studentID: UserID, since: Date?) async throws -> [GymCheckIn] {
        try await store.list(ownerID: studentID.rawValue).filter { since == nil || $0.arrivedAt >= since! }
    }
}

public struct BodyCompositionRepositoryImpl: BodyCompositionRepository {
    private let store: OfflineFirstStore<BodyCompositionCheckpoint>

    public init(store: OfflineFirstStore<BodyCompositionCheckpoint>) { self.store = store }

    /// Validates before anything touches storage (OWASP M4).
    public func save(_ checkpoint: BodyCompositionCheckpoint) async throws -> BodyCompositionCheckpoint {
        try await store.save(try checkpoint.validated())
    }

    public func checkpoints(studentID: UserID) async throws -> [BodyCompositionCheckpoint] {
        try await store.list(ownerID: studentID.rawValue)
    }
}


public struct PostRepositoryImpl: PostRepository {
    private let store: OfflineFirstStore<ActivityPost>

    public init(store: OfflineFirstStore<ActivityPost>) { self.store = store }

    public func save(_ post: ActivityPost) async throws -> ActivityPost { try await store.save(post) }

    public func posts(studentID: UserID) async throws -> [ActivityPost] {
        try await store.list(ownerID: studentID.rawValue)
    }

    public func observePosts(studentID: UserID) -> AsyncStream<[ActivityPost]> {
        store.observe(ownerID: studentID.rawValue)
    }
}

public struct TrainerProfileRepositoryImpl: TrainerProfileRepository {
    private let store: OfflineFirstStore<TrainerProfile>

    public init(store: OfflineFirstStore<TrainerProfile>) { self.store = store }

    public func save(_ profile: TrainerProfile) async throws -> TrainerProfile { try await store.save(profile) }

    public func profile(trainerID: UserID) async throws -> TrainerProfile? {
        guard let found = try await store.get(id: trainerID.rawValue), !found.meta.isDeleted else { return nil }
        return found
    }

    public func observeProfile(trainerID: UserID) -> AsyncStream<TrainerProfile?> {
        let source = store.observe(ownerID: trainerID.rawValue)
        return AsyncStream { continuation in
            let task = Task {
                for await all in source { continuation.yield(all.first { $0.id == trainerID && !$0.meta.isDeleted }) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct SharedPhotoRepositoryImpl: SharedPhotoRepository {
    private let store: OfflineFirstStore<SharedPhoto>

    public init(store: OfflineFirstStore<SharedPhoto>) { self.store = store }

    public func save(_ photo: SharedPhoto) async throws -> SharedPhoto { try await store.save(photo) }

    public func remove(id: PostID, studentID: UserID) async throws {
        guard var existing = try await store.get(id: id.rawValue), existing.studentID == studentID, !existing.meta.isDeleted else { return }
        existing.photo = Data()                                   // the bytes go; the tombstone stays so the trainer's copy disappears too
        _ = try await store.delete(existing)
    }

    public func photos(studentID: UserID) async throws -> [SharedPhoto] {
        try await store.list(ownerID: studentID.rawValue).sorted { $0.takenAt > $1.takenAt }
    }

    public func observePhotos(studentID: UserID) -> AsyncStream<[SharedPhoto]> {
        let source = store.observe(ownerID: studentID.rawValue)
        return AsyncStream { continuation in
            let task = Task {
                for await all in source { continuation.yield(all.filter { !$0.meta.isDeleted }.sorted { $0.takenAt > $1.takenAt }) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reads only. Nothing here can enqueue a write the rules would reject.
public struct ExternalActivityRepositoryImpl: ExternalActivityRepository {
    private let store: OfflineFirstStore<ExternalActivity>

    public init(store: OfflineFirstStore<ExternalActivity>) { self.store = store }

    public func activities(studentID: UserID, since: Date?) async throws -> [ExternalActivity] {
        try await store.list(ownerID: studentID.rawValue).filter { since == nil || $0.startedAt >= since! }
    }

    public func observeActivities(studentID: UserID) -> AsyncStream<[ExternalActivity]> {
        store.observe(ownerID: studentID.rawValue)
    }
}

/// Reads only, like `ExternalActivityRepositoryImpl`.
public struct IntegrationLinkRepositoryImpl: IntegrationLinkRepository {
    private let store: OfflineFirstStore<IntegrationLink>

    public init(store: OfflineFirstStore<IntegrationLink>) { self.store = store }

    public func link(provider: IntegrationProvider, studentID: UserID) async throws -> IntegrationLink? {
        try await store.list(ownerID: studentID.rawValue).first { $0.provider == provider }
    }

    public func observeLinks(studentID: UserID) -> AsyncStream<[IntegrationLink]> {
        store.observe(ownerID: studentID.rawValue)
    }
}

public struct SharingPreferencesRepositoryImpl: SharingPreferencesRepository {
    private let store: OfflineFirstStore<SharingPreferences>
    private let now: @Sendable () -> Date

    public init(store: OfflineFirstStore<SharingPreferences>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func preferences(studentID: UserID) async throws -> SharingPreferences {
        try await store.list(ownerID: studentID.rawValue).first ?? Self.defaults(studentID, now())
    }

    public func save(_ preferences: SharingPreferences) async throws -> SharingPreferences { try await store.save(preferences) }

    public func observePreferences(studentID: UserID) -> AsyncStream<SharingPreferences> {
        let source = store.observe(ownerID: studentID.rawValue)
        let fallback = Self.defaults(studentID, now())
        return AsyncStream { continuation in
            let task = Task {
                for await items in source { continuation.yield(items.first ?? fallback) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func defaults(_ studentID: UserID, _ now: Date) -> SharingPreferences {
        SharingPreferences(studentID: studentID, meta: SyncMetadata(updatedAt: now, lastWriterDeviceID: "", state: .synced))
    }
}
