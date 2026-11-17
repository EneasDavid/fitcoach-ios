import Foundation
import Testing
@testable import Domain

@Suite("FocusCycle (strength weeks / volume weeks)")
struct FocusCycleTests {
    @Test("3 strength + 2 volume weeks repeat: S S S V V S S S V V …")
    func alternation() {
        let cycle = FocusCycle(strengthWeeks: 3, volumeWeeks: 2)
        let focus = (0..<10).map { cycle.focus(forWeekIndex: $0) }
        #expect(focus == [.strength, .strength, .strength, .volume, .volume, .strength, .strength, .strength, .volume, .volume])
        #expect(cycle.position(forWeekIndex: 4) == .init(focus: .volume, week: 2, of: 2))
        #expect(cycle.position(forWeekIndex: 5) == .init(focus: .strength, week: 1, of: 3))
        #expect(cycle.cycleLength == 5)
    }

    @Test("A cycle can start with volume; negative weeks clamp to the first")
    func startsWithVolume() {
        let cycle = FocusCycle(strengthWeeks: 2, volumeWeeks: 4, startsWith: .volume)
        #expect((0..<7).map { cycle.focus(forWeekIndex: $0) } == [.volume, .volume, .volume, .volume, .strength, .strength, .volume])
        #expect(cycle.focus(forWeekIndex: -3) == .volume)
    }

    @Test("Weeks are counted from the plan start in whole calendar days / 7")
    func weekIndex() {
        let cycle = FocusCycle()
        #expect(cycle.weekIndex(startDate: Fx.date(day: 0), now: Fx.date(day: 6, hour: 23), calendar: Fx.calendar) == 0)
        #expect(cycle.weekIndex(startDate: Fx.date(day: 0), now: Fx.date(day: 7, hour: 1), calendar: Fx.calendar) == 1)
        #expect(cycle.weekIndex(startDate: Fx.date(day: 10), now: Fx.date(day: 3), calendar: Fx.calendar) == 0)     // before the start
    }

    @Test("Validity: 1–12 weeks each; rep ranges per kind of week")
    func validity() {
        #expect(FocusCycle(strengthWeeks: 0, volumeWeeks: 3).isValid == false)
        #expect(FocusCycle(strengthWeeks: 3, volumeWeeks: 13).isValid == false)
        let cycle = FocusCycle(strengthReps: 2...5, volumeReps: 12...20)
        #expect(cycle.repRange(for: .strength) == 2...5 && cycle.repRange(for: .volume) == 12...20)
        #expect(TrainingFocus.strength.opposite == .volume)
    }

    @Test("A plan carries the cycle through Codable, and an old plan without one still decodes")
    func codable() throws {
        var plan = Fx.plan()
        plan.focusCycle = FocusCycle(strengthWeeks: 4, volumeWeeks: 2)
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(WorkoutPlan.self, from: data).focusCycle == plan.focusCycle)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["focusCycle"] = nil
        let legacy = try JSONDecoder().decode(WorkoutPlan.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.focusCycle == nil)
    }
}

@Suite("FocusGuard (lifting the wrong way round)")
struct FocusGuardTests {
    let start = Fx.date(day: 0)
    let guardrail = FocusGuard()

