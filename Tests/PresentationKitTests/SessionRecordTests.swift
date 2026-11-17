import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

private enum RecFx {
    static let bench = ExerciseRef(id: "bench", name: "Supino reto")
    static let squat = ExerciseRef(id: "squat", name: "Agachamento")
    static let day = PFx.t0

    static func plan() -> WorkoutPlan {
        let block = ResistanceBlock(id: "blk-bench", exercise: bench, sets: (1...3).map { PrescribedSet(index: $0, repsMin: 8, repsMax: 12, targetLoadKg: 60) }, restSeconds: 90)
        let hiit = HIITBlock(id: "blk-hiit", title: "Finisher", rounds: 4, workSeconds: 20, restSeconds: 10, movements: ["Burpee"])
        let template = WorkoutTemplate(id: "tpl-a", label: "Treino A", order: 0, blocks: [.resistance(block), .hiit(hiit)])
        return WorkoutPlan(id: "plan", trainerID: "t1", studentID: PFx.student, name: "Plan", templates: [template], targetSessionsPerWeek: 3, startDate: day, meta: PFx.meta())
    }

    static func log(coached: Bool = false) -> WorkoutLog {
        let sets = [SetLog(id: "w", index: 1, weightKg: 20, reps: 12, restTakenSeconds: nil, completedAt: day.addingTimeInterval(60), isWarmup: true),
                    SetLog(id: "s1", index: 2, weightKg: 60, reps: 10, rpe: 7, restTakenSeconds: 45, completedAt: day.addingTimeInterval(240)),
                    SetLog(id: "s2", index: 3, weightKg: 55, reps: 12, rpe: 8, restTakenSeconds: 95, completedAt: day.addingTimeInterval(480)),
                    SetLog(id: "s3", index: 4, weightKg: 60, reps: 6, rpe: 9, restTakenSeconds: 100, completedAt: day.addingTimeInterval(720))]
        return WorkoutLog(id: "log-1", planID: "plan", templateID: "tpl-a", templateLabel: "Treino A", studentID: PFx.student, status: .completed, startedAt: day,
                          completedAt: day.addingTimeInterval(55 * 60), focus: .strength,
                          blocks: [.resistance(ResistanceLog(blockID: "blk-bench", exercise: bench, sets: sets)),
                                   .hiit(HIITLog(blockID: "blk-hiit", roundsCompleted: 4, totalSeconds: 160, averageHeartRate: 160, rpe: 8)),
                                   .cardio(CardioLog(blockID: "blk-cardio", modality: .bike, durationSeconds: 600, distanceMeters: 4_200, averageHeartRate: 140))],
                          sessionRPE: 8, feedbackNote: "Ombro incomodou", coachedBy: coached ? "t1" : nil, meta: PFx.meta())
    }
}

@Suite("Session record (everything one workout recorded)")
struct SessionRecordTests {
    @Test("Header facts: title, time span, minutes, effort, note, strength/volume week, who ran it")
    func header() {
        let record = SessionRecordBuilder.build(RecFx.log(), plan: RecFx.plan())
        #expect(record.title == "Treino A" && record.minutes == 55 && record.rpe == 8 && record.note == "Ombro incomodou" && record.focus == .strength)
        #expect(record.startedAt == RecFx.day && record.completedAt == RecFx.day.addingTimeInterval(55 * 60))
        #expect(record.isCoached == false)
        #expect(SessionRecordBuilder.build(RecFx.log(coached: true)).isCoached)
    }

    @Test("Every set is there with its load, reps, effort, rest and time; the warm-up is marked and the sets are in order")
    func sets() throws {
        let record = SessionRecordBuilder.build(RecFx.log(), plan: RecFx.plan())
        guard case .resistance(let bench) = try #require(record.blocks.first) else { Issue.record("expected a resistance block"); return }
        #expect(bench.exercise == "Supino reto" && bench.sets.map(\.id) == ["w", "s1", "s2", "s3"])
        #expect(bench.sets.map(\.isWarmup) == [true, false, false, false])
        let first = bench.sets[1]
        #expect(first.weightKg == 60 && first.reps == 10 && first.rpe == 7 && first.restSeconds == 45 && first.time == RecFx.day.addingTimeInterval(240))
        #expect(bench.volumeKg == 1_620)                                                         // 60×10 + 55×12 + 60×6; warm-ups aren't volume
    }

