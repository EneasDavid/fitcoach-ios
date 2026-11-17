import Domain
import Foundation
import Observation

public struct SetRow: Identifiable, Equatable, Sendable {
    /// The prescribed set number (1-based).
    public let id: Int
    public let repsMin: Int
    public let repsMax: Int
    public var weightKg: Double
    public var reps: Int
    public var isDone: Bool
    public var completedAt: Date?
    public var restTakenSeconds: Int?
    /// What the student did in this set last session ("last time: 55 kg × 8").
    public let lastWeightKg: Double?
    public let lastReps: Int?
}

/// Real-time logging for one exercise.
///
/// Loads can be typed or nudged ±1 kg. **"Same load for all sets"** keeps the load that is already there and locks
/// the *pending* sets to it (one shared field drives them all).
///
/// **Completed-set invariant:** once a set is marked done, its load and reps are *locked*. The only way back is to
/// un-mark the **last performed set** — an undo that reverts exactly that set and leaves earlier completed sets
/// untouched. The rest timer, substitutions and per-set persistence all live here so the views stay thin.
@MainActor
@Observable
public final class ResistanceBlockViewModel: WorkoutBlockViewModel {
    public static let maxLoadKg = 1_000.0
    public static let maxReps = 100
    public static let restPresets = [30, 45, 60, 90, 120, 180]

    public let block: ResistanceBlock
    public private(set) var rows: [SetRow]
    public private(set) var sameLoadForAllSets: Bool
    public private(set) var restSeconds: Int
    public private(set) var activeExercise: ExerciseRef
    /// The prescribed exercise, when the student swapped it for a substitute.
    public private(set) var substitutedFor: ExerciseRef?
    /// The rest ran out and the student hasn't started the next set yet.
    public private(set) var restFinishedWaiting = false
    /// The set the student tapped to look at / correct; `nil` = follow the next pending set.
    public private(set) var focusedSetNumber: Int?
    public let restTimer: CountdownTimer
    public let detail: ExerciseDetailViewModel
    /// Set when the load in front of the student is the wrong way round for this week (see `FocusGuard`). Advisory: never blocks a set.
    public private(set) var focusWarning: FocusWarning?

    @ObservationIgnored private let context: BlockBuildContext
    @ObservationIgnored private var lastCompletion: (date: Date, reps: Int)?

    /// Which kind of week this is, for the small chip on the exercise screen.
    public var focusContext: FocusContext? { context.focus }

    public var blockID: BlockID { block.id }
    public var kind: WorkoutBlockKind { .resistance }
    public var title: String { activeExercise.name }
    public var isComplete: Bool { !rows.isEmpty && rows.allSatisfy(\.isDone) }
    public var completedSetCount: Int { rows.filter(\.isDone).count }
    public var iconName: String { "dumbbell.fill" }
    public var statusText: String? { completedSetCount == 0 ? nil : "\(completedSetCount)/\(rows.count)" }

    public var summary: String { block.summaryLine }

    public init(block: ResistanceBlock, context: BlockBuildContext) {
        self.block = block
        self.context = context
        self.restSeconds = block.restSeconds
        self.sameLoadForAllSets = block.sameLoadAcrossSets
        self.restTimer = CountdownTimer(now: context.now, autoTick: context.autoTick)

        var exercise = block.exercise
        var swappedFrom: ExerciseRef?
        var restoredSets: [Int: SetLog] = [:]
        if case .resistance(let log)? = context.restored[block.id] {
            for set in log.sets { restoredSets[set.index] = set }
            if let original = log.substitutedFor { swappedFrom = original; exercise = log.exercise }
        }
        self.activeExercise = exercise
        self.substitutedFor = swappedFrom
        self.detail = ExerciseDetailViewModel(planned: block.exercise, shown: exercise, catalog: context.catalog)

        let previous = context.previousLog(forExercise: exercise.id)
        var built: [SetRow] = []
        var carry: Double = 0
        for prescribed in block.sets.sorted(by: { $0.index < $1.index }) {
            let last = previous?.sets.first { $0.index == prescribed.index }
            if let done = restoredSets[prescribed.index] {
                built.append(SetRow(id: prescribed.index, repsMin: prescribed.repsMin, repsMax: prescribed.repsMax,
                                    weightKg: done.weightKg, reps: done.reps, isDone: true, completedAt: done.completedAt,
                                    restTakenSeconds: done.restTakenSeconds, lastWeightKg: last?.weightKg, lastReps: last?.reps))
                carry = done.weightKg
            } else {
                let suggested = last?.weightKg ?? prescribed.targetLoadKg ?? (carry > 0 ? carry : 0)
                built.append(SetRow(id: prescribed.index, repsMin: prescribed.repsMin, repsMax: prescribed.repsMax,
                                    weightKg: suggested, reps: prescribed.repsMin, isDone: false, completedAt: nil,
                                    restTakenSeconds: nil, lastWeightKg: last?.weightKg, lastReps: last?.reps))
                if suggested > 0 { carry = suggested }
            }
        }
        self.rows = built
        if let lastDone = built.last(where: \.isDone), let date = lastDone.completedAt {
            lastCompletion = (date, lastDone.reps)
        }
        if sameLoadForAllSets { applySharedLoad(sharedLoadKg) }
        restTimer.onFinish = { [weak self] in
            self?.restFinishedWaiting = true
            self?.context.feedback.restFinished()
        }
        refreshFocusWarning(haptic: false)
    }

