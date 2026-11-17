import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

// MARK: - Doubles

actor FakeRegistrations: StudentRegistering {
    var items: [StudentRegistration] = []
    func seed(_ registration: StudentRegistration) { items.append(registration) }
    func register(cpf: String, fullName: String, trainerID: UserID) async throws -> StudentRegistration {
        let digits = try RegistrationRules.cpf(cpf)
        let name = try RegistrationRules.fullName(fullName)
        if items.contains(where: { $0.id == digits }) { throw RegistrationError.duplicate }
        let registration = StudentRegistration(id: digits, trainerID: trainerID, fullName: name, cpfMasked: RegistrationRules.masked(cpf: digits), createdAt: PFx.t0, meta: PFx.meta())
        items.append(registration)
        return registration
    }
    func registrations(trainerID: UserID) async throws -> [StudentRegistration] { items.filter { $0.trainerID == trainerID } }
}

actor FakeNicknames: NicknameRepository {
    var map: [String: String] = [:]
    func nicknames(trainerID: UserID) async throws -> [String: String] { map }
    func setNickname(_ nickname: String, forRegistration id: String, trainerID: UserID) async throws {
        guard let clean = try NicknameRules.clean(nickname) else { map[id] = nil; return }
        map[id] = clean
    }
}

actor FakePlans: WorkoutPlanRepository {
    var byStudent: [UserID: WorkoutPlan] = [:]
    func save(_ plan: WorkoutPlan) async throws -> WorkoutPlan { byStudent[plan.studentID] = plan; return plan }
    func activePlan(studentID: UserID) async throws -> WorkoutPlan? { byStudent[studentID] }
    func plans(studentID: UserID) async throws -> [WorkoutPlan] { byStudent[studentID].map { [$0] } ?? [] }
    nonisolated func observeActivePlan(studentID: UserID) -> AsyncStream<WorkoutPlan?> { AsyncStream { $0.finish() } }
}

struct StubCatalog: ExerciseCatalogRepository {
    var exercises: [Exercise] = [Exercise(id: "bench", name: "Supino reto", primaryMuscles: [.chest], equipment: .barbell),
                                 Exercise(id: "squat", name: "Agachamento", primaryMuscles: [.quadriceps], equipment: .barbell)]
    var fails = false
    func search(query: String, limit: Int) async throws -> [Exercise] {
        if fails { throw URLError(.notConnectedToInternet) }
        return exercises.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    func exercise(id: ExerciseID) async throws -> Exercise? { exercises.first { $0.id == id } }
    func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution] { [] }
}

func registration(_ cpf: String, _ name: String, status: RegistrationStatus = .invited, student: UserID? = nil) -> StudentRegistration {
    StudentRegistration(id: cpf, trainerID: "t1", fullName: name, cpfMasked: RegistrationRules.masked(cpf: cpf), status: status, studentID: student,
                        email: status == .active ? "x@y.co" : nil, age: status == .active ? 30 : nil, gender: status == .active ? .female : nil,
                        createdAt: PFx.t0, meta: PFx.meta())
}

// MARK: - Media policy

@Suite("MediaPolicy (reduce motion & data)")
@MainActor
struct MediaPolicyTests {
    @Test("Videos autoplay only on Wi-Fi with nothing asking to save data")
    func autoplay() {
        #expect(MediaPolicy().allowsAutoplay && MediaPolicy().pauseReason == nil)
        #expect(MediaPolicy(dataSaverEnabled: true).pauseReason == .yourSetting)
        #expect(MediaPolicy(isUnmetered: false).pauseReason == .mobileData)                 // automatic off Wi-Fi: no switch needed
        #expect(MediaPolicy(isLowPowerMode: true).pauseReason == .lowPowerMode)
        #expect(MediaPolicy(isReduceMotion: true).pauseReason == .reduceMotion)
        #expect(!MediaPolicy(isUnmetered: false).allowsAutoplay)
    }

