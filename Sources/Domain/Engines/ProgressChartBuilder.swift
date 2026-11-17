import Foundation

/// What a chart measures. Every metric is a function over the working sets of the sessions it covers.
public enum ProgressMetric: String, Codable, Sendable, CaseIterable {
    /// Best estimated one-rep max (Epley). Needs one exercise.
    case estimatedOneRepMax
    /// Heaviest working-set load.
    case topSetLoad
    /// Σ load × reps.
    case volume
    /// Number of working sets.
    case workingSets
    case averageReps
    /// Mean rest the student actually took before a set.
    case averageRest

    /// Metrics that only make sense for a single exercise (mixing exercises would compare unlike loads).
    public var needsSingleExercise: Bool { self == .estimatedOneRepMax || self == .topSetLoad }

    public var unit: String {
        switch self {
        case .estimatedOneRepMax, .topSetLoad: return "kg"
        case .volume: return "kg"
        case .workingSets: return ""
        case .averageReps: return ""
        case .averageRest: return "s"
        }
    }
}

public enum ChartGrouping: String, Codable, Sendable, CaseIterable { case perSession, perWeek }
public enum ChartStyle: String, Codable, Sendable, CaseIterable { case line, bar }
public enum ChartRange: String, Codable, Sendable, CaseIterable {
    case fourWeeks, twelveWeeks, all

    public var weeks: Int? {
        switch self {
        case .fourWeeks: return 4
        case .twelveWeeks: return 12
        case .all: return nil
        }
    }
}

/// How the personal trainer chose to build a chart. Plain data (Codable), so a trainer's choice can be remembered per student.
public struct ChartConfiguration: Codable, Equatable, Sendable {
    public var metric: ProgressMetric
    /// `nil` = every exercise (only for metrics that allow it).
    public var exerciseID: ExerciseID?
    public var grouping: ChartGrouping
    public var style: ChartStyle
    public var range: ChartRange
    /// Stripe the chart by strength / volume weeks.
    public var showFocus: Bool

    public init(metric: ProgressMetric = .estimatedOneRepMax, exerciseID: ExerciseID? = nil, grouping: ChartGrouping = .perSession,
                style: ChartStyle = .line, range: ChartRange = .twelveWeeks, showFocus: Bool = true) {
        self.metric = metric
        self.exerciseID = exerciseID
        self.grouping = grouping
        self.style = style
        self.range = range
        self.showFocus = showFocus
    }

    /// A configuration that can actually be drawn: single-exercise metrics get an exercise.
    public func normalised(defaultExercise: ExerciseID?) -> ChartConfiguration {
        var copy = self
        if metric.needsSingleExercise, copy.exerciseID == nil { copy.exerciseID = defaultExercise }
        return copy
    }
}

public struct ChartPoint: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    /// Session date, or the first day of the week when grouped per week.
    public let date: Date
    public let value: Double
    /// How many sessions the point summarises.
    public let sessions: Int
    public let focus: TrainingFocus?
    public let isDeload: Bool
}

public struct ProgressChartBuilder: Sendable {
    public var calendar: Calendar
    public var formula: OneRepMaxFormula
    /// e1RM formulas degrade past ~12 reps (same limit as `ProgressionEngine`).
    public var maxRepsForEstimate: Int

    public init(calendar: Calendar = .current, formula: OneRepMaxFormula = .epley, maxRepsForEstimate: Int = 12) {
        self.calendar = calendar
        self.formula = formula
        self.maxRepsForEstimate = maxRepsForEstimate
    }

    /// Exercises the student has actually logged, most-logged first — what the trainer can pick from.
    public func exercises(in logs: [WorkoutLog]) -> [ExerciseRef] {
        var counts: [ExerciseID: (ref: ExerciseRef, sessions: Int)] = [:]
        for log in logs where log.status == .completed && !log.meta.isDeleted {
            var seen = Set<ExerciseID>()
            for case .resistance(let performed) in log.blocks where !performed.sets.isEmpty && seen.insert(performed.exercise.id).inserted {
                counts[performed.exercise.id, default: (performed.exercise, 0)].sessions += 1
            }
        }
        return counts.values.sorted { ($0.sessions, $1.ref.name) > ($1.sessions, $0.ref.name) }.map(\.ref)
    }

    public func points(logs: [WorkoutLog], configuration: ChartConfiguration, now: Date) -> [ChartPoint] {
        if configuration.metric.needsSingleExercise, configuration.exerciseID == nil { return [] }
        let cutoff = configuration.range.weeks.map { now.addingTimeInterval(-TimeInterval($0) * 7 * 86_400) }

        struct Session { let date: Date; let sets: [SetLog]; let focus: TrainingFocus?; let isDeload: Bool }
        let sessions: [Session] = logs
            .filter { $0.status == .completed && !$0.meta.isDeleted && (cutoff == nil || $0.effectiveDate >= cutoff!) && $0.effectiveDate <= now }
            .sorted { $0.effectiveDate < $1.effectiveDate }
            .compactMap { log in
                let sets = log.blocks.flatMap { block -> [SetLog] in
                    guard case .resistance(let performed) = block else { return [] }
                    if let wanted = configuration.exerciseID, performed.exercise.id != wanted { return [] }
                    return performed.sets.filter { !$0.isWarmup }
                }
                return sets.isEmpty ? nil : Session(date: log.effectiveDate, sets: sets, focus: log.focus, isDeload: !log.loadPhase.countsTowardProgression)
            }

        // Group: each session is its own point, or sessions of the same calendar week share one.
        var groups: [(date: Date, sessions: [Session])] = []
        for session in sessions {
            let key = configuration.grouping == .perWeek ? (calendar.dateInterval(of: .weekOfYear, for: session.date)?.start ?? session.date) : session.date
            if configuration.grouping == .perWeek, let last = groups.indices.last, groups[last].date == key {
                groups[last].sessions.append(session)
            } else {
                groups.append((key, [session]))
            }
        }

        return groups.compactMap { group in
            let sets = group.sessions.flatMap(\.sets)
            guard let value = value(of: configuration.metric, over: sets) else { return nil }
            return ChartPoint(date: group.date, value: value, sessions: group.sessions.count,
                              focus: group.sessions.last?.focus, isDeload: group.sessions.allSatisfy(\.isDeload))
        }
    }

    func value(of metric: ProgressMetric, over sets: [SetLog]) -> Double? {
        guard !sets.isEmpty else { return nil }
        switch metric {
        case .estimatedOneRepMax:
            return sets.filter { $0.reps <= maxRepsForEstimate }.map { formula.estimate(weightKg: $0.weightKg, reps: $0.reps) }.max()
        case .topSetLoad:
            return sets.map(\.weightKg).max()
        case .volume:
            return sets.reduce(0) { $0 + $1.volumeKg }
        case .workingSets:
            return Double(sets.count)
        case .averageReps:
            return Double(sets.reduce(0) { $0 + $1.reps }) / Double(sets.count)
        case .averageRest:
            let rests = sets.compactMap(\.restTakenSeconds)
            return rests.isEmpty ? nil : Double(rests.reduce(0, +)) / Double(rests.count)
        }
    }

    /// First → last value, in percent. `nil` with fewer than two points or a zero start.
    public func changePercent(_ points: [ChartPoint]) -> Double? {
        guard let first = points.first?.value, let last = points.last?.value, points.count > 1, first > 0 else { return nil }
        return (last - first) / first * 100
    }
}