    // MARK: Loads

    /// With "same load" on, pending sets can't be edited one by one: they mirror the shared load.
    public func isLoadLocked(_ row: SetRow) -> Bool { sameLoadForAllSets && !row.isDone }

    /// The load the pending sets share: the first pending set's, or the last set's when everything is done.
    public var sharedLoadKg: Double { (rows.first { !$0.isDone } ?? rows.last)?.weightKg ?? 0 }

    public var nextSetNumber: Int? { rows.first { !$0.isDone }?.id }

    /// The one set shown in the big card: the one the student tapped, else the next to do, else — when everything is done —
    /// the last performed set (the only one that can be un-done).
    public var activeSetNumber: Int? {
        if let focused = focusedSetNumber, rows.contains(where: { $0.id == focused }) { return focused }
        return nextSetNumber ?? lastDoneSetNumber ?? rows.last?.id
    }

    public func focus(set number: Int) {
        guard rows.contains(where: { $0.id == number }) else { return }
        focusedSetNumber = number
        refreshFocusWarning()
    }

    /// What the load control of the big card edits: with "same load" on, a pending set *is* the shared load.
    public func editLoad(_ kg: Double, forSet number: Int) {
        guard let row = rows.first(where: { $0.id == number }) else { return }
        if sameLoadForAllSets && !row.isDone { setSharedLoad(kg) } else { setWeight(kg, forSet: number) }
    }

    public func loadShown(forSet number: Int) -> Double {
        guard let row = rows.first(where: { $0.id == number }) else { return 0 }
        return sameLoadForAllSets && !row.isDone ? sharedLoadKg : row.weightKg
    }

    /// A completed set is read-only; a pending one can be edited (unless "same load" drives it).
    public func isEditable(_ row: SetRow) -> Bool { !row.isDone }

    public func setWeight(_ kg: Double, forSet number: Int) {
        guard let index = rows.firstIndex(where: { $0.id == number }), isEditable(rows[index]), !isLoadLocked(rows[index]) else { return }
        rows[index].weightKg = Self.clampLoad(kg)
        refreshFocusWarning()
    }

    public func nudgeWeight(by delta: Double, forSet number: Int) {
        guard let row = rows.first(where: { $0.id == number }) else { return }
        setWeight(row.weightKg + delta, forSet: number)
    }

    public func setReps(_ reps: Int, forSet number: Int) {
        guard let index = rows.firstIndex(where: { $0.id == number }), isEditable(rows[index]) else { return }
        rows[index].reps = max(1, min(reps, Self.maxReps))
    }

    public func nudgeReps(by delta: Int, forSet number: Int) {
        guard let row = rows.first(where: { $0.id == number }) else { return }
        setReps(row.reps + delta, forSet: number)
    }

    /// Turns "same load" on or off. Turning it on **keeps the load that is already there** (no reset to zero).
    public func setSameLoad(_ enabled: Bool) {
        let current = sharedLoadKg
        sameLoadForAllSets = enabled
        if enabled { applySharedLoad(current) }
    }

    /// Edits the one load every pending set follows.
    public func setSharedLoad(_ kg: Double) {
        guard sameLoadForAllSets else { return }
        applySharedLoad(Self.clampLoad(kg))
    }

    public func nudgeSharedLoad(by delta: Double) {
        setSharedLoad(sharedLoadKg + delta)
    }

    private func applySharedLoad(_ kg: Double) {
        for index in rows.indices where !rows[index].isDone { rows[index].weightKg = kg }
        refreshFocusWarning()
    }

    private static func clampLoad(_ kg: Double) -> Double {
        // Keep at most two decimals so typed values like 62.555 don't leak odd numbers into history.
        (max(0, min(kg, maxLoadKg)) * 100).rounded() / 100
    }

    // MARK: Completing sets

