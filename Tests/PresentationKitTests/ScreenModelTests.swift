import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

@MainActor
@Suite("WorkoutComponentFactory")
struct FactoryTests {
    @Test("The standard registry builds a typed view model — and a view — for every block kind")
    func standardRegistry() {
        let env = Env()
        let factory = WorkoutComponentFactory.standard()
        #expect(factory.registeredKinds == [.resistance, .hiit, .cardio])

        let template = PFx.template([.resistance(PFx.resistance()), .hiit(PFx.hiit), .cardio(PFx.cardio), .resistance(PFx.resistance(PFx.bench))])
        let components = factory.makeComponents(for: template, context: env.context())

        #expect(components.map(\.kind) == [.resistance, .hiit, .cardio, .resistance])
        #expect(components.map(\.id.rawValue) == ["blk-squat", "hiit", "cardio", "blk-bench"])
        #expect(components[0].viewModel is ResistanceBlockViewModel)
        #expect(components[1].viewModel is HIITBlockViewModel)
        #expect(components[2].viewModel is CardioBlockViewModel)
        #expect(components.allSatisfy { $0.viewModel.blockID == $0.id })
    }

    @Test("A block type from a newer app renders a placeholder that never blocks finishing")
    func unsupportedFallback() {
        let env = Env()
        let factory = WorkoutComponentFactory.standard()
        let component = factory.makeComponent(for: .unsupported(UnsupportedBlock(originalType: "mobility")), context: env.context())
        #expect(component.kind == .unsupported)
        #expect(component.viewModel.isComplete && component.viewModel.currentLog() == nil)
        #expect((component.viewModel as? UnsupportedBlockViewModel)?.originalType == "mobility")
    }

    @Test("New block kinds plug in by registration — no existing code changes")
    func extensibility() {
        let env = Env()
        let factory = WorkoutComponentFactory()
        #expect(factory.makeComponent(for: .hiit(PFx.hiit), context: env.context()).kind == .unsupported)   // nothing registered yet

        var builds = 0
        factory.register(.hiit) { block, context in
            guard case .hiit(let hiit) = block else { return nil }
            builds += 1
            let vm = HIITBlockViewModel(block: hiit, context: context)
            return WorkoutComponent(id: hiit.id, kind: .hiit, viewModel: vm, detailView: AnyView(EmptyView()))
        }
        #expect(factory.makeComponent(for: .hiit(PFx.hiit), context: env.context()).kind == .hiit)
        #expect(builds == 1)

        // A builder that declines (returns nil) also falls back safely.
        factory.register(.cardio) { _, _ in nil }
        #expect(factory.makeComponent(for: .cardio(PFx.cardio), context: env.context()).kind == .unsupported)
    }

    @Test("Every screen can build its body in each of its states (smoke test for the thin SwiftUI layer)")
    func viewsBuild() {
        let env = Env()
        let resistance = ResistanceBlockViewModel(block: PFx.resistance(), context: env.context())
        _ = ResistanceExerciseScreen(viewModel: resistance).body
        resistance.complete(set: 1)                                     // rest panel visible
        _ = ResistanceExerciseScreen(viewModel: resistance).body
        _ = RestPanel(viewModel: resistance).body
        resistance.pauseRest(); _ = RestPanel(viewModel: resistance).body
        resistance.skipRest()

        let hiit = HIITBlockViewModel(block: PFx.hiit, context: env.context())
        _ = HIITScreen(viewModel: hiit).body
        hiit.start(); _ = HIITScreen(viewModel: hiit).body
        hiit.pause(); _ = HIITScreen(viewModel: hiit).body
        hiit.finishEarly(); _ = HIITScreen(viewModel: hiit).body

        let cardio = CardioBlockViewModel(block: PFx.cardio, context: env.context())
        _ = CardioScreen(viewModel: cardio).body
        cardio.start(); _ = CardioScreen(viewModel: cardio).body
        cardio.finish(); _ = CardioScreen(viewModel: cardio).body

        _ = UnsupportedBlockScreen(viewModel: UnsupportedBlockViewModel(block: UnsupportedBlock(originalType: "x"))).body
        _ = RPEFeedbackView(draft: RPEFeedbackDraft(), onSubmit: {}).body
        for (pending, failed, online) in [(0, 0, true), (3, 0, true), (2, 0, false), (0, 0, false), (1, 2, true)] {
            _ = SyncBadge(pending: pending, failed: failed, isOnline: online).body
        }
        _ = MuscleChips(primary: [.chest], secondary: [.triceps], equipment: .barbell).body
        _ = MuscleChips(primary: [], secondary: [], equipment: nil).body
        _ = Chip("x", systemImage: "star", tint: .red, filled: true).body
        _ = TimerRing(progress: 0.5, tint: .blue) { Text(verbatim: "1:00") }.body
        _ = Color(light: .white, dark: .black)
    }

