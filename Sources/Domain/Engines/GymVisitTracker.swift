import Foundation

/// Pure dwell logic: enter/exit events in, "has this person stayed long enough?" out.
///
/// iOS cannot run code on a timer in the background — it only wakes the app for region *enter* and *exit*. So the
/// design is event-sourced: `apply` keeps the set of open visits, `evaluate(now:)` answers whenever *anything*
/// wakes the app (an exit, a background refresh, a notification tap, opening the app).
public struct GymVisitTracker: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Still inside, not long enough yet.
        case waiting(venueID: String, readyAt: Date)
        /// Stayed long enough: start the workout.
        case ready(PendingVisit)
        /// No exit event for too long: forget it rather than guess.
        case stale(PendingVisit)
    }

    public var policy: DwellPolicy

    public init(policy: DwellPolicy = DwellPolicy()) {
        self.policy = policy
    }

    public func apply(_ event: GymPresenceEvent, to pending: [PendingVisit]) -> [PendingVisit] {
        switch event.kind {
        case .entered:
            // Geofences can fire twice (and a second provider may report the same visit): first entry wins.
            guard !pending.contains(where: { $0.venue.id == event.venue.id }) else { return pending }
            return pending + [PendingVisit(venue: event.venue, enteredAt: event.at, provider: event.provider)]
        case .exited:
            return pending.filter { $0.venue.id != event.venue.id }
        }
    }

    public func evaluate(_ pending: [PendingVisit], now: Date) -> [Decision] {
        pending.map { visit in
            let ready = visit.enteredAt.addingTimeInterval(policy.minimumStay)
            if now >= visit.enteredAt.addingTimeInterval(policy.staleAfter) { return .stale(visit) }
            return now >= ready ? .ready(visit) : .waiting(venueID: visit.venue.id, readyAt: ready)
        }
    }

    public func readyDate(for visit: PendingVisit) -> Date {
        visit.enteredAt.addingTimeInterval(policy.minimumStay)
    }
}
