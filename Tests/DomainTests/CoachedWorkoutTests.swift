import Foundation
import Testing
@testable import Domain

/// A log repository the test drives by hand, to check how the merged one combines two sources.
actor ScriptedLogs: WorkoutLogRepository {
    private(set) var stored: [LogID: WorkoutLog] = [:]
    private(set) var saved: [LogID] = []
    private var continuation: AsyncStream<[WorkoutLog]>.Continuation?
    private var stream: AsyncStream<[WorkoutLog]>

    init(_ logs: [WorkoutLog] = []) {
        var captured: AsyncStream<[WorkoutLog]>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured
        for log in logs { stored[log.id] = log }
        continuation?.yield(Array(stored.values))
    }

    func publish(_ logs: [WorkoutLog]) { for log in logs { stored[log.id] = log }; continuation?.yield(Array(stored.values)) }
    func finish() { continuation?.finish() }
    func save(_ log: WorkoutLog) async throws -> WorkoutLog {
        var next = log
        next.meta.version += 1
        stored[log.id] = next
        saved.append(log.id)
        continuation?.yield(Array(stored.values))
        return next
    }
    func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? { stored[id] }
    func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] {
        stored.values.filter { $0.studentID == studentID && (planID == nil || $0.planID == planID) && (since == nil || $0.startedAt >= since!) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    nonisolated func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> { AsyncStream { $0.finish() } }
    func observed() -> AsyncStream<[WorkoutLog]> { stream }
}

private extension WorkoutLog {
    func coached(by trainer: UserID = Fx.trainer) -> WorkoutLog { var copy = self; copy.coachedBy = trainer; return copy }
}

@Suite("MergedWorkoutLogRepository")
struct MergedWorkoutLogRepositoryTests {
    let plan = Fx.plan()
    func log(_ label: String, day: Int, status: WorkoutStatus = .completed) -> WorkoutLog {
        Fx.log(plan: plan, template: plan.templates.first { $0.label == label }!, at: Fx.date(day: day), status: status)
    }

    @Test("Writes are routed by who ran the workout: the student's own to theirs, the trainer's to the trainer-written store")
    func routing() async throws {
        let own = ScriptedLogs(), coached = ScriptedLogs()
        let merged = MergedWorkoutLogRepository(own: own, coached: coached)
        let mine = log("A", day: 1), theirs = log("B", day: 2).coached()
        _ = try await merged.save(mine)
        _ = try await merged.save(theirs)
        let ownSaved = await own.saved, coachedSaved = await coached.saved
        #expect(ownSaved == [mine.id] && coachedSaved == [theirs.id])
    }

    @Test("Reading merges both stores, newest first, with no duplicates, and finds a log by id in either")
    func reading() async throws {
        let a = log("A", day: 1), b = log("B", day: 3).coached(), c = log("C", day: 2)
        let merged = MergedWorkoutLogRepository(own: ScriptedLogs([a, c]), coached: ScriptedLogs([b, a]))
        let all = try await merged.logs(studentID: Fx.student, planID: nil, since: nil)
        #expect(all.map(\.id) == [b.id, c.id, a.id])
        #expect(try await merged.log(id: b.id, studentID: Fx.student)?.coachedBy == Fx.trainer)
        #expect(try await merged.log(id: a.id, studentID: Fx.student) != nil)
        #expect(try await merged.log(id: "nope", studentID: Fx.student) == nil)
        #expect(try await merged.logs(studentID: Fx.student, planID: "other", since: nil).isEmpty)
        #expect(try await merged.logs(studentID: Fx.student, planID: plan.id, since: Fx.date(day: 2)).map(\.id) == [b.id, c.id])
    }

    @Test("Observing emits the combined list once both sides have reported, then again on every change from either side")
    func observing() async throws {
        let own = ScriptedLogs([log("A", day: 1)]), coached = ScriptedLogs()
        let merged = MergedWorkoutLogRepository(own: ScriptedObserver(own), coached: ScriptedObserver(coached))
        var iterator = merged.observeLogs(studentID: Fx.student).makeAsyncIterator()
        #expect(await iterator.next()?.count == 1)                       // the student's own, once the trainer's side has said it is empty
        let session = log("B", day: 2).coached()
        await coached.publish([session])
        let afterTrainer = await iterator.next()
        #expect(afterTrainer?.map(\.coachedBy) == [Fx.trainer, nil])
        await own.publish([log("C", day: 3)])
        #expect(await iterator.next()?.count == 3)
    }

    /// Adapts a `ScriptedLogs` so `observeLogs` hands out its controllable stream (an actor can't expose it synchronously).
    struct ScriptedObserver: WorkoutLogRepository {
        let base: ScriptedLogs
        init(_ base: ScriptedLogs) { self.base = base }
        func save(_ log: WorkoutLog) async throws -> WorkoutLog { try await base.save(log) }
        func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? { try await base.log(id: id, studentID: studentID) }
        func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] { try await base.logs(studentID: studentID, planID: planID, since: since) }
        func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> {
            AsyncStream { continuation in
                let task = Task { for await value in await base.observed() { continuation.yield(value) } }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

@Suite("Coached workouts and the rotation")
struct CoachedSequencingTests {
    let plan = Fx.plan()
    let now = Fx.date(day: 5)

    @Test("The student never resumes a session the trainer is running — it isn't theirs to finish")
    func studentIgnoresCoachedInProgress() {
        let running = Fx.log(plan: plan, template: plan.templates[1], at: now.addingTimeInterval(-600), status: .inProgress).coached()
        let next = WorkoutSequencer().next(plan: plan, logs: [running], now: now)
        #expect(next?.reason == .firstWorkout && next?.template.label == "A")
        let own = Fx.log(plan: plan, template: plan.templates[1], at: now.addingTimeInterval(-600), status: .inProgress)
        #expect(WorkoutSequencer().next(plan: plan, logs: [own], now: now)?.reason == .resumedInProgress)             // their own still resumes
    }

    @Test("A finished coached session advances the rotation like any other")
    func coachedAdvances() {
        let done = Fx.log(plan: plan, template: plan.templates[0], at: now.addingTimeInterval(-3_600)).coached()
        let next = WorkoutSequencer().next(plan: plan, logs: [done], now: now)
        #expect(next?.template.label == "B" && next?.reason == .continuedSequence)
    }

    @Test("Starting their own workout, the student's device leaves a stale trainer session alone (it could not write it anyway)")
    func studentDoesNotAbandonCoached() async throws {
        let stale = Fx.log(plan: plan, template: plan.templates[0], at: now.addingTimeInterval(-20 * 3_600), status: .inProgress).coached()
        let ownStale = Fx.log(plan: plan, template: plan.templates[1], at: now.addingTimeInterval(-20 * 3_600), status: .inProgress)
        let repo = InMemoryLogRepository()
        await repo.seed([stale, ownStale])
        let started = try await StartWorkoutUseCase(logs: repo, now: { [now] in now }, calendar: Fx.calendar).execute(plan: plan)
        let coachedStatus = await repo.stored[stale.id]?.status, ownStatus = await repo.stored[ownStale.id]?.status
        #expect(coachedStatus == .inProgress)                                            // untouched
        #expect(ownStatus == .abandoned)                                                 // their own stale one is cleaned up as before
        #expect(started.coachedBy == nil)
    }
}

@Suite("StartCoachedWorkoutUseCase")
struct StartCoachedWorkoutTests {
    let plan = Fx.plan()
    let now = Fx.date(day: 5)

    func useCase(_ repo: some WorkoutLogRepository, trainer: UserID = Fx.trainer) -> StartCoachedWorkoutUseCase {
        StartCoachedWorkoutUseCase(logs: repo, trainerID: trainer, now: { [now] in now }, calendar: Fx.calendar)
    }

    @Test("Starts the next workout in the rotation, marked as run by the trainer, for the student's plan")
    func startsNext() async throws {
        let repo = InMemoryLogRepository()
        await repo.seed([Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 4))])
        let log = try await useCase(repo).execute(plan: plan)
        #expect(log.templateLabel == "B" && log.coachedBy == Fx.trainer && log.status == .inProgress)
        #expect(log.studentID == Fx.student && log.planID == plan.id && log.startedAt == now)
        #expect(await repo.stored[log.id] != nil)
    }

    @Test("The trainer can pick any workout of the plan instead of the suggested one; one that isn't in the plan is refused")
    func picksAWorkout() async throws {
        let repo = InMemoryLogRepository()
        let log = try await useCase(repo).execute(plan: plan, templateID: plan.templates[2].id)
        #expect(log.templateLabel == "C")
        await #expect(throws: DomainError.self) { try await useCase(InMemoryLogRepository()).execute(plan: plan, templateID: "not-in-plan") }
    }

    @Test("An unfinished session of this trainer is resumed, not duplicated; a different workout closes the old one")
    func resumes() async throws {
        let repo = InMemoryLogRepository()
        let uc = useCase(repo)
        let first = try await uc.execute(plan: plan)
        #expect(try await uc.resumable(plan: plan)?.id == first.id)
        #expect(try await uc.execute(plan: plan).id == first.id)
        #expect(try await uc.execute(plan: plan, templateID: first.templateID).id == first.id)

        let other = try await uc.execute(plan: plan, templateID: plan.templates[1].id)
        #expect(other.id != first.id && other.templateLabel == "B")
        #expect(await repo.stored[first.id]?.status == .abandoned)
        #expect(try await uc.resumable(plan: plan)?.id == other.id)
    }

    @Test("A session left open for the whole day is closed, and a new one starts")
    func staleIsClosed() async throws {
        let repo = InMemoryLogRepository()
        let old = Fx.log(plan: plan, template: plan.templates[0], at: now.addingTimeInterval(-20 * 3_600), status: .inProgress).coached()
        await repo.seed([old])
        let uc = useCase(repo)
        #expect(try await uc.resumable(plan: plan) == nil)
        let fresh = try await uc.execute(plan: plan)
        let oldStatus = await repo.stored[old.id]?.status
        #expect(fresh.id != old.id && oldStatus == .abandoned)
    }

    @Test("The student's own unfinished workout neither blocks the trainer nor decides which workout is next")
    func ignoresTheStudentsOwn() async throws {
        let repo = InMemoryLogRepository()
        await repo.seed([Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 3)),
                         Fx.log(plan: plan, template: plan.templates[1], at: now.addingTimeInterval(-600), status: .inProgress)])
        let uc = useCase(repo)
        #expect(try await uc.resumable(plan: plan) == nil)
        #expect(try await uc.suggestedTemplate(plan: plan)?.label == "B")                // after A, regardless of the half-done B
        let log = try await uc.execute(plan: plan)
        #expect(log.templateLabel == "B" && log.coachedBy == Fx.trainer)
        #expect(await repo.stored.values.filter { $0.status == .inProgress }.count == 2)  // the student's own was left alone
    }

    @Test("Only the plan's own trainer can run it")
    func onlyTheOwner() async {
        await #expect(throws: DomainError.self) { try await useCase(InMemoryLogRepository(), trainer: "someone-else").execute(plan: plan) }
    }

    @Test("A plan without workouts can't be run")
    func emptyPlan() async {
        let empty = Fx.plan(templates: [])
        await #expect(throws: DomainError.self) { try await useCase(InMemoryLogRepository()).execute(plan: empty) }
    }

    @Test("The strength/volume week of the day is frozen on the session, like the student's own")
    func focusSnapshot() async throws {
        var cycled = plan
        cycled.focusCycle = FocusCycle(strengthWeeks: 2, volumeWeeks: 2)
        let log = try await useCase(InMemoryLogRepository()).execute(plan: cycled)
        #expect(log.focus != nil)
    }
}
