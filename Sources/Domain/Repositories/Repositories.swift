import Foundation

// Ports (Clean Architecture): the domain declares what it needs; DataKit / the App target implement it.
//
// Contract shared by every `save`: **the repository owns `meta`.** It bumps `meta.version`,
// stamps `updatedAt`/`lastWriterDeviceID`, flags the record pending and returns the stored entity.
// Callers must continue with the returned value.

public protocol WorkoutPlanRepository: Sendable {
    @discardableResult func save(_ plan: WorkoutPlan) async throws -> WorkoutPlan
    func activePlan(studentID: UserID) async throws -> WorkoutPlan?
    func plans(studentID: UserID) async throws -> [WorkoutPlan]
    func observeActivePlan(studentID: UserID) -> AsyncStream<WorkoutPlan?>
}

public protocol WorkoutLogRepository: Sendable {
    @discardableResult func save(_ log: WorkoutLog) async throws -> WorkoutLog
    func log(id: LogID, studentID: UserID) async throws -> WorkoutLog?
    /// Newest first. `planID`/`since` are optional filters.
    func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog]
    func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]>
}

public protocol CheckInRepository: Sendable {
    @discardableResult func save(_ checkIn: GymCheckIn) async throws -> GymCheckIn
    func checkIns(studentID: UserID, since: Date?) async throws -> [GymCheckIn]
}

public protocol BodyCompositionRepository: Sendable {
    @discardableResult func save(_ checkpoint: BodyCompositionCheckpoint) async throws -> BodyCompositionCheckpoint
    func checkpoints(studentID: UserID) async throws -> [BodyCompositionCheckpoint]
}

public protocol ExerciseCatalogRepository: Sendable {
    func search(query: String, limit: Int) async throws -> [Exercise]
    func exercise(id: ExerciseID) async throws -> Exercise?
    func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution]
}

// MARK: - Notifications

public struct LocalNotification: Equatable, Sendable, Identifiable {
    public static let trainingReminderCategory = "training.reminder"
    public static let arrivalCategory = "gym.arrival"

    public let id: String
    public let title: String
    public let body: String
    /// `nil` = deliver immediately.
    public let fireDate: Date?
    public let category: String
    public let userInfo: [String: String]

    public init(id: String, title: String, body: String, fireDate: Date?, category: String, userInfo: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.category = category
        self.userInfo = userInfo
    }
}

public protocol LocalNotificationScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func post(_ notification: LocalNotification) async throws
    /// Cancels pending notifications by id (e.g. the "still at the gym?" reminder when the student leaves early).
    func cancel(ids: [String]) async throws
    /// Cancels all pending notifications of `category`, then schedules `notifications`.
    func replacePending(category: String, with notifications: [LocalNotification]) async throws
}

// MARK: - Presence, feed, integrations

/// Visits that began (the student entered a gym) but haven't been decided yet. Persisted so a relaunch — or the
/// OS waking the app hours later — can still act on them.
public protocol PendingVisitStoring: Sendable {
    func load() async throws -> [PendingVisit]
    func save(_ visits: [PendingVisit]) async throws
}

public protocol PostRepository: Sendable {
    @discardableResult func save(_ post: ActivityPost) async throws -> ActivityPost
    /// Newest first.
    func posts(studentID: UserID) async throws -> [ActivityPost]
    func observePosts(studentID: UserID) -> AsyncStream<[ActivityPost]>
}

/// Read-only on the device: activities are written by the Strava webhook's Cloud Function (Admin SDK) and arrive
/// through the inbound listener. Firestore rules deny client writes to this collection.
public protocol ExternalActivityRepository: Sendable {
    /// Newest first.
    func activities(studentID: UserID, since: Date?) async throws -> [ExternalActivity]
    func observeActivities(studentID: UserID) -> AsyncStream<[ExternalActivity]>
}

public protocol TrackPlayRepository: Sendable {
    /// Idempotent by play id, so re-importing the same listening history never double-counts.
    func save(_ plays: [TrackPlay]) async throws
    func plays(studentID: UserID, from: Date, to: Date) async throws -> [TrackPlay]
}

/// A listening-history source (Spotify today). Tokens and OAuth live in the app target.
public protocol MusicHistoryProviding: Sendable {
    var provider: MusicProvider { get }
    var isConnected: Bool { get async }
    /// Everything played after `date` (newest sources cap at ~50 items, so call this soon after the workout).
    func recentlyPlayed(after date: Date) async throws -> [TrackPlay]
}

/// Finds gyms near a coordinate (Google Places via our proxy, MapKit on device).
public protocol GymLocating: Sendable {
    func gyms(near latitude: Double, longitude: Double, radiusMeters: Double) async throws -> [GymVenue]
}

/// Read-only: the link is written by the backend after a successful OAuth exchange.
public protocol IntegrationLinkRepository: Sendable {
    func link(provider: IntegrationProvider, studentID: UserID) async throws -> IntegrationLink?
    func observeLinks(studentID: UserID) -> AsyncStream<[IntegrationLink]>
}

public protocol SharingPreferencesRepository: Sendable {
    /// Defaults (everything off) when the student has never chosen.
    func preferences(studentID: UserID) async throws -> SharingPreferences
    @discardableResult func save(_ preferences: SharingPreferences) async throws -> SharingPreferences
    func observePreferences(studentID: UserID) -> AsyncStream<SharingPreferences>
}
