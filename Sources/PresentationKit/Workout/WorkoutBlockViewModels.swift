import Domain
import Foundation
import Observation

/// What the factory needs from any block's view model, regardless of block type.
@MainActor
public protocol WorkoutBlockViewModel: AnyObject {
    var blockID: BlockID { get }
    var kind: WorkoutBlockKind { get }
    var title: String { get }
    /// One line for the workout overview, e.g. "3 × 8–12 reps · 40 kg".
    var summary: String { get }
    /// Short progress label for the overview row, e.g. "2/3"; nil when there is nothing to report yet.
    var statusText: String? { get }
    /// SF Symbol for the overview row.
    var iconName: String { get }
    var isComplete: Bool { get }
    /// The student's recorded result so far (nil if nothing has been logged yet).
    func currentLog() -> BlockLog?
}

/// Everything a block view model needs from its environment.
@MainActor
public struct BlockBuildContext {
    public var feedback: any FeedbackProviding
    public var now: @MainActor () -> Date
    /// Same exercise last session — used to prefill loads.
    public var previousSession: WorkoutLog?
    /// Results already stored on the in-progress log (when resuming a workout).
    public var restored: [BlockID: BlockLog]
    public var onBlockLogged: @MainActor (BlockLog) -> Void
    /// Used to estimate rest from the gap between two sets.
    public var secondsPerRep: Int
    public var autoTick: Bool
    /// Exercise catalogue for videos, muscles and substitutions (nil = details unavailable, e.g. in unit tests).
    public var catalog: (any ExerciseCatalogRepository)?
    /// This week's strength/volume focus and the student's best loads in the opposite kind of week (nil = plan has no cycle).
    public var focus: FocusContext?
    public var focusGuard: FocusGuard

    public init(feedback: any FeedbackProviding = NoopFeedback(),
                now: @escaping @MainActor () -> Date = { Date() },
                previousSession: WorkoutLog? = nil,
                restored: [BlockID: BlockLog] = [:],
                secondsPerRep: Int = 3,
                autoTick: Bool = true,
                catalog: (any ExerciseCatalogRepository)? = nil,
                focus: FocusContext? = nil,
                focusGuard: FocusGuard = FocusGuard(),
                onBlockLogged: @escaping @MainActor (BlockLog) -> Void = { _ in }) {
        self.feedback = feedback
        self.now = now
        self.previousSession = previousSession
        self.restored = restored
        self.secondsPerRep = secondsPerRep
        self.autoTick = autoTick
        self.catalog = catalog
        self.focus = focus
        self.focusGuard = focusGuard
        self.onBlockLogged = onBlockLogged
    }

    func previousLog(forExercise id: ExerciseID) -> ResistanceLog? {
        guard let previousSession else { return nil }
        for case .resistance(let log) in previousSession.blocks where log.exercise.id == id { return log }
        return nil
    }
}

// MARK: - HIIT

@MainActor
@Observable
public final class HIITBlockViewModel: WorkoutBlockViewModel {
    public enum State: Equatable, Sendable { case ready, running, paused, finished }

    public let block: HIITBlock
    public let schedule: IntervalSchedule
    public let timer: CountdownTimer
    public private(set) var state: State = .ready
    public private(set) var segmentIndex = 0
    /// Work intervals the student actually completed (a skipped interval doesn't count).
    public private(set) var roundsCompleted = 0
    public var perceivedRPE: Double?

    @ObservationIgnored private let context: BlockBuildContext
    @ObservationIgnored private var elapsedBeforeSegment = 0

    public var blockID: BlockID { block.id }
    public var kind: WorkoutBlockKind { .hiit }
    public var title: String { block.title }
    public var summary: String { block.summaryLine }
    public var statusText: String? { state == .ready ? nil : "\(roundsCompleted)/\(block.rounds)" }
    public var iconName: String { "bolt.heart.fill" }
    public var isComplete: Bool { state == .finished }
    public var currentSegment: IntervalSegment? { schedule.segments.indices.contains(segmentIndex) ? schedule.segments[segmentIndex] : nil }
    public var elapsedSeconds: Int {
        elapsedBeforeSegment + ((state == .running || state == .paused) ? elapsedInSegment : 0)
    }

    private var elapsedInSegment: Int { Int((timer.duration - timer.liveRemaining).rounded()) }

    public init(block: HIITBlock, context: BlockBuildContext) {
        self.block = block
        self.context = context
        self.schedule = IntervalSchedule(rounds: block.rounds, workSeconds: block.workSeconds, restSeconds: block.restSeconds)
        self.timer = CountdownTimer(now: context.now, autoTick: context.autoTick)
        if case .hiit(let log)? = context.restored[block.id] {
            state = .finished
            perceivedRPE = log.rpe
            segmentIndex = max(0, schedule.segments.count - 1)
            elapsedBeforeSegment = log.totalSeconds
            roundsCompleted = log.roundsCompleted
        }
        timer.onFinish = { [weak self] in self?.segmentFinished() }
    }

    public func start() {
        guard state == .ready, currentSegment != nil else { return }
        state = .running
        timer.start(TimeInterval(currentSegment?.duration ?? 0))
    }

    public func pause() {
        guard state == .running else { return }
        timer.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        timer.resume()
        state = .running
    }

    /// Jumps to the next segment (e.g. the student can't finish the work interval).
    public func skipSegment() {
        guard state == .running || state == .paused else { return }
        elapsedBeforeSegment += elapsedInSegment
        timer.stop()
        advance()
    }

