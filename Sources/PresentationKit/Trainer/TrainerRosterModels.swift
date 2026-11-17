import Domain
import Foundation
import Observation

// MARK: - Student directory

/// The personal trainer's students: search, register (CPF + name), and a private nickname per student.
@MainActor
@Observable
public final class TrainerRosterViewModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let registration: StudentRegistration
        public let nickname: String?
        public let plan: WorkoutPlan?
        /// Weight (latest measurement, else the one typed at sign-up), height and BMI. `nil` until the student has done their first access.
        public var body: BodySnapshot?

        public var id: String { registration.id }
        /// What the trainer sees as the student's label: their own nickname if they gave one, else the real name.
        public var title: String { nickname ?? registration.fullName }
        /// The real name sits underneath a nickname; otherwise the masked CPF does.
        public var subtitle: String { nickname == nil ? registration.cpfMasked : registration.fullName }

        public var statusText: String {
            switch (registration.status, plan) {
            case (.invited, _): return String(localized: "Waiting for first access")
            case (.active, nil): return String(localized: "No plan yet")
            case (.active, let plan?): return plan.name
            }
        }

        public var needsPlan: Bool { registration.status == .active && plan == nil }
    }

    public var query = ""
    public private(set) var rows: [Row] = []
    public private(set) var isLoaded = false
    public private(set) var loadFailed = false

    // Add-student form
    public var newCPF = ""
    public var newName = ""
    public private(set) var addError: String?
    public private(set) var isAdding = false

    @ObservationIgnored private let trainerID: UserID
    @ObservationIgnored private let registrations: any StudentRegistering
    @ObservationIgnored private let plans: any WorkoutPlanRepository
    @ObservationIgnored private let nicknames: any NicknameRepository
    @ObservationIgnored private let bodyMeasurements: (any BodyCompositionRepository)?

    public init(trainerID: UserID, registrations: any StudentRegistering, plans: any WorkoutPlanRepository, nicknames: any NicknameRepository,
                bodyMeasurements: (any BodyCompositionRepository)? = nil) {
        self.trainerID = trainerID
        self.registrations = registrations
        self.plans = plans
        self.nicknames = nicknames
        self.bodyMeasurements = bodyMeasurements
    }

    /// Search over nickname, real name and the visible CPF digits; accents and case are ignored.
    public var filtered: [Row] {
        let needle = RegistrationRules.normalizedName(query)
        let digits = query.filter(\.isNumber)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            RegistrationRules.normalizedName(row.registration.fullName).contains(needle)
                || RegistrationRules.normalizedName(row.nickname ?? "").contains(needle)
                || (!digits.isEmpty && row.registration.cpfMasked.filter(\.isNumber).contains(digits))
        }
    }

    public func load() async {
        do {
            let all = try await registrations.registrations(trainerID: trainerID)
            let names = (try? await nicknames.nicknames(trainerID: trainerID)) ?? [:]
            var built: [Row] = []
            for registration in all {
                var plan: WorkoutPlan?
                var body: BodySnapshot?
                if let studentID = registration.studentID {
                    plan = try? await plans.activePlan(studentID: studentID)
                    let measurements = (try? await bodyMeasurements?.checkpoints(studentID: studentID)) ?? []
                    body = BodySnapshot(profileWeightKg: registration.weightKg, heightCm: registration.heightCm, age: registration.age, checkpoints: measurements)
                }
                built.append(Row(registration: registration, nickname: names[registration.id], plan: plan, body: body))
            }
            rows = built.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
            loadFailed = false
        } catch {
            loadFailed = true
        }
        isLoaded = true
    }

    @discardableResult
    public func add() async -> Bool {
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            _ = try await registrations.register(cpf: newCPF, fullName: newName, trainerID: trainerID)
            newCPF = ""
            newName = ""
            await load()
            return true
        } catch {
            addError = Self.message(for: error)
            return false
        }
    }

    public func setNickname(_ text: String, forStudent id: String) async {
        do {
            try await nicknames.setNickname(text, forRegistration: id, trainerID: trainerID)
            await load()
        } catch {
            addError = String(localized: "Nicknames can have up to 30 characters.")
        }
    }

    public func row(id: String) -> Row? { rows.first { $0.id == id } }

    static func message(for error: Error) -> String {
        switch error as? RegistrationError {
        case .invalidCPF: return String(localized: "That CPF isn't valid.")
        case .invalidName: return String(localized: "Enter the student's full name (first and last).")
        case .duplicate: return String(localized: "This CPF is already registered.")
        case .offline: return String(localized: "No connection. Try again.")
        default: return String(localized: "Something went wrong. Please try again.")
        }
    }
}