    @Test("Display names exist for every muscle, equipment and cardio modality")
    func displayNames() {
        #expect(MuscleGroup.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(Equipment.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.systemImage.isEmpty })
        #expect(CardioModality.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.systemImage.isEmpty })
    }

    @Test("Loads follow the phone's decimal mark and never gain a thousands separator or a trailing .0")
    func loadFormat() {
        let english = Locale(identifier: "en_US"), portuguese = Locale(identifier: "pt_BR")
        #expect(LoadFormat.kg(60, locale: english) == "60")
        #expect(LoadFormat.kg(62.5, locale: english) == "62.5")
        #expect(LoadFormat.kg(62.555, locale: english) == "62.56")
        #expect(LoadFormat.kg(62.5, locale: portuguese) == "62,5")
        #expect(LoadFormat.kg(1250, locale: portuguese) == "1250")
    }

    @Test("Block summaries read the same on the 'today' card and the workout overview")
    func summaries() {
        let template = PFx.template([.resistance(PFx.resistance(sets: 3, rest: 90, targets: [40, 40, 40])), .hiit(PFx.hiit), .cardio(PFx.cardio),
                                     .unsupported(UnsupportedBlock(originalType: "mobility"))])
        let blocks = template.blocks
        #expect(blocks.map(\.previewTitle) == ["Back Squat", "Finisher", "Bike", "Unsupported exercise block"])
        #expect(blocks[0].previewSummary == "3 × 5–8 reps · 40 kg")
        #expect(blocks[1].previewSummary == "2 rounds · 20 s work / 10 s rest")
        #expect(blocks[2].previewSummary == "10 min · Zone 2")
        #expect(blocks.map(\.previewIcon) == ["dumbbell.fill", "bolt.heart.fill", "figure.indoor.cycle", "exclamationmark.triangle.fill"])
        // 3 × (40 s + 90 s) + 2 × 30 s + 600 s = 1 050 s ≈ 17.5 min → nearest 5
        #expect(template.estimatedMinutes == 20)
        #expect(PFx.template([]).estimatedMinutes == 5)
        #expect(ResistanceBlock(exercise: PFx.squat, sets: []).summaryLine == "")
    }
}

