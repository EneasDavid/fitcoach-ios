import Foundation

// MARK: - Configuration

public enum OneRepMaxFormula: Sendable {
    case epley, brzycki, lombardi

    /// Estimated one-rep max (kg). Returns 0 for invalid input.
    public func estimate(weightKg: Double, reps: Int) -> Double {
        guard weightKg > 0, reps >= 1 else { return 0 }
        if reps == 1 { return weightKg }
        let r = Double(reps)
        switch self {
        case .epley: return weightKg * (1 + r / 30)
        case .brzycki: return reps >= 37 ? 0 : weightKg * 36 / (37 - r)
        case .lombardi: return weightKg * pow(r, 0.10)
        }
    }
}

public struct ProgressionConfig: Sendable {
    public var formula: OneRepMaxFormula
    /// e1RM formulas degrade quickly past ~10–12 reps; higher-rep sets still count for volume.
    public var maxRepsForEstimate: Int
    public var countWarmups: Bool
    public var minimumTrendPoints: Int
    /// Slope (percent of mean e1RM per *working* week) that counts as a plateau.
    public var plateauBand: ClosedRange<Double>

    public init(formula: OneRepMaxFormula = .epley,
                maxRepsForEstimate: Int = 12,
                countWarmups: Bool = false,
                minimumTrendPoints: Int = 3,
                plateauBand: ClosedRange<Double> = -0.25...0.25) {
        self.formula = formula
        self.maxRepsForEstimate = maxRepsForEstimate
        self.countWarmups = countWarmups
        self.minimumTrendPoints = minimumTrendPoints
        self.plateauBand = plateauBand
    }
}

// MARK: - Output

public struct ProgressionPoint: Equatable, Sendable, Identifiable {
    public var id: LogID { logID }
    public let logID: LogID
    public let date: Date
    /// Global week ordinal from the plan (or calendar weeks since the first log as a fallback).
    public let weekIndex: Int
    /// `weekIndex` with deload weeks collapsed out. This is the x-axis of the trend line, so a
    /// deload never stretches or dents the curve.
    public let effectiveWeek: Int
    public let phase: LoadPhase
    public let bestE1RMKg: Double?
    public let topSetWeightKg: Double
    public let topSetReps: Int
    public let workingSets: Int
    /// Σ weight × reps over working sets, as performed.
    public let tonnageKg: Double
    /// Tonnage divided by the week's planned volume multiplier, so a planned 85 %-volume week is
    /// comparable to a 100 % week. Equal to `tonnageKg` for deload points (which are never compared).
    public let normalizedTonnageKg: Double
    /// e1RM change versus the previous *working* session; deload sessions are skipped on both sides.
    public var changeVsPreviousWorkingPercent: Double?

    public var isDeload: Bool { !phase.countsTowardProgression }
    public var isTrendEligible: Bool { !isDeload && bestE1RMKg != nil }
}

public struct Trend: Equatable, Sendable {
    public let slopeKgPerWeek: Double
    public let interceptKg: Double
    public let slopePercentPerWeek: Double
    public let r2: Double
    public let sampleCount: Int
}

public enum OverloadVerdict: String, Sendable {
    case insufficientData, progressing, plateau, regressing
}

public struct PersonalRecord: Equatable, Sendable {
    public let logID: LogID
    public let date: Date
    public let e1RMKg: Double
    public let weightKg: Double
    public let reps: Int
}

public struct ProgressionSeries: Equatable, Sendable {
    public let exerciseID: ExerciseID
    /// Every session, chronological — including deload sessions (flagged) so charts can show them.
    public let points: [ProgressionPoint]
    public let trend: Trend?
    public let personalRecords: [PersonalRecord]
    public let verdict: OverloadVerdict

    public var trendPoints: [ProgressionPoint] { points.filter(\.isTrendEligible) }
    public var deloadPoints: [ProgressionPoint] { points.filter(\.isDeload) }

    /// First working e1RM → latest working e1RM, in percent.
    public var changePercent: Double? {
        let working = trendPoints
        guard let first = working.first?.bestE1RMKg, let last = working.last?.bestE1RMKg, first > 0, working.count > 1 else { return nil }
        return (last - first) / first * 100
    }