    @Test("Set against the plan: reps inside the range, the load asked for (warm-ups have no target); the plan line is readable")
    func againstThePlan() throws {
        let record = SessionRecordBuilder.build(RecFx.log(), plan: RecFx.plan())
        guard case .resistance(let bench) = try #require(record.blocks.first) else { return }
        #expect(bench.sets.map(\.repsInRange) == [nil, true, true, false])
        #expect(bench.sets.map(\.loadReached) == [nil, true, false, true])
        #expect(bench.sets.map(\.prescribedReps) == [nil, "8–12", "8–12", "8–12"])
        #expect(bench.prescription == "3 × 8–12 · 60 kg · 1:30 rest")
    }

    @Test("Without the plan the record is still complete — it just has nothing to compare with")
    func withoutPlan() throws {
        let record = SessionRecordBuilder.build(RecFx.log())
        guard case .resistance(let bench) = try #require(record.blocks.first) else { return }
        #expect(bench.prescription == nil && bench.sets.allSatisfy { $0.prescribedReps == nil && $0.repsInRange == nil && $0.loadReached == nil })
        #expect(bench.sets.count == 4)
    }

    @Test("Totals: working sets, reps, volume load and the average rest between working sets")
    func totals() {
        let totals = SessionRecordBuilder.build(RecFx.log(), plan: RecFx.plan()).totals
        #expect(totals.workingSets == 3 && totals.reps == 28 && totals.volumeKg == 1_620)
        #expect(totals.averageRestSeconds == 80)                                                 // (45 + 95 + 100) / 3
    }

    @Test("HIIT and cardio blocks keep their own numbers; the HIIT title comes from the plan")
    func otherBlocks() throws {
        let record = SessionRecordBuilder.build(RecFx.log(), plan: RecFx.plan())
        guard case .hiit(let hiit) = record.blocks[1], case .cardio(let cardio) = record.blocks[2] else { Issue.record("expected hiit then cardio"); return }
        #expect(hiit.title == "Finisher" && hiit.rounds == 4 && hiit.seconds == 160 && hiit.heartRate == 160 && hiit.rpe == 8)
        #expect(cardio.seconds == 600 && cardio.distanceKm == 4.2 && cardio.heartRate == 140 && !cardio.modality.isEmpty)
        #expect(SessionRecordBuilder.build(RecFx.log()).blocks[1] != record.blocks[1])           // no plan → a generic title
    }

    @Test("A swapped exercise says what it replaced and is recorded as itself")
    func swapped() throws {
        var log = RecFx.log()
        log.blocks = [.resistance(ResistanceLog(blockID: "blk-bench", exercise: RecFx.squat, substitutedFor: RecFx.bench,
                                                sets: [SetLog(index: 1, weightKg: 80, reps: 5, completedAt: RecFx.day)]))]
        guard case .resistance(let swapped) = try #require(SessionRecordBuilder.build(log, plan: RecFx.plan()).blocks.first) else { return }
        #expect(swapped.exercise == "Agachamento" && swapped.replaced == "Supino reto")
    }

    @Test("An added exercise (not in the plan) still appears in full")
    func added() throws {
        var log = RecFx.log()
        log.blocks.append(.resistance(ResistanceLog(blockID: "blk-extra", exercise: RecFx.squat, sets: [SetLog(index: 1, weightKg: 100, reps: 5, completedAt: RecFx.day)])))
        let record = SessionRecordBuilder.build(log, plan: RecFx.plan())
        guard case .resistance(let extra) = try #require(record.blocks.last) else { return }
        #expect(extra.exercise == "Agachamento" && extra.prescription == nil && extra.sets.count == 1)
    }