@MainActor
@Suite("ExerciseDetailViewModel")
struct ExerciseDetailTests {
    actor FakeCatalog: ExerciseCatalogRepository {
        var exercises: [ExerciseID: Exercise] = [:]
        var alternatives: [ExerciseSubstitution] = []
        var failing = false
        private(set) var substitutionCalls = 0
        func setFailing(_ value: Bool) { failing = value }
        func seed(_ list: [Exercise], alternatives: [ExerciseSubstitution] = []) {
            for exercise in list { exercises[exercise.id] = exercise }
            self.alternatives = alternatives
        }
        func search(query: String, limit: Int) async throws -> [Exercise] { Array(exercises.values.prefix(limit)) }
        func exercise(id: ExerciseID) async throws -> Exercise? {
            if failing { throw URLError(.notConnectedToInternet) }
            return exercises[id]
        }
        func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution] {
            substitutionCalls += 1
            if failing { throw URLError(.notConnectedToInternet) }
            return alternatives
        }
    }

    static let bench = Exercise(id: "bench", name: "Bench Press", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .shoulders],
                                equipment: .barbell, videoURL: URL(string: "https://example.com/v.mp4"), instructions: ["Lie down", "Press"], mediaCredit: "Goulart · CC-BY-SA 3")
    static func alt(_ id: String) -> ExerciseSubstitution {
        ExerciseSubstitution(original: "bench", candidate: Exercise(id: ExerciseID(id), name: id, primaryMuscles: [.chest], equipment: .dumbbell), score: 0.9, reason: .equipmentBusy)
    }

    @Test("Loads the exercise, its muscles and at most three substitutes (never the exercise itself)")
    func loads() async {
        let catalog = FakeCatalog()
        await catalog.seed([Self.bench], alternatives: [Self.alt("a"), Self.alt("b"), Self.alt("bench"), Self.alt("c"), Self.alt("d")])
        let detail = ExerciseDetailViewModel(planned: ExerciseRef(id: "bench", name: "Supino"), catalog: catalog)
        #expect(detail.state == .idle && detail.title == "Supino" && detail.primaryMuscles.isEmpty)

        await detail.load()
        #expect(detail.state == .loaded && detail.title == "Bench Press")
        #expect(detail.primaryMuscles == [.chest] && detail.secondaryMuscles == [.triceps, .shoulders])
        #expect(detail.substitutions.map(\.candidate.id.rawValue) == ["a", "b", "c"])
        #expect(ExerciseDetailViewModel.maxSubstitutions == 3)
        #expect(!detail.isSubstituted)
    }

    @Test("Without a catalogue or when it fails, the screen degrades instead of breaking; retry recovers")
    func unavailableAndRetry() async {
        let none = ExerciseDetailViewModel(planned: PFx.bench, catalog: nil)
        await none.load()
        #expect(none.state == .unavailable && none.title == "Bench Press" && none.substitutions.isEmpty)

        let catalog = FakeCatalog()
        await catalog.seed([Self.bench], alternatives: [Self.alt("a")])
        await catalog.setFailing(true)
        let detail = ExerciseDetailViewModel(planned: ExerciseRef(id: "bench", name: "Supino"), catalog: catalog)
        await detail.load()
        #expect(detail.state == .unavailable && detail.shown == nil)

        await catalog.setFailing(false)
        await detail.retry()
        #expect(detail.state == .loaded && detail.substitutions.count == 1)
    }

    @Test("Selecting a substitute switches what is shown; reverting brings the planned exercise back")
    func selectAndRevert() async {
        let catalog = FakeCatalog()
        await catalog.seed([Self.bench], alternatives: [Self.alt("a")])
        let detail = ExerciseDetailViewModel(planned: ExerciseRef(id: "bench", name: "Supino"), catalog: catalog)
        await detail.load()

        detail.select(Self.alt("a").candidate)
        #expect(detail.isSubstituted && detail.title == "a" && detail.shownRef.id == "a")
        detail.revert()
        #expect(!detail.isSubstituted && detail.title == "Bench Press")
    }

    @Test("A restored substitute is loaded too, and a pending load is not started twice")
    func restoredSubstitute() async {
        let catalog = FakeCatalog()
        let swapped = Self.alt("a").candidate
        await catalog.seed([Self.bench, swapped], alternatives: [Self.alt("a")])
        let detail = ExerciseDetailViewModel(planned: ExerciseRef(id: "bench", name: "Supino"), shown: ExerciseRef(swapped), catalog: catalog)
        async let first: Void = detail.load()
        async let second: Void = detail.load()
        _ = await (first, second)
        #expect(detail.shown?.id == "a" && detail.planned?.id == "bench" && detail.isSubstituted)
        #expect(await catalog.substitutionCalls == 1)
    }
}

@MainActor
@Suite("ActiveWorkoutViewModel")
struct ActiveWorkoutTests {
    func makeViewModel(_ repo: MemLogRepo, env: Env, log: WorkoutLog = PFx.log(),
                       blocks: [WorkoutBlock]? = nil, previous: WorkoutLog? = nil) -> ActiveWorkoutViewModel {
        let clock = env.clock
        return ActiveWorkoutViewModel(log: log,
                                      template: PFx.template(blocks ?? [.resistance(PFx.resistance(sets: 2)), .hiit(PFx.hiit), .cardio(PFx.cardio)]),
                                      factory: WorkoutComponentFactory.standard(),
                                      record: RecordBlockUseCase(logs: repo),
                                      finish: FinishWorkoutUseCase(logs: repo, now: { PFx.t0.addingTimeInterval(3_600) }),
                                      feedback: env.feedback, previousSession: previous,
                                      now: { clock.now() }, autoTick: false)
    }

