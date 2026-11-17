import Domain
import Observation
import SwiftUI

/// "Run workout": the trainer picks which of the student's workouts to run (the next one in the rotation is preselected), then runs it on their
/// own phone — loads, sets and rest are entered here, saved to the student's history, and arrive on the student's phone by themselves.
@MainActor
@Observable
public final class CoachedWorkoutSetupViewModel {
    public struct Option: Identifiable, Equatable, Sendable {
        public let id: TemplateID
        public let label: String
        public let exercises: Int
        public let minutes: Int
        public let isSuggested: Bool
    }

    public let studentName: String
    public let plan: WorkoutPlan?
    public private(set) var options: [Option] = []
    public var selectedID: TemplateID?
    /// A session this trainer already started for the student and didn't finish.
    public private(set) var resumable: WorkoutLog?
    public private(set) var isLoaded = false
    public private(set) var isStarting = false
    public private(set) var errorMessage: String?
    public private(set) var session: ActiveWorkoutViewModel?

    @ObservationIgnored private let start: StartCoachedWorkoutUseCase
    @ObservationIgnored private let makeSession: @MainActor (WorkoutLog, WorkoutTemplate) async -> ActiveWorkoutViewModel

    /// - Parameter makeSession: builds the workout screen's model for a started session (the app owns the components, the feedback and the catalogue).
    public init(plan: WorkoutPlan?, studentName: String, start: StartCoachedWorkoutUseCase,
                makeSession: @escaping @MainActor (WorkoutLog, WorkoutTemplate) async -> ActiveWorkoutViewModel) {
        self.plan = plan
        self.studentName = studentName
        self.start = start
        self.makeSession = makeSession
    }

    public var hasWorkouts: Bool { !(plan?.templates.isEmpty ?? true) }

    public func load() async {
        guard let plan, hasWorkouts else { isLoaded = true; return }
        resumable = try? await start.resumable(plan: plan)
        let suggested = try? await start.suggestedTemplate(plan: plan)
        options = plan.orderedTemplates.map {
            Option(id: $0.id, label: $0.label, exercises: $0.blocks.count, minutes: $0.estimatedMinutes, isSuggested: $0.id == suggested?.id)
        }
        if selectedID == nil || !options.contains(where: { $0.id == selectedID }) { selectedID = resumable?.templateID ?? suggested?.id ?? options.first?.id }
        isLoaded = true
    }

    /// Starts the chosen workout (or carries on with the unfinished one) and opens it.
    public func begin() async {
        guard let plan, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let log = try await start.execute(plan: plan, templateID: selectedID)
            guard let template = plan.template(id: log.templateID) else { throw DomainError.notFound("template") }
            session = await makeSession(log, template)
        } catch {
            errorMessage = String(localized: "Couldn't start the workout.")
        }
    }

    public func closeSession() async {
        await session?.flush()
        session = nil
        await load()                                     // the rotation moved on, or an unfinished one can be resumed
    }

    public var buttonTitle: String {
        resumable != nil && resumable?.templateID == selectedID ? String(localized: "Continue workout") : String(localized: "Start workout")
    }
}

public struct CoachedWorkoutSetupView: View {
    private let model: CoachedWorkoutSetupViewModel

    public init(model: CoachedWorkoutSetupViewModel) { self.model = model }

    public var body: some View {
        Group {
            if !model.hasWorkouts {
                ContentUnavailableView(String(localized: "No workouts yet"), systemImage: "list.bullet.clipboard",
                                       description: Text(String(localized: "Create the student's workouts first, then run them here.")))
            } else {
                List {
                    if let resumable = model.resumable {
                        Section {
                            Label(String(localized: "\(resumable.templateLabel) was left unfinished"), systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(Theme.warning)
                                .accessibilityIdentifier("coached-unfinished")
                        }
                    }
                    Section {
                        ForEach(model.options) { option in
                            Button { model.selectedID = option.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 8) {
                                            Text(verbatim: option.label).font(.body.weight(.medium))
                                            if option.isSuggested {
                                                Text(String(localized: "Next")).font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.14), in: Capsule())
                                            }
                                        }
                                        Text(String(localized: "\(option.exercises) exercises · ~\(option.minutes) min")).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedID == option.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("coached-option-\(option.id)")
                        }
                    } header: { Text(String(localized: "Which workout?")) } footer: {
                        Text(String(localized: "Loads, sets and rest are saved to \(model.studentName)'s history and show up on their phone."))
                    }
                    if let message = model.errorMessage { Section { Text(verbatim: message).foregroundStyle(.red).accessibilityIdentifier("coached-error") } }
                }
            }
        }
        .navigationTitle(String(localized: "Run workout"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            if model.hasWorkouts {
                Button(model.buttonTitle) { Task { await model.begin() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.selectedID == nil || model.isStarting)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("coached-start")
            }
        }
        .task { await model.load() }
        .modifier(SessionCover(isPresented: Binding(get: { model.session != nil }, set: { if !$0 { Task { await model.closeSession() } } })) {
            if let session = model.session {
                ActiveWorkoutView(viewModel: session, onClose: { Task { await model.closeSession() } })
            }
        })
    }
}

/// The workout takes over the whole screen on iPhone/iPad (a sheet elsewhere, where there is no full-screen cover).
private struct SessionCover<Cover: View>: ViewModifier {
    let isPresented: Binding<Bool>
    @ViewBuilder let cover: () -> Cover

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: isPresented, content: cover)
        #else
        content.sheet(isPresented: isPresented, content: cover)
        #endif
    }
}
