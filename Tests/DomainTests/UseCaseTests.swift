import Foundation
import Testing
@testable import Domain

@Suite("Workout use cases")
struct WorkoutUseCaseTests {
    let plan = Fx.plan(periodization: Fx.threeOneProgram)
    let now = Fx.date(day: 20)

    func useCase(_ repo: InMemoryLogRepository) -> StartWorkoutUseCase {
        let moment = now
        return StartWorkoutUseCase(logs: repo, now: { moment }, calendar: Fx.calendar)
    }

    @Test("First workout: template A, with a frozen periodization snapshot")
    func startsFirstWorkout() async throws {
        let repo = InMemoryLogRepository()
        let log = try await useCase(repo).execute(plan: plan, checkInID: "ci-1")

        #expect(log.templateID == plan.templates[0].id)
        #expect(log.status == .inProgress)
        #expect(log.checkInID == "ci-1")
        #expect(log.periodization?.weekIndex == 0)
        #expect(log.periodization?.phase == .high)
        #expect(log.meta.version == 1)            // repository owns meta: 0 (new) → 1 on first save
        #expect(await repo.stored[log.id] != nil)
    }

    @Test("Rotation index selects the periodization week — the 4th rotation lands on the deload")
    func snapshotFollowsRotation() async throws {
        let repo = InMemoryLogRepository()
        await repo.seed([Fx.log(plan: plan, template: plan.templates[2], at: Fx.date(day: 15), rotation: 2)])
        let log = try await useCase(repo).execute(plan: plan)
        #expect(log.templateID == plan.templates[0].id)
        #expect(log.rotationIndex == 3)
        #expect(log.periodization?.phase == .deload)
        #expect(log.periodization?.volumeMultiplier == 0.5)
    }

    @Test("A live in-progress workout is resumed rather than duplicated")
    func resumes() async throws {
        let repo = InMemoryLogRepository()
        let live = Fx.log(plan: plan, template: plan.templates[1], at: now.addingTimeInterval(-1_800), status: .inProgress)
        await repo.seed([live])
        let resumed = try await useCase(repo).execute(plan: plan)
        #expect(resumed.id == live.id)
        #expect(await repo.saveCount == 0)
    }

    @Test("A stale in-progress workout is abandoned, then the rotation continues")
    func abandonsStale() async throws {
        let repo = InMemoryLogRepository()
        let stale = Fx.log(plan: plan, template: plan.templates[1], at: now.addingTimeInterval(-30 * 3_600), status: .inProgress)
        await repo.seed([Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 10)), stale])

        let log = try await useCase(repo).execute(plan: plan)
        #expect(await repo.stored[stale.id]?.status == .abandoned)
        #expect(log.id != stale.id)
        #expect(log.templateID == plan.templates[1].id)   // abandoned B didn't advance the sequence
    }

    @Test("A plan without templates cannot start")
    func emptyPlanThrows() async {
        await #expect(throws: DomainError.self) {
            try await useCase(InMemoryLogRepository()).execute(plan: Fx.plan(templates: []))
        }
    }

    @Test("Recording a block replaces it and persists immediately")
    func recordsBlocks() async throws {
        let repo = InMemoryLogRepository()
        let log = try await useCase(repo).execute(plan: plan)
        let record = RecordBlockUseCase(logs: repo)
        let block = BlockLog.resistance(ResistanceLog(blockID: "block-ex-squat", exercise: Fx.squat,
                                                      sets: [SetLog(index: 1, weightKg: 100, reps: 5, completedAt: now)]))
        let saved = try await record.execute(block, in: log)
        #expect(saved.blocks == [block])
        #expect(saved.meta.version == log.meta.version + 1)
    }

    @Test("Finishing validates RPE and stamps completion")
    func finishes() async throws {
        let repo = InMemoryLogRepository()
        let log = try await useCase(repo).execute(plan: plan)
        let finish = FinishWorkoutUseCase(logs: repo, now: { Fx.date(day: 21) })

        await #expect(throws: DomainError.self) { try await finish.execute(log, sessionRPE: 11, note: nil) }
        await #expect(throws: DomainError.self) { try await finish.execute(log, sessionRPE: 0, note: nil) }

        let done = try await finish.execute(log, sessionRPE: 8, note: "  felt strong  ")
        #expect(done.status == .completed)
        #expect(done.sessionRPE == 8)
        #expect(done.feedbackNote == "felt strong")
        #expect(done.completedAt == Fx.date(day: 21))

        await #expect(throws: DomainError.self) { try await finish.execute(done, sessionRPE: 5, note: nil) }
        await #expect(throws: DomainError.self) { try await finish.skip(done) }
    }

    @Test("Skipping advances the rotation and blank notes are dropped")
    func skips() async throws {
        let repo = InMemoryLogRepository()
        let log = try await useCase(repo).execute(plan: plan)
        let skipped = try await FinishWorkoutUseCase(logs: repo, now: { Fx.date(day: 21) }).skip(log)
        #expect(skipped.status == .skipped)
        #expect(WorkoutSequencer().next(plan: plan, logs: [skipped], now: now)?.template.id == plan.templates[1].id)

        var blank = log
        try blank.complete(at: now, sessionRPE: 6, note: "   ")
        #expect(blank.feedbackNote == nil)
    }
}

