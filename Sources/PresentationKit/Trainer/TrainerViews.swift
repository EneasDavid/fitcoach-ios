import Charts
import Domain
import SwiftUI

/// Where the trainer's navigation can go. The app owns the `NavigationStack`; these are the values it pushes.
public enum TrainerRoute: Hashable, Sendable {
    case student(String)
    case plan(String)
    case evolution(String)
    case body(String)
    case photos(String)
    case summary(String)
    case history(String)
    case run(String)
}

// MARK: - Student directory

public struct TrainerRosterView: View {
    private let model: TrainerRosterViewModel
    private let profileButton: AnyView?
    @State private var showingAdd = false

    public init(model: TrainerRosterViewModel, profileButton: AnyView? = nil) {
        self.model = model
        self.profileButton = profileButton
    }

    public var body: some View {
        @Bindable var model = model
        List {
            if model.isLoaded && model.rows.isEmpty {
                ContentUnavailableView(String(localized: "No students yet"), systemImage: "person.2",
                                       description: Text(String(localized: "Tap + to register a student with their CPF and name.")))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("no-students")
            }
            ForEach(model.filtered) { row in
                NavigationLink(value: TrainerRoute.student(row.id)) { RosterRow(row: row) }
                    .accessibilityIdentifier("student-row-\(row.id)")
            }
        }
        .searchable(text: $model.query, prompt: String(localized: "Search students"))
        .navigationTitle(String(localized: "Students"))
        .toolbar {
            ProfileToolbarSlot(profileButton ?? AnyView(EmptyView()))
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(String(localized: "Add student"))
                    .accessibilityIdentifier("add-student")
            }
        }
        .sheet(isPresented: $showingAdd) { AddStudentSheet(model: model) }
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

private struct RosterRow: View {
    let row: TrainerRosterViewModel.Row