    @Test("A short or unfinished session shows no minutes rather than 0")
    func minutes() {
        var log = RecFx.log()
        log.completedAt = RecFx.day.addingTimeInterval(30)
        #expect(SessionRecordBuilder.build(log).minutes == nil)
        log.completedAt = nil
        #expect(SessionRecordBuilder.build(log).minutes == nil)
    }

    @MainActor
    @Test("The detail screen renders with a plan, without one, with photos and for a coached session")
    func renders() {
        let record = SessionRecordBuilder.build(RecFx.log(coached: true), plan: RecFx.plan())
        let photo = SharedPhoto(id: "p", studentID: PFx.student, logID: "log-1", takenAt: RecFx.day, caption: "Treino A", photo: Data([1]), meta: PFx.meta())
        _ = SessionDetailView(record: record, photos: [photo]).body
        _ = SessionDetailView(record: SessionRecordBuilder.build(RecFx.log())).body
    }
}

@Suite("History with full records")
@MainActor
struct HistoryRecordsTests {
    @Test("The selected day's records carry the plan comparison and the photos linked to that workout")
    func recordsAndPhotos() async throws {
        let repo = StreamingLogs()
        let photos = RecordingPhotos()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let model = HistoryViewModel(studentID: PFx.student, logs: repo, plan: { RecFx.plan() }, photos: photos, calendar: calendar, now: { RecFx.day.addingTimeInterval(86_400) })
        let task = Task { await model.run() }
        defer { task.cancel() }
        repo.pipe.send([RecFx.log()])
        photos.pipe.send([SharedPhoto(id: "p", studentID: PFx.student, logID: "log-1", takenAt: RecFx.day, caption: "Treino A", photo: Data([1]), meta: PFx.meta()),
                          SharedPhoto(id: "q", studentID: PFx.student, logID: "other", takenAt: RecFx.day, caption: "x", photo: Data([1]), meta: PFx.meta()),
                          SharedPhoto(id: "gone", studentID: PFx.student, logID: "log-1", takenAt: RecFx.day, caption: "x", photo: Data(), meta: PFx.meta())])
        #expect(await FeedFx.wait { model.isLoaded && model.photos.count == 2 })
        model.select(RecFx.day)
        let record = try #require(model.selectedRecords.first)
        guard case .resistance(let bench) = try #require(record.blocks.first) else { return }
        #expect(bench.prescription != nil)
        #expect(model.photos(for: record).map(\.id.rawValue) == ["p"])
    }

    @Test("Embedded in the trainer's stack the screen renders without an avatar or stack of its own")
    func embedded() {
        let model = HistoryViewModel(studentID: PFx.student, logs: StreamingLogs())
        _ = HistoryView(model: model, embedded: true).body
    }
}

@Suite("Trainer summary screen model")
@MainActor
struct StudentSummaryViewModelTests {
    func logs() -> [WorkoutLog] {
        (0..<5).map { index in
            WorkoutLog(id: LogID("l\(index)"), planID: "plan", templateID: "tpl-a", templateLabel: "Treino A", studentID: PFx.student, status: .completed,
                       startedAt: RecFx.day.addingTimeInterval(-Double(index) * 86_400), completedAt: RecFx.day.addingTimeInterval(-Double(index) * 86_400 + 3_600),
                       blocks: [.resistance(ResistanceLog(blockID: "blk-bench", exercise: RecFx.bench,
                                                          sets: [SetLog(index: 1, weightKg: 60, reps: 10, restTakenSeconds: nil, completedAt: RecFx.day),
                                                                 SetLog(index: 2, weightKg: 60, reps: 10, restTakenSeconds: 90, completedAt: RecFx.day)]))],
                       sessionRPE: 7, meta: PFx.meta())
        }
    }

