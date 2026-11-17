import Foundation
import Testing
@testable import Domain

actor InMemoryPendingVisitStore: PendingVisitStoring {
    private(set) var visits: [PendingVisit] = []
    func load() async throws -> [PendingVisit] { visits }
    func save(_ visits: [PendingVisit]) async throws { self.visits = visits }
}

@Suite("GymVisitTracker")
struct GymVisitTrackerTests {
    let venue = GymVenue(id: "gym-1", name: "Smart Fit Centro", latitude: -9.66, longitude: -35.73)
    let tracker = GymVisitTracker(policy: DwellPolicy(minimumStay: 30 * 60, staleAfter: 6 * 3_600))
    let entered = Fx.date(day: 3, hour: 18)

    func enter(_ pending: [PendingVisit] = [], at date: Date? = nil) -> [PendingVisit] {
        tracker.apply(GymPresenceEvent(kind: .entered, venue: venue, at: date ?? entered), to: pending)
    }

    @Test("Staying less than the minimum waits; at exactly the minimum it is ready")
    func dwellBoundary() {
        let pending = enter()
        guard case .waiting(let id, let readyAt) = tracker.evaluate(pending, now: entered.addingTimeInterval(29 * 60)).first else {
            Issue.record("expected waiting"); return
        }
        #expect(id == venue.id)
        #expect(readyAt == entered.addingTimeInterval(30 * 60))

        guard case .ready(let visit) = tracker.evaluate(pending, now: entered.addingTimeInterval(30 * 60)).first else {
            Issue.record("expected ready"); return
        }
        #expect(visit.enteredAt == entered)
    }

    @Test("Leaving forgets the visit")
    func exitCancels() {
        let after = tracker.apply(GymPresenceEvent(kind: .exited, venue: venue, at: entered.addingTimeInterval(600)), to: enter())
        #expect(after.isEmpty)
    }

    @Test("A repeated enter keeps the first entry time")
    func firstEntryWins() {
        let twice = enter(enter(), at: entered.addingTimeInterval(900))
        #expect(twice.count == 1)
        #expect(twice[0].enteredAt == entered)
    }

    @Test("A visit whose exit was never seen goes stale instead of starting a workout from old data")
    func stale() {
        guard case .stale = tracker.evaluate(enter(), now: entered.addingTimeInterval(6 * 3_600)).first else {
            Issue.record("expected stale"); return
        }
    }

    @Test("Two gyms are tracked independently")
    func independentVenues() {
        let other = GymVenue(id: "gym-2", name: "Other", latitude: 0, longitude: 0)
        var pending = enter()
        pending = tracker.apply(GymPresenceEvent(kind: .entered, venue: other, at: entered), to: pending)
        pending = tracker.apply(GymPresenceEvent(kind: .exited, venue: venue, at: entered), to: pending)
        #expect(pending.map(\.venue.id) == ["gym-2"])
    }
}

@Suite("GymPresenceCoordinator")
struct GymPresenceCoordinatorTests {
    let venue = GymVenue(id: "gym-1", name: "Smart Fit Centro", latitude: -9.66, longitude: -35.73)
    let entered = Fx.date(day: 3, hour: 18)
    let store = InMemoryPendingVisitStore()
    let logs = InMemoryLogRepository()
    let checkIns = InMemoryCheckInRepository()
    let notifier = RecordingNotifier()

    func make(plan: WorkoutPlan?, now: Date) -> GymPresenceCoordinator {
        GymPresenceCoordinator(studentID: Fx.student, deviceID: "dev", store: store, plans: InMemoryPlanRepository(plan),
                               logs: logs, checkIns: checkIns, notifier: notifier, now: { now })
    }

    func enter(_ coordinator: GymPresenceCoordinator) async throws {
        _ = try await coordinator.handle(GymPresenceEvent(kind: .entered, venue: venue, at: entered))
    }

    @Test("Entering starts the countdown and schedules the fallback reminder at enter + 30 min")
    func entering() async throws {
        let coordinator = make(plan: Fx.plan(), now: entered)
        let outcome = try await coordinator.handle(GymPresenceEvent(kind: .entered, venue: venue, at: entered))
        #expect(outcome == .dwellStarted(readyAt: entered.addingTimeInterval(30 * 60)))
        #expect(await store.visits.count == 1)

        let reminder = try #require(await notifier.posted.first)
        #expect(reminder.id == "dwell.gym-1")
        #expect(reminder.fireDate == entered.addingTimeInterval(30 * 60))
        #expect(reminder.userInfo["deeplink"] == "fitcoach://workout/start")
    }

    @Test("Leaving early cancels the visit and the reminder — nothing starts")
    func leavingEarly() async throws {
        let coordinator = make(plan: Fx.plan(), now: entered)
        try await enter(coordinator)
        let outcome = try await coordinator.handle(GymPresenceEvent(kind: .exited, venue: venue, at: entered.addingTimeInterval(600)))
        #expect(outcome == .cancelled)
        #expect(await store.visits.isEmpty)
        #expect(await notifier.cancelled == ["dwell.gym-1"])
        #expect(try await make(plan: Fx.plan(), now: entered.addingTimeInterval(3_600)).evaluate().isEmpty)
        #expect(await logs.saveCount == 0)
    }