    @Test("Each logged set is persisted immediately, serially and in order")
    func persistsEverySet() async throws {
        let env = Env()
        let repo = MemLogRepo()
        let vm = makeViewModel(repo, env: env)
        await repo.seed(vm.log)
        let squat = try #require(vm.components[0].viewModel as? ResistanceBlockViewModel)

        squat.setWeight(100, forSet: 1)
        squat.complete(set: 1)
        env.clock.advance(90)
        squat.setWeight(102.5, forSet: 2)
        squat.complete(set: 2)
        await vm.flush()

        let stored = try #require(await repo.stored[vm.log.id])
        guard case .resistance(let log)? = stored.blocks.first else { Issue.record("not persisted"); return }
        #expect(log.sets.map(\.weightKg) == [100, 102.5])
        #expect(stored.meta.version == 2 && vm.log.meta.version == 2)          // two saves on top of the seeded v0: versions continue
        #expect(vm.errorMessage == nil)
        #expect(vm.completedBlocks == 1 && abs(vm.progress - 1.0 / 3) < 1e-9 && vm.canFinish)
    }

    @Test("Finishing stores the RPE and completes the workout")
    func finishes() async throws {
        let env = Env()
        let repo = MemLogRepo()
        let vm = makeViewModel(repo, env: env)
        await repo.seed(vm.log)
        #expect(!vm.canFinish)                                                   // nothing done yet
        (vm.components[0].viewModel as? ResistanceBlockViewModel)?.complete(set: 1)

        vm.isShowingFeedback = true
        vm.feedbackDraft.rpe = 8.4
        vm.feedbackDraft.note = "  knees felt great "
        #expect(await vm.submitFeedback())

        #expect(!vm.isShowingFeedback && vm.phase == .finished)
        let stored = try #require(await repo.stored[vm.log.id])
        #expect(stored.status == .completed && stored.sessionRPE == 8 && stored.feedbackNote == "knees felt great")
        #expect(stored.blocks.count == 1)                                        // the pending save was flushed first
        #expect(await vm.finish(sessionRPE: 5, note: nil) == false)              // can't finish twice
    }

    @Test("A finished workout notifies once (for its shareable card); a skipped or rejected one does not")
    func notifiesOnFinish() async throws {
        final class Seen: @unchecked Sendable { var logs: [WorkoutLog] = []; func add(_ log: WorkoutLog) { logs.append(log) } }
        let env = Env()
        let repo = MemLogRepo()
        let seen = Seen()
        let clock = env.clock
        func make(_ log: WorkoutLog) -> ActiveWorkoutViewModel {
            ActiveWorkoutViewModel(log: log, template: PFx.template([.resistance(PFx.resistance(sets: 2))]), factory: WorkoutComponentFactory.standard(),
                                   record: RecordBlockUseCase(logs: repo), finish: FinishWorkoutUseCase(logs: repo, now: { PFx.t0.addingTimeInterval(3_600) }),
                                   feedback: env.feedback, onFinished: { seen.add($0) }, now: { clock.now() }, autoTick: false)
        }

        let rejected = make(PFx.log(id: "a"))
        await repo.seed(rejected.log)
        #expect(await rejected.finish(sessionRPE: 99, note: nil) == false)

        let skipped = make(PFx.log(id: "b"))
        await repo.seed(skipped.log)
        await skipped.skip()

        let done = make(PFx.log(id: "c"))
        await repo.seed(done.log)
        #expect(await done.finish(sessionRPE: 7, note: nil))
        #expect(await FeedFx.wait { seen.logs.count == 1 })
        #expect(seen.logs.first?.id == done.log.id && seen.logs.first?.status == .completed)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(seen.logs.count == 1)
    }

