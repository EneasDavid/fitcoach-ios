import Foundation

public enum GymProvider: String, Codable, Sendable, CaseIterable {
    case smartFit
    case wellhub      // formerly Gympass
    case gymrats
    /// Native arrival detection via CoreLocation region monitoring — needs no partner agreement.
    case geofence
    case manual
    case simulated
}

public struct GymVenue: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double

    public init(id: String, name: String, latitude: Double, longitude: Double, radiusMeters: Double = 120) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }
}

/// Raw event emitted by any arrival source before it becomes a persisted `GymCheckIn`.
public struct GymArrivalEvent: Equatable, Sendable {
    public let provider: GymProvider
    public let venue: GymVenue
    public let arrivedAt: Date
    /// Partner-side reference (e.g. a Wellhub check-in token) for reconciliation.
    public let externalReference: String?

    public init(provider: GymProvider, venue: GymVenue, arrivedAt: Date, externalReference: String? = nil) {
        self.provider = provider
        self.venue = venue
        self.arrivedAt = arrivedAt
        self.externalReference = externalReference
    }
}

public struct GymCheckIn: Syncable, Equatable {
    public var id: CheckInID
    public var studentID: UserID
    public var provider: GymProvider
    public var venue: GymVenue
    public var arrivedAt: Date
    public var externalReference: String?
    /// Set once the check-in initialised a workout session.
    public var workoutLogID: LogID?
    public var meta: SyncMetadata

    public init(id: CheckInID = .generate(),
                studentID: UserID,
                provider: GymProvider,
                venue: GymVenue,
                arrivedAt: Date,
                externalReference: String? = nil,
                workoutLogID: LogID? = nil,
                meta: SyncMetadata) {
        self.id = id
        self.studentID = studentID
        self.provider = provider
        self.venue = venue
        self.arrivedAt = arrivedAt
        self.externalReference = externalReference
        self.workoutLogID = workoutLogID
        self.meta = meta
    }
}

/// Port implemented by each arrival source (Smart Fit, Wellhub, Gymrats, geofence, simulator).
/// Smart Fit / Wellhub / Gymrats don't publish open check-in APIs; real adapters require a partner
/// agreement and live in the app target. The geofence adapter works without one.
public protocol GymArrivalProviding: Sendable {
    var provider: GymProvider { get }
    func arrivals() -> AsyncStream<GymArrivalEvent>
    func startMonitoring() async throws
    func stopMonitoring() async
}