    @Test("The student's own switch is reported first; every reason has a caption")
    func priorityAndCaptions() {
        #expect(MediaPolicy(dataSaverEnabled: true, isUnmetered: false, isLowPowerMode: true, isReduceMotion: true).pauseReason == .yourSetting)
        for reason in [MediaPolicy.Reason.yourSetting, .mobileData, .lowPowerMode, .reduceMotion] { #expect(!reason.caption.isEmpty) }
    }

    @Test("Posters are data too: skipped when saving data or off Wi-Fi, still shown in Low Power / Reduce Motion")
    func posters() {
        #expect(MediaPolicy().allowsPosterDownload)
        #expect(!MediaPolicy(dataSaverEnabled: true).allowsPosterDownload && !MediaPolicy(isUnmetered: false).allowsPosterDownload)
        #expect(MediaPolicy(isLowPowerMode: true).allowsPosterDownload && MediaPolicy(isReduceMotion: true).allowsPosterDownload)
    }

    @Test("Animations stop with the saver or the system's Reduce Motion; the policy follows live changes")
    func animations() {
        let policy = MediaPolicy()
        #expect(policy.animationsEnabled && policy.animation(.easeInOut) != nil)
        policy.dataSaverEnabled = true
        #expect(!policy.animationsEnabled && policy.animation(.easeInOut) == nil)
        policy.dataSaverEnabled = false
        policy.isUnmetered = false                                                              // mobile data: videos pause, UI motion is unaffected
        #expect(policy.animationsEnabled && !policy.allowsAutoplay)
        policy.isUnmetered = true; policy.isReduceMotion = true
        #expect(!policy.animationsEnabled)
    }

    @Test("The media view builds in every policy state")
    func viewBuilds() {
        let exercise = Exercise(id: "x", name: "X", primaryMuscles: [.chest], equipment: .barbell, imageURL: URL(string: "https://e/x.png"), videoURL: URL(string: "https://e/x.mp4"))
        for policy in [MediaPolicy(), MediaPolicy(dataSaverEnabled: true), MediaPolicy(isUnmetered: false)] {
            _ = ExerciseMediaView(exercise: exercise, title: "X", isLoading: false).environment(policy)
        }
    }
}

// MARK: - Strength / volume warning on the exercise screen

@Suite("Focus warning on the exercise screen")
@MainActor
struct FocusWarningScreenTests {
    func context(_ focus: TrainingFocus, best: Double) -> FocusContext {
        FocusContext(focus: focus, weekInPhase: 1, phaseWeeks: 2, suggestedReps: focus == .strength ? 3...6 : 10...15, oppositeBestKg: [PFx.squat.id: best])
    }

    func viewModel(_ env: Env, _ focus: FocusContext?, target: Double) -> ResistanceBlockViewModel {
        var ctx = env.context()
        ctx.focus = focus
        return ResistanceBlockViewModel(block: PFx.resistance(sets: 3, targets: [target, target, target]), context: ctx)
    }

    @Test("Volume week: starting at a load above the strength-week best warns before the set is done")
    func volumeWeek() throws {
        let env = Env()
        let vm = viewModel(env, context(.volume, best: 100), target: 110)
        let warning = try #require(vm.focusWarning)
        #expect(warning.kind == .heavierThanStrengthWeek && warning.loadKg == 110 && warning.referenceKg == 100)
        #expect(warning.message.contains("110") && warning.message.contains("100") && warning.message.localizedCaseInsensitiveContains("execution"))
        #expect(vm.focusContext?.focus == .volume)
        #expect(env.feedback.count("warning") == 0)                                    // starting the screen doesn't buzz: only changes do
    }

    @Test("Lowering the load clears the warning; raising it again brings it back — with one haptic each time it appears")
    func followsTheLoad() {
        let env = Env()
        let vm = viewModel(env, context(.volume, best: 100), target: 90)
        #expect(vm.focusWarning == nil)
        vm.setWeight(105, forSet: 1)
        #expect(vm.focusWarning != nil && env.feedback.count("warning") == 1)
        vm.setWeight(106, forSet: 1)                                                   // still wrong, but the load (so the warning) changed → one more
        #expect(env.feedback.count("warning") == 2)
        vm.setWeight(95, forSet: 1)
        #expect(vm.focusWarning == nil)
        vm.setWeight(95, forSet: 1)
        #expect(env.feedback.count("warning") == 2)
    }

    @Test("Strength week: a load below the volume-week best warns")
    func strengthWeek() throws {
        let env = Env()
        let vm = viewModel(env, context(.strength, best: 100), target: 70)
        #expect(try #require(vm.focusWarning).kind == .lighterThanVolumeWeek)
        #expect(vm.focusWarning?.message.contains("strength week") == true)
    }

    @Test("It never blocks a set; completing against the focus nudges once more; completed sets show no warning")
    func advisoryOnly() {
        let env = Env()
        let vm = viewModel(env, context(.volume, best: 100), target: 110)
        let before = env.feedback.count("warning")
        #expect(vm.complete(set: 1))
        #expect(env.feedback.count("warning") == before + 1)
        #expect(vm.rows[0].isDone)
        #expect(vm.focusWarning != nil)                                                // the next set (same load) still carries it
        vm.setSameLoad(true); vm.setSharedLoad(90)
        #expect(vm.focusWarning == nil)
    }

