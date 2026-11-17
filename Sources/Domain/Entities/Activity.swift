import Foundation

public enum ActivitySource: String, Codable, Sendable, CaseIterable {
    case fitCoach
    case strava
}

public enum IntegrationProvider: String, Codable, Sendable, CaseIterable {
    case strava, spotify, geofence
}

/// What is connected, as proven by the backend. **Server-owned and read-only on the device**: the Strava OAuth
/// exchange (done in a Cloud Function) is what proves the account belongs to this student, so a tampered client must
/// not be able to write `externalAccountID` — the webhook uses it to decide whose activities an event is about.
/// Tokens are never stored here (Secret-Manager-backed server collection; Keychain on the device).
public struct IntegrationLink: Syncable, Equatable {
    public var id: String { provider.rawValue }
    public var studentID: UserID
    public var provider: IntegrationProvider
    public var isConnected: Bool
    public var connectedAt: Date?
    /// The provider's own account id (Strava athlete id).
    public var externalAccountID: String?
    public var meta: SyncMetadata

    public init(studentID: UserID, provider: IntegrationProvider, isConnected: Bool, connectedAt: Date? = nil,
                externalAccountID: String? = nil, meta: SyncMetadata) {
        self.studentID = studentID
        self.provider = provider
        self.isConnected = isConnected
        self.connectedAt = connectedAt
        self.externalAccountID = externalAccountID
        self.meta = meta
    }
}

/// What the student *allows*. Student-owned and synced; the Firestore rules read it to decide what a trainer may see,
/// so the switch is enforced by the backend, not by the UI. Everything defaults to **off**.
public struct SharingPreferences: Syncable, Equatable {
    public var id: String { "preferences" }
    public var studentID: UserID
    /// The linked trainer may see this student's Strava activities (also needs the server-side policy flag).
    public var shareStravaWithTrainer: Bool
    /// Automatic posts may quote the songs that were playing.
    public var includeMusicInPosts: Bool
    public var meta: SyncMetadata

    public init(studentID: UserID, shareStravaWithTrainer: Bool = false, includeMusicInPosts: Bool = false, meta: SyncMetadata) {
        self.studentID = studentID
        self.shareStravaWithTrainer = shareStravaWithTrainer
        self.includeMusicInPosts = includeMusicInPosts
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey { case studentID, shareStravaWithTrainer, includeMusicInPosts, meta }
}

/// An activity recorded somewhere else (Strava) and delivered by the webhook → Cloud Function → Firestore.
public struct ExternalActivity: Syncable, Equatable {
    public var id: ExternalActivityID
    public var studentID: UserID
    public var source: ActivitySource
    /// The provider's id, so a webhook "update" event rewrites the same record instead of adding another.
    public var externalID: String
    /// Strava `sport_type`, e.g. "Run", "Ride", "WeightTraining".
    public var sportType: String
    public var name: String
    public var startedAt: Date
    public var movingSeconds: Int
    public var elapsedSeconds: Int
    public var distanceMeters: Double?
    public var elevationGainMeters: Double?
    public var averageHeartRate: Int?
    public var meta: SyncMetadata

    public init(id: ExternalActivityID? = nil, studentID: UserID, source: ActivitySource = .strava, externalID: String,
                sportType: String, name: String, startedAt: Date, movingSeconds: Int, elapsedSeconds: Int,
                distanceMeters: Double? = nil, elevationGainMeters: Double? = nil, averageHeartRate: Int? = nil, meta: SyncMetadata) {
        self.id = id ?? ExternalActivityID("\(source.rawValue)-\(externalID)")
        self.studentID = studentID
        self.source = source
        self.externalID = externalID
        self.sportType = sportType
        self.name = name
        self.startedAt = startedAt
        self.movingSeconds = movingSeconds
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.elevationGainMeters = elevationGainMeters
        self.averageHeartRate = averageHeartRate
        self.meta = meta
    }

    public var interval: DateInterval { DateInterval(start: startedAt, duration: TimeInterval(max(elapsedSeconds, movingSeconds))) }
    /// Gym strength work logged on a watch/phone is the same session the app already knows about.
    public var isStrengthTraining: Bool { ["WeightTraining", "Workout", "Crossfit"].contains(sportType) }
}

// MARK: - Feed posts

public enum PostKind: String, Codable, Sendable {
    case workout, personalRecord, playlistOfTheDay, externalActivity
}

public struct PostStat: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

public struct PostTrack: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var plays: Int
    /// e.g. "Playing when you hit the PR".
    public var note: String?
    public init(title: String, artist: String, plays: Int, note: String? = nil) {
        self.title = title; self.artist = artist; self.plays = plays; self.note = note
    }
}

/// A generated, shareable card of what the student did. Everything on it is already known on the device.
public struct ActivityPost: Syncable, Equatable {
    public var id: PostID
    public var studentID: UserID
    public var kind: PostKind
    public var createdAt: Date
    public var title: String
    public var subtitle: String?
    public var stats: [PostStat]
    public var tracks: [PostTrack]
    /// A photo the student attached (downsized JPEG). Private to the student, like the rest of the post; shown behind the share poster.
    public var photo: Data?
    public var sourceLogID: LogID?
    public var sourceActivityID: ExternalActivityID?
    public var meta: SyncMetadata

    public init(id: PostID, studentID: UserID, kind: PostKind, createdAt: Date, title: String, subtitle: String? = nil,
                stats: [PostStat] = [], tracks: [PostTrack] = [], photo: Data? = nil, sourceLogID: LogID? = nil,
                sourceActivityID: ExternalActivityID? = nil, meta: SyncMetadata) {
        self.id = id
        self.studentID = studentID
        self.kind = kind
        self.createdAt = createdAt
        self.title = title
        self.subtitle = subtitle
        self.stats = stats
        self.tracks = tracks
        self.photo = photo
        self.sourceLogID = sourceLogID
        self.sourceActivityID = sourceActivityID
        self.meta = meta
    }
}

public enum ShareDestination: String, Sendable, CaseIterable {
    case whatsapp, instagramStories, gymrats, more

    public var displayName: String {
        switch self {
        case .whatsapp: return "WhatsApp"
        case .instagramStories: return "Instagram"
        case .gymrats: return "Gymrats"
        case .more: return String(localized: "More…")
        }
    }
}
