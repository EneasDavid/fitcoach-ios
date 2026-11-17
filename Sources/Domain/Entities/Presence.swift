import Foundation

public enum GymPresenceKind: String, Codable, Sendable {
    case entered, exited
}

/// Raw enter/exit signal from a geofence (or any other presence source).
public struct GymPresenceEvent: Equatable, Sendable {
    public let kind: GymPresenceKind
    public let venue: GymVenue
    public let at: Date
    public let provider: GymProvider

    public init(kind: GymPresenceKind, venue: GymVenue, at: Date, provider: GymProvider = .geofence) {
        self.kind = kind
        self.venue = venue
        self.at = at
        self.provider = provider
    }
}

/// When does "being near a gym" count as "training"?
public struct DwellPolicy: Equatable, Sendable {
    /// How long the student must stay inside the perimeter before the workout starts by itself.
    public var minimumStay: TimeInterval
    /// A visit with no exit event after this long is dropped (the exit was missed — never start from stale data).
    public var staleAfter: TimeInterval
    /// No automatic start if the student already finished a workout this recently.
    public var cooldownAfterWorkout: TimeInterval

    public init(minimumStay: TimeInterval = 30 * 60, staleAfter: TimeInterval = 6 * 3_600, cooldownAfterWorkout: TimeInterval = 3 * 3_600) {
        self.minimumStay = minimumStay
        self.staleAfter = staleAfter
        self.cooldownAfterWorkout = cooldownAfterWorkout
    }
}

/// A visit that has begun (entered) and not yet been decided.
public struct PendingVisit: Codable, Equatable, Sendable, Identifiable {
    public var id: String { venue.id }
    public let venue: GymVenue
    public let enteredAt: Date
    public let provider: GymProvider

    public init(venue: GymVenue, enteredAt: Date, provider: GymProvider) {
        self.venue = venue
        self.enteredAt = enteredAt
        self.provider = provider
    }
}

/// Source of enter/exit signals (CoreLocation region monitoring on device, a scripted one in demos and tests).
public protocol GymPresenceProviding: Sendable {
    func presenceEvents() -> AsyncStream<GymPresenceEvent>
    func startMonitoring() async throws
    func stopMonitoring() async
}

public extension GymVenue {
    /// Great-circle distance (haversine) in metres. Plenty accurate at gym scale; avoids needing CoreLocation in Domain.
    func distanceMeters(toLatitude latitude: Double, longitude: Double) -> Double {
        let radius = 6_371_000.0
        let toRadians = Double.pi / 180
        let dLat = (latitude - self.latitude) * toRadians
        let dLon = (longitude - self.longitude) * toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(self.latitude * toRadians) * cos(latitude * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