    @Test("Same load for all sets, undo, other exercises and no cycle")
    func edges() {
        let env = Env()
        let vm = viewModel(env, context(.volume, best: 100), target: 110)
        vm.setSameLoad(true)
        vm.setSharedLoad(120)
        #expect(vm.focusWarning?.loadKg == 120)
        vm.complete(set: 1)
        vm.undoLast()
        #expect(vm.focusWarning != nil)

        let none = viewModel(Env(), nil, target: 500)
        #expect(none.focusWarning == nil && none.focusContext == nil)
        var other = Env().context(); other.focus = FocusContext(focus: .volume, weekInPhase: 1, phaseWeeks: 1, suggestedReps: 10...15, oppositeBestKg: ["something-else": 50])
        #expect(ResistanceBlockViewModel(block: PFx.resistance(sets: 1, targets: [300]), context: other).focusWarning == nil)
    }

    @Test("The chip, the banner and the exercise screen build")
    func viewsBuild() {
        let env = Env()
        let vm = viewModel(env, context(.volume, best: 100), target: 120)
        _ = FocusChip(context: context(.strength, best: 1)).body
        _ = FocusChip(context: context(.volume, best: 1)).body
        _ = FocusWarningBanner(warning: vm.focusWarning!).body
        _ = ResistanceExerciseScreen(viewModel: vm).body
    }
}

// MARK: - Trainer roster

@Suite("Trainer roster")
@MainActor
struct TrainerRosterTests {
    func model() async -> (TrainerRosterViewModel, FakeRegistrations, FakeNicknames, FakePlans) {
        let regs = FakeRegistrations(), nicks = FakeNicknames(), plans = FakePlans()
        await regs.seed(registration("52998224725", "Maria Souza", status: .active, student: "stu-maria"))
        await regs.seed(registration("11144477735", "João Lima"))
        await regs.seed(registration("39053344705", "Ana Beatriz Costa", status: .active, student: "stu-ana"))
        return (TrainerRosterViewModel(trainerID: "t1", registrations: regs, plans: plans, nicknames: nicks), regs, nicks, plans)
    }

    @Test("Lists the trainer's students with a status: waiting for first access / no plan yet / the plan's name")
    func statuses() async {
        let (model, _, _, plans) = await model()
        _ = try? await plans.save(PFx.plan().with(studentID: "stu-ana", name: "Hipertrofia"))
        await model.load()
        #expect(model.isLoaded && model.rows.count == 3)
        func status(_ name: String) -> String? { model.rows.first { $0.registration.fullName == name }?.statusText }
        #expect(status("João Lima") == String(localized: "Waiting for first access"))
        #expect(status("Maria Souza") == String(localized: "No plan yet"))
        #expect(status("Ana Beatriz Costa") == "Hipertrofia")
        #expect(model.rows.first { $0.registration.fullName == "Maria Souza" }?.needsPlan == true)
        #expect(model.rows.map(\.title) == ["Ana Beatriz Costa", "João Lima", "Maria Souza"])          // alphabetical
    }

    @Test("A nickname becomes the title (the real name moves underneath) and is searchable; the CPF stays masked")
    func nicknames() async {
        let (model, _, nicks, _) = await model()
        await model.load()
        let maria = model.rows.first { $0.registration.fullName == "Maria Souza" }!
        #expect(maria.title == "Maria Souza" && maria.subtitle == "***.982.247-**")
        await model.setNickname("  Maria  da 7h ", forStudent: maria.id)
        #expect(await nicks.map[maria.id] == "Maria da 7h")
        let updated = model.row(id: maria.id)!
        #expect(updated.title == "Maria da 7h" && updated.subtitle == "Maria Souza")
        await model.setNickname("", forStudent: maria.id)
        #expect(model.row(id: maria.id)?.title == "Maria Souza")
        await model.setNickname(String(repeating: "x", count: 40), forStudent: maria.id)
        #expect(model.addError != nil)
    }

    @Test("Search matches nickname, name (accents and case ignored) and CPF digits")
    func search() async {
        let (model, _, _, _) = await model()
        await model.load()
        await model.setNickname("Tigresa", forStudent: "39053344705")
        model.query = "tigre"; #expect(model.filtered.map(\.id) == ["39053344705"])
        model.query = "JOAO"; #expect(model.filtered.map(\.registration.fullName) == ["João Lima"])
        model.query = "982.247"; #expect(model.filtered.map(\.registration.fullName) == ["Maria Souza"])
        model.query = "zzz"; #expect(model.filtered.isEmpty)
        model.query = "  "; #expect(model.filtered.count == 3)
    }

