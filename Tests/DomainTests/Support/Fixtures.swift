import Foundation
@testable import Domain

/// Deterministic builders shared by the Domain tests. Everything is anchored to a fixed Monday in UTC
/// so no test depends on the machine's clock, locale or time zone.
enum Fx {
    static let student: UserID = "student-1"
    static let trainer: UserID = "trainer-1"
    static let squat = ExerciseRef(id: "ex-squat", name: "Back Squat")
    static let bench = ExerciseRef(id: "ex-bench", name: "Bench Press")

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Monday 2024-01-01 00:00 UTC.
    static let monday = Date(timeIntervalSince1970: 1_704_067_200)

    static func date(day: Int, hour: Int = 18) -> Date {
        monday.addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3_600)
    }

    static func meta(_ at: Date = monday, state: SyncState = .synced) -> SyncMetadata {
        SyncMetadata(version: 1, updatedAt: at, lastWriterDeviceID: "dev", state: state)
    }

    static func resistanceBlock(_ ref: ExerciseRef = squat,
                                sets: Int = 3,
                                reps: Int = 5,
                                rest: Int = 90) -> ResistanceBlock {
        ResistanceBlock(id: BlockID("block-\(ref.id)"),
                        exercise: ref,
                        sets: (1...sets).map { PrescribedSet(index: $0, repsMin: reps, repsMax: reps + 2) },
                        restSeconds: rest)
    }

    static func template(_ label: String, order: Int, blocks: [WorkoutBlock]? = nil) -> WorkoutTemplate {
        WorkoutTemplate(id: TemplateID("tpl-\(label)"), label: label, order: order,
                        blocks: blocks ?? [.resistance(resistanceBlock())])
    }

    static var threeTemplates: [WorkoutTemplate] {
        [template("A", order: 0), template("B", order: 1), template("C", order: 2)]
    }

    static func plan(templates: [WorkoutTemplate]? = nil,
                     periodization: PeriodizationPlan? = nil,
                     sessionsPerWeek: Int = 3) -> WorkoutPlan {
        WorkoutPlan(id: PlanID("plan-1"), trainerID: trainer, studentID: student, name: "Hypertrophy",
                    templates: templates ?? threeTemplates, periodization: periodization,
                    targetSessionsPerWeek: sessionsPerWeek, startDate: monday, meta: meta())
    }

    static var threeOneProgram: PeriodizationPlan {
        PeriodizationPlan(macrocycles: [.alternating(name: "Hypertrophy", highWeeks: 3, deloadWeeks: 1, cycles: 3)],
                          startDate: monday)
    }

    static func log(plan: WorkoutPlan,
                    template: WorkoutTemplate,
                    at date: Date,
                    status: WorkoutStatus = .completed,
                    rotation: Int = 0,
                    snapshot: PeriodizationSnapshot? = nil,
                    exercise: ExerciseRef = squat,
                    sets: [(kg: Double, reps: Int)] = [(100, 5)],
                    restTaken: Int? = nil) -> WorkoutLog {
        let setLogs = sets.enumerated().map { offset, entry in
            SetLog(index: offset + 1, weightKg: entry.kg, reps: entry.reps,
                   restTakenSeconds: offset == 0 ? nil : restTaken, completedAt: date)
        }
        return WorkoutLog(id: LogID.generate(), planID: plan.id, templateID: template.id,
                          templateLabel: template.label, studentID: plan.studentID, status: status,
                          startedAt: date, completedAt: status == .inProgress ? nil : date,
                          rotationIndex: rotation, periodization: snapshot,
                          blocks: [.resistance(ResistanceLog(blockID: BlockID("block-\(exercise.id)"),
                                                             exercise: exercise, sets: setLogs))],
                          meta: meta(date))
    }

    /// One bench-press session per week following `program`. Working weeks add `step` kg per working
    /// week; deload weeks use a much lighter `deloadKg` — the scenario that naive analytics gets wrong.
    static func progressiveLogs(plan: WorkoutPlan,
                                program: PeriodizationPlan,
                                weeks: Int,
                                exercise: ExerciseRef = bench,
                                base: Double = 80,
                                step: Double = 2.5,
                                deloadKg: Double = 60,
                                includeDeloadWeeks: Bool = true) -> [WorkoutLog] {
        var workingSoFar = 0
        var logs: [WorkoutLog] = []
        for week in 0..<weeks {
            guard let resolved = program.resolve(weekIndex: week) else { continue }
            let isDeload = resolved.microcycle.phase == .deload
            if isDeload && !includeDeloadWeeks { continue }
            let kg = isDeload ? deloadKg : base + step * Double(workingSoFar)
            if !isDeload { workingSoFar += 1 }
            logs.append(log(plan: plan, template: plan.templates[0], at: date(day: week * 7 + 1),
                            snapshot: PeriodizationSnapshot(resolved), exercise: exercise,
                            sets: [(kg, 5), (kg, 5), (kg, 5)]))
        }
        return logs
    }
}

// MARK: - Test doubles

actor InMemoryLogRepository: WorkoutLogRepository {
    private(set) var stored: [LogID: WorkoutLog] = [:]
    private(set) var saveCount = 0

    func seed(_ logs: [WorkoutLog]) { for log in logs { stored[log.id] = log } }

    func save(_ log: WorkoutLog) async throws -> WorkoutLog {
        var saved = log
        saved.meta.version = (stored[log.id]?.meta.version ?? log.meta.version) + 1
        saved.meta.state = .pendingUpsert
        stored[log.id] = saved
        saveCount += 1
        return saved
    }

    func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? { stored[id] }

    func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] {
        stored.values
            .filter { $0.studentID == studentID && (planID == nil || $0.planID == planID) && (since == nil || $0.startedAt >= since!) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    nonisolated func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> {
        AsyncStream { $0.finish() }
    }
}

actor InMemoryPlanRepository: WorkoutPlanRepository {
    var plan: WorkoutPlan?
    init(_ plan: WorkoutPlan? = nil) { self.plan = plan }
    func save(_ plan: WorkoutPlan) async throws -> WorkoutPlan { self.plan = plan; return plan }
    func activePlan(studentID: UserID) async throws -> WorkoutPlan? { plan }
    func plans(studentID: UserID) async throws -> [WorkoutPlan] { plan.map { [$0] } ?? [] }
    nonisolated func observeActivePlan(studentID: UserID) -> AsyncStream<WorkoutPlan?> { AsyncStream { $0.finish() } }
}

actor InMemoryCheckInRepository: CheckInRepository {
    private(set) var items: [GymCheckIn] = []
    func save(_ checkIn: GymCheckIn) async throws -> GymCheckIn { items.append(checkIn); return checkIn }
    func checkIns(studentID: UserID, since: Date?) async throws -> [GymCheckIn] {
        items.filter { since == nil || $0.arrivedAt >= since! }
    }
}

actor RecordingNotifier: LocalNotificationScheduling {
    private(set) var posted: [LocalNotification] = []
    private(set) var replaced: [(category: String, items: [LocalNotification])] = []
    func requestAuthorization() async throws -> Bool { true }
    func post(_ notification: LocalNotification) async throws { posted.append(notification) }
    private(set) var cancelled: [String] = []
    func cancel(ids: [String]) async throws { cancelled += ids }
    func replacePending(category: String, with notifications: [LocalNotification]) async throws {
        replaced.append((category, notifications))
    }
}