    static func empty(_ id: ExerciseID) -> ProgressionSeries {
        ProgressionSeries(exerciseID: id, points: [], trend: nil, personalRecords: [], verdict: .insufficientData)
    }
}

public struct WeeklyVolume: Equatable, Sendable {
    public let weekIndex: Int
    public let phase: LoadPhase
    public let sessions: Int
    public let workingSets: Int
    public let tonnageKg: Double
    public let normalizedTonnageKg: Double
    public var isDeload: Bool { !phase.countsTowardProgression }
}

// MARK: - Engine

/// Progressive-overload analytics.
///
/// **Deload rule.** Sessions performed in a `.deload` microcycle are *recorded* (they show up in
/// `points`, flagged) but are excluded from:
///   * the regression trend and its verdict,
///   * personal-record detection,
///   * the "previous session" baseline used for session-over-session change, and
///   * the x-axis (deload weeks are collapsed so slope is "kg per training-effective week").
/// The phase comes from the snapshot frozen on each `WorkoutLog` — never re-derived from the
/// current plan — so editing periodization later cannot rewrite history.
public struct ProgressionEngine: Sendable {
    public var config: ProgressionConfig

    public init(config: ProgressionConfig = .init()) {
        self.config = config
    }

    public func series(for exerciseID: ExerciseID,
                       logs: [WorkoutLog],
                       periodization: PeriodizationPlan? = nil,
                       calendar: Calendar = .current) -> ProgressionSeries {
        let completed = Self.completed(logs)
        guard let origin = completed.first?.effectiveDate else { return .empty(exerciseID) }

        let ordinals = completed.map { Self.weekOrdinal(of: $0, origin: origin, calendar: calendar) }
        var deloadOrdinals = Set(zip(completed, ordinals).filter { $0.0.loadPhase == .deload }.map(\.1))
        if let periodization, let maxOrdinal = ordinals.max() {
            // Covers deload weeks in which the student logged nothing: they still collapse out of the x-axis.
            deloadOrdinals.formUnion(periodization.deloadWeekIndices(upTo: maxOrdinal))
        }

        var points: [ProgressionPoint] = []
        for (log, ordinal) in zip(completed, ordinals) {
            let sets = workingSets(in: log, exerciseID: exerciseID)
            guard let top = sets.max(by: { ($0.weightKg, $0.reps) < ($1.weightKg, $1.reps) }) else { continue }

            let phase = log.loadPhase
            let tonnage = sets.reduce(0) { $0 + $1.volumeKg }
            let multiplier = max(log.periodization?.volumeMultiplier ?? 1.0, 0.1)
            let best = sets
                .filter { $0.reps <= config.maxRepsForEstimate }
                .map { config.formula.estimate(weightKg: $0.weightKg, reps: $0.reps) }
                .max()

            points.append(ProgressionPoint(
                logID: log.id,
                date: log.effectiveDate,
                weekIndex: ordinal,
                effectiveWeek: ordinal - deloadOrdinals.filter { $0 < ordinal }.count,
                phase: phase,
                bestE1RMKg: best,
                topSetWeightKg: top.weightKg,
                topSetReps: top.reps,
                workingSets: sets.count,
                tonnageKg: tonnage,
                normalizedTonnageKg: phase.countsTowardProgression ? tonnage / multiplier : tonnage,
                changeVsPreviousWorkingPercent: nil))
        }

        var records: [PersonalRecord] = []
        var previousWorking: Double?
        var bestSoFar: Double?
        for index in points.indices {
            guard points[index].isTrendEligible, let e1rm = points[index].bestE1RMKg else { continue }
            if let previous = previousWorking, previous > 0 {
                points[index].changeVsPreviousWorkingPercent = (e1rm - previous) / previous * 100
            }
            if let best = bestSoFar {
                if e1rm > best + 1e-9 {
                    records.append(PersonalRecord(logID: points[index].logID,
                                                  date: points[index].date,
                                                  e1RMKg: e1rm,
                                                  weightKg: points[index].topSetWeightKg,
                                                  reps: points[index].topSetReps))
                    bestSoFar = e1rm
                }
            } else {
                bestSoFar = e1rm   // first working session is the baseline, not a "record"
            }
            previousWorking = e1rm
        }

        let working = points.filter(\.isTrendEligible)
        var trend: Trend?
        if working.count >= config.minimumTrendPoints,
           let fit = LinearRegression.fit(xs: working.map { Double($0.effectiveWeek) },
                                          ys: working.compactMap(\.bestE1RMKg)) {
            let mean = working.compactMap(\.bestE1RMKg).reduce(0, +) / Double(working.count)
            trend = Trend(slopeKgPerWeek: fit.slope,
                          interceptKg: fit.intercept,
                          slopePercentPerWeek: mean > 0 ? fit.slope / mean * 100 : 0,
                          r2: fit.r2,
                          sampleCount: working.count)
        }

        return ProgressionSeries(exerciseID: exerciseID,
                                 points: points,
                                 trend: trend,
                                 personalRecords: records,
                                 verdict: verdict(for: trend))
    }