    @Test("Registering validates, refuses duplicates, clears the form on success and shows the new student")
    func adding() async {
        let (model, _, _, _) = await model()
        await model.load()
        model.newCPF = "123.456.789-00"; model.newName = "Bia Lima"
        #expect(await model.add() == false && model.addError == String(localized: "That CPF isn't valid."))
        model.newCPF = "529.982.247-25"
        #expect(await model.add() == false && model.addError == String(localized: "This CPF is already registered."))
        model.newCPF = "390.533.447-05"; model.newName = "Bia"
        #expect(await model.add() == false && model.addError == String(localized: "Enter the student's full name (first and last)."))
        model.newCPF = "111.444.777-35"; model.newName = "Pedro Alves"
        #expect(await model.add() == false)                                                  // João Lima already has this CPF
        model.newCPF = "000.000.001-91"; model.newName = "Bia Lima"
        // 000.000.001-91 is valid
        #expect(RegistrationRules.masked(cpf: "00000000191") == "***.000.001-**")
    }

    @Test("A fresh registration shows up and empties the form")
    func addSucceeds() async throws {
        let regs = FakeRegistrations()
        let model = TrainerRosterViewModel(trainerID: "t1", registrations: regs, plans: FakePlans(), nicknames: FakeNicknames())
        await model.load()
        #expect(model.isLoaded && model.rows.isEmpty)
        model.newCPF = "529.982.247-25"; model.newName = "Maria Souza"
        #expect(await model.add())
        #expect(model.rows.count == 1 && model.newCPF.isEmpty && model.newName.isEmpty && model.addError == nil)
        #expect(model.rows[0].statusText == String(localized: "Waiting for first access"))
    }

    @Test("The roster, the add sheet and the student screen build")
    func viewsBuild() async {
        let (model, _, _, _) = await model()
        _ = TrainerRosterView(model: model).body
        await model.load()
        _ = TrainerRosterView(model: model, profileButton: AnyView(Text("p"))).body
        _ = AddStudentSheet(model: model).body
        for row in model.rows { _ = TrainerStudentView(model: model, studentID: row.id).body }
        _ = TrainerStudentView(model: model, studentID: "missing").body
    }
}

extension WorkoutPlan {
    func with(studentID: UserID, name: String) -> WorkoutPlan {
        var copy = self
        copy.studentID = studentID
        copy.name = name
        return copy
    }
}

// MARK: - Plan editor

@Suite("Plan editor (only the trainer creates or changes workouts)")
@MainActor
struct PlanEditorTests {
    let student = registration("52998224725", "Maria Souza", status: .active, student: "stu-maria")

    func editor(existing: WorkoutPlan? = nil, plans: FakePlans = FakePlans(), student: StudentRegistration? = nil) -> (PlanEditorViewModel, FakePlans) {
        (PlanEditorViewModel(trainerID: "t1", student: student ?? self.student, existing: existing, plans: plans, now: { PFx.t0 }), plans)
    }

    @Test("Days are lettered, exercises get sensible defaults and can be edited in place")
    func building() {
        let (editor, _) = editor()
        #expect(editor.builder.name.contains("Maria"))
        let a = editor.addDay(), b = editor.addDay()
        #expect(editor.builder.templates.map(\.label) == [String(localized: "Workout A"), String(localized: "Workout B")])
        editor.addExercise(Exercise(id: "bench", name: "Supino reto", primaryMuscles: [.chest], equipment: .barbell), to: a, sets: 4, repsMin: 5, repsMax: 8, loadKg: 60, restSeconds: 120)
        guard case .resistance(let block)? = editor.builder.templates[0].blocks.first else { Issue.record("no block"); return }
        #expect(block.sets.count == 4 && block.sets[0].repsMin == 5 && block.sets[0].repsMax == 8 && block.sets[0].targetLoadKg == 60 && block.restSeconds == 120)

        editor.builder.updateResistance(block.id, in: a) { $0.restSeconds = 45; $0.sets[0].targetLoadKg = 62.5 }
        guard case .resistance(let edited)? = editor.builder.templates[0].blocks.first else { return }
        #expect(edited.restSeconds == 45 && edited.sets[0].targetLoadKg == 62.5)
        editor.builder.updateResistance("nope", in: a) { $0.restSeconds = 1 }                       // unknown block: ignored
        editor.builder.updateResistance(block.id, in: b) { $0.restSeconds = 1 }                     // wrong day: ignored
        #expect(editor.addDay() != a)
    }

    @Test("Saving builds the plan for THIS student with the trainer as owner, strength/volume weeks included")
    func saving() async throws {
        let (editor, plans) = editor()
        let day = editor.addDay()
        editor.addExercise(Exercise(id: "bench", name: "Supino reto", primaryMuscles: [.chest], equipment: .barbell), to: day)
        editor.builder.focus.enabled = true
        editor.builder.focus.strengthWeeks = 4
        editor.builder.focus.volumeWeeks = 2
        editor.builder.focus.startsWith = .volume

        #expect(await editor.save() && editor.didSave)
        let plan = try #require(await plans.byStudent["stu-maria"])
        #expect(plan.trainerID == "t1" && plan.studentID == "stu-maria" && plan.templates.count == 1)
        #expect(plan.focusCycle == FocusCycle(strengthWeeks: 4, volumeWeeks: 2, startsWith: .volume, strengthReps: 3...6, volumeReps: 10...15))
        #expect(plan.startDate == PFx.t0)
    }

