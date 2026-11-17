import Foundation

/// What a training week is for. **Strength**: heavier loads, fewer reps. **Volume** (repetição): lighter loads, more reps.
public enum TrainingFocus: String, Codable, Sendable, CaseIterable {
    case strength, volume

    public var opposite: TrainingFocus { self == .strength ? .volume : .strength }
}

/// The trainer's alternation: *N* weeks of strength, then *M* weeks of volume, repeating. Weeks are calendar weeks counted from the
/// plan's start date — they advance whether or not the student showed up, so "this is a volume week" is never ambiguous.
public struct FocusCycle: Codable, Equatable, Sendable {
    public var strengthWeeks: Int
    public var volumeWeeks: Int
    public var startsWith: TrainingFocus
    /// Rep ranges the trainer suggests for each kind of week (shown to the student; the warning itself looks at loads).
    public var strengthReps: ClosedRange<Int>
    public var volumeReps: ClosedRange<Int>

    public init(strengthWeeks: Int = 3, volumeWeeks: Int = 3, startsWith: TrainingFocus = .strength,
                strengthReps: ClosedRange<Int> = 3...6, volumeReps: ClosedRange<Int> = 10...15) {
        self.strengthWeeks = strengthWeeks
        self.volumeWeeks = volumeWeeks
        self.startsWith = startsWith
        self.strengthReps = strengthReps
        self.volumeReps = volumeReps
    }

    public var isValid: Bool { (1...12).contains(strengthWeeks) && (1...12).contains(volumeWeeks) }
    public var cycleLength: Int { max(strengthWeeks + volumeWeeks, 1) }

    public struct Position: Equatable, Sendable {
        public let focus: TrainingFocus
        /// 1-based week inside the current phase, and how many weeks the phase has.
        public let week: Int
        public let of: Int
    }

    public func position(forWeekIndex index: Int) -> Position {
        let inCycle = max(index, 0) % cycleLength
        let firstLength = startsWith == .strength ? strengthWeeks : volumeWeeks
        if inCycle < firstLength { return Position(focus: startsWith, week: inCycle + 1, of: firstLength) }
        return Position(focus: startsWith.opposite, week: inCycle - firstLength + 1, of: cycleLength - firstLength)
    }

    public func focus(forWeekIndex index: Int) -> TrainingFocus { position(forWeekIndex: index).focus }

    public func repRange(for focus: TrainingFocus) -> ClosedRange<Int> { focus == .strength ? strengthReps : volumeReps }

    /// Whole weeks elapsed since `startDate` (0 during the first week; never negative).
    public func weekIndex(startDate: Date, now: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate), to: calendar.startOfDay(for: now)).day ?? 0
        return max(days, 0) / 7
    }
}

// MARK: - The warning

/// Everything the exercise screen needs to know about *this* week: which kind it is, and the student's best loads in the
/// opposite kind of week (the yardstick for "you're lifting the wrong way round").
public struct FocusContext: Equatable, Sendable {
    public let focus: TrainingFocus
    public let weekInPhase: Int
    public let phaseWeeks: Int
    public let suggestedReps: ClosedRange<Int>
    /// Best working-set load per exercise during the most recent opposite-focus weeks.
    public let oppositeBestKg: [ExerciseID: Double]

    public init(focus: TrainingFocus, weekInPhase: Int, phaseWeeks: Int, suggestedReps: ClosedRange<Int>, oppositeBestKg: [ExerciseID: Double]) {
        self.focus = focus
        self.weekInPhase = weekInPhase
        self.phaseWeeks = phaseWeeks
        self.suggestedReps = suggestedReps
        self.oppositeBestKg = oppositeBestKg
    }
}

public enum FocusWarningKind: Equatable, Sendable {
    /// Volume week, but the load is above the student's strength-week best → "focus on execution".
    case heavierThanStrengthWeek
    /// Strength week, but the load is below the student's volume-week best → "this week is for load".
    case lighterThanVolumeWeek
}

public struct FocusWarning: Equatable, Sendable {
    public let kind: FocusWarningKind
    public let exercise: ExerciseRef
    public let loadKg: Double
    public let referenceKg: Double
}

public struct FocusGuard: Sendable {
    /// How far past the reference a load may go before it counts as inverted (0 = any excess warns).
    public var tolerancePercent: Double
    /// Only recent opposite-phase weeks are the yardstick: a strength week from last year says little about today.
    public var lookbackWeeks: Int

    public init(tolerancePercent: Double = 0, lookbackWeeks: Int = 16) {
        self.tolerancePercent = tolerancePercent
        self.lookbackWeeks = lookbackWeeks
    }

    /// `nil` when the plan has no focus cycle.
    public func context(plan: WorkoutPlan, logs: [WorkoutLog], now: Date, calendar: Calendar = .current) -> FocusContext? {
        guard let cycle = plan.focusCycle, cycle.isValid else { return nil }
        let position = cycle.position(forWeekIndex: cycle.weekIndex(startDate: plan.startDate, now: now, calendar: calendar))
        let cutoff = now.addingTimeInterval(-TimeInterval(lookbackWeeks) * 7 * 86_400)

        var best: [ExerciseID: Double] = [:]
        for log in logs where log.status == .completed && log.studentID == plan.studentID && !log.meta.isDeleted
            && log.focus == position.focus.opposite && log.effectiveDate >= cutoff {
            for case .resistance(let performed) in log.blocks {
                for set in performed.sets where !set.isWarmup {
                    best[performed.exercise.id] = max(best[performed.exercise.id] ?? 0, set.weightKg)
                }
            }
        }
        return FocusContext(focus: position.focus, weekInPhase: position.week, phaseWeeks: position.of,
                            suggestedReps: cycle.repRange(for: position.focus), oppositeBestKg: best)
    }

    public func warning(exercise: ExerciseRef, loadKg: Double, in context: FocusContext) -> FocusWarning? {
        guard loadKg > 0, let reference = context.oppositeBestKg[exercise.id], reference > 0 else { return nil }
        let factor = tolerancePercent / 100
        switch context.focus {
        case .volume where loadKg > reference * (1 + factor):
            return FocusWarning(kind: .heavierThanStrengthWeek, exercise: exercise, loadKg: loadKg, referenceKg: reference)
        case .strength where loadKg < reference * (1 - factor):
            return FocusWarning(kind: .lighterThanVolumeWeek, exercise: exercise, loadKg: loadKg, referenceKg: reference)
        default:
            return nil
        }
    }
}
