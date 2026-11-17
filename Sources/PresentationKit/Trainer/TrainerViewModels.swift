import Domain
import Foundation
import Observation

// MARK: - Plan builder (trainer assigns & customises routines per student)

public struct PlanIssue: Equatable, Sendable, Identifiable {
    public let id: String
    public let message: String
}

public struct PeriodizationDraft: Equatable, Sendable {
    public var enabled = false
    public var highWeeks = 3
    public var deloadWeeks = 1
    public var cycles = 3
    public var advancement: WeekAdvancement = .bySequence
}

public struct FocusDraft: Equatable, Sendable {
    public var enabled = false
    public var strengthWeeks = 3
    public var volumeWeeks = 3
    public var startsWith: TrainingFocus = .strength
    public var strengthRepsMin = 3, strengthRepsMax = 6
    public var volumeRepsMin = 10, volumeRepsMax = 15

    public init() {}

    var cycle: FocusCycle {
        FocusCycle(strengthWeeks: strengthWeeks, volumeWeeks: volumeWeeks, startsWith: startsWith,
                   strengthReps: strengthRepsMin...max(strengthRepsMin, strengthRepsMax), volumeReps: volumeRepsMin...max(volumeRepsMin, volumeRepsMax))
    }
}

/// Editing state for a plan, with validation. Pure logic; the SwiftUI form binds to it.
@MainActor
@Observable
public final class PlanBuilderViewModel {
    public var name = ""
    public var targetSessionsPerWeek = 3
    public var templates: [WorkoutTemplate] = []
    public var periodization = PeriodizationDraft()
    /// "N weeks of strength, M weeks of volume" — and the student is warned when they lift the wrong way round.
    public var focus = FocusDraft()

    public init() {}

    public init(editing plan: WorkoutPlan) {
        name = plan.name
        targetSessionsPerWeek = plan.targetSessionsPerWeek
        templates = plan.orderedTemplates
        if let cycle = plan.focusCycle {
            focus = FocusDraft()
            focus.enabled = true
            focus.strengthWeeks = cycle.strengthWeeks; focus.volumeWeeks = cycle.volumeWeeks; focus.startsWith = cycle.startsWith
            focus.strengthRepsMin = cycle.strengthReps.lowerBound; focus.strengthRepsMax = cycle.strengthReps.upperBound
            focus.volumeRepsMin = cycle.volumeReps.lowerBound; focus.volumeRepsMax = cycle.volumeReps.upperBound
        }
        // Recover the alternating pattern (H…H D…D, repeated) from the stored plan so editing round-trips.
        if let existing = plan.periodization, let first = existing.macrocycles.first {
            let weeks = first.microcycles
            let high = weeks.prefix { $0.phase != .deload }.count
            let deload = weeks.dropFirst(high).prefix { $0.phase == .deload }.count
            let cycleLength = max(high + deload, 1)
            periodization = PeriodizationDraft(enabled: true, highWeeks: max(high, 1), deloadWeeks: deload,
                                               cycles: max(weeks.count / cycleLength, 1), advancement: existing.advancement)
        }
    }

    // MARK: Editing

    @discardableResult
    public func addTemplate(label: String) -> TemplateID {
        let template = WorkoutTemplate(label: label, order: templates.count, blocks: [])
        templates.append(template)
        return template.id
    }

    public func removeTemplate(_ id: TemplateID) {
        templates.removeAll { $0.id == id }
        renumber()
    }

    public func moveTemplate(from source: Int, to destination: Int) {
        guard templates.indices.contains(source), (0...templates.count).contains(destination) else { return }
        let moved = templates.remove(at: source)
        templates.insert(moved, at: min(destination > source ? destination - 1 : destination, templates.count))
        renumber()
    }

    public func addBlock(_ block: WorkoutBlock, to templateID: TemplateID) {
        guard let index = templates.firstIndex(where: { $0.id == templateID }) else { return }
        templates[index].blocks.append(block)
    }

