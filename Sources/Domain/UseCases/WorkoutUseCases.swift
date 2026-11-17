import Foundation

/// Starts (or resumes) the student's next workout.
///
/// 1. Abandons stale in-progress logs (left open overnight) so they never block the rotation.
/// 2. Asks `WorkoutSequencer` for the next template from the last *completed* workout.
/// 3. Resumes a live in-progress log if one exists.
/// 4. Otherwise creates a new log with a frozen periodization snapshot.
public struct StartWorkoutUseCase: Sendable {
    public let logs: any WorkoutLogRepository
    public let sequencer: WorkoutSequencer
    public let now: @Sendable () -> Date
    public let calendar: Calendar

    public init(logs: any WorkoutLogRepository,
                sequencer: WorkoutSequencer = WorkoutSequencer(),
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.logs = logs
        self.sequencer = sequencer
        self.now = now
        self.calendar = calendar
    }

    /// - Parameter startedAt: when the session really began (e.g. the moment the student walked into the gym); defaults to now.
    public func execute(plan: WorkoutPlan, checkInID: CheckInID? = nil, startedAt: Date? = nil) async throws -> WorkoutLog {
        let timestamp = now()
        var history = try await logs.logs(studentID: plan.studentID, planID: plan.id, since: nil)

        // A trainer's unfinished session is the trainer's to close (a student's device may not write it).
        for index in history.indices where history[index].coachedBy == nil && sequencer.isStale(history[index], now: timestamp) {
            var stale = history[index]
            stale.status = .abandoned
            history[index] = try await logs.save(stale)
        }

        guard let next = sequencer.next(plan: plan, logs: history, now: timestamp) else {
            throw DomainError.invalidState("The plan has no workouts")
        }
        if let resumeID = next.resumableLogID, let existing = history.first(where: { $0.id == resumeID }) {
            return existing
        }

        var snapshot: PeriodizationSnapshot?
        if let periodization = plan.periodization {
            let week = periodization.weekIndex(rotationIndex: next.rotationIndex, now: timestamp, calendar: calendar)
            snapshot = periodization.resolve(weekIndex: week).map(PeriodizationSnapshot.init)
        }

        let focus = plan.focusCycle.map { $0.focus(forWeekIndex: $0.weekIndex(startDate: plan.startDate, now: timestamp, calendar: calendar)) }
        let log = WorkoutLog(planID: plan.id,
                             templateID: next.template.id,
                             templateLabel: next.template.label,
                             studentID: plan.studentID,
                             startedAt: startedAt ?? timestamp,
                             rotationIndex: next.rotationIndex,
                             periodization: snapshot,
                             focus: focus,
                             checkInID: checkInID,
                             meta: SyncMetadata(updatedAt: timestamp, lastWriterDeviceID: ""))
        return try await logs.save(log)
    }
}

/// Persists a block result into the in-progress log. Called after every logged set, so a crash or
/// dead battery loses at most the set being typed.
public struct RecordBlockUseCase: Sendable {
    public let logs: any WorkoutLogRepository

    public init(logs: any WorkoutLogRepository) {
        self.logs = logs
    }

    public func execute(_ blockLog: BlockLog, in log: WorkoutLog) async throws -> WorkoutLog {
        guard log.status == .inProgress else {
            throw DomainError.invalidState("Cannot record into a \(log.status.rawValue) workout")
        }
        var updated = log
        updated.record(blockLog)
        return try await logs.save(updated)
    }
}

/// Completes the workout and stores the post-workout RPE feedback.
public struct FinishWorkoutUseCase: Sendable {
    public let logs: any WorkoutLogRepository
    public let now: @Sendable () -> Date

    public init(logs: any WorkoutLogRepository, now: @escaping @Sendable () -> Date = { Date() }) {
        self.logs = logs
        self.now = now
    }

    public func execute(_ log: WorkoutLog, sessionRPE: Int, note: String?) async throws -> WorkoutLog {
        var finished = log
        try finished.complete(at: now(), sessionRPE: sessionRPE, note: note)
        return try await logs.save(finished)
    }

    public func skip(_ log: WorkoutLog) async throws -> WorkoutLog {
        guard log.status == .inProgress else {
            throw DomainError.invalidState("Only an in-progress workout can be skipped")
        }
        var skipped = log
        skipped.status = .skipped
        skipped.completedAt = now()
        return try await logs.save(skipped)
    }
}

/// Fills the not-yet-logged sets with a single load ("same load across all sets" quick logging).
public enum SameLoadPropagation {
    public static func apply(weightKg: Double, to pending: inout [Double], from index: Int) {
        guard index < pending.count else { return }
        for position in index..<pending.count { pending[position] = weightKg }
    }
}