@Suite("GymArrivalCoordinator")
struct GymArrivalCoordinatorTests {
    let venue = GymVenue(id: "sf-1", name: "Smart Fit Centro", latitude: -9.66, longitude: -35.73)
    let arrival = Fx.date(day: 3, hour: 18)

    func makeCoordinator(plan: WorkoutPlan?, logs: [WorkoutLog] = [])
        async -> (GymArrivalCoordinator, InMemoryCheckInRepository, RecordingNotifier) {
        let checkIns = InMemoryCheckInRepository()
        let notifier = RecordingNotifier()
        let logRepo = InMemoryLogRepository()
        await logRepo.seed(logs)
        let coordinator = GymArrivalCoordinator(studentID: Fx.student, deviceID: "dev",
                                                checkIns: checkIns, plans: InMemoryPlanRepository(plan),
                                                logs: logRepo, notifier: notifier, now: { [arrival] in arrival })
        return (coordinator, checkIns, notifier)
    }

    @Test("Arrival → check-in saved → today's workout announced with a deep link")
    func checksInAndNotifies() async throws {
        let plan = Fx.plan()
        let (coordinator, checkIns, notifier) = await makeCoordinator(
            plan: plan, logs: [Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 2))])

        let outcome = try await coordinator.handle(GymArrivalEvent(provider: .geofence, venue: venue, arrivedAt: arrival))
        guard case .checkedIn(let id, let next) = outcome else { Issue.record("expected check-in"); return }
        #expect(next?.template.label == "B")

        let saved = try #require(await checkIns.items.first)
        #expect(saved.id == id && saved.provider == .geofence)

        let notification = try #require(await notifier.posted.first)
        #expect(notification.fireDate == nil)
        #expect(notification.category == LocalNotification.arrivalCategory)
        #expect(notification.body.contains("B"))
        #expect(notification.userInfo["deeplink"] == "fitcoach://workout/start?checkIn=\(id)")
    }

    @Test("Duplicate events for the same visit are ignored — in memory and across relaunches")
    func dedupes() async throws {
        let (coordinator, checkIns, notifier) = await makeCoordinator(plan: Fx.plan())
        let event = GymArrivalEvent(provider: .geofence, venue: venue, arrivedAt: arrival)
        _ = try await coordinator.handle(event)
        let second = try await coordinator.handle(GymArrivalEvent(provider: .smartFit, venue: venue, arrivedAt: arrival.addingTimeInterval(600)))
        #expect(second == .duplicate)
        #expect(await checkIns.items.count == 1)
        #expect(await notifier.posted.count == 1)

        // A fresh coordinator (app relaunch) still sees the persisted check-in.
        let relaunched = GymArrivalCoordinator(studentID: Fx.student, deviceID: "dev", checkIns: checkIns,
                                               plans: InMemoryPlanRepository(Fx.plan()), logs: InMemoryLogRepository(),
                                               notifier: notifier, now: { [arrival] in arrival })
        #expect(try await relaunched.handle(GymArrivalEvent(provider: .geofence, venue: venue, arrivedAt: arrival.addingTimeInterval(900))) == .duplicate)
    }

    @Test("Visits beyond the dedupe window check in again")
    func laterVisitCounts() async throws {
        let (coordinator, checkIns, _) = await makeCoordinator(plan: Fx.plan())
        _ = try await coordinator.handle(GymArrivalEvent(provider: .geofence, venue: venue, arrivedAt: arrival))
        let later = try await coordinator.handle(GymArrivalEvent(provider: .geofence, venue: venue, arrivedAt: arrival.addingTimeInterval(6 * 3_600)))
        guard case .checkedIn = later else { Issue.record("expected a second check-in"); return }
        #expect(await checkIns.items.count == 2)
    }

    @Test("Without a plan the student is still checked in")
    func noPlan() async throws {
        let (coordinator, _, notifier) = await makeCoordinator(plan: nil)
        let outcome = try await coordinator.handle(GymArrivalEvent(provider: .manual, venue: venue, arrivedAt: arrival))
        guard case .checkedIn(_, let next) = outcome else { Issue.record("expected check-in"); return }
        #expect(next == nil)
        #expect(await notifier.posted.count == 1)
    }

    @Test("Consuming a provider stream handles every event")
    func consumesStream() async throws {
        let (coordinator, checkIns, _) = await makeCoordinator(plan: Fx.plan())
        let provider = ScriptedProvider(events: [GymArrivalEvent(provider: .simulated, venue: venue, arrivedAt: arrival)])
        await coordinator.startConsuming(provider)
        for _ in 0..<200 where await checkIns.items.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        await coordinator.stopConsuming()
        #expect(await checkIns.items.count == 1)
    }
}

