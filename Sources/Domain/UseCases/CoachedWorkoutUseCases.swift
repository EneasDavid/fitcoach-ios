import Foundation

/// Starts (or resumes) a workout that the **trainer** runs on their own device, with the student next to them.
///
/// The session is an ordinary `WorkoutLog` marked `coachedBy`, stored in the trainer-written collection, so it joins the student's history, the
/// rotation and every metric without a special case — and a student's device can neither start nor edit one.
public struct StartCoachedWorkoutUseCase: Sendable {
    public let logs: any WorkoutLogRepository
    public let trainerID: UserID
    public let sequencer: WorkoutSequencer
    public let now: @Sendable () -> Date
    public let calendar: Calendar

    public init(logs: any WorkoutLogRepository, trainerID: UserID, sequencer: WorkoutSequencer = WorkoutSequencer(),
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.logs = logs
        self.trainerID = trainerID
        self.sequencer = sequencer
        self.now = now
        self.calendar = calendar
    }

    /// An unfinished session this trainer already started for the student (the app was closed, the phone died) — what "Run workout" offers to continue.
    public func resumable(plan: WorkoutPlan) async throws -> WorkoutLog? {
        let timestamp = now()
        return try await logs.logs(studentID: plan.studentID, planID: plan.id, since: nil)
            .first { $0.coachedBy == trainerID && $0.status == .inProgress && !$0.meta.isDeleted && !sequencer.isStale($0, now: timestamp) }
    }

    /// The workout the rotation says is next. The student's own unfinished sessions and the trainer's are set aside, so neither decides it.
    public func suggestedTemplate(plan: WorkoutPlan) async throws -> WorkoutTemplate? {
        let history = try await logs.logs(studentID: plan.studentID, planID: plan.id, since: nil).filter { $0.status != .inProgress }
        return sequencer.next(plan: plan, logs: history, now: now())?.template
    }

    /// - Parameter templateID: the workout to run; `nil` = the next one in the rotation.
    public func execute(plan: WorkoutPlan, templateID: TemplateID? = nil) async throws -> WorkoutLog {
        guard plan.trainerID == trainerID else { throw DomainError.invalidState("Only the plan's own trainer can run its workouts") }
        let timestamp = now()
        var history = try await logs.logs(studentID: plan.studentID, planID: plan.id, since: nil)

        // Close anything this trainer left open too long, and anything open for a different workout than the one chosen now.
        for index in history.indices where history[index].coachedBy == trainerID && history[index].status == .inProgress {
            let other = templateID.map { $0 != history[index].templateID } ?? false
            guard sequencer.isStale(history[index], now: timestamp) || other else { continue }
            var abandoned = history[index]
            abandoned.status = .abandoned
            history[index] = try await logs.save(abandoned)
        }
        if let live = history.first(where: { $0.coachedBy == trainerID && $0.status == .inProgress && !$0.meta.isDeleted }) { return live }

        let settled = history.filter { $0.status != .inProgress }
        guard let next = sequencer.next(plan: plan, logs: settled, now: timestamp) else { throw DomainError.invalidState("The plan has no workouts") }
        let template: WorkoutTemplate
        if let templateID {
            guard let chosen = plan.template(id: templateID) else { throw DomainError.notFound("That workout is not in the plan") }
            template = chosen
        } else {
            template = next.template
        }

        let focus = plan.focusCycle.map { $0.focus(forWeekIndex: $0.weekIndex(startDate: plan.startDate, now: timestamp, calendar: calendar)) }
        var snapshot: PeriodizationSnapshot?
        if let periodization = plan.periodization {
            let week = periodization.weekIndex(rotationIndex: next.rotationIndex, now: timestamp, calendar: calendar)
            snapshot = periodization.resolve(weekIndex: week).map(PeriodizationSnapshot.init)
        }
        let log = WorkoutLog(planID: plan.id, templateID: template.id, templateLabel: template.label, studentID: plan.studentID, startedAt: timestamp,
                             rotationIndex: next.rotationIndex, periodization: snapshot, focus: focus, coachedBy: trainerID,
                             meta: SyncMetadata(updatedAt: timestamp, lastWriterDeviceID: ""))
        return try await logs.save(log)
    }
}
