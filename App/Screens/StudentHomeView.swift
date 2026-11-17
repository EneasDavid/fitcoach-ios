import Domain
import Observation
import PresentationKit
import SwiftUI
import SyncKit

/// Student landing screen: today's workout (from the *sequence*, not the weekday), a preview of what's in it,
/// one big button to start, and a small sync indicator.
@MainActor
@Observable
final class StudentHomeViewModel {
    private(set) var plan: WorkoutPlan?
    private(set) var next: NextWorkout?
    private(set) var activeWorkout: ActiveWorkoutViewModel?
    private(set) var errorMessage: String?

    @ObservationIgnored private let container: AppContainer
    @ObservationIgnored private var history: [WorkoutLog] = []

    init(container: AppContainer) {
        self.container = container
    }

    /// Everything the screen shows is derived from three streams: plan, logs and sync status.
    func run() async {
        guard let student = container.userID else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await plan in self.container.plans.observeActivePlan(studentID: student) { self.plan = plan; self.recompute() }
            }
            group.addTask { @MainActor in
                for await logs in self.container.logs.observeLogs(studentID: student) { self.history = logs; self.recompute() }
            }
        }
    }

    private func recompute() {
        next = plan.flatMap { WorkoutSequencer().next(plan: $0, logs: history, now: Date()) }
    }

    func startWorkout() async {
        guard let plan else { return }
        let checkIn = container.pendingCheckInID
        container.pendingCheckInID = nil
        do {
            let log = try await StartWorkoutUseCase(logs: container.logs).execute(plan: plan, checkInID: checkIn)
            guard let template = plan.template(id: log.templateID) else { return }
            let previous = history.first { $0.templateID == log.templateID && $0.status == .completed }
            let focus = FocusGuard().context(plan: plan, logs: history, now: Date())      // strength/volume week + the yardstick loads
            activeWorkout = ActiveWorkoutViewModel(
                log: log, template: template, factory: container.componentFactory,
                record: RecordBlockUseCase(logs: container.logs), finish: FinishWorkoutUseCase(logs: container.logs),
                feedback: container.feedback, previousSession: previous, catalog: container.catalog, focus: focus,
                onFinished: { [container] log in await container.publishPost(for: log) })
        } catch {
            errorMessage = String(localized: "Couldn't start your workout.")
        }
    }

    func closeWorkout() { activeWorkout = nil }
}

struct StudentHomeView: View {
    let model: StudentHomeViewModel
    let profileButton: AnyView

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let plan = model.plan, let next = model.next {
                        hero(plan: plan, next: next)
                        WorkoutListSection(templates: plan.orderedTemplates, nextID: next.template.id)
                    } else {
                        ContentUnavailableView(String(localized: "No plan yet"), systemImage: "list.bullet.clipboard",
                                               description: Text(String(localized: "Your trainer will assign one soon.")))
                            .padding(.top, 60)
                    }
                    if let message = model.errorMessage { Text(message).foregroundStyle(.red) }
                }
                .padding(16)
                .adaptiveContentWidth()
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "Today"))
            .toolbar { ProfileToolbarSlot(profileButton) }
            .task { await model.run() }
            .fullScreenCover(item: Binding(get: { model.activeWorkout.map(WorkoutSession.init) }, set: { if $0 == nil { model.closeWorkout() } })) { session in
                ActiveWorkoutView(viewModel: session.model, onClose: { model.closeWorkout() })
            }
        }
        .tint(Theme.accent)
    }

    private func hero(plan: WorkoutPlan, next: NextWorkout) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                // "Today" is already the tab and the title; the card only speaks up when there is something to say.
                if next.reason == .resumedInProgress {
                    Text(String(localized: "Workout in progress")).font(.subheadline.weight(.semibold)).opacity(0.85)
                }
                Text(verbatim: next.template.label).font(.largeTitle.bold()).accessibilityIdentifier("next-workout-label")
                Text(String(localized: "\(next.template.blocks.count) exercises · ~\(next.template.estimatedMinutes) min"))
                    .font(.subheadline).opacity(0.9)
            }

            Button {
                Task { await model.startWorkout() }
            } label: {
                Text(next.reason == .resumedInProgress ? String(localized: "Resume workout") : String(localized: "Start workout"))
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityIdentifier("start-workout")
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct WorkoutSession: Identifiable {
    let model: ActiveWorkoutViewModel
    let id: LogID

    @MainActor init(_ model: ActiveWorkoutViewModel) {
        self.model = model
        self.id = model.log.id
    }
}