struct ScriptedProvider: GymArrivalProviding {
    let provider: GymProvider = .simulated
    let events: [GymArrivalEvent]
    func arrivals() -> AsyncStream<GymArrivalEvent> {
        AsyncStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
    func startMonitoring() async throws {}
    func stopMonitoring() async {}
}

@Suite("Cadence reminders & adherence")
struct CadenceAndAdherenceTests {
    let plan = Fx.plan()

    @Test("Typical slots need repeat behaviour; one-offs are ignored")
    func typicalSlots() {
        // Mondays at 18:00 for three weeks, plus a single Wednesday 07:00.
        let logs = [0, 7, 14].map { Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: $0, hour: 18)) }
            + [Fx.log(plan: plan, template: plan.templates[1], at: Fx.date(day: 2, hour: 7))]
        let slots = CadenceAnalyzer().typicalSlots(from: logs, now: Fx.date(day: 15), calendar: Fx.calendar)
        #expect(slots == [TrainingSlot(weekday: 2, hour: 18)])    // Calendar: Monday = 2
    }

    @Test("Old history outside the look-back window is ignored")
    func lookback() {
        let logs = [0, 7].map { Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: $0, hour: 18)) }
        #expect(CadenceAnalyzer(lookbackWeeks: 2).typicalSlots(from: logs, now: Fx.date(day: 200), calendar: Fx.calendar).isEmpty)
    }

    @Test("Reminders skip past slots and days already trained; only the first names the workout")
    func reminders() throws {
        let slots = [TrainingSlot(weekday: 2, hour: 18), TrainingSlot(weekday: 4, hour: 18)]   // Mon + Wed
        let now = Fx.date(day: 0, hour: 9)   // Monday morning
        let trainedMonday = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 0, hour: 7))
        let analyzer = CadenceAnalyzer()

        let afterTraining = analyzer.reminders(slots: slots, logs: [trainedMonday], nextWorkoutLabel: "B", now: now, calendar: Fx.calendar)
        #expect(afterTraining.count == 1)                       // today's slot skipped (already trained); 7-day horizon → Wed only
        #expect(afterTraining[0].body.contains("B"))

        let twoWeeks = CadenceAnalyzer(horizonDays: 14)
            .reminders(slots: slots, logs: [trainedMonday], nextWorkoutLabel: "B", now: now, calendar: Fx.calendar)
        #expect(twoWeeks.count == 3)                            // Wed, next Mon, next Wed
        #expect(twoWeeks[0].body.contains("B"))
        #expect(!twoWeeks[1].body.contains("B") && !twoWeeks[2].body.contains("B"))

        let beforeTraining = analyzer.reminders(slots: slots, logs: [], nextWorkoutLabel: "A", now: now, calendar: Fx.calendar)
        let first = try #require(beforeTraining.first)
        #expect(first.fireDate == Fx.date(day: 0, hour: 17).addingTimeInterval(1_800))   // 30 min before 18:00
        #expect(first.category == LocalNotification.trainingReminderCategory)

        let afterSlot = analyzer.reminders(slots: slots, logs: [], nextWorkoutLabel: "A", now: Fx.date(day: 0, hour: 19), calendar: Fx.calendar)
        #expect(afterSlot.first?.id.contains("2024-1-3") == true)   // today's slot already passed → Wednesday
        #expect(Set(beforeTraining.map(\.id)).count == beforeTraining.count)
    }

    @Test("Adherence: sessions, sets, reps and rest compliance against the prescription")
    func adherence() throws {
        // Prescription: 3 sets × 5–7 reps, 90 s rest. Expectation: 3 sessions / week over 2 weeks = 6.
        let interval = DateInterval(start: Fx.date(day: 0, hour: 0), end: Fx.date(day: 14, hour: 0))
        let full = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 1),
                          sets: [(100, 5), (100, 5), (100, 5)], restTaken: 90)       // all rest on target
        let partial = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 3),
                             sets: [(100, 5), (100, 4)], restTaken: 30)               // 2 of 3 sets, rest far too short
        let outside = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 30))
        let abandoned = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 4), status: .abandoned)

        let report = AdherenceCalculator().report(plan: plan, logs: [full, partial, outside, abandoned], interval: interval)
        #expect(report.sessionsExpected == 6)
        #expect(report.sessionsCompleted == 2)
        #expect(abs(report.sessionAdherence - 2.0 / 6) < 1e-9)
        #expect(report.setsPrescribed == 6)
        #expect(report.setsCompleted == 5)
        #expect(report.repsTarget == 30)
        #expect(report.repsCompleted == 5 + 5 + 5 + 5 + 4)
        #expect(report.averagePrescribedRestSeconds == 90)
        // Timed sets: full → 2 (both 90 s ✔), partial → 1 (30 s ✘) ⇒ 2 / 3.
        #expect(abs(try #require(report.restComplianceRate) - 2.0 / 3) < 1e-9)
        #expect(report.setCompletion > 0.8 && report.repCompletion < 1)
    }

    @Test("Empty history yields zeroed, non-crashing ratios")
    func adherenceEmpty() {
        let report = AdherenceCalculator().report(plan: plan, logs: [], interval: DateInterval(start: Fx.monday, duration: 86_400))
        #expect(report.sessionsExpected == 3)
        #expect(report.sessionAdherence == 0 && report.setCompletion == 0 && report.repCompletion == 0)
        #expect(report.restComplianceRate == nil && report.averageActualRestSeconds == nil)
    }
}
