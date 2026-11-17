import Foundation

// What a trainer can read off a prescription (the plan) and its execution (the logs): sets, reps, loads, rest and time.
//
// The measures are the standard monitoring set of resistance training, all derived — nothing is entered twice:
//  * volume load (kg) = Σ load × reps over working sets — the usual proxy for how much work was done;
//  * estimated 1RM (Epley) — strength progress without testing a true max; PRs and stagnation come from it;
//  * session-RPE load = session RPE × minutes (Foster) — internal load that also captures how hard the student found it;
//  * acute : chronic load = the last 7 days against the average of the 4 weeks before — a spike (≥ 1.5) is the classic overload flag;
//  * adherence = sessions done against the plan's target sessions per week;
//  * rest compliance, rep-range and load-target adherence = execution against what the plan asked for;
//  * density (kg per minute) and average load per rep (intensity); hard sets per muscle group (the hypertrophy dose).
// They are signals for a conversation, not verdicts: thresholds are advisory and every number is shown with what it is made of.

public enum WorkloadZone: String, Sendable, Equatable {
    /// Under 0.8: training well below the recent habit.
    case low
    /// 0.8 – 1.3.
    case balanced
    /// 1.3 – 1.5.
    case elevated
    /// 1.5 and up.
    case high
}

public struct WeekMetrics: Equatable, Identifiable, Sendable {
    public let weekStart: Date
    public var id: Date { weekStart }
    public let sessions: Int
    public let workingSets: Int
    public let reps: Int
    public let volumeLoadKg: Double
    public let minutes: Int
    /// Session RPE × minutes, summed.
    public let sessionLoad: Double
}

public struct ExerciseTrend: Equatable, Identifiable, Sendable {
    public var id: ExerciseID { exercise.id }
    public let exercise: ExerciseRef
    public let sessions: Int
    public let firstE1RM: Double
    public let bestE1RM: Double
    public let latestE1RM: Double
    public let heaviestKg: Double
    /// Sessions that beat every earlier one (the first session is the baseline, not a PR).
    public let personalRecords: Int
    public let lastPerformed: Date
    /// Four or more sessions and none of the last three beat what came before.
    public let isStagnant: Bool

    public var changePercent: Double? { firstE1RM > 0 ? (latestE1RM - firstE1RM) / firstE1RM * 100 : nil }
}

public struct Adherence: Equatable, Sendable {
    public let completed: Int
    public let planned: Int
    public var ratio: Double { planned > 0 ? Double(completed) / Double(planned) : 0 }
}

public struct RestCompliance: Equatable, Sendable {
    public let setsMeasured: Int
    public let setsOnTarget: Int
    public let averageTakenSeconds: Int
    public let averagePrescribedSeconds: Int
    public var onTargetRatio: Double { setsMeasured > 0 ? Double(setsOnTarget) / Double(setsMeasured) : 0 }
}

public struct PrescriptionAdherence: Equatable, Sendable {
    public let setsPrescribed: Int
    public let setsDone: Int
    /// Sets that could be compared with a prescribed set at the same position.
    public let setsCompared: Int
    public let setsInRepRange: Int
    public let setsWithLoadTarget: Int
    public let setsAtLoadTarget: Int

    public var completionRatio: Double { setsPrescribed > 0 ? Double(setsDone) / Double(setsPrescribed) : 0 }
    public var repRangeRatio: Double? { setsCompared > 0 ? Double(setsInRepRange) / Double(setsCompared) : nil }
    public var loadTargetRatio: Double? { setsWithLoadTarget > 0 ? Double(setsAtLoadTarget) / Double(setsWithLoadTarget) : nil }
}

public enum TrainingAlert: Equatable, Sendable {
    case noRecentSession(days: Int)
    case lowAdherence(percent: Int)
    case workloadSpike(ratio: Double)
    case workloadDrop(ratio: Double)
    case stagnant(exercise: ExerciseRef, sessions: Int)
    case restOffTarget(percent: Int)
}

public struct TrainingSummary: Equatable, Sendable {
    /// `nil` without a plan.
    public let adherence: Adherence?
    /// Oldest first; weeks without a session are present (as zeros), so a gap shows as a gap.
    public let weeks: [WeekMetrics]
    public let workloadRatio: Double?
    public let workloadZone: WorkloadZone?
    /// Most-trained first.
    public let exercises: [ExerciseTrend]
    public let rest: RestCompliance?
    public let prescription: PrescriptionAdherence?
    public let daysSinceLastSession: Int?
    /// kg per rep across working sets.
    public let averageLoadPerRepKg: Double?
    /// Volume load per minute of training.
    public let volumePerMinuteKg: Double?
    /// Hard (working) sets in the last 7 days, by primary muscle. Empty when no muscle data was supplied.
    public let weeklySetsByMuscle: [MuscleGroup: Int]
    public let alerts: [TrainingAlert]

