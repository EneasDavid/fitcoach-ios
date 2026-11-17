import Foundation
import Testing
@testable import Domain

@Suite("ProgressionEngine · deload normalisation")
struct ProgressionEngineTests {
    let engine = ProgressionEngine()
    let plan = Fx.plan(periodization: Fx.threeOneProgram)

    // MARK: The headline rule

    @Test("A deload week neither dents the slope nor distorts the fit")
    func deloadDoesNotSkewTrend() throws {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 12)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)

        #expect(series.deloadPoints.count == 3)
        #expect(series.trendPoints.count == 9)

        // 80 kg + 2.5 kg per working week, 5 reps → e1RM rises 2.5 × (1 + 5/30) per working week.
        let trend = try #require(series.trend)
        #expect(abs(trend.slopeKgPerWeek - 2.5 * (1 + 5.0 / 30)) < 1e-9)
        #expect(trend.r2 > 0.999_999)
        #expect(series.verdict == .progressing)
    }

    @Test("The same data analysed naively (deloads included) gives a visibly worse answer")
    func naiveAnalysisIsWorse() throws {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 12)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)

        let all = series.points
        let naive = try #require(LinearRegression.fit(xs: all.map { Double($0.weekIndex) },
                                                      ys: all.compactMap(\.bestE1RMKg)))
        let normalised = try #require(series.trend)
        #expect(naive.r2 < 0.9)                                  // sawtooth ≠ a line
        #expect(naive.slope < normalised.slopeKgPerWeek * 0.8)   // and the slope is under-reported
    }

    @Test("Removing the deload logs entirely yields the identical trend")
    func deloadLogsAreIrrelevantToTrend() throws {
        let withDeload = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 12)
        let withoutDeload = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 12, includeDeloadWeeks: false)

        let a = try #require(engine.series(for: Fx.bench.id, logs: withDeload, periodization: Fx.threeOneProgram, calendar: Fx.calendar).trend)
        let b = try #require(engine.series(for: Fx.bench.id, logs: withoutDeload, periodization: Fx.threeOneProgram, calendar: Fx.calendar).trend)
        #expect(abs(a.slopeKgPerWeek - b.slopeKgPerWeek) < 1e-9)
        #expect(abs(a.interceptKg - b.interceptKg) < 1e-9)
    }

    @Test("First working session after a deload is compared with the last one *before* it")
    func baselineSkipsDeload() throws {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 5)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)

        let week2 = try #require(series.points.first { $0.weekIndex == 2 })       // last working week, 85 kg
        let week4 = try #require(series.points.first { $0.weekIndex == 4 })       // first after deload, 87.5 kg
        let deload = try #require(series.points.first { $0.weekIndex == 3 })
        #expect(deload.isDeload)
        #expect(deload.changeVsPreviousWorkingPercent == nil)

        let expected = ((week4.bestE1RMKg ?? 0) - (week2.bestE1RMKg ?? 0)) / (week2.bestE1RMKg ?? 1) * 100
        let actual = try #require(week4.changeVsPreviousWorkingPercent)
        #expect(abs(actual - expected) < 1e-9)
        #expect(actual > 0)   // a naive "vs previous session" would show +45 % here — or −27 % into the deload
    }

    @Test("Deload sessions never register as personal records")
    func deloadsAreNotPRs() {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 12)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)
        let deloadIDs = Set(series.deloadPoints.map(\.logID))

        #expect(series.personalRecords.count == 8)   // 9 working sessions, the first is the baseline
        #expect(series.personalRecords.allSatisfy { !deloadIDs.contains($0.logID) })
    }

    @Test("A deload week the student skipped still collapses out of the x-axis (via the plan)")
    func skippedDeloadWeekCollapses() throws {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 8, includeDeloadWeeks: false)
        let withPlan = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)
        let withoutPlan = engine.series(for: Fx.bench.id, logs: logs, periodization: nil, calendar: Fx.calendar)

        #expect(withPlan.points.first { $0.weekIndex == 4 }?.effectiveWeek == 3)
        #expect(withoutPlan.points.first { $0.weekIndex == 4 }?.effectiveWeek == 4)
    }

    @Test("Phase comes from the snapshot frozen on the log, not from today's plan")
    func snapshotBeatsCurrentPlan() throws {
        // The plan has since been edited so week 3 is no longer a deload…
        var edited = Fx.threeOneProgram
        edited.macrocycles[0].microcycles[3].phase = .high
        // …but the session was performed (and snapshotted) as a deload.
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 5)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: edited, calendar: Fx.calendar)
        #expect(series.points.first { $0.weekIndex == 3 }?.isDeload == true)
    }

    // MARK: Volume

    @Test("Non-deload tonnage is normalised by the planned volume multiplier")
    func tonnageNormalisation() throws {
        let light = PeriodizationSnapshot(weekIndex: 0, phase: .moderate, volumeMultiplier: 0.8)
        let log = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 1), snapshot: light,
                         exercise: Fx.bench, sets: [(100, 10)])
        let point = try #require(engine.series(for: Fx.bench.id, logs: [log], calendar: Fx.calendar).points.first)
        #expect(point.tonnageKg == 1000)
        #expect(abs(point.normalizedTonnageKg - 1250) < 1e-9)
    }

    @Test("Deload tonnage is reported as performed, never inflated")
    func deloadTonnageNotNormalised() throws {
        let deload = PeriodizationSnapshot(weekIndex: 3, phase: .deload, volumeMultiplier: 0.5)
        let log = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 22), snapshot: deload,
                         exercise: Fx.bench, sets: [(60, 10)])
        let point = try #require(engine.series(for: Fx.bench.id, logs: [log], calendar: Fx.calendar).points.first)
        #expect(point.normalizedTonnageKg == point.tonnageKg)
    }

    @Test("Weekly volume flags deload weeks so dashboards can shade them")
    func weeklyVolumeFlagsDeload() {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 5)
        let weekly = engine.weeklyVolume(logs: logs, calendar: Fx.calendar)
        #expect(weekly.map(\.weekIndex) == [0, 1, 2, 3, 4])
        #expect(weekly.map(\.isDeload) == [false, false, false, true, false])
        #expect(weekly.allSatisfy { $0.workingSets == 3 && $0.sessions == 1 })
    }

    // MARK: Verdicts & data hygiene

    @Test("Fewer than three working points → no trend, insufficient data")
    func insufficientData() {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 2)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)
        #expect(series.trend == nil)
        #expect(series.verdict == .insufficientData)
    }

    @Test("Flat strength is a plateau; falling strength is regression")
    func plateauAndRegression() {
        func verdict(_ weights: [Double]) -> OverloadVerdict {
            let logs = weights.enumerated().map { index, kg in
                Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: index * 7 + 1),
                       exercise: Fx.bench, sets: [(kg, 5)])
            }
            return engine.series(for: Fx.bench.id, logs: logs, calendar: Fx.calendar).verdict
        }
        #expect(verdict([100, 100, 100, 100]) == .plateau)
        #expect(verdict([100, 97.5, 95, 92.5]) == .regressing)
        #expect(verdict([100, 102.5, 105, 107.5]) == .progressing)
    }

    @Test("Without a periodization snapshot, weeks fall back to calendar weeks (and everything counts)")
    func calendarFallback() {
        let logs = [0, 7, 14].map {
            Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: $0), exercise: Fx.bench, sets: [(100, 5)])
        }
        let series = engine.series(for: Fx.bench.id, logs: logs, calendar: Fx.calendar)
        #expect(series.points.map(\.weekIndex) == [0, 1, 2])
        #expect(series.deloadPoints.isEmpty)
    }

    @Test("High-rep sets feed tonnage but not the 1RM estimate; warm-ups are ignored")
    func setFiltering() throws {
        var log = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 1), exercise: Fx.bench,
                         sets: [(40, 20), (20, 5)])
        if case .resistance(var resistance) = log.blocks[0] {
            resistance.sets[1].isWarmup = true
            log.blocks[0] = .resistance(resistance)
        }
        let point = try #require(engine.series(for: Fx.bench.id, logs: [log], calendar: Fx.calendar).points.first)
        #expect(point.bestE1RMKg == nil)          // 20 reps is beyond the estimate cap
        #expect(point.tonnageKg == 800)           // warm-up excluded
        #expect(!point.isTrendEligible)
    }

    @Test("Abandoned, in-progress and soft-deleted logs are ignored")
    func ignoresNonCompleted() {
        var deleted = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 1), exercise: Fx.bench)
        deleted.meta.deletedAt = Fx.date(day: 2)
        let logs = [
            Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 3), status: .abandoned, exercise: Fx.bench),
            Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 4), status: .inProgress, exercise: Fx.bench),
            deleted,
        ]
        #expect(engine.series(for: Fx.bench.id, logs: logs, calendar: Fx.calendar).points.isEmpty)
        #expect(engine.weeklyVolume(logs: logs, calendar: Fx.calendar).isEmpty)
    }

    @Test("Other exercises in the same session don't leak into the series")
    func exerciseIsolation() {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 4, exercise: Fx.squat)
        #expect(engine.series(for: Fx.bench.id, logs: logs, calendar: Fx.calendar).points.isEmpty)
    }

    @Test("changePercent compares first and last working e1RM")
    func changePercent() throws {
        let logs = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 12)
        let series = engine.series(for: Fx.bench.id, logs: logs, periodization: Fx.threeOneProgram, calendar: Fx.calendar)
        // 80 kg → 100 kg working top weight.
        let change = try #require(series.changePercent)
        #expect(abs(change - 25) < 1e-9)
    }

    // MARK: 1RM formulas

    @Test("1RM formulas")
    func formulas() {
        #expect(abs(OneRepMaxFormula.epley.estimate(weightKg: 100, reps: 5) - 116.666_666_7) < 1e-6)
        #expect(OneRepMaxFormula.brzycki.estimate(weightKg: 100, reps: 5) == 112.5)
        #expect(abs(OneRepMaxFormula.lombardi.estimate(weightKg: 100, reps: 5) - 117.46) < 0.01)
        #expect(OneRepMaxFormula.epley.estimate(weightKg: 100, reps: 1) == 100)
        #expect(OneRepMaxFormula.epley.estimate(weightKg: 0, reps: 5) == 0)
        #expect(OneRepMaxFormula.brzycki.estimate(weightKg: 100, reps: 40) == 0)
    }

    @Test("Regression guards")
    func regressionGuards() {
        #expect(LinearRegression.fit(xs: [1], ys: [1]) == nil)
        #expect(LinearRegression.fit(xs: [2, 2, 2], ys: [1, 2, 3]) == nil)
        #expect(LinearRegression.fit(xs: [1, 2, 3], ys: [5, 5, 5])?.r2 == 1)
    }
}