    /// 2 strength weeks then 2 volume weeks. Strength week 0: bench at 100 kg ×4. Now it's week 2 (volume).
    func scenario() -> (plan: WorkoutPlan, logs: [WorkoutLog]) {
        var plan = Fx.plan()
        plan.startDate = start
        plan.focusCycle = FocusCycle(strengthWeeks: 2, volumeWeeks: 2)
        var heavy = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 2), exercise: Fx.bench, sets: [(100, 4), (100, 4), (60, 5)])
        heavy.focus = .strength
        return (plan, [heavy])
    }

    @Test("The context says which kind of week it is and keeps the best opposite-week load per exercise")
    func context() throws {
        let (plan, logs) = scenario()
        let context = try #require(guardrail.context(plan: plan, logs: logs, now: Fx.date(day: 15), calendar: Fx.calendar))
        #expect(context.focus == .volume && context.weekInPhase == 1 && context.phaseWeeks == 2)
        #expect(context.oppositeBestKg == [Fx.bench.id: 100])
        #expect(context.suggestedReps == 10...15)
    }

    @Test("Volume week: a load above the strength-week best warns; at or below it does not")
    func heavierInAVolumeWeek() throws {
        let (plan, logs) = scenario()
        let context = try #require(guardrail.context(plan: plan, logs: logs, now: Fx.date(day: 15), calendar: Fx.calendar))
        let warning = try #require(guardrail.warning(exercise: Fx.bench, loadKg: 105, in: context))
        #expect(warning.kind == .heavierThanStrengthWeek && warning.referenceKg == 100 && warning.loadKg == 105)
        #expect(guardrail.warning(exercise: Fx.bench, loadKg: 100, in: context) == nil)
        #expect(guardrail.warning(exercise: Fx.bench, loadKg: 70, in: context) == nil)
    }

    @Test("Strength week: a load below the volume-week best warns")
    func lighterInAStrengthWeek() throws {
        var (plan, logs) = scenario()
        logs[0].focus = .volume                                              // the earlier week was the volume one
        let context = try #require(guardrail.context(plan: plan, logs: logs, now: Fx.date(day: 2), calendar: Fx.calendar))
        #expect(context.focus == .strength)
        let warning = try #require(guardrail.warning(exercise: Fx.bench, loadKg: 80, in: context))
        #expect(warning.kind == .lighterThanVolumeWeek)
        #expect(guardrail.warning(exercise: Fx.bench, loadKg: 100, in: context) == nil)
    }

    @Test("Tolerance widens the band; other exercises, zero loads and missing history never warn")
    func tolerance() throws {
        let (plan, logs) = scenario()
        let context = try #require(guardrail.context(plan: plan, logs: logs, now: Fx.date(day: 15), calendar: Fx.calendar))
        #expect(FocusGuard(tolerancePercent: 10).warning(exercise: Fx.bench, loadKg: 105, in: context) == nil)
        #expect(FocusGuard(tolerancePercent: 10).warning(exercise: Fx.bench, loadKg: 111, in: context) != nil)
        #expect(guardrail.warning(exercise: Fx.squat, loadKg: 200, in: context) == nil)         // no squat reference
        #expect(guardrail.warning(exercise: Fx.bench, loadKg: 0, in: context) == nil)
    }

    @Test("Only recent, completed, un-deleted, warm-up-free work of the same student is the yardstick; no cycle → no context")
    func yardstick() throws {
        var (plan, logs) = scenario()
        var old = logs[0]; old.focus = .strength
        old = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: -400), exercise: Fx.bench, sets: [(200, 1)])
        old.focus = .strength
        var abandoned = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 3), status: .abandoned, exercise: Fx.bench, sets: [(150, 1)])
        abandoned.focus = .strength
        var noFocus = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 4), exercise: Fx.bench, sets: [(140, 1)])
        noFocus.focus = nil
        let context = try #require(guardrail.context(plan: plan, logs: logs + [old, abandoned, noFocus], now: Fx.date(day: 15), calendar: Fx.calendar))
        #expect(context.oppositeBestKg[Fx.bench.id] == 100)

        plan.focusCycle = nil
        #expect(guardrail.context(plan: plan, logs: logs, now: Fx.date(day: 15), calendar: Fx.calendar) == nil)
    }

    @Test("Starting a workout freezes whether it was a strength or a volume week")
    func startFreezesFocus() async throws {
        var plan = Fx.plan()
        plan.startDate = start
        plan.focusCycle = FocusCycle(strengthWeeks: 1, volumeWeeks: 1)
        let repo = InMemoryLogRepository()
        let week0 = try await StartWorkoutUseCase(logs: repo, now: { Fx.date(day: 2) }, calendar: Fx.calendar).execute(plan: plan)
        #expect(week0.focus == .strength)
        let repo2 = InMemoryLogRepository()
        let week1 = try await StartWorkoutUseCase(logs: repo2, now: { Fx.date(day: 9) }, calendar: Fx.calendar).execute(plan: plan)
        #expect(week1.focus == .volume)
    }
}

@Suite("Registration rules")
struct RegistrationRulesTests {
    @Test("CPF must be valid; the normalised digits come back", arguments: ["529.982.247-25", "52998224725"])
    func cpf(input: String) throws {
        #expect(try RegistrationRules.cpf(input) == "52998224725")
    }

    @Test("Invalid CPFs are refused")
    func badCPF() {
        #expect(throws: RegistrationError.invalidCPF) { try RegistrationRules.cpf("123.456.789-00") }
        #expect(throws: RegistrationError.invalidCPF) { try RegistrationRules.cpf("") }
    }

    @Test("Names need two words, letters only, collapse spaces", arguments: [("  Maria   Souza ", "Maria Souza"), ("José da Silva", "José da Silva"), ("Ana-Clara D'Ávila", "Ana-Clara D'Ávila")])
    func names(input: String, expected: String) throws {
        #expect(try RegistrationRules.fullName(input) == expected)
    }