    var body: some View {
        HStack(spacing: 12) {
            Avatar(initials: Avatar.initials(for: row.title), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title).font(.headline)
                Text(verbatim: row.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: row.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.registration.status == .invited ? Theme.warning : (row.needsPlan ? Theme.rest : Theme.accent))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

struct AddStudentSheet: View {
    let model: TrainerRosterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "CPF")) {
                        TextField("000.000.000-00", text: $model.newCPF)
                            .onChange(of: model.newCPF) { _, new in let masked = CPFMask.apply(new); if masked != new { model.newCPF = masked } }
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .accessibilityIdentifier("new-student-cpf")
                    }
                    LabeledContent(String(localized: "Full name")) {
                        TextField(String(localized: "As on their ID"), text: $model.newName)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .accessibilityIdentifier("new-student-name")
                    }
                } footer: {
                    Text(String(localized: "The student logs in the first time with this CPF and name, then fills in their e-mail, age, gender, height and weight. They'll have no workouts until you add them."))
                }
                if let error = model.addError {
                    Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("add-student-error")
                }
            }
            .navigationTitle(String(localized: "New student"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Register")) { Task { if await model.add() { dismiss() } } }
                        .disabled(model.isAdding || model.newCPF.isEmpty || model.newName.isEmpty)
                        .accessibilityIdentifier("register-student")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - One student

public struct TrainerStudentView: View {
    private let model: TrainerRosterViewModel
    private let studentID: String
    @State private var nickname = ""
    @State private var loadedNickname = false

    public init(model: TrainerRosterViewModel, studentID: String) {
        self.model = model
        self.studentID = studentID
    }

    public var body: some View {
        List {
            if let row = model.row(id: studentID) {
                Section {
                    TextField(String(localized: "Nickname"), text: $nickname)
                        .onSubmit { Task { await model.setNickname(nickname, forStudent: studentID) } }
                        .submitLabel(.done)
                        .accessibilityIdentifier("nickname-field")
                    if nickname != (row.nickname ?? "") {
                        Button(String(localized: "Save nickname")) { Task { await model.setNickname(nickname, forStudent: studentID) } }
                            .accessibilityIdentifier("save-nickname")
                    }
                } footer: {
                    Text(String(localized: "Only you see this. Your student never does."))
                }

                if row.registration.status == .active {
                    Section {
                        if let plan = row.plan {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: plan.name).font(.headline)
                                Text(String(localized: "\(plan.templates.count) workouts · \(plan.targetSessionsPerWeek)× per week")).font(.footnote).foregroundStyle(.secondary)
                                if let cycle = plan.focusCycle {
                                    Text(String(localized: "\(cycle.strengthWeeks) strength weeks · \(cycle.volumeWeeks) volume weeks")).font(.footnote).foregroundStyle(Theme.accent)
                                }
                            }
                        } else {
                            Text(String(localized: "No plan yet — the student sees no workouts until you add them.")).foregroundStyle(.secondary)
                        }
                        if row.plan != nil {
                            // The one thing a trainer does with the student in front of them.
                            NavigationLink(value: TrainerRoute.run(studentID)) {
                                Label(String(localized: "Run workout"), systemImage: "play.circle.fill").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                            .accessibilityIdentifier("run-workout")
                        }
                        NavigationLink(value: TrainerRoute.plan(studentID)) {
                            Label(row.plan == nil ? String(localized: "Create workouts") : String(localized: "Edit workouts"), systemImage: "list.bullet.clipboard")
                        }
                        .accessibilityIdentifier("edit-plan")
                    } header: { Text(String(localized: "Workouts")) }

                    // Everything the trainer follows about this student, one tap each: no row appears twice, and none repeats the screen's title.
                    Section {
                        NavigationLink(value: TrainerRoute.summary(studentID)) {
                            Label(String(localized: "Summary"), systemImage: "gauge.with.dots.needle.33percent")
                        }
                        .accessibilityIdentifier("open-summary")
                        NavigationLink(value: TrainerRoute.evolution(studentID)) {
                            Label(String(localized: "Progress"), systemImage: "chart.line.uptrend.xyaxis")
                        }
                        .accessibilityIdentifier("open-evolution")
                        NavigationLink(value: TrainerRoute.history(studentID)) {
                            Label(String(localized: "History"), systemImage: "calendar")
                        }
                        .accessibilityIdentifier("open-history")
                        NavigationLink(value: TrainerRoute.body(studentID)) {
                            Label(String(localized: "Body"), systemImage: "figure.arms.open")
                        }
                        .accessibilityIdentifier("open-body")
                        NavigationLink(value: TrainerRoute.photos(studentID)) {
                            Label(String(localized: "Photos"), systemImage: "photo.on.rectangle.angled")
                        }
                        .accessibilityIdentifier("open-photos")
                    } header: { Text(String(localized: "Follow-up")) }
                } else {
                    Section {
                        Label(String(localized: "Waiting for the student's first access"), systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                }

                Section {
                    // The title already shows the name — unless a nickname took its place.
                    if row.nickname != nil { info(String(localized: "Name"), row.registration.fullName) }
                    info("CPF", row.registration.cpfMasked)
                    if let email = row.registration.email { info(String(localized: "E-mail"), email) }
                    if let age = row.registration.age { info(String(localized: "Age"), "\(age)") }
                    if let gender = row.registration.gender { info(String(localized: "Gender"), gender.title) }
                    if let body = row.body, body.weightKg != nil || body.heightCm != nil {
                        // Weight, height and the BMI they give, on one line.
                        info(String(localized: "Body"), [body.weightKg.map { BodyFormat.number($0) + " kg" }, body.heightCm.map { BodyFormat.number($0) + " cm" },
                                                        body.bmi.map { String(localized: "BMI \(BodyFormat.bmi($0))") }].compactMap { $0 }.joined(separator: " · "))
                    }
                } header: { Text(String(localized: "Data")) }
            }
        }
        .navigationTitle(model.row(id: studentID)?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await model.load()
            if !loadedNickname { nickname = model.row(id: studentID)?.nickname ?? ""; loadedNickname = true }
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack { Text(verbatim: title).foregroundStyle(.secondary); Spacer(); Text(verbatim: value) }
    }
}

// MARK: - Plan editor

public struct PlanEditorView: View {
    private let model: PlanEditorViewModel
    private let catalog: (any ExerciseCatalogRepository)?
    private let onSaved: () -> Void
    @State private var pickerTemplate: TemplateTarget?

    public init(model: PlanEditorViewModel, catalog: (any ExerciseCatalogRepository)?, onSaved: @escaping () -> Void) {
        self.model = model
        self.catalog = catalog
        self.onSaved = onSaved
    }

    public var body: some View {
        @Bindable var builder = model.builder
        List {
            Section {
                TextField(String(localized: "Plan name"), text: $builder.name).accessibilityIdentifier("plan-name")
                Stepper(String(localized: "\(builder.targetSessionsPerWeek) workouts per week"), value: $builder.targetSessionsPerWeek, in: 1...7)
            }

            Section {
                Toggle(String(localized: "Strength & volume weeks"), isOn: $builder.focus.enabled).accessibilityIdentifier("toggle-focus")
                if builder.focus.enabled {
                    Stepper(String(localized: "\(builder.focus.strengthWeeks) weeks of strength"), value: $builder.focus.strengthWeeks, in: 1...12)
                        .accessibilityIdentifier("strength-weeks")
                    Stepper(String(localized: "\(builder.focus.volumeWeeks) weeks of volume"), value: $builder.focus.volumeWeeks, in: 1...12)
                        .accessibilityIdentifier("volume-weeks")
                    Picker(String(localized: "Starts with"), selection: $builder.focus.startsWith) {
                        ForEach(TrainingFocus.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }
                    Stepper(String(localized: "Strength reps: \(builder.focus.strengthRepsMin)–\(builder.focus.strengthRepsMax)"),
                            onIncrement: { builder.focus.strengthRepsMax = min(builder.focus.strengthRepsMax + 1, 30) },
                            onDecrement: { builder.focus.strengthRepsMax = max(builder.focus.strengthRepsMax - 1, builder.focus.strengthRepsMin) })
                    Stepper(String(localized: "Volume reps: \(builder.focus.volumeRepsMin)–\(builder.focus.volumeRepsMax)"),
                            onIncrement: { builder.focus.volumeRepsMax = min(builder.focus.volumeRepsMax + 1, 50) },
                            onDecrement: { builder.focus.volumeRepsMax = max(builder.focus.volumeRepsMax - 1, builder.focus.volumeRepsMin) })
                }
            } header: { Text(String(localized: "Weeks")) } footer: {
                Text(String(localized: "In strength weeks the student lifts heavier for fewer reps; in volume weeks lighter for more. If they lift the wrong way round, they get a warning."))
            }

            ForEach($builder.templates) { $template in
                Section {
                    ForEach(template.blocks) { block in
                        if case .resistance(let resistance) = block {
                            ResistanceBlockEditor(block: resistance) { change in
                                model.builder.updateResistance(resistance.id, in: template.id, change)
                            }
                        } else {
                            Text(verbatim: block.previewTitle)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.builder.removeBlock(template.blocks[index].id, from: template.id) }
                    }
                    Button { pickerTemplate = TemplateTarget(templateID: template.id) } label: { Label(String(localized: "Add exercise"), systemImage: "plus.circle") }
                        .accessibilityIdentifier("add-exercise-\(template.label)")
                } header: {
                    HStack {
                        TextField(String(localized: "Workout name"), text: $template.label).font(.headline).textCase(nil)
                        Spacer()
                        Button(role: .destructive) { model.builder.removeTemplate(template.id) } label: { Image(systemName: "trash") }
                    }
                }
            }

            Section {
                Button { model.addDay() } label: { Label(String(localized: "Add workout day"), systemImage: "calendar.badge.plus") }
                    .accessibilityIdentifier("add-day")
            }

            if let message = model.errorMessage {
                Section { Text(verbatim: message).foregroundStyle(.red).accessibilityIdentifier("plan-error") }
            }
        }
        .navigationTitle(model.isEditing ? String(localized: "Edit workouts") : String(localized: "New workouts"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) { Task { if await model.save() { onSaved() } } }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("save-plan")
            }
        }
        .sheet(item: $pickerTemplate) { target in
            if let catalog {
                ExercisePickerSheet(model: ExercisePickerViewModel(catalog: catalog)) { exercise in
                    model.addExercise(exercise, to: target.templateID)
                }
            }
        }
    }
}

private struct TemplateTarget: Identifiable {
    let templateID: TemplateID
    var id: String { templateID.rawValue }
}

private struct ResistanceBlockEditor: View {
    let block: ResistanceBlock
    let edit: ((inout ResistanceBlock) -> Void) -> Void

    private var first: PrescribedSet? { block.sets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: block.exercise.name).font(.headline)
            Stepper(String(localized: "\(block.sets.count) sets"), value: Binding(get: { block.sets.count }, set: { count in
                edit { b in
                    let template = b.sets.first ?? PrescribedSet(index: 1, repsMin: 8, repsMax: 12)
                    b.sets = (1...max(count, 1)).map { PrescribedSet(index: $0, repsMin: template.repsMin, repsMax: template.repsMax, targetLoadKg: template.targetLoadKg) }
                }
            }), in: 1...10)
            Stepper(String(localized: "\(first?.repsMin ?? 8)–\(first?.repsMax ?? 12) reps"), onIncrement: { shiftReps(1) }, onDecrement: { shiftReps(-1) })
            Stepper(String(localized: "Rest \(block.restSeconds) s"), value: Binding(get: { block.restSeconds }, set: { value in edit { $0.restSeconds = value } }), in: 15...600, step: 15)
            HStack {
                Text(String(localized: "Starting load"))
                Spacer()
                TextField("kg", value: Binding(get: { first?.targetLoadKg }, set: { value in
                    edit { b in for index in b.sets.indices { b.sets[index].targetLoadKg = value } }
                }), format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .frame(width: 80)
                Text(verbatim: "kg").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func shiftReps(_ delta: Int) {
        edit { b in
            for index in b.sets.indices {
                b.sets[index].repsMin = max(1, b.sets[index].repsMin + delta)
                b.sets[index].repsMax = max(b.sets[index].repsMin, b.sets[index].repsMax + delta)
            }
        }
    }
}

struct ExercisePickerSheet: View {
    let model: ExercisePickerViewModel
    var title: String = String(localized: "Add exercise")
    let onPick: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if model.failed {
                    Text(String(localized: "Connect to the internet to search exercises.")).foregroundStyle(.secondary)
                }
                ForEach(model.results) { exercise in
                    Button {
                        onPick(exercise)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: exercise.name).font(.body)
                            Text(verbatim: ([exercise.primaryMuscles.first?.displayName, exercise.equipment.displayName].compactMap { $0 }).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("pick-\(exercise.id)")
                }
            }
            .searchable(text: $model.query, prompt: String(localized: "Search exercises"))
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
            .task(id: model.query) {
                try? await Task.sleep(nanoseconds: 250_000_000)           // debounce typing
                if !Task.isCancelled { await model.search() }
            }
        }
    }
}

// MARK: - Individual evolution

public struct StudentEvolutionView: View {
    private let model: StudentEvolutionViewModel

    public init(model: StudentEvolutionViewModel) { self.model = model }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    if model.isEmpty {
                        ContentUnavailableView(String(localized: "No data yet"), systemImage: "chart.xyaxis.line",
                                               description: Text(String(localized: "Charts appear after the student completes workouts.")))
                            .frame(height: 180)
                            .accessibilityIdentifier("evolution-empty")
                    } else {
                        EvolutionChart(points: model.points, configuration: model.configuration, model: model).frame(height: 230)
                            .accessibilityIdentifier("evolution-chart")
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker(String(localized: "What to measure"), selection: Binding(get: { model.configuration.metric }, set: { model.setMetric($0) })) {
                    ForEach(ProgressMetric.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .accessibilityIdentifier("metric-picker")

                Picker(String(localized: "Exercise"), selection: Binding(get: { model.configuration.exerciseID }, set: { model.setExercise($0) })) {
                    if model.canShowAllExercises { Text(String(localized: "All exercises")).tag(ExerciseID?.none) }
                    ForEach(model.exercises, id: \.id) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("exercise-picker")

                segmented(String(localized: "Group"), ChartGrouping.allCases, selection: model.configuration.grouping, id: "grouping-picker", title: \.title) { model.setGrouping($0) }
                segmented(String(localized: "Chart"), ChartStyle.allCases, selection: model.configuration.style, id: "style-picker", title: \.title) { model.setStyle($0) }
                segmented(String(localized: "Period"), ChartRange.allCases, selection: model.configuration.range, id: "range-picker", title: \.title) { model.setRange($0) }
                Toggle(String(localized: "Mark strength / volume weeks"), isOn: Binding(get: { model.configuration.showFocus }, set: { model.setShowFocus($0) }))
                    .accessibilityIdentifier("toggle-show-focus")
            } header: { Text(String(localized: "Build the chart")) }
        }
        .navigationTitle(String(localized: "Progress"))
        .task { await model.load() }
    }

    @ViewBuilder private var summary: some View {
        if let latest = model.latest {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: model.format(latest.value)).font(.title.bold()).accessibilityIdentifier("evolution-latest")
                if let change = model.changePercent {
                    Text(verbatim: change.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "%").font(.subheadline.weight(.semibold))
                        .foregroundStyle(abs(change) < 0.05 ? Color.secondary : (change > 0 ? Theme.success : Theme.warning))
                        .accessibilityIdentifier("evolution-change")
                }
                Spacer()
            }
        }
    }

    private func segmented<T: Hashable>(_ title: String, _ options: [T], selection: T, id: String, title label: @escaping (T) -> String,
                                        set: @escaping (T) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            ForEach(options, id: \.self) { Text(verbatim: label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(id)
    }
}

struct EvolutionChart: View {
    let points: [ChartPoint]
    let configuration: ChartConfiguration
    let model: StudentEvolutionViewModel

    private var seriesNames: [String] { Array(Set(points.map(series))).sorted() }

    private func color(for name: String) -> Color {
        if name == TrainingFocus.volume.title { return Theme.rest }
        if name == String(localized: "Other") { return .gray }
        return Theme.accent
    }

    private func series(_ point: ChartPoint) -> String {
        configuration.showFocus ? (point.focus?.title ?? String(localized: "Other")) : String(localized: "Workouts")
    }

    var body: some View {
        Chart(points) { point in
            switch configuration.style {
            case .line:
                LineMark(x: .value("Date", point.date), y: .value(configuration.metric.title, point.value))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                PointMark(x: .value("Date", point.date), y: .value(configuration.metric.title, point.value))
                    .foregroundStyle(by: .value("Week", series(point)))
                    .opacity(point.isDeload ? 0.4 : 1)
            case .bar:
                BarMark(x: .value("Date", point.date, unit: configuration.grouping == .perWeek ? .weekOfYear : .day),
                        y: .value(configuration.metric.title, point.value))
                    .foregroundStyle(by: .value("Week", series(point)))
                    .opacity(point.isDeload ? 0.4 : 1)
            }
        }
        // Only the series that are actually drawn appear in the legend, and the axis fits the data instead of starting at zero.
        .chartForegroundStyleScale(domain: seriesNames, range: seriesNames.map(color(for:)))
        .chartYScale(domain: .automatic(includesZero: false))
        // The Strength / Volume legend only exists while the trainer asks for the weeks to be marked; otherwise there is a single series and nothing to explain.
        .chartLegend(configuration.showFocus ? .automatic : .hidden)
        .chartYAxisLabel(configuration.metric.unit)
    }
}