    /// Marks a set done, persists it and starts the rest timer (not after the last set).
    @discardableResult
    public func complete(set number: Int) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == number }), !rows[index].isDone else { return false }
        guard (1...Self.maxReps).contains(rows[index].reps), (0...Self.maxLoadKg).contains(rows[index].weightKg) else { return false }

        let moment = context.now()
        if let last = lastCompletion {
            // The gap between two completions includes the set itself; subtract an estimate of it.
            let gap = Int(moment.timeIntervalSince(last.date))
            rows[index].restTakenSeconds = max(0, gap - rows[index].reps * context.secondsPerRep)
        }
        rows[index].isDone = true
        rows[index].completedAt = moment
        lastCompletion = (moment, rows[index].reps)
        restFinishedWaiting = false
        if focusWarning != nil { context.feedback.warning() }               // completing a set against the week's focus: one more nudge
        focusedSetNumber = nil                                              // move on to the next set

        context.feedback.setLogged()
        emitLog()

        if rows.contains(where: { !$0.isDone }) {
            startRest()
        } else {
            skipRest()
        }
        refreshFocusWarning(haptic: false)
        return true
    }

    /// The set most recently marked done (by time; the higher set number wins a tie). The only one that can be un-done.
    public var lastDoneSetNumber: Int? {
        rows.filter(\.isDone).max { ($0.completedAt ?? .distantPast, $0.id) < ($1.completedAt ?? .distantPast, $1.id) }?.id
    }

    public func canUndo(set number: Int) -> Bool { lastDoneSetNumber == number }

    /// Un-marks the last performed set. Earlier completed sets keep their results and stay locked.
    @discardableResult
    public func undoLast() -> Bool {
        guard let number = lastDoneSetNumber else { return false }
        return undo(set: number)
    }

    /// Reverts the last performed set; it goes back to pending (editable again) and is removed from the saved log.
    /// Any other completed set is refused: results are undone in reverse order, never out of the middle.
    @discardableResult
    public func undo(set number: Int) -> Bool {
        guard canUndo(set: number), let index = rows.firstIndex(where: { $0.id == number }), rows[index].isDone else { return false }
        rows[index].isDone = false
        rows[index].completedAt = nil
        rows[index].restTakenSeconds = nil
        focusedSetNumber = number
        if sameLoadForAllSets { applySharedLoad(rows[index].weightKg) }
        lastCompletion = rows.last(where: \.isDone).flatMap { row in row.completedAt.map { ($0, row.reps) } }
        emitLog()
        refreshFocusWarning(haptic: false)
        return true
    }

    // MARK: Rest timer

    public func startRest() {
        restFinishedWaiting = false
        restTimer.start(TimeInterval(restSeconds))
        if let end = restTimer.endsAt { context.feedback.scheduleRestAlert(at: end) }
    }

    /// Chooses how long the rest between sets is (30 s … 3 min presets).
    public func setRestSeconds(_ seconds: Int) {
        restSeconds = max(15, min(seconds, 600))
    }

    /// ±15 s on the running timer; also becomes the default for the following sets.
    public func adjustRest(by seconds: Int) {
        restSeconds = max(15, min(restSeconds + seconds, 600))
        guard restTimer.isRunning || restTimer.isPaused else { return }
        restTimer.adjust(by: TimeInterval(seconds))
        context.feedback.cancelRestAlert()
        if let end = restTimer.endsAt { context.feedback.scheduleRestAlert(at: end) }
    }

    public func pauseRest() {
        guard restTimer.isRunning else { return }
        restTimer.pause()
        context.feedback.cancelRestAlert()
    }

    public func resumeRest() {
        guard restTimer.isPaused else { return }
        restTimer.resume()
        if let end = restTimer.endsAt { context.feedback.scheduleRestAlert(at: end) }
    }

    public func skipRest() {
        restTimer.stop()
        restFinishedWaiting = false
        context.feedback.cancelRestAlert()
    }

    public func dismissRestFinished() { restFinishedWaiting = false }

    // MARK: Substitution

    /// Swapping is only offered before the first set, so a workout never mixes two exercises under one name.
    public var canSubstitute: Bool { completedSetCount == 0 }

    public func substitute(with exercise: Exercise) {
        guard canSubstitute else { return }
        if exercise.id == block.exercise.id { return revertSubstitution() }
        activeExercise = ExerciseRef(exercise)
        substitutedFor = block.exercise
        detail.select(exercise)
        refreshFocusWarning()
    }

    public func revertSubstitution() {
        guard canSubstitute else { return }
        activeExercise = block.exercise
        substitutedFor = nil
        detail.revert()
        refreshFocusWarning()
    }

    // MARK: Focus (strength / volume weeks)

    /// Re-evaluates the load on the card against this week's focus. The haptic fires only when a warning *appears* or changes, so
    /// nudging the load up and down doesn't buzz on every tap.
    private func refreshFocusWarning(haptic: Bool = true) {
        var next: FocusWarning?
        if let focus = context.focus, let number = activeSetNumber, let row = rows.first(where: { $0.id == number }), !row.isDone {
            next = context.focusGuard.warning(exercise: activeExercise, loadKg: loadShown(forSet: number), in: focus)
        }
        if next != focusWarning {
            focusWarning = next
            if haptic, next != nil { context.feedback.warning() }
        }
    }

    // MARK: Persistence

    public func currentLog() -> BlockLog? {
        let log = resistanceLog()
        return log.sets.isEmpty ? nil : .resistance(log)
    }

    private func resistanceLog() -> ResistanceLog {
        let done = rows.filter(\.isDone).map { row in
            SetLog(id: "\(block.id)-\(row.id)", index: row.id, weightKg: row.weightKg, reps: row.reps,
                   restTakenSeconds: row.restTakenSeconds, completedAt: row.completedAt ?? context.now())
        }
        return ResistanceLog(blockID: block.id, exercise: activeExercise, substitutedFor: substitutedFor, sets: done)
    }

    /// Always emits — even an empty log — so undoing the only completed set also removes it from the stored workout.
    private func emitLog() {
        context.onBlockLogged(.resistance(resistanceLog()))
    }
}
