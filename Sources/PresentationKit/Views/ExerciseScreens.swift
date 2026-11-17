import Domain
import SwiftUI

// One dedicated screen per exercise. Views stay thin: every rule (locking, clamping, persistence) is in the view
// models, and every control has an accessibility identifier — the contract the XCUITests rely on.

// MARK: - Navigation cue

/// "→ next exercise". Injected by the workout overview so a screen never needs to know about the queue.
struct NextExerciseAction: Sendable {
    /// The next exercise's name, or `nil` when this was the last one (the arrow then leads back to the overview).
    let title: String?
    let go: @MainActor @Sendable () -> Void
}

private struct NextExerciseKey: EnvironmentKey { static let defaultValue: NextExerciseAction? = nil }

extension EnvironmentValues {
    var nextExercise: NextExerciseAction? {
        get { self[NextExerciseKey.self] }
        set { self[NextExerciseKey.self] = newValue }
    }
}

/// The trainer's exercise catalogue, present only while a trainer runs the workout: it unlocks "any other exercise" on the exercise screen.
private struct CoachingToolsKey: EnvironmentKey { static let defaultValue: CoachingTools? = nil }

extension EnvironmentValues {
    var coachingTools: CoachingTools? {
        get { self[CoachingToolsKey.self] }
        set { self[CoachingToolsKey.self] = newValue }
    }
}

// MARK: - Strength exercise (minimal: one set in focus)

/// The exercise screen shows only what matters *right now*: the video, the name, the set you're on, and a button.
/// Everything else is one tap away — substitutes (a dropdown that starts collapsed), how-to (sheet), rest length (menu).
public struct ResistanceExerciseScreen: View {
    private let viewModel: ResistanceBlockViewModel
    @State private var showingSubstitutions = false      // the dropdown always starts collapsed
    @State private var showingHowTo = false
    @State private var choosingAnyExercise = false
    @Environment(\.coachingTools) private var coaching
    @Environment(\.nextExercise) private var next
    @Environment(MediaPolicy.self) private var policy: MediaPolicy?

    public init(viewModel: ResistanceBlockViewModel) {
        self.viewModel = viewModel
    }

    private var detail: ExerciseDetailViewModel { viewModel.detail }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExerciseMediaView(exercise: detail.shown, title: viewModel.title, isLoading: detail.state == .loading)

                header
                if let focus = viewModel.focusContext { FocusChip(context: focus) }
                progressDots

                if let number = viewModel.activeSetNumber, let row = viewModel.rows.first(where: { $0.id == number }) {
                    ActiveSetCard(row: row, count: viewModel.rows.count, viewModel: viewModel)
                }