    @Test("Still inside after the minimum stay → the workout starts, dated from arrival, once")
    func autoStarts() async throws {
        let plan = Fx.plan()
        try await enter(make(plan: plan, now: entered))

        let later = make(plan: plan, now: entered.addingTimeInterval(31 * 60))
        let outcomes = try await later.evaluate()
        guard case .autoStarted(let logID) = outcomes.first else { Issue.record("expected autoStarted, got \(outcomes)"); return }

        let log = try #require(await logs.stored[logID])
        #expect(log.status == .inProgress)
        #expect(log.startedAt == entered)
        #expect(log.templateID == plan.templates[0].id)
        let checkIn = try #require(await checkIns.items.first)
        #expect(log.checkInID == checkIn.id && checkIn.venue.id == venue.id && checkIn.provider == .geofence)

        let started = try #require(await notifier.posted.last)
        #expect(started.userInfo["deeplink"] == "fitcoach://workout/resume")
        #expect(await notifier.cancelled.contains("dwell.gym-1"))

        // Decided once: waking again (BGTask, app open) neither duplicates nor restarts it.
        #expect(try await later.evaluate().isEmpty)
        #expect(await logs.saveCount == 1)
    }

    @Test("Reuses the check-in the arrival flow already created")
    func reusesCheckIn() async throws {
        let existing = try await checkIns.save(GymCheckIn(studentID: Fx.student, provider: .geofence, venue: venue,
                                                          arrivedAt: entered.addingTimeInterval(20), meta: Fx.meta(entered)))
        try await enter(make(plan: Fx.plan(), now: entered))
        let outcomes = try await make(plan: Fx.plan(), now: entered.addingTimeInterval(40 * 60)).evaluate()
        guard case .autoStarted(let id) = outcomes.first else { Issue.record("expected autoStarted"); return }
        #expect(await logs.stored[id]?.checkInID == existing.id)
        #expect(await checkIns.items.count == 1)
    }

    @Test("Before the minimum stay it only reports when it will be ready")
    func notYet() async throws {
        try await enter(make(plan: Fx.plan(), now: entered))
        let outcomes = try await make(plan: Fx.plan(), now: entered.addingTimeInterval(10 * 60)).evaluate()
        #expect(outcomes == [.waiting(readyAt: entered.addingTimeInterval(30 * 60))])
        #expect(await logs.saveCount == 0)
        #expect(await store.visits.count == 1)
    }

    @Test("No plan, a workout already live, or one just finished: it does not start another")
    func guards() async throws {
        // no plan
        try await enter(make(plan: nil, now: entered))
        #expect(try await make(plan: nil, now: entered.addingTimeInterval(31 * 60)).evaluate() == [.skipped(.noPlan)])

        // live workout
        let plan = Fx.plan()
        await logs.seed([Fx.log(plan: plan, template: plan.templates[0], at: entered.addingTimeInterval(-600), status: .inProgress)])
        try await enter(make(plan: plan, now: entered))
        #expect(try await make(plan: plan, now: entered.addingTimeInterval(31 * 60)).evaluate() == [.skipped(.alreadyInProgress)])

        // finished an hour ago
        let other = InMemoryLogRepository()
        await other.seed([Fx.log(plan: plan, template: plan.templates[0], at: entered.addingTimeInterval(-3_600))])
        let coordinator = GymPresenceCoordinator(studentID: Fx.student, deviceID: "dev", store: store, plans: InMemoryPlanRepository(plan),
                                                 logs: other, checkIns: checkIns, notifier: notifier,
                                                 now: { [entered] in entered.addingTimeInterval(31 * 60) })
        try await enter(coordinator)
        #expect(try await coordinator.evaluate() == [.skipped(.trainedRecently)])
        #expect(await other.saveCount == 0)
    }

    @Test("A visit whose exit was missed for hours is dropped, not started")
    func staleVisit() async throws {
        try await enter(make(plan: Fx.plan(), now: entered))
        let outcomes = try await make(plan: Fx.plan(), now: entered.addingTimeInterval(7 * 3_600)).evaluate()
        #expect(outcomes == [.skipped(.stale)])
        #expect(await store.visits.isEmpty)
        #expect(await logs.saveCount == 0)
    }

    @Test("StartWorkoutUseCase honours an explicit start time")
    func explicitStart() async throws {
        let repo = InMemoryLogRepository()
        let moment = Fx.date(day: 3, hour: 19)
        let log = try await StartWorkoutUseCase(logs: repo, now: { moment }, calendar: Fx.calendar)
            .execute(plan: Fx.plan(), startedAt: moment.addingTimeInterval(-1_800))
        #expect(log.startedAt == moment.addingTimeInterval(-1_800))
    }
}