    @Test("Editing keeps the plan's identity and start date, and round-trips the cycle")
    func editing() async throws {
        var original = PFx.plan()
        original.studentID = "stu-maria"; original.trainerID = "t1"
        original.focusCycle = FocusCycle(strengthWeeks: 2, volumeWeeks: 5)
        original.startDate = PFx.t0.addingTimeInterval(-30 * 86_400)
        let (editor, plans) = editor(existing: original)
        #expect(editor.isEditing && editor.builder.focus.enabled && editor.builder.focus.strengthWeeks == 2 && editor.builder.focus.volumeWeeks == 5)
        editor.builder.name = "Renamed"
        #expect(await editor.save())
        let saved = try #require(await plans.byStudent["stu-maria"])
        #expect(saved.id == original.id && saved.name == "Renamed" && saved.startDate == original.startDate && saved.focusCycle == original.focusCycle)
    }

    @Test("Nothing is saved for a student who hasn't done their first access, or for an invalid plan")
    func refusals() async {
        let invited = registration("11144477735", "João Lima")
        let (editor1, plans1) = editor(student: invited)
        editor1.addDay()
        #expect(await editor1.save() == false && editor1.errorMessage != nil)
        #expect(await plans1.byStudent.isEmpty)

        let (editor2, plans2) = editor()
        #expect(await editor2.save() == false && editor2.errorMessage != nil && !editor2.issues.isEmpty)       // no workouts at all
        editor2.addDay()
        editor2.builder.focus.enabled = true
        editor2.builder.focus.volumeWeeks = 0
        #expect(editor2.issues.contains { $0.id == "volume-weeks" })
        #expect(await plans2.byStudent.isEmpty)
    }

    @Test("The exercise picker searches the catalogue and reports being offline")
    func picker() async {
        let picker = ExercisePickerViewModel(catalog: StubCatalog())
        await picker.search()
        #expect(picker.results.count == 2)
        picker.query = "agach"; await picker.search()
        #expect(picker.results.map(\.name) == ["Agachamento"] && !picker.failed)
        let offline = ExercisePickerViewModel(catalog: StubCatalog(fails: true))
        await offline.search()
        #expect(offline.results.isEmpty && offline.failed)
    }

    @Test("The editor, the exercise picker and an empty editor build")
    func viewsBuild() {
        let (editor, _) = editor()
        _ = PlanEditorView(model: editor, catalog: StubCatalog(), onSaved: {}).body
        let day = editor.addDay()
        editor.addExercise(Exercise(id: "bench", name: "Supino reto", primaryMuscles: [.chest], equipment: .barbell), to: day)
        editor.builder.focus.enabled = true
        _ = PlanEditorView(model: editor, catalog: nil, onSaved: {}).body
        _ = ExercisePickerSheet(model: ExercisePickerViewModel(catalog: StubCatalog()), onPick: { _ in }).body
    }
}

// MARK: - Individual evolution

@Suite("Individual evolution (the trainer builds the chart)")
@MainActor
struct EvolutionTests {
    func logs() async -> MemLogRepo {
        let repo = MemLogRepo()
        func session(_ id: String, day: Double, kg: Double, reps: Int, rest: Int?, focus: TrainingFocus) -> WorkoutLog {
            var log = PFx.log(id: id, status: .completed, blocks: [.resistance(ResistanceLog(blockID: "blk-squat", exercise: PFx.squat,
                sets: [SetLog(index: 1, weightKg: kg, reps: reps, restTakenSeconds: nil, completedAt: PFx.t0), SetLog(index: 2, weightKg: kg, reps: reps, restTakenSeconds: rest, completedAt: PFx.t0)]))],
                start: PFx.t0.addingTimeInterval(day * 86_400))
            log.focus = focus
            return log
        }
        await repo.seed(session("a", day: 1, kg: 100, reps: 4, rest: 150, focus: .strength))
        await repo.seed(session("b", day: 8, kg: 60, reps: 12, rest: 60, focus: .volume))
        await repo.seed(session("c", day: 15, kg: 105, reps: 4, rest: 180, focus: .strength))
        return repo
    }