    public var isEmpty: Bool { exercises.isEmpty }
}

public struct TrainingMetricsBuilder: Sendable {
    public var calendar: Calendar
    public var formula: OneRepMaxFormula
    /// e1RM degrades past ~12 reps (same limit as the progression engine and the charts).
    public var maxRepsForEstimate: Int
    public var weeksShown: Int
    /// Rest counts as on target within ±20 % (never tighter than ±10 s).
    public var restTolerance: Double

    public static let minimumHistoryDaysForWorkloadRatio = 21
    public static let noRecentSessionDays = 7
    public static let lowAdherenceBelow = 0.6
    public static let workloadDropBelow = 0.6
    public static let minimumRestSetsForAlert = 6

    public init(calendar: Calendar = .current, formula: OneRepMaxFormula = .epley, maxRepsForEstimate: Int = 12, weeksShown: Int = 8, restTolerance: Double = 0.2) {
        self.calendar = calendar
        self.formula = formula
        self.maxRepsForEstimate = maxRepsForEstimate
        self.weeksShown = max(weeksShown, 1)
        self.restTolerance = restTolerance
    }

    public func summary(logs: [WorkoutLog], plan: WorkoutPlan?, now: Date, muscles: (ExerciseID) -> [MuscleGroup] = { _ in [] }) -> TrainingSummary {
        let completed = logs
            .filter { $0.status == .completed && !$0.meta.isDeleted && $0.effectiveDate <= now }
            .sorted { $0.effectiveDate < $1.effectiveDate }
        let day: TimeInterval = 86_400
        let windowStart = now.addingTimeInterval(-Double(weeksShown) * 7 * day)
        let inWindow = completed.filter { $0.effectiveDate >= windowStart }

        let weeks = weekly(completed, now: now)
        let ratio = workloadRatio(completed, now: now)
        let trends = exerciseTrends(completed)
        let rest = restCompliance(inWindow, plan: plan)
        let prescription = prescriptionAdherence(inWindow, plan: plan)
        let adherence = plan.map { adherence(completed, plan: $0, now: now) }
        let lastSession = completed.last?.effectiveDate
        let since = lastSession.map { max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: now)).day ?? 0) }

        let sets = inWindow.flatMap(workingSets(in:))
        let reps = sets.reduce(0) { $0 + $1.reps }
        let volume = sets.reduce(0.0) { $0 + $1.volumeKg }
        let minutes = inWindow.reduce(0.0) { $0 + minutes(of: $1) }

        let zone = ratio.map(Self.zone(for:))
        return TrainingSummary(
            adherence: adherence, weeks: weeks, workloadRatio: ratio, workloadZone: zone, exercises: trends, rest: rest, prescription: prescription,
            daysSinceLastSession: since,
            averageLoadPerRepKg: reps > 0 ? volume / Double(reps) : nil,
            volumePerMinuteKg: minutes > 0 ? volume / minutes : nil,
            weeklySetsByMuscle: setsByMuscle(completed, now: now, muscles: muscles),
            alerts: alerts(adherence: adherence, ratio: ratio, zone: zone, trends: trends, rest: rest, daysSince: since))
    }

    public static func zone(for ratio: Double) -> WorkloadZone {
        switch ratio {
        case ..<0.8: return .low
        case ..<1.3: return .balanced
        case ..<1.5: return .elevated
        default: return .high
        }
    }

    // MARK: Pieces

    private func workingSets(in log: WorkoutLog) -> [SetLog] {
        log.blocks.flatMap { block -> [SetLog] in
            guard case .resistance(let performed) = block else { return [] }
            return performed.sets.filter { !$0.isWarmup }
        }
    }

    private func minutes(of log: WorkoutLog) -> Double {
        guard let end = log.completedAt else { return 0 }
        return max(0, end.timeIntervalSince(log.startedAt) / 60)
    }

    private func sessionLoad(_ log: WorkoutLog) -> Double { Double(log.sessionRPE ?? 0) * minutes(of: log) }

    private func weekly(_ logs: [WorkoutLog], now: Date) -> [WeekMetrics] {
        guard let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<weeksShown).reversed().compactMap { back -> WeekMetrics? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let inWeek = logs.filter { $0.effectiveDate >= start && $0.effectiveDate < end }
            let sets = inWeek.flatMap(workingSets(in:))
            return WeekMetrics(weekStart: start, sessions: inWeek.count, workingSets: sets.count, reps: sets.reduce(0) { $0 + $1.reps },
                               volumeLoadKg: sets.reduce(0.0) { $0 + $1.volumeKg }, minutes: Int(inWeek.reduce(0.0) { $0 + minutes(of: $1) }.rounded()),
                               sessionLoad: inWeek.reduce(0.0) { $0 + sessionLoad($1) })
        }
    }

    /// The last 7 days against the average of the four 7-day blocks before. Needs three weeks of history: in the first weeks the "habit"
    /// is still being formed and any ratio would be a spike by construction.
    private func workloadRatio(_ logs: [WorkoutLog], now: Date) -> Double? {
        guard let first = logs.first, now.timeIntervalSince(first.effectiveDate) >= Double(Self.minimumHistoryDaysForWorkloadRatio) * 86_400 else { return nil }
        func load(from: Double, to: Double) -> Double {
            logs.filter { $0.effectiveDate > now.addingTimeInterval(-to * 86_400) && $0.effectiveDate <= now.addingTimeInterval(-from * 86_400) }
                .reduce(0.0) { $0 + sessionLoad($1) }
        }
        let acute = load(from: 0, to: 7)
        var previous = 0.0
        for block in 1...4 {
            let from = Double(block) * 7
            previous += load(from: from, to: from + 7)
        }
        let chronic = previous / 4
        return chronic > 0 ? acute / chronic : nil
    }

    private func exerciseTrends(_ logs: [WorkoutLog]) -> [ExerciseTrend] {
        struct Visit { let date: Date; let e1RM: Double; let heaviest: Double }
        var visits: [ExerciseID: (ref: ExerciseRef, visits: [Visit])] = [:]
        for log in logs {
            for case .resistance(let performed) in log.blocks {
                let working = performed.sets.filter { !$0.isWarmup && $0.reps >= 1 && $0.weightKg > 0 }
                guard !working.isEmpty else { continue }
                let best = working.filter { $0.reps <= maxRepsForEstimate }.map { formula.estimate(weightKg: $0.weightKg, reps: $0.reps) }.max()
                    ?? working.map { formula.estimate(weightKg: $0.weightKg, reps: maxRepsForEstimate) }.max() ?? 0
                visits[performed.exercise.id, default: (performed.exercise, [])].visits
                    .append(Visit(date: log.effectiveDate, e1RM: best, heaviest: working.map(\.weightKg).max() ?? 0))
            }
        }
        return visits.values.compactMap { entry -> ExerciseTrend? in
            guard let first = entry.visits.first, let last = entry.visits.last else { return nil }
            var running = first.e1RM
            var records = 0
            for visit in entry.visits.dropFirst() where visit.e1RM > running + 1e-9 { records += 1; running = visit.e1RM }
            let earlier = entry.visits.dropLast(3).map(\.e1RM).max() ?? 0
            let recent = entry.visits.suffix(3).map(\.e1RM).max() ?? 0
            return ExerciseTrend(exercise: entry.ref, sessions: entry.visits.count, firstE1RM: first.e1RM, bestE1RM: entry.visits.map(\.e1RM).max() ?? 0,
                                 latestE1RM: last.e1RM, heaviestKg: entry.visits.map(\.heaviest).max() ?? 0, personalRecords: records,
                                 lastPerformed: last.date, isStagnant: entry.visits.count >= 4 && recent <= earlier + 1e-9)
        }
        .sorted { ($0.sessions, $1.exercise.name) > ($1.sessions, $0.exercise.name) }
    }

    private func adherence(_ logs: [WorkoutLog], plan: WorkoutPlan, now: Date) -> Adherence {
        let weeksSincePlan = max(1, Int((now.timeIntervalSince(plan.startDate) / (7 * 86_400)).rounded(.up)))
        let weeks = min(4, weeksSincePlan)
        let since = now.addingTimeInterval(-Double(weeks) * 7 * 86_400)
        let done = logs.filter { $0.effectiveDate > since && $0.effectiveDate <= now }.count
        return Adherence(completed: done, planned: plan.targetSessionsPerWeek * weeks)
    }

    private func restCompliance(_ logs: [WorkoutLog], plan: WorkoutPlan?) -> RestCompliance? {
        guard let plan else { return nil }
        var prescribed: [BlockID: Int] = [:]
        for template in plan.templates { for case .resistance(let block) in template.blocks { prescribed[block.id] = block.restSeconds } }
        var measured = 0, onTarget = 0, taken = 0, wanted = 0
        for log in logs {
            for case .resistance(let performed) in log.blocks {
                guard let rest = prescribed[performed.blockID], rest > 0 else { continue }
                for set in performed.sets where !set.isWarmup {
                    guard let seconds = set.restTakenSeconds else { continue }
                    measured += 1
                    taken += seconds
                    wanted += rest
                    if abs(Double(seconds - rest)) <= max(10, Double(rest) * restTolerance) { onTarget += 1 }
                }
            }
        }
        guard measured > 0 else { return nil }
        return RestCompliance(setsMeasured: measured, setsOnTarget: onTarget, averageTakenSeconds: Int((Double(taken) / Double(measured)).rounded()),
                              averagePrescribedSeconds: Int((Double(wanted) / Double(measured)).rounded()))
    }

    private func prescriptionAdherence(_ logs: [WorkoutLog], plan: WorkoutPlan?) -> PrescriptionAdherence? {
        guard let plan else { return nil }
        var prescribedCount = 0, done = 0, compared = 0, inRange = 0, withTarget = 0, atTarget = 0
        for log in logs {
            guard let template = plan.template(id: log.templateID) else { continue }
            for case .resistance(let block) in template.blocks {
                prescribedCount += block.sets.count
                guard let performed = log.blocks.compactMap({ entry -> ResistanceLog? in
                    if case .resistance(let r) = entry, r.blockID == block.id { return r } else { return nil }
                }).first else { continue }
                let working = performed.sets.filter { !$0.isWarmup }.sorted { $0.index < $1.index }
                done += min(working.count, block.sets.count)
                for (position, set) in working.enumerated() where position < block.sets.count {
                    let target = block.sets[position]
                    compared += 1
                    if (target.repsMin...max(target.repsMin, target.repsMax)).contains(set.reps) { inRange += 1 }
                    if let load = target.targetLoadKg, load > 0 {
                        withTarget += 1
                        if set.weightKg >= load * 0.975 { atTarget += 1 }          // 2.5 % under counts as "the load asked for" (plate rounding)
                    }
                }
            }
        }
        guard prescribedCount > 0 else { return nil }
        return PrescriptionAdherence(setsPrescribed: prescribedCount, setsDone: done, setsCompared: compared, setsInRepRange: inRange,
                                     setsWithLoadTarget: withTarget, setsAtLoadTarget: atTarget)
    }

    private func setsByMuscle(_ logs: [WorkoutLog], now: Date, muscles: (ExerciseID) -> [MuscleGroup]) -> [MuscleGroup: Int] {
        let since = now.addingTimeInterval(-7 * 86_400)
        var counts: [MuscleGroup: Int] = [:]
        for log in logs where log.effectiveDate > since {
            for case .resistance(let performed) in log.blocks {
                let working = performed.sets.filter { !$0.isWarmup }.count
                for muscle in muscles(performed.exercise.id) { counts[muscle, default: 0] += working }
            }
        }
        return counts
    }

    private func alerts(adherence: Adherence?, ratio: Double?, zone: WorkloadZone?, trends: [ExerciseTrend], rest: RestCompliance?, daysSince: Int?) -> [TrainingAlert] {
        var result: [TrainingAlert] = []
        if let daysSince, daysSince >= Self.noRecentSessionDays { result.append(.noRecentSession(days: daysSince)) }
        if let adherence, adherence.planned >= 3, adherence.ratio < Self.lowAdherenceBelow { result.append(.lowAdherence(percent: Int((adherence.ratio * 100).rounded()))) }
        if let ratio, zone == .high { result.append(.workloadSpike(ratio: ratio)) }
        if let ratio, ratio < Self.workloadDropBelow { result.append(.workloadDrop(ratio: ratio)) }
        for trend in trends where trend.isStagnant { result.append(.stagnant(exercise: trend.exercise, sessions: trend.sessions)); if result.count >= 6 { break } }
        if let rest, rest.setsMeasured >= Self.minimumRestSetsForAlert, rest.onTargetRatio < 0.5 { result.append(.restOffTarget(percent: Int((rest.onTargetRatio * 100).rounded()))) }
        return result
    }
}