    @Test("A rejected RPE keeps the workout open and explains why")
    func invalidRPE() async {
        let env = Env()
        let repo = MemLogRepo()
        let vm = makeViewModel(repo, env: env)
        #expect(await vm.finish(sessionRPE: 11, note: nil) == false)
        #expect(vm.phase == .active && vm.errorMessage?.contains("between 1 and 10") == true)
    }

    @Test("Storage failures surface a retryable message instead of crashing or losing the screen state")
    func saveFailure() async throws {
        let env = Env()
        let repo = MemLogRepo()
        await repo.setFailSaves(true)
        let vm = makeViewModel(repo, env: env)
        (vm.components[0].viewModel as? ResistanceBlockViewModel)?.complete(set: 1)
        await vm.flush()
        #expect(vm.errorMessage != nil)

        await repo.setFailSaves(false)
        (vm.components[0].viewModel as? ResistanceBlockViewModel)?.complete(set: 2)
        await vm.flush()
        #expect(vm.errorMessage == nil)                                          // recovered; the full block log was re-sent
        guard case .resistance(let log)? = try #require(await repo.stored[vm.log.id]).blocks.first else { Issue.record("missing"); return }
        #expect(log.sets.count == 2)
    }

    @Test("Skipping marks the workout skipped (which advances the rotation)")
    func skip() async throws {
        let env = Env()
        let repo = MemLogRepo()
        let vm = makeViewModel(repo, env: env)
        await repo.seed(vm.log)
        await vm.skip()
        #expect(vm.phase == .skipped)
        #expect(await repo.stored[vm.log.id]?.status == .skipped)
        await vm.skip()                                                          // no effect once decided
        #expect(vm.phase == .skipped)
    }

    @Test("Resuming an in-progress workout restores finished blocks and prefills from the last session")
    func resume() async throws {
        let env = Env()
        let repo = MemLogRepo()
        let saved = BlockLog.resistance(ResistanceLog(blockID: "blk-squat", exercise: PFx.squat,
                                                      sets: [SetLog(index: 1, weightKg: 100, reps: 5, completedAt: PFx.t0)]))
        let previous = PFx.completedSquatSession(weights: [90, 95], start: PFx.t0.addingTimeInterval(-86_400))
        let vm = makeViewModel(repo, env: env, log: PFx.log(blocks: [saved]), previous: previous)
        let squat = try #require(vm.components[0].viewModel as? ResistanceBlockViewModel)
        #expect(squat.rows[0].isDone && squat.rows[0].weightKg == 100)
        #expect(!squat.rows[1].isDone && squat.rows[1].weightKg == 95)           // this one comes from last session
    }

    @Test("A plan block this app can't show doesn't prevent a finished workout from counting")
    func unsupportedDoesNotBlock() async {
        let env = Env()
        let repo = MemLogRepo()
        let vm = makeViewModel(repo, env: env, blocks: [.unsupported(UnsupportedBlock(originalType: "mobility")), .resistance(PFx.resistance(sets: 1))])
        await repo.seed(vm.log)
        (vm.components[1].viewModel as? ResistanceBlockViewModel)?.complete(set: 1)
        #expect(vm.completedBlocks == 2 && vm.progress == 1)
        #expect(await vm.finish(sessionRPE: 7, note: nil))
    }

    @Test("Undoing the only completed set removes the block from the stored workout")
    func undoRemovesStoredBlock() async throws {
        let env = Env()
        let repo = MemLogRepo()
        let vm = makeViewModel(repo, env: env)
        await repo.seed(vm.log)
        let squat = try #require(vm.components[0].viewModel as? ResistanceBlockViewModel)
        squat.complete(set: 1)
        await vm.flush()
        #expect(await repo.stored[vm.log.id]?.blocks.count == 1)
        squat.undo(set: 1)
        await vm.flush()
        #expect(await repo.stored[vm.log.id]?.blocks.isEmpty == true)
    }

    @Test("The overview knows which exercise is resting, and can open any exercise screen by id")
    func restingAndNavigation() throws {
        let env = Env()
        let vm = makeViewModel(MemLogRepo(), env: env)
        #expect(vm.restingBlock == nil && vm.path.isEmpty)
        let squat = try #require(vm.components[0].viewModel as? ResistanceBlockViewModel)
        squat.complete(set: 1)
        #expect(vm.restingBlock?.blockID == squat.blockID)
        squat.pauseRest()
        #expect(vm.restingBlock != nil)                                  // paused still counts as resting
        squat.skipRest()
        #expect(vm.restingBlock == nil)

        vm.path = [squat.blockID]
        #expect(vm.component(for: squat.blockID)?.kind == .resistance && vm.component(for: "nope") == nil)
    }

