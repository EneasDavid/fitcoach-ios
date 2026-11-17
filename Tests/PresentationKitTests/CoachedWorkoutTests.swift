import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

@MainActor
@Suite("Running a workout next to the student")
struct CoachedWorkoutPresentationTests {
    static let trainer: UserID = "t1"

    func coachedLog(_ id: String = "coached-1") -> WorkoutLog {
        var log = PFx.log(id: id)
        log.coachedBy = Self.trainer
        return log
    }

    func session(_ repo: MemLogRepo, env: Env, log: WorkoutLog? = nil, coaching: Bool = true) -> ActiveWorkoutViewModel {
        let clock = env.clock
        return ActiveWorkoutViewModel(log: log ?? coachedLog(), template: PFx.template([.resistance(PFx.resistance(sets: 2))]), factory: WorkoutComponentFactory.standard(),
                                      record: RecordBlockUseCase(logs: repo), finish: FinishWorkoutUseCase(logs: repo, now: { PFx.t0.addingTimeInterval(3_600) }),
                                      feedback: env.feedback, coaching: coaching ? CoachingTools(catalog: StubCatalog(), studentName: "Maria") : nil,
                                      now: { clock.now() }, autoTick: false)
    }

    @Test("The trainer can add an exercise that isn't in the plan; it gets its own sets, is logged by name, and counts toward finishing")
    func addExercise() async throws {
        let env = Env(), repo = MemLogRepo()
        let vm = session(repo, env: env)
        await repo.seed(vm.log)
        #expect(vm.components.count == 1 && vm.isCoached)

        let squat = Exercise(id: "squat", name: "Agachamento", primaryMuscles: [.quadriceps], equipment: .barbell)
        let id = try #require(vm.addExercise(squat, sets: 4, repsMin: 6, repsMax: 8, restSeconds: 120))
        #expect(vm.components.count == 2 && vm.addedBlocks == [id])
        let added = try #require(vm.component(for: id)?.viewModel as? ResistanceBlockViewModel)
        #expect(added.rows.count == 4 && added.restSeconds == 120 && added.title == "Agachamento")

        added.setWeight(100, forSet: 1)
        added.complete(set: 1)
        await vm.flush()
        #expect(!vm.canFinish)                                                       // one set of four isn't a finished exercise yet
        let stored = try #require(await repo.stored[vm.log.id])
        guard case .resistance(let logged)? = stored.blocks.first else { Issue.record("the added exercise was not persisted"); return }
        #expect(logged.blockID == id && logged.exercise.name == "Agachamento" && logged.sets.first?.weightKg == 100)
        for number in 2...4 { added.complete(set: number) }
        #expect(vm.completedBlocks == 1 && vm.canFinish)                              // finishing counts the added exercise like any other
    }

    @Test("A student's own workout can't have exercises added, and a finished one can't either")
    func addIsForTheTrainerOnly() async {
        let env = Env(), repo = MemLogRepo()
        let own = session(repo, env: env, log: PFx.log(id: "own"), coaching: false)
        #expect(own.addExercise(Exercise(id: "x", name: "X", primaryMuscles: [.chest], equipment: .barbell)) == nil && own.components.count == 1 && !own.isCoached)

        let coached = session(repo, env: env)
        await repo.seed(coached.log)
        (coached.components[0].viewModel as? ResistanceBlockViewModel)?.complete(set: 1)
        #expect(await coached.finish(sessionRPE: 7, note: nil))
        #expect(coached.addExercise(Exercise(id: "x", name: "X", primaryMuscles: [.chest], equipment: .barbell)) == nil)
    }

    @Test("The trainer's sets reach the coached store, never the student's: the log is routed by who ran it")
    func savedWhereTheTrainerOwnsIt() async throws {
        let env = Env()
        let own = MemLogRepo(), coached = MemLogRepo()
        let merged = MergedWorkoutLogRepository(own: own, coached: coached)
        let clock = env.clock
        let vm = ActiveWorkoutViewModel(log: coachedLog(), template: PFx.template([.resistance(PFx.resistance(sets: 2))]), factory: WorkoutComponentFactory.standard(),
                                        record: RecordBlockUseCase(logs: merged), finish: FinishWorkoutUseCase(logs: merged, now: { PFx.t0.addingTimeInterval(3_600) }),
                                        feedback: env.feedback, coaching: CoachingTools(catalog: StubCatalog(), studentName: "Maria"), now: { clock.now() }, autoTick: false)
        await coached.seed(vm.log)
        let bench = try #require(vm.components[0].viewModel as? ResistanceBlockViewModel)
        bench.setWeight(80, forSet: 1)
        bench.complete(set: 1)
        await vm.flush()
        #expect(await vm.finish(sessionRPE: 8, note: "ok"))
        let inCoached = await coached.stored[vm.log.id], inOwn = await own.stored[vm.log.id]
        #expect(inCoached?.status == .completed && inCoached?.coachedBy == Self.trainer && inOwn == nil)
    }

