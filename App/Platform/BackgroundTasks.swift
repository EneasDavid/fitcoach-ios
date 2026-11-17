import BackgroundTasks
import Domain
import Foundation
import SyncKit

// NOT COMPILED IN THE AUTHORING ENVIRONMENT — see README → "Verification status".
// Both identifiers must be listed in Info.plist → BGTaskSchedulerPermittedIdentifiers (see project.yml)
// and the "Background fetch" / "Background processing" modes enabled.

enum BackgroundTaskID {
    static let sync = "com.fitcoach.app.sync"
    static let reminders = "com.fitcoach.app.reminders"
}

/// Two opportunistic background jobs:
///  * **sync** — drains the mutation queue even if the student never reopens the app after a workout;
///  * **reminders** — re-plans proactive training reminders from the latest cadence and next workout.
/// iOS decides *when* these run; they are a safety net, not a scheduler. Foreground sync (on reconnect and
/// after every save) remains the primary path.
final class BackgroundTasks {
    private let dispatcher: SyncDispatcher
    private let refreshReminders: @Sendable () async -> Void

    init(dispatcher: SyncDispatcher, refreshReminders: @escaping @Sendable () async -> Void) {
        self.dispatcher = dispatcher
        self.refreshReminders = refreshReminders
    }

    /// Must run before the app finishes launching (`application(_:didFinishLaunchingWithOptions:)`).
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskID.sync, using: nil) { [self] task in
            run(task, next: BackgroundTaskID.sync, earliest: 15 * 60) { await dispatcher.drain() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskID.reminders, using: nil) { [self] task in
            run(task, next: BackgroundTaskID.reminders, earliest: 6 * 3600) { await refreshReminders() }
        }
    }

    /// Call when the app moves to the background.
    func scheduleAll() {
        schedule(BackgroundTaskID.sync, earliest: 15 * 60)
        schedule(BackgroundTaskID.reminders, earliest: 6 * 3600)
    }

    private func schedule(_ identifier: String, earliest: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func run(_ task: BGTask, next identifier: String, earliest: TimeInterval, work: @escaping @Sendable () async -> Void) {
        schedule(identifier, earliest: earliest)                 // always queue the next run first
        let job = Task {
            await work()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { job.cancel() }
    }
}

/// Plans the next week of reminders from history (see `CadenceAnalyzer`).
struct ReminderRefresher: Sendable {
    let studentID: UserID
    let plans: any WorkoutPlanRepository
    let logs: any WorkoutLogRepository
    let notifier: any LocalNotificationScheduling

    func refresh(now: Date = Date()) async {
        guard let plan = try? await plans.activePlan(studentID: studentID),
              let history = try? await logs.logs(studentID: studentID, planID: plan.id, since: nil) else { return }
        let analyzer = CadenceAnalyzer()
        let slots = analyzer.typicalSlots(from: history, now: now)
        let next = WorkoutSequencer().next(plan: plan, logs: history, now: now)
        let reminders = analyzer.reminders(slots: slots, logs: history, nextWorkoutLabel: next?.template.label, now: now)
        try? await notifier.replacePending(category: LocalNotification.trainingReminderCategory, with: reminders)
    }
}