    @Test("Feedback draft clamps the slider to the 1–10 scale")
    func draft() {
        let draft = RPEFeedbackDraft()
        #expect(draft.score == 7)
        draft.rpe = 0.2; #expect(draft.score == 1)
        draft.rpe = 14; #expect(draft.score == 10)
        #expect(Set(RPEScale.range.map(RPEScale.explanation(for:))).count == 6)
    }
}

@MainActor
@Suite("Trainer view models")
struct TrainerViewModelTests {
    func filledBuilder() -> PlanBuilderViewModel {
        let builder = PlanBuilderViewModel()
        builder.name = "  Hypertrophy  "
        let a = builder.addTemplate(label: "A")
        let b = builder.addTemplate(label: "B")
        builder.addBlock(.resistance(PFx.resistance()), to: a)
        builder.addBlock(.hiit(PFx.hiit), to: a)
        builder.addBlock(.cardio(PFx.cardio), to: b)
        return builder
    }

    @Test("A valid plan builds, with a periodization program when enabled")
    func buildsPlan() throws {
        let builder = filledBuilder()
        builder.periodization = PeriodizationDraft(enabled: true, highWeeks: 3, deloadWeeks: 1, cycles: 2, advancement: .bySequence)
        #expect(builder.validate().isEmpty)

        let plan = try builder.build(trainerID: "t1", studentID: "s1", startDate: PFx.t0, deviceID: "iphone")
        #expect(plan.name == "Hypertrophy" && plan.studentID == "s1" && plan.trainerID == "t1")
        #expect(plan.templates.map(\.label) == ["A", "B"] && plan.templates.map(\.order) == [0, 1])
        #expect(plan.periodization?.totalWeeks == 8)
        #expect(plan.periodization?.resolve(weekIndex: 3)?.microcycle.phase == .deload)
        #expect(plan.meta.lastWriterDeviceID == "iphone")

        builder.periodization.enabled = false
        #expect(try builder.build(trainerID: "t1", studentID: "s1", startDate: PFx.t0).periodization == nil)
    }

