import Domain
import Foundation
import Observation

public enum RPEScale {
    public static let range = 1...10

    /// What the number means in plain words (Rate of Perceived Exertion, explained for non-experts).
    public static func explanation(for value: Int) -> String {
        switch value {
        case ...2: return String(localized: "Barely felt it.")
        case 3...4: return String(localized: "Easy. Plenty left in the tank.")
        case 5...6: return String(localized: "Comfortable, but you were working.")
        case 7...8: return String(localized: "Hard. You could have done 2–3 more reps.")
        case 9: return String(localized: "Very hard. Maybe one more rep.")
        default: return String(localized: "All-out. Nothing left.")
        }
    }

    public static func description(for value: Int) -> String {
        switch value {
        case ...2: return String(localized: "Very easy")
        case 3...4: return String(localized: "Easy")
        case 5...6: return String(localized: "Moderate")
        case 7...8: return String(localized: "Hard")
        case 9: return String(localized: "Very hard")
        default: return String(localized: "Max effort")
        }
    }
}

public enum ClockFormat {
    /// 75 → "1:15". Rounds up so a timer never shows 0:00 while still running.
    public static func minutesSeconds(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Draft of the post-workout feedback sheet (kept in a model, not in view `@State`, so it is testable).
@MainActor
@Observable
public final class RPEFeedbackDraft {
    public var rpe = 7.0
    public var note = ""
    public init() {}
    public var score: Int { max(RPEScale.range.lowerBound, min(Int(rpe.rounded()), RPEScale.range.upperBound)) }
}

/// What the trainer has in hand while running a workout next to the student: the whole exercise catalogue, to swap an exercise for any other
/// or add one that isn't in the plan. `nil` for a student's own workout.
public struct CoachingTools: Sendable {
    public let catalog: any ExerciseCatalogRepository
    /// Shown in the workout header: whose workout this is.
    public let studentName: String

    public init(catalog: any ExerciseCatalogRepository, studentName: String) {
        self.catalog = catalog
        self.studentName = studentName
    }
}

/// Screen model for one workout in progress. Every block reports into it; it persists each result
/// immediately (serially, so saves can't overtake each other) through the offline-first repository, which
/// means a crash, dead battery or no signal never loses more than the set being typed.
@MainActor
@Observable
public final class ActiveWorkoutViewModel {
    public enum Phase: Equatable, Sendable { case active, finishing, finished, skipped }

    public private(set) var log: WorkoutLog
    public private(set) var components: [WorkoutComponent] = []
    public private(set) var phase: Phase = .active
    public private(set) var errorMessage: String?
    public var isShowingFeedback = false
    public let feedbackDraft = RPEFeedbackDraft()
    /// Navigation: which exercise screen is open (empty = the overview).
    public var path: [BlockID] = []
    /// Set when the trainer runs this workout: swap any exercise, add one, and the header says whose workout it is.
    public let coaching: CoachingTools?
    /// Exercises added during this session (they aren't in the plan).
    public private(set) var addedBlocks: Set<BlockID> = []

    @ObservationIgnored private let record: RecordBlockUseCase
    @ObservationIgnored private let finishUseCase: FinishWorkoutUseCase
    @ObservationIgnored private let onFinished: (@MainActor (WorkoutLog) async -> Void)?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private let factory: any WorkoutComponentBuilding
    @ObservationIgnored private var buildContext: BlockBuildContext?

    public init(log: WorkoutLog,
                template: WorkoutTemplate,
                factory: any WorkoutComponentBuilding,
                record: RecordBlockUseCase,
                finish: FinishWorkoutUseCase,
                feedback: any FeedbackProviding = NoopFeedback(),
                previousSession: WorkoutLog? = nil,
                catalog: (any ExerciseCatalogRepository)? = nil,
                focus: FocusContext? = nil,
                coaching: CoachingTools? = nil,
                onFinished: (@MainActor (WorkoutLog) async -> Void)? = nil,
                now: @escaping @MainActor () -> Date = { Date() },
                autoTick: Bool = true) {
        self.log = log
        self.record = record
        self.finishUseCase = finish
        self.onFinished = onFinished
        self.factory = factory
        self.coaching = coaching

        var restored: [BlockID: BlockLog] = [:]
        for block in log.blocks { restored[block.blockID] = block }

        let context = BlockBuildContext(feedback: feedback, now: now, previousSession: previousSession,
                                        restored: restored, autoTick: autoTick, catalog: catalog, focus: focus,
                                        onBlockLogged: { [weak self] blockLog in self?.blockLogged(blockLog) })
        self.buildContext = context
        self.components = template.blocks.map { factory.makeComponent(for: $0, context: context) }
    }

    /// Run by the trainer, with the student next to them.
    public var isCoached: Bool { log.coachedBy != nil }

    /// Adds an exercise that isn't in the plan, at the end of this session. It is logged like any other (the history shows the exercise by name);
    /// the plan itself is edited from "Edit workouts".
    @discardableResult
    public func addExercise(_ exercise: Exercise, sets: Int = 3, repsMin: Int = 8, repsMax: Int = 12, restSeconds: Int = 90) -> BlockID? {
        guard coaching != nil, phase == .active, let buildContext else { return nil }
        let prescribed = (1...max(sets, 1)).map { PrescribedSet(index: $0, repsMin: repsMin, repsMax: max(repsMax, repsMin)) }
        let block = ResistanceBlock(exercise: ExerciseRef(exercise), sets: prescribed, restSeconds: restSeconds)
        components.append(factory.makeComponent(for: .resistance(block), context: buildContext))
        addedBlocks.insert(block.id)
        return block.id
    }

    public func component(for id: BlockID) -> WorkoutComponent? { components.first { $0.id == id } }

    /// The exercise whose rest timer is currently counting (so the overview can show a mini timer).
    public var restingBlock: ResistanceBlockViewModel? {
        components.compactMap { $0.viewModel as? ResistanceBlockViewModel }.first { $0.restTimer.isRunning || $0.restTimer.isPaused }
    }

    public var completedBlocks: Int { components.filter { $0.viewModel.isComplete }.count }
    public var progress: Double { components.isEmpty ? 0 : Double(completedBlocks) / Double(components.count) }
    public var canFinish: Bool { phase == .active && completedBlocks > 0 }

    private func blockLogged(_ blockLog: BlockLog) {
        let previous = saveChain
        saveChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                self.log = try await self.record.execute(blockLog, in: self.log)
                self.errorMessage = nil
            } catch {
                self.errorMessage = String(localized: "Couldn't save your last set. It will be retried.")
            }
        }
    }