                // Done with this exercise: one arrow to the next one (no banner, no confirmation).
                if viewModel.isComplete, let next {
                    Button { next.go() } label: {
                        HStack(spacing: 10) {
                            Text(verbatim: next.title ?? String(localized: "Back to workout")).font(.headline).lineLimit(1)
                            Image(systemName: "arrow.right").font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .accessibilityIdentifier("next-exercise")
                }

                if viewModel.canSubstitute { substitutions }
                if viewModel.canSubstitute, coaching != nil {
                    // The trainer isn't limited to the suggested substitutes: any exercise in the catalogue.
                    Button { choosingAnyExercise = true } label: {
                        Label(String(localized: "Choose another exercise"), systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityIdentifier("choose-any-exercise")
                }
            }
            .padding(16)
            .padding(.bottom, 24)
            .adaptiveContentWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .background(Theme.background)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingHowTo = true } label: { Label(String(localized: "How to do it"), systemImage: "questionmark.circle") }
                    Menu {
                        ForEach(restOptions, id: \.self) { seconds in
                            Button { viewModel.setRestSeconds(seconds) } label: {
                                Label(ClockFormat.minutesSeconds(TimeInterval(seconds)),
                                      systemImage: viewModel.restSeconds == seconds ? "checkmark" : "timer")
                            }
                        }
                    } label: { Label(String(localized: "Rest between sets"), systemImage: "timer") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "More"))
                .accessibilityIdentifier("exercise-menu")
            }
        }
        .safeAreaInset(edge: .bottom) { RestPanel(viewModel: viewModel).padding(.bottom, 4) }
        .animation((policy?.animationsEnabled ?? true) ? .easeInOut(duration: 0.2) : nil, value: viewModel.restTimer.isRunning)
        .sheet(isPresented: $showingHowTo) { HowToSheet(viewModel: viewModel) }
        .sheet(isPresented: $choosingAnyExercise) {
            if let coaching {
                ExercisePickerSheet(model: ExercisePickerViewModel(catalog: coaching.catalog), title: String(localized: "Choose another exercise")) { exercise in
                    viewModel.substitute(with: exercise)
                }
            }
        }
        .task { await detail.load() }
    }

    private var restOptions: [Int] {
        Array(Set(ResistanceBlockViewModel.restPresets + [viewModel.restSeconds])).sorted()
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: viewModel.title).font(.title.bold()).accessibilityIdentifier("exercise-title")
            if let line = muscleLine {
                Text(verbatim: line).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("muscles")
            }
            if let original = viewModel.substitutedFor {
                Text(String(localized: "Instead of \(original.name)")).font(.footnote).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("swap-banner")
            }
        }
    }

    /// "Chest · also shoulders, triceps · Barbell" — muscles and equipment in a single quiet line.
    private var muscleLine: String? {
        let main = detail.primaryMuscles.map(\.displayName).joined(separator: ", ")
        let also = detail.secondaryMuscles.map { $0.displayName.lowercased() }.joined(separator: ", ")
        var parts: [String] = []
        if !main.isEmpty { parts.append(main) }
        if !main.isEmpty, !also.isEmpty { parts.append(String(localized: "also \(also)")) }
        if let equipment = detail.shown?.equipment, equipment != .other { parts.append(equipment.displayName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.rows) { row in
                Capsule()
                    .fill(row.isDone ? Theme.success : (row.id == viewModel.activeSetNumber ? Theme.accent : Theme.field))
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(viewModel.completedSetCount) of \(viewModel.rows.count) sets done"))
        .accessibilityIdentifier("set-progress")
    }

    /// Possible substitutes (at most three), in a dropdown that is always collapsed when the screen opens.
    private var substitutions: some View {
        DisclosureGroup(isExpanded: $showingSubstitutions) {
            SubstitutionList(viewModel: viewModel) { withAnimation { showingSubstitutions = false } }
                .padding(.top, 10)
        } label: {
            Text(String(localized: "Substitutions")).font(.subheadline.weight(.semibold))
        }
        .tint(.secondary)
        .card()
        .accessibilityIdentifier("substitutions-toggle")
    }
}

// MARK: - Strength / volume weeks

struct FocusChip: View {
    let context: FocusContext

    var body: some View {
        let reps = context.suggestedReps
        let text = context.focus == .strength
            ? String(localized: "Strength week \(context.weekInPhase) of \(context.phaseWeeks) · \(reps.lowerBound)–\(reps.upperBound) reps")
            : String(localized: "Volume week \(context.weekInPhase) of \(context.phaseWeeks) · \(reps.lowerBound)–\(reps.upperBound) reps")
        Label(text, systemImage: context.focus == .strength ? "bolt.fill" : "repeat")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(context.focus == .strength ? Theme.accent : Theme.rest)
            .accessibilityIdentifier("focus-chip")
    }
}

/// "Focus on execution": shown on the exercise screen when the load is the wrong way round for this week.
struct FocusWarningBanner: View {
    let warning: FocusWarning

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(verbatim: warning.message).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("focus-warning")
    }
}

public extension FocusWarning {
    var message: String {
        let load = LoadFormat.kg(loadKg), reference = LoadFormat.kg(referenceKg)
        switch kind {
        case .heavierThanStrengthWeek:
            return String(localized: "This is a volume week, and \(load) kg is heavier than your strength-week best (\(reference) kg). Focus on execution.")
        case .lighterThanVolumeWeek:
            return String(localized: "This is a strength week, but \(load) kg is lighter than your volume-week best (\(reference) kg). Aim for more load.")
        }
    }
}