    @Test("Validation reports every problem; build refuses to produce an invalid plan")
    func validation() {
        let empty = PlanBuilderViewModel()
        let ids = Set(empty.validate().map(\.id))
        #expect(ids == ["name", "templates"])
        #expect(throws: DomainError.self) { try empty.build(trainerID: "t", studentID: "s", startDate: PFx.t0) }

        let builder = PlanBuilderViewModel()
        builder.name = "x"
        builder.targetSessionsPerWeek = 9
        let a = builder.addTemplate(label: "A")
        builder.addTemplate(label: "Empty")
        builder.addBlock(.resistance(ResistanceBlock(id: "r1", exercise: PFx.squat, sets: [], restSeconds: 999)), to: a)
        builder.addBlock(.resistance(ResistanceBlock(id: "r2", exercise: PFx.bench, sets: [PrescribedSet(index: 1, repsMin: 10, repsMax: 5)])), to: a)
        builder.addBlock(.hiit(HIITBlock(id: "h", title: "H", rounds: 0, workSeconds: 1, restSeconds: 0)), to: a)
        builder.addBlock(.cardio(CardioBlock(id: "c", modality: .run, targetDurationSeconds: 10, targetZone: 9)), to: a)
        builder.addBlock(.unsupported(UnsupportedBlock(originalType: "mobility")), to: a)
        builder.periodization = PeriodizationDraft(enabled: true, highWeeks: 0, deloadWeeks: 9, cycles: 99)

        let ids2 = Set(builder.validate().map(\.id))
        #expect(ids2.isSuperset(of: ["sessions", "sets-r1", "rest-r1", "reps-r2", "hiit-h", "cardio-c", "zone-c",
                                     "unsupported-unsupported-mobility", "high", "deload", "cycles"]))
        #expect(ids2.contains { $0.hasPrefix("empty-") })
    }

    @Test("Templates and blocks can be reordered and removed; order stays contiguous")
    func editing() {
        let builder = filledBuilder()
        let c = builder.addTemplate(label: "C")
        builder.moveTemplate(from: 2, to: 0)
        #expect(builder.templates.map(\.label) == ["C", "A", "B"] && builder.templates.map(\.order) == [0, 1, 2])
        builder.moveTemplate(from: 0, to: 3)
        #expect(builder.templates.map(\.label) == ["A", "B", "C"])
        builder.moveTemplate(from: 9, to: 0)                                      // out of range: ignored
        #expect(builder.templates.map(\.label) == ["A", "B", "C"])

        let a = builder.templates[0].id
        builder.moveBlock(in: a, from: 1, to: 0)                                  // HIIT before the squats
        #expect(builder.templates[0].blocks.map(\.kind) == [.hiit, .resistance])
        builder.removeBlock(builder.templates[0].blocks[0].id, from: a)
        #expect(builder.templates[0].blocks.map(\.kind) == [.resistance])
        builder.removeTemplate(c)
        #expect(builder.templates.count == 2)
        builder.addBlock(.hiit(PFx.hiit), to: "missing")                          // unknown template: ignored
        builder.removeBlock("missing", from: "missing")
        builder.moveBlock(in: "missing", from: 0, to: 1)
    }

    @Test("Editing an existing plan recovers its periodization pattern")
    func editExisting() throws {
        let builder = filledBuilder()
        builder.periodization = PeriodizationDraft(enabled: true, highWeeks: 4, deloadWeeks: 1, cycles: 3, advancement: .byCalendar)
        let plan = try builder.build(trainerID: "t1", studentID: "s1", startDate: PFx.t0)

        let reopened = PlanBuilderViewModel(editing: plan)
        #expect(reopened.periodization == PeriodizationDraft(enabled: true, highWeeks: 4, deloadWeeks: 1, cycles: 3, advancement: .byCalendar))
        #expect(reopened.templates == plan.orderedTemplates && reopened.name == plan.name)
        #expect(PlanBuilderViewModel(editing: PFx.plan()).periodization.enabled == false)
    }

    @Test("The progress dashboard loads series, weekly volume and adherence for one student")
    func progressDashboard() async {
        let repo = MemLogRepo()
        let program = PeriodizationPlan(macrocycles: [.alternating(name: "m", highWeeks: 3, deloadWeeks: 1, cycles: 1)], startDate: PFx.t0)
        let plan = PFx.plan(periodization: program)
        for week in 0..<4 {
            let snapshot = PeriodizationSnapshot(program.resolve(weekIndex: week)!)
            let kg = week == 3 ? 60.0 : 100.0 + Double(week) * 2.5
            let sets = (1...3).map { SetLog(index: $0, weightKg: kg, reps: 5, completedAt: PFx.t0) }
            var log = PFx.log(id: "l\(week)", status: .completed, blocks: [.resistance(ResistanceLog(blockID: "blk-squat", exercise: PFx.squat, sets: sets))],
                              start: PFx.t0.addingTimeInterval(Double(week) * 7 * 86_400))
            log.periodization = snapshot
            await repo.seed(log)
        }
        let end = PFx.t0.addingTimeInterval(28 * 86_400)
        let vm = StudentProgressViewModel(plan: plan, logs: repo, now: { end }, calendar: Calendar(identifier: .gregorian))
        #expect(vm.state == .idle && vm.exercises == [PFx.squat])

        await vm.load(exercise: PFx.squat.id)
        #expect(vm.state == .loaded)
        #expect(vm.series?.deloadPoints.count == 1 && vm.series?.trendPoints.count == 3)
        #expect(vm.series?.verdict == .progressing)
        #expect(vm.weeklyVolume.count == 4 && vm.weeklyVolume.last?.isDeload == true)
        #expect(vm.adherence?.sessionsCompleted == 4)

        await repo.setFailSaves(true)
        await vm.load(exercise: PFx.squat.id)
        if case .failed = vm.state {} else { Issue.record("expected a failed state") }
    }
}
