import Foundation

/// Load phase of a training week. `deload` is the *low-load* week.
public enum LoadPhase: String, Codable, Sendable, CaseIterable {
    case high
    case moderate
    case deload

    /// Deload weeks are excluded from progressive-overload trend, PR and normalised-volume maths.
    public var countsTowardProgression: Bool { self != .deload }
}

/// One training week (a *microcycle*).
public struct Microcycle: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var phase: LoadPhase
    /// Planned volume relative to a standard (1.0) week. Used to normalise non-deload volume.
    public var volumeMultiplier: Double
    /// Planned intensity (load) relative to a standard week.
    public var intensityMultiplier: Double

    public init(id: String = UUID().uuidString,
                label: String,
                phase: LoadPhase,
                volumeMultiplier: Double = 1.0,
                intensityMultiplier: Double = 1.0) {
        self.id = id
        self.label = label
        self.phase = phase
        self.volumeMultiplier = volumeMultiplier
        self.intensityMultiplier = intensityMultiplier
    }
}

/// A block of consecutive weeks with a shared goal (e.g. "Hypertrophy 12 weeks").
public struct Macrocycle: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var goal: String?
    public var microcycles: [Microcycle]

    public init(id: String = UUID().uuidString, name: String, goal: String? = nil, microcycles: [Microcycle]) {
        self.id = id
        self.name = name
        self.goal = goal
        self.microcycles = microcycles
    }

    /// Builds the classic alternating pattern, e.g. `highWeeks: 3, deloadWeeks: 1, cycles: 3`
    /// → H H H D H H H D H H H D.
    public static func alternating(name: String,
                                   highWeeks: Int,
                                   deloadWeeks: Int,
                                   cycles: Int,
                                   deloadVolume: Double = 0.5,
                                   deloadIntensity: Double = 0.85) -> Macrocycle {
        var weeks: [Microcycle] = []
        for cycle in 1...max(cycles, 1) {
            for week in 1...max(highWeeks, 1) {
                weeks.append(Microcycle(label: "Block \(cycle) · Week \(week)", phase: .high))
            }
            for week in 0..<max(deloadWeeks, 0) {
                weeks.append(Microcycle(label: "Block \(cycle) · Deload \(week + 1)",
                                        phase: .deload,
                                        volumeMultiplier: deloadVolume,
                                        intensityMultiplier: deloadIntensity))
            }
        }
        return Macrocycle(name: name, microcycles: weeks)
    }
}

/// How the "current week" advances.
public enum WeekAdvancement: String, Codable, Sendable {
    /// One completed rotation of the template sequence = one week. A missed week never skips
    /// the student into a deload they haven't earned. (Default.)
    case bySequence
    /// Calendar weeks since `startDate`.
    case byCalendar
}

public struct ResolvedWeek: Equatable, Sendable {
    /// Global, un-wrapped week ordinal (0-based) within the plan.
    public let weekIndex: Int
    public let macrocycleID: String
    public let macrocycleName: String
    public let microcycle: Microcycle
}

public struct PeriodizationPlan: Codable, Equatable, Sendable {
    public var macrocycles: [Macrocycle]
    public var advancement: WeekAdvancement
    /// Restart from week 0 when the plan runs out.
    public var loops: Bool
    public var startDate: Date

    public init(macrocycles: [Macrocycle],
                advancement: WeekAdvancement = .bySequence,
                loops: Bool = false,
                startDate: Date) {
        self.macrocycles = macrocycles
        self.advancement = advancement
        self.loops = loops
        self.startDate = startDate
    }

    private var flattened: [(macro: Macrocycle, micro: Microcycle)] {
        macrocycles.flatMap { macro in macro.microcycles.map { (macro, $0) } }
    }

    public var totalWeeks: Int { macrocycles.reduce(0) { $0 + $1.microcycles.count } }

    public func resolve(weekIndex: Int) -> ResolvedWeek? {
        let weeks = flattened
        guard !weeks.isEmpty, weekIndex >= 0 else { return nil }
        let position: Int
        if weekIndex < weeks.count {
            position = weekIndex
        } else if loops {
            position = weekIndex % weeks.count
        } else {
            return nil
        }
        let entry = weeks[position]
        return ResolvedWeek(weekIndex: weekIndex,
                            macrocycleID: entry.macro.id,
                            macrocycleName: entry.macro.name,
                            microcycle: entry.micro)
    }

    public func weekIndex(rotationIndex: Int, now: Date, calendar: Calendar = .current) -> Int {
        switch advancement {
        case .bySequence:
            return max(0, rotationIndex)
        case .byCalendar:
            let start = calendar.startOfDay(for: startDate)
            let today = calendar.startOfDay(for: now)
            let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            return max(0, days / 7)
        }
    }

    /// Global week ordinals `0...maxIndex` whose microcycle is a deload.
    public func deloadWeekIndices(upTo maxIndex: Int) -> Set<Int> {
        guard maxIndex >= 0 else { return [] }
        return Set((0...maxIndex).filter { resolve(weekIndex: $0)?.microcycle.phase == .deload })
    }
}

/// Frozen copy of the week a workout was performed in. Stored on the log at start time so
/// editing the plan later can never rewrite history or retroactively change analytics.
public struct PeriodizationSnapshot: Codable, Equatable, Sendable {
    public var weekIndex: Int
    public var phase: LoadPhase
    public var volumeMultiplier: Double
    public var intensityMultiplier: Double
    public var macrocycleID: String?

    public init(weekIndex: Int,
                phase: LoadPhase,
                volumeMultiplier: Double = 1.0,
                intensityMultiplier: Double = 1.0,
                macrocycleID: String? = nil) {
        self.weekIndex = weekIndex
        self.phase = phase
        self.volumeMultiplier = volumeMultiplier
        self.intensityMultiplier = intensityMultiplier
        self.macrocycleID = macrocycleID
    }

    public init(_ week: ResolvedWeek) {
        self.init(weekIndex: week.weekIndex,
                  phase: week.microcycle.phase,
                  volumeMultiplier: week.microcycle.volumeMultiplier,
                  intensityMultiplier: week.microcycle.intensityMultiplier,
                  macrocycleID: week.macrocycleID)
    }
}