    public func removeBlock(_ blockID: BlockID, from templateID: TemplateID) {
        guard let index = templates.firstIndex(where: { $0.id == templateID }) else { return }
        templates[index].blocks.removeAll { $0.id == blockID }
    }

    /// HIIT / cardio blocks sit *between* resistance blocks, so reordering is by position.
    /// Edits one strength exercise in place (sets, reps, load, rest). Anything else is ignored.
    public func updateResistance(_ blockID: BlockID, in templateID: TemplateID, _ change: (inout ResistanceBlock) -> Void) {
        guard let t = templates.firstIndex(where: { $0.id == templateID }),
              let b = templates[t].blocks.firstIndex(where: { $0.id == blockID }),
              case .resistance(var block) = templates[t].blocks[b] else { return }
        change(&block)
        templates[t].blocks[b] = .resistance(block)
    }

    public func moveBlock(in templateID: TemplateID, from source: Int, to destination: Int) {
        guard let index = templates.firstIndex(where: { $0.id == templateID }),
              templates[index].blocks.indices.contains(source), (0...templates[index].blocks.count).contains(destination) else { return }
        let moved = templates[index].blocks.remove(at: source)
        templates[index].blocks.insert(moved, at: min(destination > source ? destination - 1 : destination, templates[index].blocks.count))
    }

    private func renumber() {
        for index in templates.indices { templates[index].order = index }
    }

    // MARK: Validation & build

    public func validate() -> [PlanIssue] {
        var issues: [PlanIssue] = []
        func add(_ key: String, _ message: String) { issues.append(PlanIssue(id: key, message: message)) }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("name", "Give the plan a name.") }
        if !(1...7).contains(targetSessionsPerWeek) { add("sessions", "Sessions per week must be between 1 and 7.") }
        if templates.isEmpty { add("templates", "Add at least one workout.") }

        for template in templates {
            if template.blocks.isEmpty { add("empty-\(template.id)", "\(template.label) has no exercises.") }
            for block in template.blocks {
                switch block {
                case .resistance(let resistance):
                    if resistance.sets.isEmpty { add("sets-\(resistance.id)", "\(resistance.exercise.name) needs at least one set.") }
                    if resistance.sets.contains(where: { $0.repsMin < 1 || $0.repsMax < $0.repsMin || $0.repsMax > 100 }) {
                        add("reps-\(resistance.id)", "\(resistance.exercise.name) has an invalid rep range.")
                    }
                    if !(0...600).contains(resistance.restSeconds) { add("rest-\(resistance.id)", "\(resistance.exercise.name) rest must be 0–600 s.") }
                case .hiit(let hiit):
                    if !(1...50).contains(hiit.rounds) || hiit.workSeconds < 5 || hiit.restSeconds < 0 {
                        add("hiit-\(hiit.id)", "\(hiit.title) needs 1–50 rounds and at least 5 s of work.")
                    }
                case .cardio(let cardio):
                    if cardio.targetDurationSeconds < 60 { add("cardio-\(cardio.id)", "Cardio must be at least 1 minute.") }
                    if let zone = cardio.targetZone, !(1...5).contains(zone) { add("zone-\(cardio.id)", "Heart-rate zone must be 1–5.") }
                case .unsupported:
                    add("unsupported-\(block.id)", "This plan contains a block type this app version can't edit.")
                }
            }
        }