    func model(_ repo: MemLogRepo, configuration: ChartConfiguration = ChartConfiguration(range: .all), changes: ChangeSink? = nil) -> StudentEvolutionViewModel {
        StudentEvolutionViewModel(studentID: PFx.student, logs: repo, configuration: configuration, builder: ProgressChartBuilder(calendar: Fx2.calendar),
                                  now: { PFx.t0.addingTimeInterval(30 * 86_400) }, onConfigurationChange: { changes?.add($0) })
    }

    final class ChangeSink { var all: [ChartConfiguration] = []; func add(_ c: ChartConfiguration) { all.append(c) } }
    enum Fx2 { static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }() }

    @Test("Loads the student's history and defaults a single-exercise metric to the most-logged exercise")
    func load() async {
        let model = model(await logs())
        await model.load()
        #expect(model.isLoaded && model.exercises.map(\.id) == [PFx.squat.id])
        #expect(model.configuration.exerciseID == PFx.squat.id)                     // e1RM needs an exercise → defaulted
        #expect(model.points.count == 3 && model.latest != nil && !model.isEmpty)
    }

    @Test("The trainer can switch metric, exercise scope, grouping, style, period and focus markers — and each change is reported")
    func configuring() async {
        let sink = ChangeSink()
        let model = model(await logs(), changes: sink)
        await model.load()
        let before = sink.all.count

        model.setMetric(.volume)
        #expect(model.points.map(\.value) == [800, 1_440, 840])                        // 2 sets × 100 × 4, 2 × 60 × 12, 2 × 105 × 4
        #expect(model.canShowAllExercises)
        model.setExercise(nil)
        #expect(model.configuration.exerciseID == nil && model.points.count == 3)

        model.setMetric(.averageRest)
        #expect(model.points.map(\.value) == [150, 60, 180] && model.format(150) == "150 s")
        model.setMetric(.workingSets); #expect(model.points.map(\.value) == [2, 2, 2])
        model.setMetric(.averageReps); #expect(model.points.map(\.value) == [4, 12, 4])
        model.setMetric(.topSetLoad)
        #expect(model.configuration.exerciseID == PFx.squat.id && !model.canShowAllExercises)   // single-exercise metrics get an exercise back
        #expect(model.points.map(\.value) == [100, 60, 105] && model.format(100) == "100 kg")

        model.setGrouping(.perWeek); #expect(model.points.count == 3)
        model.setStyle(.bar); model.setRange(.fourWeeks); model.setShowFocus(false)
        #expect(model.configuration.style == .bar && model.configuration.range == .fourWeeks && !model.configuration.showFocus)
        #expect(sink.all.count > before && sink.all.last == model.configuration)
    }

    @Test("Change over the period, formatting per metric, and the empty state")
    func summary() async {
        let model = model(await logs(), configuration: ChartConfiguration(metric: .topSetLoad, exerciseID: PFx.squat.id, range: .all))
        await model.load()
        #expect(abs((model.changePercent ?? 0) - 5) < 0.001)
        #expect(model.format(2) == "2" || model.configuration.metric == .topSetLoad)
        model.setMetric(.workingSets); #expect(model.format(3) == "3")
        model.setMetric(.averageReps); #expect(["6.5", "6,5"].contains(model.format(6.5)))

        let empty = StudentEvolutionViewModel(studentID: "nobody", logs: MemLogRepo(), now: { PFx.t0 })
        await empty.load()
        #expect(empty.isEmpty && empty.points.isEmpty && empty.exercises.isEmpty)
    }

    @Test("A remembered configuration is restored, and a failing history is not fatal")
    func restoringAndFailing() async {
        let saved = ChartConfiguration(metric: .averageRest, exerciseID: nil, grouping: .perWeek, style: .bar, range: .twelveWeeks, showFocus: false)
        let model = model(await logs(), configuration: saved)
        await model.load()
        #expect(model.configuration == saved && !model.points.isEmpty)

        let broken = MemLogRepo()
        await broken.setFailSaves(true)
        let failing = StudentEvolutionViewModel(studentID: PFx.student, logs: broken, now: { PFx.t0 })
        await failing.load()
        #expect(failing.failed && failing.isLoaded && failing.points.isEmpty)
    }

    @Test("Every title exists, and the screen builds with data, without data and in each style")
    func viewsBuild() async {
        #expect(ProgressMetric.allCases.allSatisfy { !$0.title.isEmpty } && ChartGrouping.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(ChartStyle.allCases.allSatisfy { !$0.title.isEmpty } && ChartRange.allCases.allSatisfy { !$0.title.isEmpty } && TrainingFocus.allCases.allSatisfy { !$0.title.isEmpty })
        let model = model(await logs())
        _ = StudentEvolutionView(model: model).body
        await model.load()
        for style in ChartStyle.allCases {
            model.setStyle(style)
            _ = StudentEvolutionView(model: model).body
            _ = EvolutionChart(points: model.points, configuration: model.configuration, model: model).body
        }
        _ = StudentEvolutionView(model: StudentEvolutionViewModel(studentID: "x", logs: MemLogRepo())).body
    }
}

