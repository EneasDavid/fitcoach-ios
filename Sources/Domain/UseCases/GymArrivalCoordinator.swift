import Foundation

public enum GymArrivalOutcome: Equatable, Sendable {
    /// Same venue already checked in within the dedupe window.
    case duplicate
    case checkedIn(CheckInID, next: NextWorkout?)
}

/// Turns a raw arrival event into: a persisted check-in → the day's workout (from the sequence)
/// → an immediate local notification that deep-links into the workout. The workout log itself is
/// created when the student taps through (`StartWorkoutUseCase`), so arriving at the gym and
/// leaving again never litters history with empty sessions.
public actor GymArrivalCoordinator {
    private let studentID: UserID
    private let deviceID: String
    private let checkIns: any CheckInRepository
    private let plans: any WorkoutPlanRepository
    private let logs: any WorkoutLogRepository
    private let notifier: any LocalNotificationScheduling
    private let sequencer: WorkoutSequencer
    private let dedupeWindow: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSeen: [String: Date] = [:]
    private var consumeTask: Task<Void, Never>?

    public init(studentID: UserID,
                deviceID: String,
                checkIns: any CheckInRepository,
                plans: any WorkoutPlanRepository,
                logs: any WorkoutLogRepository,
                notifier: any LocalNotificationScheduling,
                sequencer: WorkoutSequencer = WorkoutSequencer(),
                dedupeWindow: TimeInterval = 4 * 3600,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.studentID = studentID
        self.deviceID = deviceID
        self.checkIns = checkIns
        self.plans = plans
        self.logs = logs
        self.notifier = notifier
        self.sequencer = sequencer
        self.dedupeWindow = dedupeWindow
        self.now = now
    }

    public func handle(_ event: GymArrivalEvent) async throws -> GymArrivalOutcome {
        let venueKey = event.venue.id
        if let seen = lastSeen[venueKey], event.arrivedAt.timeIntervalSince(seen) < dedupeWindow {
            return .duplicate
        }
        // Persisted check too, so a relaunch (or a second provider reporting the same visit) is deduped.
        let recent = try await checkIns.checkIns(studentID: studentID, since: event.arrivedAt.addingTimeInterval(-dedupeWindow))
        if recent.contains(where: { $0.venue.id == venueKey && !$0.meta.isDeleted }) {
            lastSeen[venueKey] = event.arrivedAt
            return .duplicate
        }
        lastSeen[venueKey] = event.arrivedAt

        let saved = try await checkIns.save(GymCheckIn(studentID: studentID,
                                                       provider: event.provider,
                                                       venue: event.venue,
                                                       arrivedAt: event.arrivedAt,
                                                       externalReference: event.externalReference,
                                                       meta: SyncMetadata(updatedAt: now(), lastWriterDeviceID: deviceID)))

        var next: NextWorkout?
        if let plan = try await plans.activePlan(studentID: studentID) {
            let history = try await logs.logs(studentID: studentID, planID: plan.id, since: nil)
            next = sequencer.next(plan: plan, logs: history, now: now())
        }

        let body: String
        if let next {
            let count = next.template.blocks.count
            body = String(localized: "Today: \(next.template.label) · \(count) blocks")
        } else {
            body = String(localized: "You're checked in. Ask your trainer to assign a plan.")
        }
        try await notifier.post(LocalNotification(
            id: "gym.arrival.\(saved.id)",
            title: String(localized: "Welcome to \(event.venue.name)"),
            body: body,
            fireDate: nil,
            category: LocalNotification.arrivalCategory,
            userInfo: ["deeplink": "fitcoach://workout/start?checkIn=\(saved.id)"]))

        return .checkedIn(saved.id, next: next)
    }

    /// Starts listening to a provider until cancelled. Errors for one event never stop the loop.
    public func startConsuming(_ provider: some GymArrivalProviding) {
        consumeTask?.cancel()
        let stream = provider.arrivals()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                _ = try? await self.handle(event)
            }
        }
    }

    public func stopConsuming() {
        consumeTask?.cancel()
        consumeTask = nil
    }
}