    public func finishEarly() {
        guard state != .finished else { return }
        if state == .running || state == .paused { elapsedBeforeSegment += elapsedInSegment }
        timer.stop()
        complete()
    }

    private func segmentFinished() {
        if currentSegment?.kind == .work { roundsCompleted += 1 }
        elapsedBeforeSegment += currentSegment?.duration ?? 0
        advance()
    }

    private func advance() {
        segmentIndex += 1
        if let next = currentSegment {
            context.feedback.intervalChanged()
            state = .running
            timer.start(TimeInterval(next.duration))
        } else {
            segmentIndex = max(0, schedule.segments.count - 1)
            complete()
        }
    }

    private func complete() {
        state = .finished
        context.feedback.restFinished()
        if let log = currentLog() { context.onBlockLogged(log) }
    }

    public func currentLog() -> BlockLog? {
        guard state == .finished else { return nil }
        return .hiit(HIITLog(blockID: block.id, roundsCompleted: min(roundsCompleted, block.rounds),
                             totalSeconds: elapsedBeforeSegment, rpe: perceivedRPE))
    }
}

// MARK: - Cardio

@MainActor
@Observable
public final class CardioBlockViewModel: WorkoutBlockViewModel {
    public let block: CardioBlock
    public private(set) var isRunning = false
    public private(set) var isFinished = false
    public private(set) var distanceKm: Double?
    public private(set) var averageHeartRate: Int?
    /// Raw field contents; parsed (and range-checked) when the student finishes.
    public var distanceText = ""
    public var heartRateText = ""

    @ObservationIgnored private let context: BlockBuildContext
    @ObservationIgnored private var runStart: Date?
    @ObservationIgnored private var accumulated: TimeInterval = 0

    public var blockID: BlockID { block.id }
    public var kind: WorkoutBlockKind { .cardio }
    public var title: String { block.modality.displayName }
    public var summary: String { block.summaryLine }
    public var statusText: String? { isFinished ? String(localized: "Done") : nil }
    public var iconName: String { block.modality.systemImage }
    public var isComplete: Bool { isFinished }

    public init(block: CardioBlock, context: BlockBuildContext) {
        self.block = block
        self.context = context
        if case .cardio(let log)? = context.restored[block.id] {
            isFinished = true
            accumulated = TimeInterval(log.durationSeconds)
            distanceKm = log.distanceMeters.map { $0 / 1_000 }
            averageHeartRate = log.averageHeartRate
            distanceText = distanceKm.map { String($0) } ?? ""
            heartRateText = averageHeartRate.map { String($0) } ?? ""
        }
    }

    public func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runStart.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    public func progress(at date: Date) -> Double {
        block.targetDurationSeconds > 0 ? min(1, elapsed(at: date) / Double(block.targetDurationSeconds)) : 0
    }

    public func start() {
        guard !isRunning, !isFinished else { return }
        runStart = context.now()
        isRunning = true
    }

    public func pause() {
        guard isRunning else { return }
        accumulated = elapsed(at: context.now())
        runStart = nil
        isRunning = false
    }

    public func finish() {
        guard !isFinished else { return }
        pause()
        // Input validation (OWASP M4): accept decimal commas, reject nonsense instead of storing it.
        distanceKm = Double(distanceText.replacingOccurrences(of: ",", with: ".")).flatMap { (0...500).contains($0) ? $0 : nil }
        averageHeartRate = Int(heartRateText).flatMap { (30...250).contains($0) ? $0 : nil }
        isFinished = true
        context.feedback.setLogged()
        if let log = currentLog() { context.onBlockLogged(log) }
    }

    public func currentLog() -> BlockLog? {
        guard isFinished else { return nil }
        return .cardio(CardioLog(blockID: block.id, modality: block.modality, durationSeconds: Int(accumulated),
                                 distanceMeters: distanceKm.map { $0 * 1_000 }, averageHeartRate: averageHeartRate))
    }
}

// MARK: - Placeholder for block types from a newer app version

@MainActor
public final class UnsupportedBlockViewModel: WorkoutBlockViewModel {
    public let originalType: String
    public let blockID: BlockID
    public var kind: WorkoutBlockKind { .unsupported }
    public var title: String { String(localized: "Unsupported exercise block") }
    public var summary: String { String(localized: "Update the app to see this block") }
    public var statusText: String? { nil }
    public var iconName: String { "exclamationmark.triangle.fill" }
    /// Never blocks the student from finishing their workout.
    public var isComplete: Bool { true }

    public init(block: UnsupportedBlock) {
        originalType = block.originalType
        blockID = block.id
    }

    public func currentLog() -> BlockLog? { nil }
}

public extension CardioModality {
    var displayName: String {
        switch self {
        case .run: return String(localized: "Run")
        case .walk: return String(localized: "Walk")
        case .bike: return String(localized: "Bike")
        case .row: return String(localized: "Row")
        case .elliptical: return String(localized: "Elliptical")
        case .swim: return String(localized: "Swim")
        case .stairs: return String(localized: "Stairs")
        }
    }

    var systemImage: String {
        switch self {
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        case .bike: return "figure.indoor.cycle"
        case .row: return "figure.rower"
        case .elliptical: return "figure.elliptical"
        case .swim: return "figure.pool.swim"
        case .stairs: return "figure.stairs"
        }
    }
}
