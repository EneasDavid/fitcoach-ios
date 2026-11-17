import Domain
import PresentationKit
import SwiftUI

/// The personal trainer's shell: the student list (search, register by CPF + name, private nickname) → one student → workouts
/// editor (only the trainer can create or change a student's workouts) or the individual progress charts.
struct TrainerRootView: View {
    let container: AppContainer
    @State private var roster: TrainerRosterViewModel
    @State private var path: [TrainerRoute] = []
    @State private var profile: ProfileViewModel?

    init(container: AppContainer) {
        self.container = container
        _roster = State(initialValue: TrainerRosterViewModel(trainerID: container.userID ?? "unknown", registrations: container.registering,
                                                             plans: container.plans, nicknames: container.nicknames,
                                                             bodyMeasurements: container.bodyComposition))
    }

    private var profileButton: AnyView {
        AnyView(ProfileToolbarButton(initials: Avatar.initials(for: container.displayName), photo: container.profilePhoto, action: { profile = container.makeProfileModel() }))
    }

    var body: some View {
        NavigationStack(path: $path) {
            TrainerRosterView(model: roster, profileButton: profileButton)
                .navigationDestination(for: TrainerRoute.self) { route in
                    switch route {
                    case .student(let id): TrainerStudentView(model: roster, studentID: id)
                    case .plan(let id):
                        if let row = roster.row(id: id) {
                            PlanEditorScreen(container: container, row: row) {
                                path.removeAll { $0 == .plan(id) }
                                Task { await roster.load() }
                            }
                        }
                    case .evolution(let id):
                        if let row = roster.row(id: id), let studentID = row.registration.studentID { EvolutionScreen(container: container, studentID: studentID) }
                    case .run(let id):
                        if let row = roster.row(id: id) { CoachedWorkoutScreen(container: container, row: row) }
                    case .summary(let id):
                        if let row = roster.row(id: id), let studentID = row.registration.studentID {
                            SummaryScreen(model: StudentSummaryViewModel(studentID: studentID, logs: container.logs, plans: container.plans, catalog: container.catalog))
                        }
                    case .history(let id):
                        if let row = roster.row(id: id), let studentID = row.registration.studentID {
                            HistoryScreen(model: HistoryViewModel(studentID: studentID, logs: container.logs,
                                                                  plan: { [plans = container.plans] in try? await plans.activePlan(studentID: studentID) },
                                                                  photos: container.sharedPhotos))
                        }
                    case .photos(let id):
                        if let row = roster.row(id: id), let studentID = row.registration.studentID {
                            PhotosScreen(model: StudentPhotosViewModel(studentID: studentID, photos: container.sharedPhotos))
                        }
                    case .body(let id):
                        if let row = roster.row(id: id), let studentID = row.registration.studentID {
                            BodyScreen(container: container, studentID: studentID, profile: BodyProfile(row.registration), planID: row.plan?.id) {
                                Task { await roster.load() }
                            }
                        }
                    }
                }
        }
        .tint(Theme.accent)
        .environment(container.mediaPolicy)
        .sheet(isPresented: Binding(get: { profile != nil }, set: { if !$0 { profile = nil } })) {
            if let model = profile { ProfileView(model: model).environment(container.mediaPolicy) }
        }
    }
}

private struct PlanEditorScreen: View {
    let container: AppContainer
    let onSaved: () -> Void
    @State private var model: PlanEditorViewModel

    init(container: AppContainer, row: TrainerRosterViewModel.Row, onSaved: @escaping () -> Void) {
        self.container = container
        self.onSaved = onSaved
        _model = State(initialValue: PlanEditorViewModel(trainerID: container.userID ?? "unknown", student: row.registration, existing: row.plan,
                                                         plans: container.plans, deviceID: container.deviceID))
    }

    var body: some View { PlanEditorView(model: model, catalog: container.catalog, onSaved: onSaved) }
}

private struct EvolutionScreen: View {
    @State private var model: StudentEvolutionViewModel

    init(container: AppContainer, studentID: UserID) {
        // The trainer's chart choices are remembered per student.
        let key = "chart.config.\(studentID)"
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ChartConfiguration.self, from: $0) } ?? ChartConfiguration()
        _model = State(initialValue: StudentEvolutionViewModel(studentID: studentID, logs: container.logs, configuration: saved,
                                                               onConfigurationChange: { UserDefaults.standard.set(try? JSONEncoder().encode($0), forKey: key) }))
    }

    var body: some View { StudentEvolutionView(model: model) }
}

private struct BodyScreen: View {
    @State private var model: StudentBodyViewModel
    private let onChange: () -> Void

    init(container: AppContainer, studentID: UserID, profile: BodyProfile, planID: PlanID?, onChange: @escaping () -> Void) {
        _model = State(initialValue: StudentBodyViewModel(profile: profile, studentID: studentID, trainerID: container.userID, planID: planID,
                                                          deviceID: container.deviceID, repository: container.bodyComposition))
        self.onChange = onChange
    }

    var body: some View {
        BodyView(model: model)
            .onChange(of: model.entries.count) { _, _ in onChange() }        // the roster's weight / BMI follow the newest measurement
    }
}

private struct PhotosScreen: View {
    @State var model: StudentPhotosViewModel
    var body: some View { StudentPhotosView(model: model) }
}

private struct SummaryScreen: View {
    @State var model: StudentSummaryViewModel
    var body: some View { StudentSummaryView(model: model) }
}

private struct HistoryScreen: View {
    @State var model: HistoryViewModel
    var body: some View { HistoryView(model: model, embedded: true) }
}

/// "Run workout": the trainer runs one of the student's workouts on this phone. Everything entered is saved to the student's history.
private struct CoachedWorkoutScreen: View {
    @State private var model: CoachedWorkoutSetupViewModel

    init(container: AppContainer, row: TrainerRosterViewModel.Row) {
        let trainerID = container.userID ?? "unknown"
        let plan = row.plan
        let name = row.title                       // the trainer's own label (nickname or name) — it only ever appears on the trainer's phone
        _model = State(initialValue: CoachedWorkoutSetupViewModel(
            plan: plan, studentName: name,
            start: StartCoachedWorkoutUseCase(logs: container.logs, trainerID: trainerID),
            makeSession: { log, template in
                let history = (try? await container.logs.logs(studentID: log.studentID, planID: nil, since: nil)) ?? []
                let previous = history.first { $0.templateID == log.templateID && $0.status == .completed && $0.id != log.id }
                let focus = plan.flatMap { FocusGuard().context(plan: $0, logs: history, now: Date()) }
                return ActiveWorkoutViewModel(
                    log: log, template: template, factory: container.componentFactory,
                    record: RecordBlockUseCase(logs: container.logs), finish: FinishWorkoutUseCase(logs: container.logs),
                    feedback: container.feedback, previousSession: previous, catalog: container.catalog, focus: focus,
                    coaching: CoachingTools(catalog: container.catalog, studentName: name))
            }))
    }

    var body: some View { CoachedWorkoutSetupView(model: model) }
}
