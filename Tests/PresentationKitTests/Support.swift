import Domain
import Foundation
@testable import PresentationKit

enum PFx {
    static let t0 = Date(timeIntervalSince1970: 1_704_067_200)
    static let student: UserID = "s1"
    static let squat = ExerciseRef(id: "squat", name: "Back Squat")
    static let bench = ExerciseRef(id: "bench", name: "Bench Press")

    static func meta(_ version: Int = 0) -> SyncMetadata { SyncMetadata(version: version, updatedAt: t0, lastWriterDeviceID: "t", state: .synced) }

    static func resistance(_ exercise: ExerciseRef = squat, sets: Int = 3, rest: Int = 90, sameLoad: Bool = false,
                           targets: [Double?] = []) -> ResistanceBlock {
        ResistanceBlock(id: BlockID("blk-\(exercise.id)"), exercise: exercise,
                        sets: (1...sets).map { index in
                            PrescribedSet(index: index, repsMin: 5, repsMax: 8,
                                          targetLoadKg: targets.indices.contains(index - 1) ? targets[index - 1] : nil)
                        },
                        restSeconds: rest, sameLoadAcrossSets: sameLoad)
    }

    static let hiit = HIITBlock(id: "hiit", title: "Finisher", rounds: 2, workSeconds: 20, restSeconds: 10, movements: ["Burpee"])
    static let cardio = CardioBlock(id: "cardio", modality: .bike, targetDurationSeconds: 600, targetZone: 2)

    static func template(_ blocks: [WorkoutBlock]) -> WorkoutTemplate {
        WorkoutTemplate(id: "tpl-a", label: "Workout A", order: 0, blocks: blocks)
    }

    static func plan(blocks: [WorkoutBlock]? = nil, periodization: PeriodizationPlan? = nil) -> WorkoutPlan {
        WorkoutPlan(id: "plan-1", trainerID: "t1", studentID: student, name: "Plan",
                    templates: [template(blocks ?? [.resistance(resistance()), .hiit(hiit), .cardio(cardio)])],
                    periodization: periodization, targetSessionsPerWeek: 3, startDate: t0, meta: meta())
    }

    static func log(id: String = "log-1", status: WorkoutStatus = .inProgress, blocks: [BlockLog] = [],
                    start: Date = t0, planID: PlanID = "plan-1") -> WorkoutLog {
        WorkoutLog(id: LogID(id), planID: planID, templateID: "tpl-a", templateLabel: "Workout A", studentID: student,
                   status: status, startedAt: start, completedAt: status == .completed ? start : nil, blocks: blocks, meta: meta())
    }

    static func completedSquatSession(weights: [Double], start: Date) -> WorkoutLog {
        let sets = weights.enumerated().map { SetLog(index: $0.offset + 1, weightKg: $0.element, reps: 5, completedAt: start) }
        return log(id: "prev", status: .completed, blocks: [.resistance(ResistanceLog(blockID: "blk-squat", exercise: squat, sets: sets))], start: start)
    }
}

@MainActor
final class FakeClock {
    var current = PFx.t0
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

@MainActor
final class RecordingFeedback: FeedbackProviding {
    private(set) var events: [String] = []
    private(set) var restAlerts: [Date] = []
    private(set) var cancelledAlerts = 0

    func setLogged() { events.append("setLogged") }
    func restFinished() { events.append("restFinished") }
    func intervalChanged() { events.append("intervalChanged") }
    func warning() { events.append("warning") }
    func scheduleRestAlert(at date: Date) { restAlerts.append(date) }
    func cancelRestAlert() { cancelledAlerts += 1 }
    func count(_ name: String) -> Int { events.filter { $0 == name }.count }
}

@MainActor
final class LogSink {
    private(set) var logged: [BlockLog] = []
    func add(_ log: BlockLog) { logged.append(log) }
}

@MainActor
struct Env {
    let clock = FakeClock()
    let feedback = RecordingFeedback()
    let sink = LogSink()

    func context(previous: WorkoutLog? = nil, restored: [BlockID: BlockLog] = [:]) -> BlockBuildContext {
        let clock = self.clock
        let sink = self.sink
        return BlockBuildContext(feedback: feedback, now: { clock.now() }, previousSession: previous, restored: restored,
                                 autoTick: false, onBlockLogged: { sink.add($0) })
    }
}

actor MemLogRepo: WorkoutLogRepository {
    private(set) var stored: [LogID: WorkoutLog] = [:]
    var failSaves = false
    struct Failure: Error {}

    func setFailSaves(_ value: Bool) { failSaves = value }
    func seed(_ log: WorkoutLog) { stored[log.id] = log }

    func save(_ log: WorkoutLog) async throws -> WorkoutLog {
        if failSaves { throw Failure() }
        var saved = log
        saved.meta.version = (stored[log.id]?.meta.version ?? log.meta.version) + 1
        stored[log.id] = saved
        return saved
    }

    func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? { stored[id] }

    func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] {
        if failSaves { throw Failure() }
        return stored.values.filter { $0.studentID == studentID }.sorted { $0.startedAt > $1.startedAt }
    }

    nonisolated func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> { AsyncStream { $0.finish() } }
}
