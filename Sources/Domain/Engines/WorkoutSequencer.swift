import Foundation

public struct NextWorkout: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case firstWorkout
        case continuedSequence
        case startedNewRotation
        case resumedInProgress
        /// The last performed template no longer exists in the (edited) plan.
        case recoveredFromPlanEdit
    }

    public let template: WorkoutTemplate
    /// Number of full rotations completed before this session; drives sequence-based periodization.
    public let rotationIndex: Int
    public let reason: Reason
    /// Set when `reason == .resumedInProgress`.
    public let resumableLogID: LogID?
}

/// Decides *which* workout is next from the **last completed workout in the sequence**,
/// not from the weekday. Miss Monday and the student simply does Monday's workout on Tuesday.
///
/// Rules
///  * `completed` and `skipped` logs advance the rotation; `abandoned` logs do not.
///  * A fresh `inProgress` log is resumed instead of starting a duplicate; one older than
///    `resumeWindow` is stale and ignored (the caller marks it abandoned).
///  * A session the trainer is running (`coachedBy`) is never the student's to resume: their own phone can't continue or finish it.
///  * If the last performed template was removed by a plan edit, pick the least-recently-performed
///    template so nothing is silently starved.
public struct WorkoutSequencer: Sendable {
    public var resumeWindow: TimeInterval

    public init(resumeWindow: TimeInterval = 8 * 3600) {
        self.resumeWindow = resumeWindow
    }

    public func isStale(_ log: WorkoutLog, now: Date) -> Bool {
        log.status == .inProgress && now.timeIntervalSince(log.startedAt) > resumeWindow
    }

    public func next(plan: WorkoutPlan, logs: [WorkoutLog], now: Date) -> NextWorkout? {
        let templates = plan.orderedTemplates
        guard !templates.isEmpty else { return nil }

        let planLogs = logs.filter { $0.planID == plan.id && !$0.meta.isDeleted }

        if let live = planLogs
            .filter({ $0.status == .inProgress && $0.coachedBy == nil && !isStale($0, now: now) })
            .max(by: { $0.startedAt < $1.startedAt }),
           let template = plan.template(id: live.templateID) {
            return NextWorkout(template: template, rotationIndex: live.rotationIndex,
                               reason: .resumedInProgress, resumableLogID: live.id)
        }

        let advancing = planLogs
            .filter { $0.status == .completed || $0.status == .skipped }
            .sorted { $0.effectiveDate < $1.effectiveDate }

        guard let last = advancing.last else {
            return NextWorkout(template: templates[0], rotationIndex: 0, reason: .firstWorkout, resumableLogID: nil)
        }

        if let position = templates.firstIndex(where: { $0.id == last.templateID }) {
            let nextPosition = (position + 1) % templates.count
            let wrapped = nextPosition == 0
            return NextWorkout(template: templates[nextPosition],
                               rotationIndex: last.rotationIndex + (wrapped ? 1 : 0),
                               reason: wrapped ? .startedNewRotation : .continuedSequence,
                               resumableLogID: nil)
        }

        var lastPerformed: [TemplateID: Date] = [:]
        for log in advancing { lastPerformed[log.templateID] = log.effectiveDate }
        let fallback = templates.min { lhs, rhs in
            switch (lastPerformed[lhs.id], lastPerformed[rhs.id]) {
            case (nil, nil): return lhs.order < rhs.order
            case (nil, _): return true
            case (_, nil): return false
            case let (l?, r?): return l != r ? l < r : lhs.order < rhs.order
            }
        } ?? templates[0]
        return NextWorkout(template: fallback, rotationIndex: last.rotationIndex,
                           reason: .recoveredFromPlanEdit, resumableLogID: nil)
    }
}