    @Test("Bad names", arguments: ["Maria", "", "123 456", "Maria <script>", String(repeating: "a ", count: 80)])
    func badNames(input: String) {
        #expect(throws: RegistrationError.invalidName) { try RegistrationRules.fullName(input) }
    }

    @Test("Name matching ignores case, accents and spacing — and nothing else")
    func matching() {
        #expect(RegistrationRules.namesMatch("JOSÉ  da Silva", "jose da silva"))
        #expect(!RegistrationRules.namesMatch("José da Silva", "José da Silva Junior"))
        #expect(!RegistrationRules.namesMatch("Ana Souza", "Ana Sousa"))
    }

    @Test("Profile: e-mail shape, age 12–100, password ≥ 8")
    func profile() throws {
        let ok = try RegistrationRules.profile(NewStudentProfile(email: " Ana@Example.COM ", age: 30, gender: .female, heightCm: 170, weightKg: 70), password: "12345678")
        #expect(ok.email == "ana@example.com")
        for bad in ["ana", "ana@", "@example.com", "ana @example.com", "ana@example"] {
            #expect(throws: RegistrationError.invalidEmail) { try RegistrationRules.profile(NewStudentProfile(email: bad, age: 30, gender: .male, heightCm: 170, weightKg: 70), password: "12345678") }
        }
        #expect(throws: RegistrationError.invalidAge) { try RegistrationRules.profile(NewStudentProfile(email: "a@b.co", age: 11, gender: .male, heightCm: 170, weightKg: 70), password: "12345678") }
        #expect(throws: RegistrationError.invalidAge) { try RegistrationRules.profile(NewStudentProfile(email: "a@b.co", age: 101, gender: .male, heightCm: 170, weightKg: 70), password: "12345678") }
        #expect(throws: RegistrationError.weakPassword) { try RegistrationRules.profile(NewStudentProfile(email: "a@b.co", age: 30, gender: .male, heightCm: 170, weightKg: 70), password: "1234567") }
    }

    @Test("The CPF is only ever shown masked")
    func masking() {
        #expect(RegistrationRules.masked(cpf: "52998224725") == "***.982.247-**")
        #expect(RegistrationRules.masked(cpf: "1") == "***")
    }
}

@Suite("ProgressChartBuilder (trainer-configurable charts)")
struct ProgressChartBuilderTests {
    let builder = ProgressChartBuilder(calendar: Fx.calendar)
    let plan = Fx.plan()
    let now = Fx.date(day: 40)