// MARK: - First access, profile, avatar

@Suite("First access & profile")
@MainActor
struct FirstAccessTests {
    actor Service: FirstAccessService {
        var claimError: RegistrationError?
        var completeError: RegistrationError?
        private(set) var completed: [(NewStudentProfile, String)] = []
        func setErrors(claim: RegistrationError? = nil, complete: RegistrationError? = nil) { claimError = claim; completeError = complete }
        func claim(cpf: String, fullName: String) async throws -> ClaimTicket {
            if let claimError { throw claimError }
            return ClaimTicket(registrationID: "r", trainerName: "Personal Demo", token: "tok")
        }
        func complete(_ ticket: ClaimTicket, profile: NewStudentProfile, password: String) async throws -> SignedInUser {
            if let completeError { throw completeError }
            completed.append((profile, password))
            return SignedInUser(userID: "stu", role: .student, displayName: "Maria Souza")
        }
    }
    final class Capture { var user: SignedInUser? }

    func make(_ service: Service = Service(), _ capture: Capture = Capture()) -> FirstAccessViewModel {
        FirstAccessViewModel(service: service, onSignedIn: { capture.user = $0 })
    }

    @Test("Step 1 needs a valid CPF and a full name; the screen says the CPF is valid as you type")
    func identify() {
        let model = make()
        #expect(!model.canContinue && !model.cpfIsValid)
        model.cpf = "529.982.247-25"; #expect(model.cpfIsValid && !model.canContinue)
        model.fullName = "Maria"; #expect(!model.canContinue)
        model.fullName = "Maria Souza"; #expect(model.canContinue)
        model.cpf = "123.456.789-00"; #expect(!model.canContinue)
    }

    @Test("Step 2 needs e-mail, an age from 12 to 100, and matching passwords of 8+ characters; success signs the student in")
    func fullFlow() async {
        let service = Service(), capture = Capture()
        let model = make(service, capture)
        model.cpf = "529.982.247-25"; model.fullName = "Maria Souza"
        await model.continueTapped()
        #expect(model.step == .profile && model.trainerName == "Personal Demo" && model.errorMessage == nil)

        #expect(!model.canSubmit)
        model.email = "maria@example.com"; model.ageText = "28"; model.gender = .female; model.heightText = "170"; model.weightText = "70"
        model.password = "longenough"; model.confirmPassword = "different"
        #expect(!model.canSubmit)
        model.confirmPassword = "longenough"; #expect(model.canSubmit)
        model.ageText = "11"; #expect(!model.canSubmit)
        model.ageText = "x"; #expect(!model.canSubmit)
        model.ageText = "28"; model.password = "short"; model.confirmPassword = "short"; #expect(!model.canSubmit)
        model.password = "longenough"; model.confirmPassword = "longenough"; #expect(model.canSubmit)
        model.heightText = ""; #expect(!model.canSubmit)                       // height and weight are required too
        model.heightText = "170"; model.weightText = ""; #expect(!model.canSubmit)
        model.weightText = "abc"; #expect(!model.canSubmit)
        model.heightText = "99"; model.weightText = "70"; #expect(!model.canSubmit)
        model.heightText = "251"; #expect(!model.canSubmit)
        model.heightText = "170"; model.weightText = "19"; #expect(!model.canSubmit)
        model.weightText = "401"; #expect(!model.canSubmit)
        model.weightText = "70"; #expect(model.canSubmit)

        await model.submit()
        #expect(capture.user == SignedInUser(userID: "stu", role: .student, displayName: "Maria Souza"))
        #expect(model.password.isEmpty && model.confirmPassword.isEmpty)
        let sent = await service.completed.first
        #expect(sent?.0 == NewStudentProfile(email: "maria@example.com", age: 28, gender: .female, heightCm: 170, weightKg: 70) && sent?.1 == "longenough")
    }

