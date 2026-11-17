import Domain
import Foundation
import Observation

/// The trainer's one-screen read of a student: how consistently they train, how much, how hard, and how closely they follow the plan.
@MainActor
@Observable
public final class StudentSummaryViewModel {
    /// What the weekly chart plots.
    public enum WeekMeasure: String, CaseIterable, Sendable {
        case volume, sets, sessions, minutes, sessionLoad

        func value(_ week: WeekMetrics) -> Double {
            switch self {
            case .volume: return week.volumeLoadKg
            case .sets: return Double(week.workingSets)
            case .sessions: return Double(week.sessions)
            case .minutes: return Double(week.minutes)
            case .sessionLoad: return week.sessionLoad
            }
        }
    }

    public private(set) var summary: TrainingSummary?
    public private(set) var isLoaded = false
    public private(set) var failed = false
    public var measure: WeekMeasure = .volume

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let logs: any WorkoutLogRepository
    @ObservationIgnored private let plans: any WorkoutPlanRepository
    @ObservationIgnored private let catalog: (any ExerciseCatalogRepository)?
    @ObservationIgnored private let builder: TrainingMetricsBuilder
    @ObservationIgnored private let now: () -> Date

    public init(studentID: UserID, logs: any WorkoutLogRepository, plans: any WorkoutPlanRepository, catalog: (any ExerciseCatalogRepository)? = nil,
                builder: TrainingMetricsBuilder = TrainingMetricsBuilder(), now: @escaping () -> Date = { Date() }) {
        self.studentID = studentID
        self.logs = logs
        self.plans = plans
        self.catalog = catalog
        self.builder = builder
        self.now = now
    }

    public func load() async {
        do {
            let history = try await logs.logs(studentID: studentID, planID: nil, since: nil)
            let plan = try? await plans.activePlan(studentID: studentID)
            let muscles = await muscleMap(for: history)
            summary = builder.summary(logs: history, plan: plan, now: now(), muscles: { muscles[$0] ?? [] })
            failed = false
        } catch {
            summary = nil
            failed = true
        }
        isLoaded = true
    }

    /// Primary muscles for the exercises done in the last week (the catalogue is cached, so this is cheap after the first time).
    private func muscleMap(for history: [WorkoutLog]) async -> [ExerciseID: [MuscleGroup]] {
        guard let catalog else { return [:] }
        let since = now().addingTimeInterval(-7 * 86_400)
        var ids = Set<ExerciseID>()
        for log in history where log.status == .completed && log.effectiveDate > since {
            for case .resistance(let performed) in log.blocks { ids.insert(performed.exercise.id) }
        }
        var map: [ExerciseID: [MuscleGroup]] = [:]
        for id in ids {
            if let exercise = try? await catalog.exercise(id: id) { map[id] = exercise.primaryMuscles }
        }
        return map
    }

    public var chartWeeks: [WeekMetrics] { summary?.weeks ?? [] }
    public func chartValue(_ week: WeekMetrics) -> Double { measure.value(week) }
    public var hasAnyWeek: Bool { chartWeeks.contains { $0.sessions > 0 } }
    public var muscleRows: [(muscle: MuscleGroup, sets: Int)] {
        (summary?.weeklySetsByMuscle ?? [:]).map { ($0.key, $0.value) }.sorted { ($0.1, $1.0.rawValue) > ($1.1, $0.0.rawValue) }
    }
}

// MARK: - Words for the numbers

public extension StudentSummaryViewModel.WeekMeasure {
    var title: String {
        switch self {
        case .volume: return String(localized: "Volume load")
        case .sets: return String(localized: "Sets")
        case .sessions: return String(localized: "Workouts")
        case .minutes: return String(localized: "Minutes")
        case .sessionLoad: return String(localized: "Effort (RPE × min)")
        }
    }

    var unit: String {
        switch self {
        case .volume: return "kg"
        case .sets: return String(localized: "sets")
        case .sessions: return String(localized: "workouts")
        case .minutes: return "min"
        case .sessionLoad: return ""
        }
    }
}

public extension WorkloadZone {
    var title: String {
        switch self {
        case .low: return String(localized: "Below usual")
        case .balanced: return String(localized: "Balanced")
        case .elevated: return String(localized: "Rising fast")
        case .high: return String(localized: "Overload risk")
        }
    }
}

public extension TrainingAlert {
    var message: String {
        switch self {
        case .noRecentSession(let days): return String(localized: "No workout for \(days) days.")
        case .lowAdherence(let percent): return String(localized: "Only \(percent)% of the planned workouts were done in the last weeks.")
        case .workloadSpike(let ratio): return String(localized: "This week's effort is \(BodyFormat.number(ratio))× the recent average. Watch recovery.")
        case .workloadDrop(let ratio): return String(localized: "This week's effort is only \(BodyFormat.number(ratio))× the recent average.")
        case .stagnant(let exercise, let sessions): return String(localized: "\(exercise.name): no new best in the last 3 of \(sessions) workouts.")
        case .restOffTarget(let percent): return String(localized: "Rest time matches the plan in only \(percent)% of the sets.")
        }
    }

    var systemImage: String {
        switch self {
        case .noRecentSession: return "calendar.badge.exclamationmark"
        case .lowAdherence: return "chart.bar.xaxis"
        case .workloadSpike, .workloadDrop: return "waveform.path.ecg"
        case .stagnant: return "equal.circle"
        case .restOffTarget: return "timer"
        }
    }
}

public enum SummaryFormat {
    public static func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    public static func daysAgo(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default: return String(localized: "\(days) days ago")
        }
    }

    public static func seconds(_ value: Int) -> String {
        value >= 60 ? "\(value / 60):" + String(format: "%02d", value % 60) : "\(value) s"
    }
}