    func session(day: Int, exercise: ExerciseRef = Fx.bench, sets: [(kg: Double, reps: Int, rest: Int?)], focus: TrainingFocus? = nil) -> WorkoutLog {
        var log = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: day), exercise: exercise, sets: sets.map { ($0.kg, $0.reps) })
        if case .resistance(var performed)? = log.blocks.first {
            for index in performed.sets.indices { performed.sets[index].restTakenSeconds = sets[index].rest }
            log.blocks = [.resistance(performed)]
        }
        log.focus = focus
        return log
    }

    var logs: [WorkoutLog] {
        [session(day: 30, sets: [(100, 5, nil), (100, 5, 120), (80, 10, 90)], focus: .strength),
         session(day: 32, sets: [(60, 12, nil), (60, 12, 60)], focus: .volume),
         session(day: 37, exercise: Fx.squat, sets: [(140, 5, nil)], focus: .strength)]
    }

    @Test("Every metric reads the same sets, per session")
    func metrics() {
        func values(_ metric: ProgressMetric, exercise: ExerciseRef? = Fx.bench) -> [Double] {
            builder.points(logs: logs, configuration: ChartConfiguration(metric: metric, exerciseID: exercise?.id, range: .all), now: now).map(\.value)
        }
        #expect(values(.topSetLoad) == [100, 60])
        #expect(values(.workingSets) == [3, 2])
        #expect(values(.volume) == [1_800.0, 1_440.0])                    // 500 + 500 + 800, and 720 + 720
        let averageReps = values(.averageReps)
        #expect(abs(averageReps[0] - 6.666_666) < 0.001 && averageReps[1] == 12)
        #expect(values(.averageRest) == [105, 60])                        // first sets have no rest → ignored
        let e1rm = values(.estimatedOneRepMax)
        #expect(abs(e1rm[0] - 100 * (1 + 5.0 / 30)) < 0.001)              // 100 kg × 5 beats 80 × 10 (Epley 106.7)
    }

    @Test("All exercises together for volume / sets / rest; single-exercise metrics refuse to mix")
    func exerciseSelection() {
        let all = builder.points(logs: logs, configuration: ChartConfiguration(metric: .workingSets, exerciseID: nil, range: .all), now: now)
        #expect(all.map(\.value) == [3, 2, 1])
        #expect(builder.points(logs: logs, configuration: ChartConfiguration(metric: .topSetLoad, exerciseID: nil, range: .all), now: now).isEmpty)
        let squat = builder.points(logs: logs, configuration: ChartConfiguration(metric: .topSetLoad, exerciseID: Fx.squat.id, range: .all), now: now)
        #expect(squat.map(\.value) == [140])
        let fixed = ChartConfiguration(metric: .topSetLoad).normalised(defaultExercise: Fx.bench.id)
        #expect(fixed.exerciseID == Fx.bench.id)
    }

    @Test("Per week: sessions of one calendar week become one point (max for loads, sum for volume and sets)")
    func perWeek() {
        let weekly = logs.filter { _ in true }
        // days 30 and 32 fall in the same week (Mon 2024-01-01 + 30 d = Wed Jan 31; +32 = Fri Feb 2), day 37 in the next.
        let load = builder.points(logs: weekly, configuration: ChartConfiguration(metric: .topSetLoad, exerciseID: Fx.bench.id, grouping: .perWeek, range: .all), now: now)
        #expect(load.map(\.value) == [100] && load[0].sessions == 2)
        let sets = builder.points(logs: weekly, configuration: ChartConfiguration(metric: .workingSets, grouping: .perWeek, range: .all), now: now)
        #expect(sets.map(\.value) == [5, 1] && sets.map(\.sessions) == [2, 1])
    }

    @Test("The range keeps only recent sessions; incomplete, deleted and warm-up sets never count")
    func filtering() {
        #expect(builder.points(logs: logs, configuration: ChartConfiguration(metric: .workingSets, range: .fourWeeks), now: Fx.date(day: 33)).count == 2)
        #expect(builder.points(logs: logs, configuration: ChartConfiguration(metric: .workingSets, range: .fourWeeks), now: Fx.date(day: 80)).isEmpty)

        var bad = logs
        bad[0].status = .abandoned
        bad[1].meta.deletedAt = Fx.date(day: 33)
        #expect(builder.points(logs: bad, configuration: ChartConfiguration(metric: .workingSets, range: .all), now: now).map(\.value) == [1])

        var warm = session(day: 31, sets: [(20, 10, nil), (100, 5, 90)])
        if case .resistance(var performed)? = warm.blocks.first { performed.sets[0].isWarmup = true; warm.blocks = [.resistance(performed)] }
        #expect(builder.points(logs: [warm], configuration: ChartConfiguration(metric: .workingSets, range: .all), now: now).map(\.value) == [1])
    }

    @Test("Points carry the strength / volume focus, and deload weeks are flagged")
    func focusAndDeload() {
        let points = builder.points(logs: logs, configuration: ChartConfiguration(metric: .volume, range: .all), now: now)
        #expect(points.map(\.focus) == [.strength, .volume, .strength])
        #expect(points.allSatisfy { !$0.isDeload })
        let deload = PeriodizationSnapshot(weekIndex: 3, phase: .deload, volumeMultiplier: 0.5)
        var flagged = logs[0]; flagged.periodization = deload
        #expect(builder.points(logs: [flagged], configuration: ChartConfiguration(metric: .volume, range: .all), now: now)[0].isDeload)
    }

    @Test("The picker lists the exercises actually logged, most-logged first; change is first→last in percent")
    func exercisesAndChange() {
        #expect(builder.exercises(in: logs).map(\.id) == [Fx.bench.id, Fx.squat.id])
        let points = builder.points(logs: logs, configuration: ChartConfiguration(metric: .topSetLoad, exerciseID: Fx.bench.id, range: .all), now: now)
        #expect(builder.changePercent(points) == -40)
        #expect(builder.changePercent(Array(points.prefix(1))) == nil)
        #expect(ProgressMetric.allCases.allSatisfy { $0.needsSingleExercise == ($0 == .estimatedOneRepMax || $0 == .topSetLoad) })
        #expect(ChartRange.fourWeeks.weeks == 4 && ChartRange.all.weeks == nil)
    }

    @Test("A configuration survives Codable (so it can be remembered per student)")
    func codable() throws {
        let configuration = ChartConfiguration(metric: .averageRest, exerciseID: "ex", grouping: .perWeek, style: .bar, range: .fourWeeks, showFocus: false)
        #expect(try JSONDecoder().decode(ChartConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    }
}