// MARK: - Plan editor (only the personal trainer can create or change a student's workouts)

@MainActor
@Observable
public final class PlanEditorViewModel {
    public let builder: PlanBuilderViewModel
    public let student: StudentRegistration
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var didSave = false

    @ObservationIgnored private let trainerID: UserID
    @ObservationIgnored private let existing: WorkoutPlan?
    @ObservationIgnored private let plans: any WorkoutPlanRepository
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let now: () -> Date

    public init(trainerID: UserID, student: StudentRegistration, existing: WorkoutPlan?, plans: any WorkoutPlanRepository,
                deviceID: String = "", now: @escaping () -> Date = { Date() }) {
        self.trainerID = trainerID
        self.student = student
        self.existing = existing
        self.plans = plans
        self.deviceID = deviceID
        self.now = now
        self.builder = existing.map(PlanBuilderViewModel.init(editing:)) ?? PlanBuilderViewModel()
        if existing == nil {
            builder.name = String(localized: "Plan for \(student.fullName.split(separator: " ").first.map(String.init) ?? student.fullName)")
        }
    }

    public var issues: [PlanIssue] { builder.validate() }
    public var isEditing: Bool { existing != nil }

    /// "Workout A", "Workout B"… the next free letter.
    @discardableResult
    public func addDay() -> TemplateID {
        let used = Set(builder.templates.map(\.label))
        let letters = "ABCDEFGHIJKLMN".map(String.init)
        let letter = letters.first { !used.contains(String(localized: "Workout \($0)")) } ?? "\(builder.templates.count + 1)"
        return builder.addTemplate(label: String(localized: "Workout \(letter)"))
    }

    public func addExercise(_ exercise: Exercise, to templateID: TemplateID, sets: Int = 3, repsMin: Int = 8, repsMax: Int = 12,
                            loadKg: Double? = nil, restSeconds: Int = 90) {
        let prescribed = (1...max(sets, 1)).map { PrescribedSet(index: $0, repsMin: repsMin, repsMax: max(repsMax, repsMin), targetLoadKg: loadKg) }
        builder.addBlock(.resistance(ResistanceBlock(exercise: ExerciseRef(exercise), sets: prescribed, restSeconds: restSeconds)), to: templateID)
    }

    @discardableResult
    public func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        guard let studentID = student.studentID else {
            errorMessage = String(localized: "The student hasn't done their first access yet.")
            return false
        }
        do {
            let plan = try builder.build(trainerID: trainerID, studentID: studentID, startDate: now(), deviceID: deviceID, reusing: existing)
            _ = try await plans.save(plan)
            didSave = true
            return true
        } catch let error as DomainError {
            if case .validation(let text) = error { errorMessage = text } else { errorMessage = String(localized: "Couldn't save the plan.") }
            return false
        } catch {
            errorMessage = String(localized: "Couldn't save the plan.")
            return false
        }
    }
}

@MainActor
@Observable
public final class ExercisePickerViewModel {
    public var query = ""
    public private(set) var results: [Exercise] = []
    public private(set) var isSearching = false
    public private(set) var failed = false

    @ObservationIgnored private let catalog: any ExerciseCatalogRepository

    public init(catalog: any ExerciseCatalogRepository) { self.catalog = catalog }

    public func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await catalog.search(query: query.trimmingCharacters(in: .whitespaces), limit: 30)
            failed = false
        } catch {
            results = []
            failed = true
        }
    }
}

// MARK: - Individual progress (the trainer chooses how the charts are built)