    @Test("Loading builds the summary from the logs, the plan and the catalogue's muscle data")
    func loads() async {
        let repo = MemLogRepo(), plans = FakePlans()
        for log in logs() { await repo.seed(log) }
        _ = try? await plans.save(RecFx.plan())
        let model = StudentSummaryViewModel(studentID: PFx.student, logs: repo, plans: plans, catalog: StubCatalog(), now: { RecFx.day.addingTimeInterval(3_600 * 2) })
        #expect(model.summary == nil && !model.isLoaded)
        await model.load()
        #expect(model.isLoaded && !model.failed)
        let summary = model.summary
        #expect(summary?.exercises.first?.exercise.name == "Supino reto" && summary?.exercises.first?.sessions == 5)
        #expect(summary?.rest?.setsMeasured == 5 && summary?.prescription != nil)
        #expect(model.muscleRows.first?.muscle == .chest && model.muscleRows.first?.sets == 10)
        #expect(model.hasAnyWeek && model.chartWeeks.count == 8)
    }

    @Test("A failing repository is reported, not shown as an empty student")
    func failure() async {
        let repo = MemLogRepo()
        await repo.setFailSaves(true)                                            // the fake also throws on reads when this is set
        let model = StudentSummaryViewModel(studentID: PFx.student, logs: repo, plans: FakePlans())
        await model.load()
        #expect(model.failed && model.summary == nil && model.isLoaded)
    }

    @Test("The weekly chart can plot each measure, and every measure has a name and a unit")
    func measures() async {
        let repo = MemLogRepo()
        for log in logs() { await repo.seed(log) }
        let model = StudentSummaryViewModel(studentID: PFx.student, logs: repo, plans: FakePlans(), now: { RecFx.day.addingTimeInterval(3_600 * 2) })
        await model.load()
        let current = try? #require(model.chartWeeks.last)
        for measure in StudentSummaryViewModel.WeekMeasure.allCases {
            model.measure = measure
            #expect(!measure.title.isEmpty)
            if let current { #expect(model.chartValue(current) >= 0) }
        }
        #expect(StudentSummaryViewModel.WeekMeasure.volume.unit == "kg")
    }

    @Test("Alerts and zones have words and icons; the formats read naturally")
    func words() {
        let alerts: [TrainingAlert] = [.noRecentSession(days: 9), .lowAdherence(percent: 40), .workloadSpike(ratio: 1.8), .workloadDrop(ratio: 0.4),
                                       .stagnant(exercise: RecFx.bench, sessions: 6), .restOffTarget(percent: 30)]
        #expect(alerts.allSatisfy { !$0.message.isEmpty && !$0.systemImage.isEmpty })
        #expect(Set(alerts.map(\.message)).count == alerts.count)
        #expect(WorkloadZone.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(SummaryFormat.percent(0.456) == "46%" && SummaryFormat.seconds(45) == "45 s" && SummaryFormat.seconds(90) == "1:30" && SummaryFormat.seconds(125) == "2:05")
        #expect(SummaryFormat.daysAgo(0) != SummaryFormat.daysAgo(1) && SummaryFormat.daysAgo(3).contains("3"))
    }

    @Test("The summary screen renders loaded, empty and while loading")
    func renders() async {
        let repo = MemLogRepo()
        let empty = StudentSummaryViewModel(studentID: PFx.student, logs: repo, plans: FakePlans())
        _ = StudentSummaryView(model: empty).body
        await empty.load()
        _ = StudentSummaryView(model: empty).body
        for log in logs() { await repo.seed(log) }
        let full = StudentSummaryViewModel(studentID: PFx.student, logs: repo, plans: FakePlans(), catalog: StubCatalog(), now: { RecFx.day.addingTimeInterval(3_600 * 2) })
        await full.load()
        _ = StudentSummaryView(model: full).body
    }
}

extension WorkloadZone: CaseIterable {
    public static var allCases: [WorkloadZone] { [.low, .balanced, .elevated, .high] }
}