        if periodization.enabled {
            if !(1...12).contains(periodization.highWeeks) { add("high", "High-load weeks must be 1–12.") }
            if !(0...4).contains(periodization.deloadWeeks) { add("deload", "Deload weeks must be 0–4.") }
            if !(1...12).contains(periodization.cycles) { add("cycles", "Cycles must be 1–12.") }
        }
        if focus.enabled {
            if !(1...12).contains(focus.strengthWeeks) { add("strength-weeks", "Strength weeks must be 1–12.") }
            if !(1...12).contains(focus.volumeWeeks) { add("volume-weeks", "Volume weeks must be 1–12.") }
            if focus.strengthRepsMin < 1 || focus.strengthRepsMax < focus.strengthRepsMin || focus.strengthRepsMax > 100 { add("strength-reps", "Strength reps need a valid range.") }
            if focus.volumeRepsMin < 1 || focus.volumeRepsMax < focus.volumeRepsMin || focus.volumeRepsMax > 100 { add("volume-reps", "Volume reps need a valid range.") }
        }
        return issues
    }

    /// - Parameter existing: when editing, keeps the plan's identity and start date (so strength/volume weeks and history stay anchored).
    public func build(trainerID: UserID, studentID: UserID, startDate: Date, deviceID: String = "", reusing existing: WorkoutPlan? = nil) throws -> WorkoutPlan {
        let issues = validate()
        guard issues.isEmpty else { throw DomainError.validation(issues.map(\.message).joined(separator: " ")) }

        var program: PeriodizationPlan?
        if periodization.enabled {
            let macrocycle = Macrocycle.alternating(name: name, highWeeks: periodization.highWeeks,
                                                    deloadWeeks: periodization.deloadWeeks, cycles: periodization.cycles)
            program = PeriodizationPlan(macrocycles: [macrocycle], advancement: periodization.advancement, startDate: startDate)
        }
        var plan = WorkoutPlan(trainerID: trainerID, studentID: studentID,
                               name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               templates: templates, periodization: program,
                               focusCycle: focus.enabled ? focus.cycle : nil,
                               targetSessionsPerWeek: targetSessionsPerWeek, startDate: existing?.startDate ?? startDate,
                               meta: existing?.meta ?? SyncMetadata(updatedAt: startDate, lastWriterDeviceID: deviceID))
        if let existing { plan.id = existing.id }
        return plan
    }
}

// MARK: - Student progress dashboard

@MainActor
@Observable
public final class StudentProgressViewModel {
    public enum LoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public private(set) var state: LoadState = .idle
    public private(set) var series: ProgressionSeries?
    public private(set) var weeklyVolume: [WeeklyVolume] = []
    public private(set) var adherence: AdherenceReport?
    public private(set) var exercises: [ExerciseRef] = []

    @ObservationIgnored private let plan: WorkoutPlan
    @ObservationIgnored private let logs: any WorkoutLogRepository
    @ObservationIgnored private let engine: ProgressionEngine
    @ObservationIgnored private let adherenceCalculator: AdherenceCalculator
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar

    public init(plan: WorkoutPlan,
                logs: any WorkoutLogRepository,
                engine: ProgressionEngine = ProgressionEngine(),
                adherenceCalculator: AdherenceCalculator = AdherenceCalculator(),
                now: @escaping @MainActor () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.plan = plan
        self.logs = logs
        self.engine = engine
        self.adherenceCalculator = adherenceCalculator
        self.now = now
        self.calendar = calendar

        var seen = Set<ExerciseID>()
        exercises = plan.orderedTemplates.flatMap(\.blocks).compactMap { block -> ExerciseRef? in
            guard case .resistance(let resistance) = block, seen.insert(resistance.exercise.id).inserted else { return nil }
            return resistance.exercise
        }
    }

    public func load(exercise: ExerciseID, adherenceWeeks: Int = 4) async {
        state = .loading
        do {
            let history = try await logs.logs(studentID: plan.studentID, planID: nil, since: nil)
            series = engine.series(for: exercise, logs: history, periodization: plan.periodization, calendar: calendar)
            weeklyVolume = engine.weeklyVolume(logs: history, calendar: calendar)
            let end = now()
            let start = calendar.date(byAdding: .weekOfYear, value: -adherenceWeeks, to: end) ?? end
            adherence = adherenceCalculator.report(plan: plan, logs: history, interval: DateInterval(start: start, end: end))
            state = .loaded
        } catch {
            state = .failed(String(localized: "Couldn't load this student's history."))
        }
    }
}