@MainActor
@Observable
public final class StudentEvolutionViewModel {
    public var configuration: ChartConfiguration {
        didSet { if oldValue != configuration { recompute(); onConfigurationChange(configuration) } }
    }
    public private(set) var points: [ChartPoint] = []
    public private(set) var exercises: [ExerciseRef] = []
    public private(set) var isLoaded = false
    public private(set) var failed = false

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let logs: any WorkoutLogRepository
    @ObservationIgnored private let builder: ProgressChartBuilder
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let onConfigurationChange: (ChartConfiguration) -> Void
    @ObservationIgnored private var history: [WorkoutLog] = []

    public init(studentID: UserID, logs: any WorkoutLogRepository, configuration: ChartConfiguration = ChartConfiguration(),
                builder: ProgressChartBuilder = ProgressChartBuilder(), now: @escaping () -> Date = { Date() },
                onConfigurationChange: @escaping (ChartConfiguration) -> Void = { _ in }) {
        self.studentID = studentID
        self.logs = logs
        self.configuration = configuration
        self.builder = builder
        self.now = now
        self.onConfigurationChange = onConfigurationChange
    }

    public func load() async {
        do {
            history = try await logs.logs(studentID: studentID, planID: nil, since: nil)
            exercises = builder.exercises(in: history)
            failed = false
        } catch {
            history = []
            failed = true
        }
        isLoaded = true
        // Single-exercise metrics need an exercise: default to the most-logged one.
        let fixed = configuration.normalised(defaultExercise: exercises.first?.id)
        if fixed != configuration { configuration = fixed } else { recompute() }
    }

    private func recompute() {
        points = builder.points(logs: history, configuration: configuration, now: now())
    }

    // MARK: What the trainer can change

    public func setMetric(_ metric: ProgressMetric) {
        var next = configuration
        next.metric = metric
        configuration = next.normalised(defaultExercise: exercises.first?.id)
    }

    public func setExercise(_ id: ExerciseID?) {
        var next = configuration
        next.exerciseID = id
        configuration = next.normalised(defaultExercise: exercises.first?.id)
    }

    public func setGrouping(_ grouping: ChartGrouping) { configuration.grouping = grouping }
    public func setStyle(_ style: ChartStyle) { configuration.style = style }
    public func setRange(_ range: ChartRange) { configuration.range = range }
    public func setShowFocus(_ show: Bool) { configuration.showFocus = show }

    /// "All exercises" only makes sense for metrics that add up (volume, sets, reps, rest).
    public var canShowAllExercises: Bool { !configuration.metric.needsSingleExercise }
    public var changePercent: Double? { builder.changePercent(points) }
    public var latest: ChartPoint? { points.last }
    public var isEmpty: Bool { isLoaded && points.isEmpty }

    public func format(_ value: Double) -> String {
        switch configuration.metric {
        case .estimatedOneRepMax, .topSetLoad, .volume: return "\(LoadFormat.kg(value)) kg"
        case .workingSets: return "\(Int(value.rounded()))"
        case .averageReps: return value.formatted(.number.precision(.fractionLength(0...1)))
        case .averageRest: return "\(Int(value.rounded())) s"
        }
    }
}

public extension ProgressMetric {
    var title: String {
        switch self {
        case .estimatedOneRepMax: return String(localized: "Estimated 1RM")
        case .topSetLoad: return String(localized: "Heaviest load")
        case .volume: return String(localized: "Volume")
        case .workingSets: return String(localized: "Sets")
        case .averageReps: return String(localized: "Average reps")
        case .averageRest: return String(localized: "Rest time")
        }
    }
}

public extension ChartGrouping {
    var title: String { self == .perSession ? String(localized: "Per workout") : String(localized: "Per week") }
}

public extension ChartStyle {
    var title: String { self == .line ? String(localized: "Line") : String(localized: "Bars") }
}

public extension ChartRange {
    var title: String {
        switch self {
        case .fourWeeks: return String(localized: "4 weeks")
        case .twelveWeeks: return String(localized: "12 weeks")
        case .all: return String(localized: "All")
        }
    }
}

public extension TrainingFocus {
    var title: String { self == .strength ? String(localized: "Strength") : String(localized: "Volume") }
}