// MARK: - The set in focus

private struct ActiveSetCard: View {
    let row: SetRow
    let count: Int
    let viewModel: ResistanceBlockViewModel

    private var prefix: String { "\(viewModel.blockID)-\(row.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let warning = viewModel.focusWarning { FocusWarningBanner(warning: warning) }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(String(localized: "Set \(row.id)")).font(.headline)
                    Spacer()
                    if row.isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success) }
                }
                Text(verbatim: hint).font(.footnote).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                NumberStepper(title: String(localized: "LOAD"), unit: "kg", value: viewModel.loadShown(forSet: row.id), step: 1,
                              isLocked: row.isDone, idPrefix: "load-\(prefix)", onSet: { viewModel.editLoad($0, forSet: row.id) })
                NumberStepper(title: String(localized: "REPS"), unit: "", value: Double(row.reps), step: 1, isLocked: row.isDone,
                              allowsDecimals: false, idPrefix: "reps-\(prefix)", onSet: { viewModel.setReps(Int($0.rounded()), forSet: row.id) })
            }

            // The whole line is tappable (a bare switch is a tiny target); the switch itself keeps working too.
            HStack {
                Text(viewModel.sameLoadForAllSets && !row.isDone
                     ? String(localized: "Same load · applies to the sets left")
                     : String(localized: "Same load for all sets"))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.setSameLoad(!viewModel.sameLoadForAllSets) }
                Toggle("", isOn: Binding(get: { viewModel.sameLoadForAllSets }, set: { viewModel.setSameLoad($0) }))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .accessibilityLabel(String(localized: "Same load for all sets"))
                    .accessibilityIdentifier("same-load-toggle")
            }

            if row.isDone {
                if viewModel.canUndo(set: row.id) {
                    Button(String(localized: "Undo")) { viewModel.undo(set: row.id) }
                        .buttonStyle(SoftButtonStyle(tint: .secondary))
                        .accessibilityIdentifier("undo-set-\(prefix)")
                }
            } else {
                Button(String(localized: "Complete set")) { viewModel.complete(set: row.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("complete-set-\(prefix)")
                if viewModel.lastDoneSetNumber != nil {
                    // Reverts exactly the last performed set; earlier completed sets stay as they are.
                    Button(String(localized: "Undo last set")) { viewModel.undoLast() }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .accessibilityIdentifier("undo-last-\(viewModel.blockID)")
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("set-card-\(prefix)")
    }

    /// "Goal 8–12 · Last time 40 kg × 10"
    private var hint: String {
        let goal = row.repsMin == row.repsMax ? "\(row.repsMin)" : "\(row.repsMin)–\(row.repsMax)"
        var text = String(localized: "Goal: \(goal) reps")
        if let kg = row.lastWeightKg, let reps = row.lastReps {
            text += " · " + String(localized: "Last time: \(LoadFormat.kg(kg)) kg × \(reps)")
        }
        return text
    }
}

// MARK: - Sheets (one tap away, never in the way)

private struct SubstitutionList: View {
    let viewModel: ResistanceBlockViewModel
    let onChosen: () -> Void

    private var detail: ExerciseDetailViewModel { viewModel.detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch detail.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            case .unavailable:
                VStack(spacing: 10) {
                    Text(String(localized: "Connect to the internet to see alternatives.")).font(.footnote).multilineTextAlignment(.center)
                    Button(String(localized: "Try again")) { Task { await detail.retry() } }
                        .buttonStyle(SoftButtonStyle()).accessibilityIdentifier("retry-catalog")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            case .loaded:
                ForEach(detail.substitutions, id: \.candidate.id) { suggestion in
                    SubstitutionRow(suggestion: suggestion,
                                    isSelected: detail.shownRef.id == suggestion.candidate.id,
                                    isEnabled: viewModel.canSubstitute) {
                        viewModel.substitute(with: suggestion.candidate)
                        onChosen()
                    }
                }
                if detail.substitutions.isEmpty {
                    Text(String(localized: "No alternatives found.")).font(.footnote).foregroundStyle(.secondary)
                }
                if viewModel.substitutedFor != nil && viewModel.canSubstitute {
                    Button(String(localized: "Back to \(viewModel.detail.plannedRef.name)")) {
                        viewModel.revertSubstitution()
                        onChosen()
                    }
                    .buttonStyle(SoftButtonStyle(tint: .secondary))
                    .accessibilityIdentifier("revert-substitution")
                }
            }
        }
        .accessibilityIdentifier("substitutions")
    }
}

private struct HowToSheet: View {
    let viewModel: ResistanceBlockViewModel
    @Environment(\.dismiss) private var dismiss

    private var shown: Exercise? { viewModel.detail.shown }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MuscleChips(primary: viewModel.detail.primaryMuscles, secondary: viewModel.detail.secondaryMuscles, equipment: shown?.equipment)
                    if let steps = shown?.instructions, !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(steps.prefix(10).enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)").font(.footnote.weight(.bold)).foregroundStyle(Theme.onAccent)
                                        .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
                                    Text(verbatim: step).font(.body)
                                }
                            }
                        }
                    } else {
                        Text(String(localized: "No instructions available.")).foregroundStyle(.secondary)
                    }
                    if let credit = shown?.mediaCredit {
                        Text(String(localized: "Video & images: \(credit) · wger.de")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "How to do it"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .accessibilityIdentifier("how-to")
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SubstitutionRow: View {
    let suggestion: ExerciseSubstitution
    let isSelected: Bool
    let isEnabled: Bool
    let onUse: () -> Void

    var body: some View {
        let exercise = suggestion.candidate
        HStack(spacing: 12) {
            thumbnail(exercise)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: exercise.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(verbatim: ([exercise.primaryMuscles.first?.displayName, exercise.equipment.displayName].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            } else {
                Button(String(localized: "Use")) { onUse() }
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(Theme.accent)
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1 : 0.4)
                    .accessibilityIdentifier("use-substitute-\(exercise.id)")
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("substitute-\(exercise.id)")
    }

    private func thumbnail(_ exercise: Exercise) -> some View {
        ZStack {
            Theme.field
            if let url = exercise.imageURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() } else { icon }
                }
            } else {
                icon
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var icon: some View {
        Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(.secondary)
    }
}

// MARK: - HIIT

public struct HIITScreen: View {
    private let viewModel: HIITBlockViewModel

    public init(viewModel: HIITBlockViewModel) {
        self.viewModel = viewModel
    }

    private var isWork: Bool { viewModel.currentSegment?.kind == .work }

    public var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: viewModel.title).font(.title.bold())
                    Text(verbatim: viewModel.summary).font(.subheadline).foregroundStyle(.secondary)
                    if !viewModel.block.movements.isEmpty {
                        Text(verbatim: viewModel.block.movements.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 18) {
                    TimerRing(progress: viewModel.state == .ready ? 0 : viewModel.timer.progress,
                              tint: isWork ? Theme.warning : Theme.rest, lineWidth: 16) {
                        VStack(spacing: 4) {
                            Text(label).font(.headline.weight(.heavy)).foregroundStyle(isWork ? Theme.warning : Theme.rest)
                            Text(ClockFormat.minutesSeconds(viewModel.state == .ready ? TimeInterval(viewModel.block.workSeconds) : viewModel.timer.remaining))
                                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("hiit-remaining")
                            Text(String(localized: "Round \(viewModel.currentSegment?.round ?? 1) of \(viewModel.block.rounds)"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 270, height: 270)

                    controls
                }
                .card()
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(viewModel.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var label: String {
        switch viewModel.state {
        case .ready: return String(localized: "READY")
        case .finished: return String(localized: "DONE")
        default: return isWork ? String(localized: "WORK") : String(localized: "REST")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.state {
        case .ready:
            Button(String(localized: "Start intervals")) { viewModel.start() }
                .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("hiit-start")
        case .running, .paused:
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if viewModel.state == .running {
                        Button(String(localized: "Pause")) { viewModel.pause() }
                            .buttonStyle(SoftButtonStyle()).accessibilityIdentifier("hiit-pause")
                    } else {
                        Button(String(localized: "Resume")) { viewModel.resume() }
                            .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("hiit-resume")
                    }
                    Button(String(localized: "Skip")) { viewModel.skipSegment() }
                        .buttonStyle(SoftButtonStyle(tint: .secondary)).accessibilityIdentifier("hiit-skip")
                }
                Button(String(localized: "End now")) { viewModel.finishEarly() }
                    .buttonStyle(SoftButtonStyle(tint: .red)).accessibilityIdentifier("hiit-end")
            }
        case .finished:
            Label(String(localized: "Intervals complete"), systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(Theme.success)
        }
    }
}

// MARK: - Cardio

public struct CardioScreen: View {
    private let viewModel: CardioBlockViewModel

    public init(viewModel: CardioBlockViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: viewModel.title).font(.title.bold())
                    Text(verbatim: viewModel.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 18) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        TimerRing(progress: 1 - viewModel.progress(at: timeline.date), tint: Theme.accent, lineWidth: 16) {
                            VStack(spacing: 4) {
                                Text(ClockFormat.minutesSeconds(viewModel.elapsed(at: timeline.date)))
                                    .font(.system(size: 60, weight: .bold, design: .rounded).monospacedDigit())
                                    .accessibilityIdentifier("cardio-elapsed")
                                Text(String(localized: "of \(viewModel.block.targetDurationSeconds / 60) min"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 250, height: 250)
                    }

                    if viewModel.isFinished {
                        Label(String(localized: "Cardio complete"), systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(Theme.success)
                    } else {
                        if viewModel.isRunning {
                            Button(String(localized: "Pause")) { viewModel.pause() }
                                .buttonStyle(SoftButtonStyle()).accessibilityIdentifier("cardio-pause")
                        } else {
                            Button(String(localized: "Start")) { viewModel.start() }
                                .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("cardio-start")
                        }
                    }
                }
                .card()

                if !viewModel.isFinished {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "How did it go? (optional)")).font(.headline)
                        entryField(String(localized: "Distance"), unit: "km", text: Binding(get: { viewModel.distanceText }, set: { viewModel.distanceText = $0 }), decimals: true, id: "cardio-distance")
                        entryField(String(localized: "Average heart rate"), unit: "bpm", text: Binding(get: { viewModel.heartRateText }, set: { viewModel.heartRateText = $0 }), decimals: false, id: "cardio-hr")
                        Button(String(localized: "Finish cardio")) { viewModel.finish() }
                            .buttonStyle(PrimaryButtonStyle(tint: Theme.success)).accessibilityIdentifier("cardio-finish")
                    }
                    .card()
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .background(Theme.background)
        .navigationTitle(viewModel.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func entryField(_ title: String, unit: String, text: Binding<String>, decimals: Bool, id: String) -> some View {
        HStack {
            Text(verbatim: title).font(.subheadline)
            Spacer()
            TextField("0", text: text)
                .multilineTextAlignment(.trailing)
                .font(.title3.weight(.semibold).monospacedDigit())
                #if os(iOS)
                .keyboardType(decimals ? .decimalPad : .numberPad)
                #endif
                .frame(width: 90)
                .accessibilityIdentifier(id)
            Text(verbatim: unit).font(.footnote).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
        }
        .padding(12)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Unsupported

public struct UnsupportedBlockScreen: View {
    private let viewModel: UnsupportedBlockViewModel

    public init(viewModel: UnsupportedBlockViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.warning)
            Text(String(localized: "Your trainer added “\(viewModel.originalType)”, which this version of the app can't show yet. Update the app to see it — the rest of your workout works as usual."))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityIdentifier("block-unsupported")
    }
}