    public func verdict(for trend: Trend?) -> OverloadVerdict {
        guard let trend else { return .insufficientData }
        if trend.slopePercentPerWeek > config.plateauBand.upperBound { return .progressing }
        if trend.slopePercentPerWeek < config.plateauBand.lowerBound { return .regressing }
        return .plateau
    }

    /// Weekly resistance volume across all exercises. Deload weeks are flagged so dashboards can
    /// shade them rather than read them as a drop in training.
    public func weeklyVolume(logs: [WorkoutLog], calendar: Calendar = .current) -> [WeeklyVolume] {
        let completed = Self.completed(logs)
        guard let origin = completed.first?.effectiveDate else { return [] }

        var buckets: [Int: [WorkoutLog]] = [:]
        for log in completed {
            buckets[Self.weekOrdinal(of: log, origin: origin, calendar: calendar), default: []].append(log)
        }

        return buckets.keys.sorted().map { week in
            let weekLogs = buckets[week] ?? []
            let phase: LoadPhase = weekLogs.contains { $0.loadPhase == .deload } ? .deload : (weekLogs.first?.loadPhase ?? .high)
            var sets = 0
            var tonnage = 0.0
            var normalized = 0.0
            for log in weekLogs {
                let multiplier = max(log.periodization?.volumeMultiplier ?? 1.0, 0.1)
                for case .resistance(let resistance) in log.blocks {
                    let working = resistance.sets.filter { isWorking($0) }
                    sets += working.count
                    let volume = working.reduce(0) { $0 + $1.volumeKg }
                    tonnage += volume
                    normalized += log.loadPhase.countsTowardProgression ? volume / multiplier : volume
                }
            }
            return WeeklyVolume(weekIndex: week, phase: phase, sessions: weekLogs.count,
                                workingSets: sets, tonnageKg: tonnage, normalizedTonnageKg: normalized)
        }
    }

    // MARK: Helpers

    private static func completed(_ logs: [WorkoutLog]) -> [WorkoutLog] {
        logs.filter { $0.status == .completed && !$0.meta.isDeleted }
            .sorted { $0.effectiveDate < $1.effectiveDate }
    }

    private static func weekOrdinal(of log: WorkoutLog, origin: Date, calendar: Calendar) -> Int {
        if let snapshot = log.periodization { return snapshot.weekIndex }
        let start = calendar.startOfDay(for: origin)
        let day = calendar.startOfDay(for: log.effectiveDate)
        let days = calendar.dateComponents([.day], from: start, to: day).day ?? 0
        return max(0, days / 7)
    }

    private func isWorking(_ set: SetLog) -> Bool {
        (config.countWarmups || !set.isWarmup) && set.weightKg > 0 && set.reps > 0
    }

    private func workingSets(in log: WorkoutLog, exerciseID: ExerciseID) -> [SetLog] {
        log.blocks.flatMap { block -> [SetLog] in
            guard case .resistance(let resistance) = block, resistance.exercise.id == exerciseID else { return [] }
            return resistance.sets.filter { isWorking($0) }
        }
    }
}

enum LinearRegression {
    /// Ordinary least squares. Returns nil for < 2 points or when every x is identical.
    static func fit(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double, r2: Double)? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
            syy += (y - meanY) * (y - meanY)
        }
        guard sxx > 1e-12 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        var residual = 0.0
        for (x, y) in zip(xs, ys) {
            let error = y - (intercept + slope * x)
            residual += error * error
        }
        let r2 = syy < 1e-12 ? 1.0 : 1 - residual / syy
        return (slope, intercept, r2)
    }
}