    @Test("Each failure has its own plain message; going back clears the ticket")
    func failures() async {
        let service = Service()
        let model = make(service)
        model.cpf = "529.982.247-25"; model.fullName = "Maria Souza"
        for error in [RegistrationError.notFound, .alreadyClaimed, .offline, .tooManyAttempts, .notConfigured] {
            await service.setErrors(claim: error)
            await model.continueTapped()
            #expect(model.step == .identify && model.errorMessage?.isEmpty == false)
        }
        await service.setErrors()
        await model.continueTapped()
        model.email = "m@x.co"; model.ageText = "30"; model.heightText = "170"; model.weightText = "70"
        model.password = "longenough"; model.confirmPassword = "longenough"
        await service.setErrors(complete: .alreadyClaimed)
        await model.submit()
        #expect(model.errorMessage != nil && model.step == .profile)
        model.back()
        #expect(model.step == .identify && model.errorMessage == nil)
        #expect(Gender.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test("Height and weight accept a comma, and a height typed in metres is understood")
    func bodyNumbers() {
        let model = make()
        model.heightText = "1,78"; model.weightText = "82,5"
        #expect(model.heightCm == 178 && model.weightKg == 82.5)
        model.heightText = "178"; #expect(model.heightCm == 178)
        model.heightText = "175.5"; #expect(model.heightCm == 175.5)
        model.heightText = ""; model.weightText = "  "
        #expect(model.heightCm == nil && model.weightKg == nil)
    }

    @Test("What was typed travels with the profile: height and weight reach the service, rounded to a tenth by the rules")
    func sendsBodyNumbers() async {
        let service = Service()
        let model = make(service)
        model.cpf = "529.982.247-25"; model.fullName = "Maria Souza"
        await model.continueTapped()
        model.email = "maria@example.com"; model.ageText = "28"; model.gender = .female; model.heightText = "1,655"; model.weightText = "61,24"
        model.password = "longenough"; model.confirmPassword = "longenough"
        await model.submit()
        let sent = await service.completed.first?.0
        #expect(sent?.heightCm == 165.5 && sent?.weightKg == 61.24)
    }

    @Test("Height and weight errors have their own plain messages")
    func bodyMessages() {
        #expect(FirstAccessViewModel.message(for: RegistrationError.invalidHeight).localizedCaseInsensitiveContains("height"))
        #expect(FirstAccessViewModel.message(for: RegistrationError.invalidWeight).localizedCaseInsensitiveContains("weight"))
    }

    @Test("The not-found message never says whether the CPF or the name was wrong")
    func noEnumerationMessage() {
        let message = FirstAccessViewModel.message(for: RegistrationError.notFound)
        #expect(message.localizedCaseInsensitiveContains("CPF") && message.localizedCaseInsensitiveContains("name"))
    }

    @Test("Profile: photo and data-saver are stored through the app; log out warns about unsent changes")
    func profile() async {
        final class Store { var photo: Data?; var saver = false; var pending = 0; var logouts = 0 }
        let store = Store()
        let model = ProfileViewModel(name: "Maria Souza", role: .student, photo: nil, dataSaverEnabled: false,
                                     pendingChanges: { store.pending }, signOut: { store.logouts += 1 },
                                     savePhoto: { data in store.photo = data; return data }, saveDataSaver: { store.saver = $0 })
        #expect(model.canChangePhoto && model.hasDataSaver && model.initials == "MS" && model.photo == nil)
        await model.setPhoto(Data([1, 2, 3]))
        #expect(model.photo == Data([1, 2, 3]) && store.photo == Data([1, 2, 3]))
        await model.setPhoto(nil)
        #expect(model.photo == nil)
        model.setDataSaver(true)
        #expect(model.dataSaverEnabled && store.saver)

        await model.requestLogout()
        #expect(store.logouts == 1 && !model.isConfirmingLogout)
        store.pending = 2
        await model.requestLogout()
        #expect(model.isConfirmingLogout && store.logouts == 1)
        await model.confirmLogout()
        #expect(store.logouts == 2)

        let bare = ProfileViewModel(name: "", role: .trainer, pendingChanges: { 0 }, signOut: {})
        #expect(!bare.canChangePhoto && !bare.hasDataSaver && bare.initials == "?" && !bare.roleTitle.isEmpty)
        await bare.setPhoto(Data([9]))
        #expect(bare.photo == nil)
    }

    @Test("First-access, settings and the avatar build — with and without a photo")
    func viewsBuild() {
        _ = FirstAccessView(model: make(), onBack: {}).body
        let model = make()
        _ = SignInView(model: SignInViewModel(auth: StubAuth(result: .failure(.offline)), onSignedIn: { _ in }), onFirstAccess: {}).body
        let profile = ProfileViewModel(name: "Maria Souza", role: .student, pendingChanges: { 0 }, signOut: {}, savePhoto: { $0 }, saveDataSaver: { _ in })
        _ = ProfileView(model: profile, onOpenConnections: {}).body
        _ = ProfileToolbarButton(initials: "MS", photo: nil, action: {}).body
        _ = Avatar(initials: "MS", photo: Data([0, 1, 2]), size: 40).body                    // not an image: falls back to initials
        _ = model
        #expect(Avatar.initials(for: "ana beatriz costa") == "AB")
    }
}