    @Test("Swapping to any catalogue exercise works exactly like a student's substitution, and the log says what it replaced")
    func swapAny() async throws {
        let env = Env(), repo = MemLogRepo()
        let vm = session(repo, env: env)
        await repo.seed(vm.log)
        let block = try #require(vm.components[0].viewModel as? ResistanceBlockViewModel)
        #expect(block.canSubstitute)
        block.substitute(with: Exercise(id: "press", name: "Supino inclinado", primaryMuscles: [.chest], equipment: .dumbbell))
        block.setWeight(30, forSet: 1)
        block.complete(set: 1)
        await vm.flush()
        guard case .resistance(let logged)? = await repo.stored[vm.log.id]?.blocks.first else { Issue.record("not persisted"); return }
        #expect(logged.exercise.name == "Supino inclinado" && logged.substitutedFor?.name == "Back Squat")
        #expect(block.canSubstitute == false)                                        // once a set is done the exercise is fixed
    }
}

@MainActor
@Suite("Run workout (setup)")
struct CoachedSetupTests {
    static let trainer: UserID = "t1"

    func plan(trainerID: UserID = "t1") -> WorkoutPlan {
        let a = WorkoutTemplate(id: "tpl-a", label: "Treino A", order: 0, blocks: [.resistance(PFx.resistance())])
        let b = WorkoutTemplate(id: "tpl-b", label: "Treino B", order: 1, blocks: [.resistance(PFx.resistance(PFx.bench)), .hiit(PFx.hiit)])
        return WorkoutPlan(id: "plan-1", trainerID: trainerID, studentID: PFx.student, name: "Plan", templates: [a, b], targetSessionsPerWeek: 3,
                           startDate: PFx.t0, meta: PFx.meta())
    }

    final class Built { var logs: [WorkoutLog] = [] }

    func model(_ repo: MemLogRepo, plan: WorkoutPlan?, built: Built = Built()) -> CoachedWorkoutSetupViewModel {
        let env = Env()
        let clock = env.clock
        return CoachedWorkoutSetupViewModel(
            plan: plan, studentName: "Maria",
            start: StartCoachedWorkoutUseCase(logs: repo, trainerID: Self.trainer, now: { PFx.t0.addingTimeInterval(86_400) }, calendar: .current),
            makeSession: { log, template in
                built.logs.append(log)
                return ActiveWorkoutViewModel(log: log, template: template, factory: WorkoutComponentFactory.standard(), record: RecordBlockUseCase(logs: repo),
                                              finish: FinishWorkoutUseCase(logs: repo), feedback: env.feedback,
                                              coaching: CoachingTools(catalog: StubCatalog(), studentName: "Maria"), now: { clock.now() }, autoTick: false)
            })
    }

    @Test("It lists the student's workouts with the next one in the rotation marked and preselected")
    func options() async {
        let repo = MemLogRepo()
        var done = PFx.log(id: "old", status: .completed, start: PFx.t0)
        done.templateID = "tpl-a"
        await repo.seed(done)
        let m = model(repo, plan: plan())
        #expect(!m.isLoaded)
        await m.load()
        #expect(m.isLoaded && m.options.map(\.label) == ["Treino A", "Treino B"])
        #expect(m.options.map(\.isSuggested) == [false, true] && m.selectedID == "tpl-b")
        #expect(m.options[1].exercises == 2 && m.buttonTitle == "Start workout")
    }

    @Test("Starting runs the chosen workout as the trainer's, and closing it brings the rotation up to date")
    func startAndClose() async throws {
        let repo = MemLogRepo(), built = Built()
        let m = model(repo, plan: plan(), built: built)
        await m.load()
        m.selectedID = "tpl-a"
        await m.begin()
        let session = try #require(m.session)
        #expect(session.isCoached && session.log.templateLabel == "Treino A" && built.logs.first?.coachedBy == Self.trainer && m.errorMessage == nil)
        #expect(await repo.stored[session.log.id]?.coachedBy == Self.trainer)

        await m.closeSession()
        #expect(m.session == nil && m.resumable?.id == session.log.id && m.selectedID == "tpl-a")      // unfinished: it can be continued
        #expect(m.buttonTitle == "Continue workout")
        await m.begin()
        #expect(built.logs.count == 2 && built.logs[1].id == built.logs[0].id)                          // the same session, not a duplicate
    }

    @Test("Without a plan, or with an empty one, there is nothing to run")
    func nothingToRun() async {
        let none = model(MemLogRepo(), plan: nil)
        await none.load()
        #expect(none.isLoaded && !none.hasWorkouts && none.options.isEmpty)
        await none.begin()
        #expect(none.session == nil)
        var empty = plan()
        empty.templates = []
        let emptyModel = model(MemLogRepo(), plan: empty)
        await emptyModel.load()
        #expect(!emptyModel.hasWorkouts)
    }

    @Test("Another trainer's plan can't be started: the failure is reported, not hidden")
    func notYourPlan() async {
        let m = model(MemLogRepo(), plan: plan(trainerID: "someone-else"))
        await m.load()
        await m.begin()
        #expect(m.session == nil && m.errorMessage != nil && !m.isStarting)
    }

    @Test("The setup screen renders: with workouts, with an unfinished session, and without a plan")
    func renders() async {
        let repo = MemLogRepo()
        let m = model(repo, plan: plan())
        _ = CoachedWorkoutSetupView(model: m).body
        await m.load()
        _ = CoachedWorkoutSetupView(model: m).body
        await m.begin()
        await m.closeSession()
        _ = CoachedWorkoutSetupView(model: m).body
        _ = CoachedWorkoutSetupView(model: model(MemLogRepo(), plan: nil)).body
    }
}