    /// Waits until every queued save has reached the local store.
    public func flush() async {
        await saveChain?.value
    }

    /// "Save" on the feedback sheet.
    @discardableResult
    public func submitFeedback() async -> Bool {
        isShowingFeedback = false
        return await finish(sessionRPE: feedbackDraft.score, note: feedbackDraft.note)
    }

    @discardableResult
    public func finish(sessionRPE: Int, note: String?) async -> Bool {
        guard phase == .active else { return false }
        phase = .finishing
        await flush()
        do {
            log = try await finishUseCase.execute(log, sessionRPE: sessionRPE, note: note)
            phase = .finished
            // Side effects of a finished workout (the shareable card) run on their own: they must never hold up "Saved".
            if let onFinished { let finished = log; Task { await onFinished(finished) } }
            return true
        } catch {
            phase = .active
            errorMessage = (error as? DomainError).map(Self.message(for:)) ?? String(localized: "Couldn't finish the workout.")
            return false
        }
    }

    /// The "→" at the end of an exercise: opens the next one (replacing, not stacking), or goes back to the overview after the last.
    func nextAction(after id: BlockID) -> NextExerciseAction {
        guard let index = components.firstIndex(where: { $0.id == id }), index + 1 < components.count else {
            return NextExerciseAction(title: nil) { [weak self] in self?.path = [] }
        }
        let next = components[index + 1]
        return NextExerciseAction(title: next.viewModel.title) { [weak self] in self?.path = [next.id] }
    }

    public func skip() async {
        guard phase == .active else { return }
        await flush()
        if let skipped = try? await finishUseCase.skip(log) {
            log = skipped
            phase = .skipped
        }
    }

    private static func message(for error: DomainError) -> String {
        switch error {
        case .validation(let text), .invalidState(let text), .notFound(let text): return text
        }
    }
}
