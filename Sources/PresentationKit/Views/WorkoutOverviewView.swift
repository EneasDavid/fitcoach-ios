import Domain
import SwiftUI

/// The workout at a glance: a checklist of exercises. Tapping one opens its own screen (video, muscles, sets,
/// rest timer, substitutes). Designed to be obvious on first use: one list, one thing to do next.
public struct ActiveWorkoutView: View {
    private let viewModel: ActiveWorkoutViewModel
    private let onClose: () -> Void
    @State private var addingExercise = false

    public init(viewModel: ActiveWorkoutViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack(path: Binding(get: { viewModel.path }, set: { viewModel.path = $0 })) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(spacing: 12) {
                        ForEach(Array(viewModel.components.enumerated()), id: \.element.id) { index, component in
                            NavigationLink(value: component.id) {
                                ExerciseRow(viewModel: component.viewModel, index: index + 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("exercise-row-\(component.id)")
                        }
                    }
                    if let message = viewModel.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("save-error")
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
                .adaptiveContentWidth()
            }
            .background(Theme.background)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: BlockID.self) { id in
                viewModel.component(for: id)?.detailView
                    .environment(\.nextExercise, viewModel.nextAction(after: id))
                    .environment(\.coachingTools, viewModel.coaching)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { onClose() }.accessibilityIdentifier("close-workout")
                }
                if viewModel.coaching != nil && viewModel.phase == .active {
                    ToolbarItem(placement: .primaryAction) {
                        Button { addingExercise = true } label: { Label(String(localized: "Add exercise"), systemImage: "plus") }
                            .accessibilityIdentifier("add-exercise-to-session")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .sheet(isPresented: Binding(get: { viewModel.isShowingFeedback }, set: { viewModel.isShowingFeedback = $0 })) {
            RPEFeedbackView(draft: viewModel.feedbackDraft) {
                Task { await viewModel.submitFeedback() }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $addingExercise) {
            if let coaching = viewModel.coaching {
                ExercisePickerSheet(model: ExercisePickerViewModel(catalog: coaching.catalog)) { exercise in viewModel.addExercise(exercise) }
            }
        }
        .tint(Theme.accent)
        .onChange(of: viewModel.phase) { _, phase in
            // Saved (or skipped): nothing left to do here, go back to "Today".
            if phase == .finished || phase == .skipped { onClose() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let coaching = viewModel.coaching {
                Label(String(localized: "With \(coaching.studentName)"), systemImage: "person.2.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("coaching-student")
            }
            Text(verbatim: viewModel.log.templateLabel).font(.largeTitle.bold())
            ProgressView(value: viewModel.progress).tint(Theme.accent)
            Text(String(localized: "\(viewModel.completedBlocks) of \(viewModel.components.count) exercises done"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let resting = viewModel.restingBlock {
                Button { viewModel.path = [resting.blockID] } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "timer").font(.title3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(localized: "Resting · \(ClockFormat.minutesSeconds(resting.restTimer.remaining))"))
                                .font(.headline.monospacedDigit())
                            Text(verbatim: resting.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                    }
                    .padding(14)
                    .foregroundStyle(Theme.rest)
                    .background(Theme.rest.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mini-rest")
            }
            Button(String(localized: "Finish workout")) { viewModel.isShowingFeedback = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!viewModel.canFinish)
                .accessibilityIdentifier("finish-workout")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }
}

private struct ExerciseRow: View {
    let viewModel: any WorkoutBlockViewModel
    let index: Int

    var body: some View {
        let done = viewModel.isComplete
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(done ? Theme.success : Theme.field).frame(width: 32, height: 32)
                if done {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.onAccent)
                } else {
                    Text("\(index)").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: viewModel.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                Text(verbatim: viewModel.statusText.map { "\($0) · \(viewModel.summary)" } ?? viewModel.summary)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .card(padding: 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Post-workout feedback

/// "How hard was it?" — RPE explained in plain words, picked with big tappable numbers instead of a slider.
public struct RPEFeedbackView: View {
    private let draft: RPEFeedbackDraft
    private let onSubmit: () -> Void

    public init(draft: RPEFeedbackDraft, onSubmit: @escaping () -> Void) {
        self.draft = draft
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "How hard was this workout?")).font(.title.bold())
                    Text(String(localized: "Pick a number from 1 (very easy) to 10 (all-out). Your trainer uses it to adjust your plan."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(RPEScale.range, id: \.self) { value in
                        let selected = draft.score == value
                        Button { draft.rpe = Double(value) } label: {
                            Text("\(value)")
                                .font(.title3.weight(.bold).monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(selected ? Color.white : .primary)
                                .background(selected ? color(for: value) : Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rpe-\(value)")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(draft.score) · \(RPEScale.description(for: draft.score))").font(.headline)
                        .accessibilityIdentifier("rpe-label")
                    Text(verbatim: RPEScale.explanation(for: draft.score)).font(.subheadline).foregroundStyle(.secondary)
                }
                .card()

                TextField(String(localized: "Anything your trainer should know? (optional)"),
                          text: Binding(get: { draft.note }, set: { draft.note = $0 }), axis: .vertical)
                    .lineLimit(3...6)
                    .padding(14)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("rpe-note")

                Button(String(localized: "Save workout")) { onSubmit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("rpe-save")
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .background(Theme.background)
    }

    /// Green (easy) → red (all-out).
    private func color(for value: Int) -> Color {
        let t = Double(value - 1) / 9
        return Color(hue: 0.36 * (1 - t), saturation: 0.75, brightness: 0.85)
    }
}
