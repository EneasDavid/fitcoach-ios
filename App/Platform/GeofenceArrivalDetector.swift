import CoreLocation
import Domain
import Foundation

// NOT COMPILED IN THE AUTHORING ENVIRONMENT beyond the simulator build — see README → "Verification status".

/// Native gym detection with CoreLocation **region monitoring** — no partner agreement needed, and iOS relaunches the app in
/// the background on enter *and* exit, so it works with the phone locked in a pocket.
///
/// It feeds two consumers from one set of regions:
///   * `arrivals()`       → "you arrived — today's workout is B" (immediately, on enter);
///   * `presenceEvents()` → enter + exit, for the dwell logic that starts the workout after a minimum stay.
///
/// Privacy: only the gyms the student explicitly selected are monitored (iOS allows 20 regions per app), no continuous
/// location is collected, and location never leaves the device. Requires "Always" authorisation.
final class GeofenceDetector: NSObject, GymArrivalProviding, GymPresenceProviding, CLLocationManagerDelegate, @unchecked Sendable {
    let provider: GymProvider = .geofence

    private let venues: [GymVenue]
    private let lock = NSLock()
    private var arrivalContinuations: [UUID: AsyncStream<GymArrivalEvent>.Continuation] = [:]
    private var presenceContinuations: [UUID: AsyncStream<GymPresenceEvent>.Continuation] = [:]
    private var manager: CLLocationManager?

    init(venues: [GymVenue]) {
        self.venues = Array(venues.prefix(20))
        super.init()
    }

    func arrivals() -> AsyncStream<GymArrivalEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { arrivalContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.arrivalContinuations.removeValue(forKey: id) } }
        }
    }

    func presenceEvents() -> AsyncStream<GymPresenceEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { presenceContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.presenceContinuations.removeValue(forKey: id) } }
        }
    }

    @MainActor
    func startMonitoring() async throws {
        let manager = CLLocationManager()      // created on the main thread: the delegate needs a run loop
        manager.delegate = self
        manager.requestAlwaysAuthorization()
        self.manager = manager
        for venue in venues {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: venue.latitude, longitude: venue.longitude),
                                          radius: min(max(venue.radiusMeters, 100), manager.maximumRegionMonitoringDistance),   // iOS is unreliable below ~100 m
                                          identifier: venue.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            manager.requestState(for: region)  // heals missed events: are we already inside (or did we leave while the app was dead)?
        }
    }

    @MainActor
    func stopMonitoring() async {
        manager?.monitoredRegions.forEach { manager?.stopMonitoring(for: $0) }
        manager = nil
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let venue = venue(for: region) else { return }
        let now = Date()
        let arrival = GymArrivalEvent(provider: .geofence, venue: venue, arrivedAt: now)
        lock.withLock { Array(arrivalContinuations.values) }.forEach { $0.yield(arrival) }
        emit(GymPresenceEvent(kind: .entered, venue: venue, at: now, provider: .geofence))
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let venue = venue(for: region) else { return }
        emit(GymPresenceEvent(kind: .exited, venue: venue, at: Date(), provider: .geofence))
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let venue = venue(for: region) else { return }
        // Only presence (never an "arrival" notification) is reconciled here. The coordinator ignores a duplicate enter and an
        // exit for a visit it doesn't know, so this is safe to call on every launch.
        switch state {
        case .inside: emit(GymPresenceEvent(kind: .entered, venue: venue, at: Date(), provider: .geofence))
        case .outside: emit(GymPresenceEvent(kind: .exited, venue: venue, at: Date(), provider: .geofence))
        case .unknown: break
        }
    }

    private func venue(for region: CLRegion) -> GymVenue? { venues.first { $0.id == region.identifier } }

    private func emit(_ event: GymPresenceEvent) {
        lock.withLock { Array(presenceContinuations.values) }.forEach { $0.yield(event) }
    }
}
