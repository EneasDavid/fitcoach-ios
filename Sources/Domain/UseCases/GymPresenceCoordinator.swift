import Foundation

public enum PresenceOutcome: Equatable, Sendable {
    case ignored
    /// Entered: the countdown to an automatic start has begun (and a fallback reminder is scheduled).
    case dwellStarted(readyAt: Date)
    /// Left before the minimum stay: nothing happens.
    case cancelled
    case autoStarted(LogID)
    case waiting(readyAt: Date)
    case skipped(Reason)

    public enum Reason: String, Equatable, Sendable {
        case noPlan, alreadyInProgress, trainedRecently, stale
    }
}

/// Starts the workout automatically once the student has stayed at the gym long enough.
///
///   enter  → remember the visit + schedule a local notification for `enteredAt + minimumStay`
///            (it fires even if the app isn't running, as a tap-to-open fallback)
///   exit   → forget the visit + cancel that notification
///   wake   → `evaluate()`: any visit that has now lasted long enough becomes a started workout
///            (`startedAt` = the moment they walked in), linked to the check-in, with a "started" notification.
public actor GymPresenceCoordinator {
    private let studentID: UserID
    private let deviceID: String
    private let store: any PendingVisitStoring
    private let plans: any WorkoutPlanRepository
    private let logs: any WorkoutLogRepository
    private let checkIns: any CheckInRepository
    private let notifier: any LocalNotificationScheduling
    private let tracker: GymVisitTracker
    private let now: @Sendable () -> Date

    public init(studentID: UserID,
                deviceID: String,
                store: any PendingVisitStoring,
                plans: any WorkoutPlanRepository,
                logs: any WorkoutLogRepository,
                checkIns: any CheckInRepository,
                notifier: any LocalNotificationScheduling,
                tracker: GymVisitTracker = GymVisitTracker(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.studentID = studentID
        self.deviceID = deviceID
        self.store = store
        self.plans = plans
        self.logs = logs
        self.checkIns = checkIns
        self.notifier = notifier
        self.tracker = tracker
        self.now = now
    }

    private func reminderID(_ venueID: String) -> String { "dwell.\(venueID)" }

    public func handle(_ event: GymPresenceEvent) async throws -> PresenceOutcome {
        let before = try await store.load()
        let after = tracker.apply(event, to: before)
        try await store.save(after)

        switch event.kind {
        case .entered:
            guard let visit = after.first(where: { $0.venue.id == event.venue.id }) else { return .ignored }
            let ready = tracker.readyDate(for: visit)
            if ready > now() {
                try await notifier.post(LocalNotification(
                    id: reminderID(visit.venue.id),
                    title: String(localized: "Still at \(visit.venue.name)?"),
                    body: String(localized: "Tap to open today's workout."),
                    fireDate: ready,
                    category: LocalNotification.arrivalCategory,
                    userInfo: ["deeplink": "fitcoach://workout/start"]))
            }
            return .dwellStarted(readyAt: ready)
        case .exited:
            try await notifier.cancel(ids: [reminderID(event.venue.id)])
            return before.contains(where: { $0.venue.id == event.venue.id }) ? .cancelled : .ignored
        }
    }

    /// Call whenever the app wakes up. Returns what happened to each open visit.
    @discardableResult
    public func evaluate() async throws -> [PresenceOutcome] {
        var pending = try await store.load()
        var outcomes: [PresenceOutcome] = []

        for decision in tracker.evaluate(pending, now: now()) {
            switch decision {
            case .waiting(_, let readyAt):
                outcomes.append(.waiting(readyAt: readyAt))
            case .stale(let visit):
                pending.removeAll { $0.id == visit.id }
                try await notifier.cancel(ids: [reminderID(visit.venue.id)])
                outcomes.append(.skipped(.stale))
            case .ready(let visit):
                pending.removeAll { $0.id == visit.id }          // decided once, never twice
                outcomes.append(try await autoStart(visit))
            }
        }
        try await store.save(pending)
        return outcomes
    }

    private func autoStart(_ visit: PendingVisit) async throws -> PresenceOutcome {
        guard let plan = try await plans.activePlan(studentID: studentID) else { return .skipped(.noPlan) }
        let history = try await logs.logs(studentID: studentID, planID: plan.id, since: nil)

        // A live in-progress workout is the student's own; a stale one (left open overnight) is abandoned by the start use case.
        let sequencer = WorkoutSequencer()
        if history.contains(where: { $0.status == .inProgress && !sequencer.isStale($0, now: now()) }) { return .skipped(.alreadyInProgress) }
        let cutoff = now().addingTimeInterval(-tracker.policy.cooldownAfterWorkout)
        if history.contains(where: { $0.status == .completed && $0.effectiveDate >= cutoff }) { return .skipped(.trainedRecently) }

        // Link to the check-in the arrival flow already created, or record one.
        let recent = try await checkIns.checkIns(studentID: studentID, since: visit.enteredAt.addingTimeInterval(-3_600))
        let checkInID: CheckInID
        if let existing = recent.first(where: { $0.venue.id == visit.venue.id && !$0.meta.isDeleted }) {
            checkInID = existing.id
        } else {
            checkInID = try await checkIns.save(GymCheckIn(studentID: studentID, provider: visit.provider, venue: visit.venue,
                                                          arrivedAt: visit.enteredAt,
                                                          meta: SyncMetadata(updatedAt: now(), lastWriterDeviceID: deviceID))).id
        }

        let log = try await StartWorkoutUseCase(logs: logs, now: now).execute(plan: plan, checkInID: checkInID, startedAt: visit.enteredAt)
        try await notifier.cancel(ids: [reminderID(visit.venue.id)])
        try await notifier.post(LocalNotification(
            id: "presence.started.\(log.id)",
            title: String(localized: "Workout started"),
            body: String(localized: "\(log.templateLabel) is ready. Tap to open."),
            fireDate: nil,
            category: LocalNotification.arrivalCategory,
            userInfo: ["deeplink": "fitcoach://workout/resume"]))
        return .autoStarted(log.id)
    }
}
