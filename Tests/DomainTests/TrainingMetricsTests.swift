import Foundation
import Testing
@testable import Domain

@Suite("Training metrics (what a trainer reads from the plan and its execution)")
struct TrainingMetricsTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    /// Friday 15 March 2024, noon.
    static let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 12))!
    static let bench = ExerciseRef(id: "bench", name: "Bench Press")
    static let squat = ExerciseRef(id: "squat", name: "Back Squat")
    let builder = TrainingMetricsBuilder(calendar: calendar)

    static func plan(started daysAgo: Double = 90, perWeek: Int = 3) -> WorkoutPlan {
        let block = ResistanceBlock(id: "blk-bench", exercise: bench,
                                    sets: (1...3).map { PrescribedSet(index: $0, repsMin: 8, repsMax: 12, targetLoadKg: 60) }, restSeconds: 90)
        let template = WorkoutTemplate(id: "tpl-a", label: "Treino A", order: 0, blocks: [.resistance(block)])
        return WorkoutPlan(id: "plan", trainerID: "t", studentID: "s", name: "Plan", templates: [template], targetSessionsPerWeek: perWeek,
                           startDate: now.addingTimeInterval(-daysAgo * 86_400), meta: SyncMetadata(updatedAt: now, lastWriterDeviceID: "d"))
    }

    static func set(_ index: Int, kg: Double, reps: Int, rest: Int? = nil, warmup: Bool = false) -> SetLog {
        SetLog(index: index, weightKg: kg, reps: reps, restTakenSeconds: rest, completedAt: now, isWarmup: warmup)
    }

    static func log(_ id: String, daysAgo: Double, sets: [SetLog], exercise: ExerciseRef = bench, block: BlockID = "blk-bench", rpe: Int? = 7, minutes: Double = 60,
                    status: WorkoutStatus = .completed, deleted: Bool = false, template: TemplateID = "tpl-a") -> WorkoutLog {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var log = WorkoutLog(id: LogID(id), planID: "plan", templateID: template, templateLabel: "Treino A", studentID: "s", status: status, startedAt: start,
                             completedAt: status == .completed ? start.addingTimeInterval(minutes * 60) : nil,
                             blocks: sets.isEmpty ? [] : [.resistance(ResistanceLog(blockID: block, exercise: exercise, sets: sets))],
                             sessionRPE: rpe, meta: SyncMetadata(updatedAt: start, lastWriterDeviceID: "d"))
        if deleted { log.meta.deletedAt = start }
        return log
    }

    // MARK: Weeks

    @Test("Weekly buckets: sessions, working sets, reps, volume load, minutes and session-RPE load; empty weeks stay as zeros, oldest first")
    func weekly() throws {
        let logs = [
            Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 20, reps: 10, warmup: true), Self.set(2, kg: 60, reps: 10), Self.set(3, kg: 60, reps: 8)], rpe: 8, minutes: 50),
            Self.log("b", daysAgo: 2, sets: [Self.set(1, kg: 50, reps: 10)], rpe: 6, minutes: 30),
            Self.log("c", daysAgo: 20, sets: [Self.set(1, kg: 40, reps: 10)]),
        ]
        let summary = builder.summary(logs: logs, plan: nil, now: Self.now)
        #expect(summary.weeks.count == 8)
        #expect(summary.weeks.map(\.weekStart) == summary.weeks.map(\.weekStart).sorted())
        let current = try #require(summary.weeks.last)
        // This week (Mon 11 → Sun 17 March): sessions a (1 day ago, Thu) and b (2 days ago, Wed).
        #expect(current.sessions == 2 && current.workingSets == 3 && current.reps == 28)
        #expect(current.volumeLoadKg == 1580)                          // 60×10 + 60×8 + 50×10 (a literal: long mixed arithmetic makes the type-checker give up)
        #expect(current.minutes == 80)
        #expect(current.sessionLoad == 580)                            // 8×50 + 6×30
        #expect(summary.weeks.dropLast().filter { $0.sessions == 0 }.count >= 5)                       // gaps are visible
    }

    @Test("Warm-ups, unfinished, skipped, removed and future sessions never count")
    func filters() {
        let logs = [
            Self.log("ok", daysAgo: 1, sets: [Self.set(1, kg: 60, reps: 10)]),
            Self.log("running", daysAgo: 1, sets: [Self.set(1, kg: 100, reps: 10)], status: .inProgress),
            Self.log("skipped", daysAgo: 1, sets: [Self.set(1, kg: 100, reps: 10)], status: .skipped),
            Self.log("gone", daysAgo: 1, sets: [Self.set(1, kg: 100, reps: 10)], deleted: true),
            Self.log("future", daysAgo: -2, sets: [Self.set(1, kg: 100, reps: 10)]),
        ]
        let summary = builder.summary(logs: logs, plan: nil, now: Self.now)
        #expect(summary.exercises.count == 1 && summary.exercises.first?.sessions == 1)
        #expect(summary.weeks.reduce(0) { $0 + $1.sessions } == 1)
    }

    // MARK: Workload

    func workloadLogs(acuteSessions: Int, history: Double = 35) -> [WorkoutLog] {
        var logs = (1...4).map { week in Self.log("w\(week)", daysAgo: Double(week) * 7 + 3, sets: [Self.set(1, kg: 60, reps: 10)]) }       // 4 × (7 × 60) = 420 each
        logs += (0..<acuteSessions).map { Self.log("acute\($0)", daysAgo: Double($0) + 1, sets: [Self.set(1, kg: 60, reps: 10)]) }
        logs.append(Self.log("old", daysAgo: history, sets: [Self.set(1, kg: 60, reps: 10)], rpe: nil))                                        // anchors the history length
        return logs
    }

    @Test("Acute : chronic load is the last 7 days over the average of the four weeks before")
    func workload() throws {
        let balanced = builder.summary(logs: workloadLogs(acuteSessions: 1), plan: nil, now: Self.now)
        let balancedRatio = try #require(balanced.workloadRatio)
        #expect(abs(balancedRatio - 1) < 1e-9 && balanced.workloadZone == .balanced)
        let spike = builder.summary(logs: workloadLogs(acuteSessions: 4), plan: nil, now: Self.now)
        let spikeRatio = try #require(spike.workloadRatio)
        #expect(abs(spikeRatio - 4) < 1e-9 && spike.workloadZone == .high)
        #expect(spike.alerts.contains(.workloadSpike(ratio: spikeRatio)))
        let quiet = builder.summary(logs: workloadLogs(acuteSessions: 0), plan: nil, now: Self.now)
        #expect(quiet.workloadRatio == 0 && quiet.workloadZone == .low)
        #expect(quiet.alerts.contains(.workloadDrop(ratio: 0)))
    }

    @Test("Zone edges: 0.8 and 1.3 and 1.5 belong to the higher zone")
    func zones() {
        for (ratio, zone) in [(0.79, WorkloadZone.low), (0.8, .balanced), (1.29, .balanced), (1.3, .elevated), (1.49, .elevated), (1.5, .high), (3, .high)] {
            #expect(TrainingMetricsBuilder.zone(for: ratio) == zone, "\(ratio)")
        }
    }

    @Test("Without three weeks of history there is no ratio (the habit isn't formed yet), and without any chronic load there is none either")
    func workloadNeedsHistory() {
        let newcomer = [Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 60, reps: 10)]), Self.log("b", daysAgo: 10, sets: [Self.set(1, kg: 60, reps: 10)])]
        #expect(builder.summary(logs: newcomer, plan: nil, now: Self.now).workloadRatio == nil)
        let onlyRecent = [Self.log("old", daysAgo: 40, sets: [Self.set(1, kg: 60, reps: 10)], rpe: nil), Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 60, reps: 10)])]
        #expect(builder.summary(logs: onlyRecent, plan: nil, now: Self.now).workloadRatio == nil)
    }

    // MARK: Adherence

    @Test("Adherence: sessions in the last four weeks against the plan's weekly target; a plan only two weeks old is judged on two weeks")
    func adherence() {
        let logs = (0..<6).map { Self.log("s\($0)", daysAgo: Double($0) * 4 + 1, sets: [Self.set(1, kg: 60, reps: 10)]) }                  // days 1,5,9,13,17,21
        let full = builder.summary(logs: logs, plan: Self.plan(), now: Self.now)
        #expect(full.adherence == Adherence(completed: 6, planned: 12) && full.adherence?.ratio == 0.5)
        #expect(full.alerts.contains(.lowAdherence(percent: 50)))
        let young = builder.summary(logs: logs, plan: Self.plan(started: 10), now: Self.now)
        #expect(young.adherence == Adherence(completed: 4, planned: 6))                                                                     // days 1, 5, 9 and 13 are inside two weeks
        #expect(builder.summary(logs: logs, plan: nil, now: Self.now).adherence == nil)
    }

    @Test("A plan too young to judge (fewer than 3 planned sessions so far) never raises the low-adherence alert")
    func youngPlansDontAlert() {
        let summary = builder.summary(logs: [], plan: Self.plan(started: 3, perWeek: 2), now: Self.now)
        #expect(summary.adherence?.planned == 2 && !summary.alerts.contains { if case .lowAdherence = $0 { return true } else { return false } })
        let overdue = builder.summary(logs: [], plan: Self.plan(perWeek: 1), now: Self.now)                    // 4 weeks of a 1×/week plan and nothing done: that is worth saying
        #expect(overdue.alerts.contains(.lowAdherence(percent: 0)))
    }

    // MARK: Exercises

    func benchSessions(_ e1RMKilos: [Double]) -> [WorkoutLog] {
        // 1 rep at the given load: e1RM == load.
        e1RMKilos.enumerated().map { index, kg in Self.log("b\(index)", daysAgo: Double(e1RMKilos.count - index) * 3, sets: [Self.set(1, kg: kg, reps: 1)]) }
    }

    @Test("Progress per exercise: first, best and latest e1RM, the change, and the personal records (the first session is the baseline)")
    func trend() throws {
        let summary = builder.summary(logs: benchSessions([100, 105, 103, 110]), plan: nil, now: Self.now)
        let bench = try #require(summary.exercises.first)
        #expect(bench.sessions == 4 && bench.firstE1RM == 100 && bench.bestE1RM == 110 && bench.latestE1RM == 110 && bench.heaviestKg == 110)
        #expect(bench.personalRecords == 2)
        #expect(abs(try #require(bench.changePercent) - 10) < 1e-9)
        #expect(bench.isStagnant == false)
    }

    @Test("Stagnation: four or more sessions and none of the last three beat what came before; fewer sessions never count")
    func stagnation() throws {
        #expect(try #require(builder.summary(logs: benchSessions([100, 110, 105, 108, 109]), plan: nil, now: Self.now).exercises.first).isStagnant)
        #expect(try #require(builder.summary(logs: benchSessions([100, 110, 105, 108, 111]), plan: nil, now: Self.now).exercises.first).isStagnant == false)
        #expect(try #require(builder.summary(logs: benchSessions([100, 100, 100]), plan: nil, now: Self.now).exercises.first).isStagnant == false)
        let alerts = builder.summary(logs: benchSessions([100, 110, 105, 108, 109]), plan: nil, now: Self.now).alerts
        #expect(alerts.contains(.stagnant(exercise: Self.bench, sessions: 5)))
    }

    @Test("A substitute is tracked as itself, so it never pollutes the original's history; most-trained first")
    func substitution() {
        var swapped = Self.log("s", daysAgo: 2, sets: [Self.set(1, kg: 80, reps: 5)], exercise: Self.squat)
        swapped.blocks = [.resistance(ResistanceLog(blockID: "blk-bench", exercise: Self.squat, substitutedFor: Self.bench, sets: [Self.set(1, kg: 80, reps: 5)]))]
        let summary = builder.summary(logs: benchSessions([100, 105]) + [swapped], plan: nil, now: Self.now)
        #expect(summary.exercises.map(\.exercise.id.rawValue) == ["bench", "squat"])
        #expect(summary.exercises.last?.sessions == 1)
    }

    @Test("High-rep sets use the capped estimate, so a set of 30 doesn't inflate the 1RM")
    func highReps() throws {
        let summary = builder.summary(logs: [Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 40, reps: 30)])], plan: nil, now: Self.now)
        let e1RM = try #require(summary.exercises.first).bestE1RM
        #expect(e1RM == OneRepMaxFormula.epley.estimate(weightKg: 40, reps: 12))
    }

    // MARK: Execution against the prescription

    @Test("Rest: a set is on target within ±20 % (at least ±10 s); the first set, warm-ups and exercises outside the plan are ignored")
    func rest() throws {
        let sets = [Self.set(1, kg: 60, reps: 10, rest: nil), Self.set(2, kg: 60, reps: 10, rest: 90), Self.set(3, kg: 60, reps: 10, rest: 100),
                    Self.set(4, kg: 60, reps: 10, rest: 60), Self.set(5, kg: 60, reps: 10, rest: 150), Self.set(6, kg: 20, reps: 10, rest: 5, warmup: true)]
        let outside = Self.log("o", daysAgo: 2, sets: [Self.set(1, kg: 10, reps: 10, rest: 5)], block: "not-in-plan")
        let rest = try #require(builder.summary(logs: [Self.log("a", daysAgo: 1, sets: sets), outside], plan: Self.plan(), now: Self.now).rest)
        #expect(rest.setsMeasured == 4 && rest.setsOnTarget == 2 && rest.onTargetRatio == 0.5)
        #expect(rest.averageTakenSeconds == 100 && rest.averagePrescribedSeconds == 90)
        #expect(builder.summary(logs: [Self.log("a", daysAgo: 1, sets: sets)], plan: nil, now: Self.now).rest == nil)
        #expect(builder.summary(logs: [Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 60, reps: 10)])], plan: Self.plan(), now: Self.now).rest == nil)     // no rest data
    }

    @Test("Short rests are flagged only once there is enough data (6 measured sets) and under half are on target")
    func restAlert() {
        func session(_ rests: [Int]) -> [WorkoutLog] { [Self.log("a", daysAgo: 1, sets: rests.enumerated().map { Self.set($0.offset + 1, kg: 60, reps: 10, rest: $0.element) })] }
        func hasRestAlert(_ rests: [Int]) -> Bool {
            builder.summary(logs: session(rests), plan: Self.plan(), now: Self.now).alerts.contains { if case .restOffTarget = $0 { return true } else { return false } }
        }
        #expect(hasRestAlert([30, 30, 30, 30, 30]) == false)                    // only 5 measured sets
        #expect(hasRestAlert([30, 30, 30, 30, 30, 30]))
        #expect(builder.summary(logs: session([30, 30, 30, 30, 30, 30]), plan: Self.plan(), now: Self.now).alerts.contains(.restOffTarget(percent: 0)))
        #expect(hasRestAlert([90, 90, 90, 30, 30, 30]) == false)                // exactly half on target is not "mostly off"
    }

    @Test("Prescription: sets done, reps inside the range and the load asked for (2.5 % under still counts); a skipped exercise counts as undone")
    func prescription() throws {
        let done = Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 60, reps: 10), Self.set(2, kg: 55, reps: 12), Self.set(3, kg: 60, reps: 6)])
        let skipped = Self.log("b", daysAgo: 3, sets: [])
        let p = try #require(builder.summary(logs: [done, skipped], plan: Self.plan(), now: Self.now).prescription)
        #expect(p.setsPrescribed == 6 && p.setsDone == 3 && p.completionRatio == 0.5)
        let repRatio = try #require(p.repRangeRatio)
        #expect(p.setsCompared == 3 && p.setsInRepRange == 2 && abs(repRatio - 2.0 / 3) < 1e-9)
        #expect(p.setsWithLoadTarget == 3 && p.setsAtLoadTarget == 2)
        let nearly = Self.log("c", daysAgo: 1, sets: [Self.set(1, kg: 58.5, reps: 10), Self.set(2, kg: 58.4, reps: 10)])
        #expect(try #require(builder.summary(logs: [nearly], plan: Self.plan(), now: Self.now).prescription).setsAtLoadTarget == 1)
        #expect(builder.summary(logs: [done], plan: nil, now: Self.now).prescription == nil)
    }

    @Test("Extra sets beyond the plan don't push completion past what was prescribed")
    func extraSets() throws {
        let extra = Self.log("a", daysAgo: 1, sets: (1...5).map { Self.set($0, kg: 60, reps: 10) })
        let p = try #require(builder.summary(logs: [extra], plan: Self.plan(), now: Self.now).prescription)
        #expect(p.setsDone == 3 && p.setsCompared == 3 && p.completionRatio == 1)
    }

    // MARK: Intensity, density, recency, muscles

    @Test("Intensity (kg per rep) and density (kg per minute) over the working sets")
    func intensityAndDensity() {
        let log = Self.log("a", daysAgo: 1, sets: [Self.set(1, kg: 20, reps: 10, warmup: true), Self.set(2, kg: 60, reps: 10), Self.set(3, kg: 80, reps: 5)], minutes: 50)
        let summary = builder.summary(logs: [log], plan: nil, now: Self.now)
        #expect(summary.averageLoadPerRepKg == (600.0 + 400.0) / 15)
        #expect(summary.volumePerMinuteKg == 1000.0 / 50)
        #expect(builder.summary(logs: [], plan: nil, now: Self.now).averageLoadPerRepKg == nil)
    }

    @Test("Days since the last session, and the alert after a week away; nothing to say about someone who hasn't started")
    func recency() {
        #expect(builder.summary(logs: [Self.log("a", daysAgo: 0.2, sets: [Self.set(1, kg: 60, reps: 10)])], plan: nil, now: Self.now).daysSinceLastSession == 0)
        let away = builder.summary(logs: [Self.log("a", daysAgo: 9, sets: [Self.set(1, kg: 60, reps: 10)])], plan: nil, now: Self.now)
        #expect(away.daysSinceLastSession == 9 && away.alerts.contains(.noRecentSession(days: 9)))
        let six = builder.summary(logs: [Self.log("a", daysAgo: 6, sets: [Self.set(1, kg: 60, reps: 10)])], plan: nil, now: Self.now)
        #expect(!six.alerts.contains { if case .noRecentSession = $0 { return true } else { return false } })
        let none = builder.summary(logs: [], plan: nil, now: Self.now)
        #expect(none.daysSinceLastSession == nil && none.alerts.isEmpty && none.isEmpty)
    }

    @Test("Hard sets per muscle group over the last 7 days, from whatever muscle data the caller has")
    func muscles() {
        let logs = [Self.log("a", daysAgo: 2, sets: [Self.set(1, kg: 20, reps: 10, warmup: true), Self.set(2, kg: 60, reps: 10), Self.set(3, kg: 60, reps: 10)]),
                    Self.log("b", daysAgo: 3, sets: [Self.set(1, kg: 80, reps: 5)], exercise: Self.squat),
                    Self.log("old", daysAgo: 10, sets: [Self.set(1, kg: 60, reps: 10)])]
        let resolver: (ExerciseID) -> [MuscleGroup] = { $0 == "bench" ? [.chest, .triceps] : ($0 == "squat" ? [.quadriceps, .glutes] : []) }
        let summary = builder.summary(logs: logs, plan: nil, now: Self.now, muscles: resolver)
        #expect(summary.weeklySetsByMuscle == [.chest: 2, .triceps: 2, .quadriceps: 1, .glutes: 1])
        #expect(builder.summary(logs: logs, plan: nil, now: Self.now).weeklySetsByMuscle.isEmpty)
    }
}
