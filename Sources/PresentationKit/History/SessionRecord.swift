import Domain
import Foundation

/// Everything a finished workout recorded, laid out for reading: the day, the time, every set with its load, reps, effort and rest, set against
/// what the plan asked for. The same record serves the student's history and the trainer's.
public struct SessionRecord: Identifiable, Equatable, Sendable {
    public struct SetRecord: Identifiable, Equatable, Sendable {
        public let id: String
        /// 1-based, as the student saw it ("Set 2").
        public let number: Int
        public let weightKg: Double
        public let reps: Int
        public let rpe: Double?
        /// Seconds rested before this set (nil for the first).
        public let restSeconds: Int?
        public let time: Date
        public let isWarmup: Bool
        /// "8–12", when the plan has a set at this position.
        public let prescribedReps: String?
        public let repsInRange: Bool?
        public let loadReached: Bool?
        public var volumeKg: Double { weightKg * Double(reps) }
    }

    public struct ResistanceRecord: Identifiable, Equatable, Sendable {
        public let id: BlockID
        public let exercise: String
        /// The exercise this one replaced, when it was swapped.
        public let replaced: String?
        /// "3 × 8–12 · 60 kg · 90 s rest".
        public let prescription: String?
        public let sets: [SetRecord]
        public let volumeKg: Double
        public let bestE1RM: Double?
    }

    public struct HIITRecord: Identifiable, Equatable, Sendable {
        public let id: BlockID
        public let title: String
        public let rounds: Int
        public let seconds: Int
        public let heartRate: Int?
        public let rpe: Double?
    }

    public struct CardioRecord: Identifiable, Equatable, Sendable {
        public let id: BlockID
        public let modality: String
        public let seconds: Int
        public let distanceKm: Double?
        public let heartRate: Int?
    }

    public enum Block: Identifiable, Equatable, Sendable {
        case resistance(ResistanceRecord)
        case hiit(HIITRecord)
        case cardio(CardioRecord)

        public var id: BlockID {
            switch self {
            case .resistance(let r): return r.id
            case .hiit(let h): return h.id
            case .cardio(let c): return c.id
            }
        }
    }

    public struct Totals: Equatable, Sendable {
        public let workingSets: Int
        public let reps: Int
        public let volumeKg: Double
        public let averageRestSeconds: Int?
    }

    public let id: LogID
    public let title: String
    public let startedAt: Date
    public let completedAt: Date?
    public let minutes: Int?
    public let rpe: Int?
    public let note: String?
    public let focus: TrainingFocus?
    /// Run by the trainer, with the student next to them.
    public let isCoached: Bool
    public let blocks: [Block]
    public let totals: Totals
}

public enum SessionRecordBuilder {
    /// - Parameter plan: used only to show what was asked next to what was done; a record is complete without it.
    public static func build(_ log: WorkoutLog, plan: WorkoutPlan? = nil) -> SessionRecord {
        let template = plan?.template(id: log.templateID)
        var plannedBlocks: [BlockID: WorkoutBlock] = [:]
        for block in template?.blocks ?? [] { plannedBlocks[block.id] = block }

        var blocks: [SessionRecord.Block] = []
        var working: [SessionRecord.SetRecord] = []
        for entry in log.blocks {
            switch entry {
            case .resistance(let performed):
                var prescribed: ResistanceBlock?
                if case .resistance(let planned)? = plannedBlocks[performed.blockID] { prescribed = planned }
                let sets = records(for: performed.sets, prescribed: prescribed)
                working += sets.filter { !$0.isWarmup }
                let e1RM = sets.filter { !$0.isWarmup && $0.reps >= 1 && $0.reps <= 12 }.map { OneRepMaxFormula.epley.estimate(weightKg: $0.weightKg, reps: $0.reps) }.max()
                blocks.append(.resistance(.init(id: performed.blockID, exercise: performed.exercise.name, replaced: performed.substitutedFor?.name,
                                                prescription: prescribed.map(describe), sets: sets,
                                                volumeKg: sets.filter { !$0.isWarmup }.reduce(0) { $0 + $1.volumeKg }, bestE1RM: e1RM)))
            case .hiit(let hiit):
                var title = String(localized: "HIIT")
                if case .hiit(let planned)? = plannedBlocks[hiit.blockID] { title = planned.title }
                blocks.append(.hiit(.init(id: hiit.blockID, title: title, rounds: hiit.roundsCompleted, seconds: hiit.totalSeconds, heartRate: hiit.averageHeartRate, rpe: hiit.rpe)))
            case .cardio(let cardio):
                blocks.append(.cardio(.init(id: cardio.blockID, modality: cardio.modality.displayName, seconds: cardio.durationSeconds,
                                            distanceKm: cardio.distanceMeters.map { $0 / 1000 }, heartRate: cardio.averageHeartRate)))
            }
        }

        let rests = working.compactMap(\.restSeconds)
        let minutes = log.completedAt.map { Int($0.timeIntervalSince(log.startedAt) / 60) }.flatMap { $0 >= 1 ? $0 : nil }
        return SessionRecord(id: log.id, title: log.templateLabel, startedAt: log.startedAt, completedAt: log.completedAt, minutes: minutes, rpe: log.sessionRPE,
                             note: log.feedbackNote, focus: log.focus, isCoached: log.coachedBy != nil, blocks: blocks,
                             totals: .init(workingSets: working.count, reps: working.reduce(0) { $0 + $1.reps }, volumeKg: working.reduce(0) { $0 + $1.volumeKg },
                                           averageRestSeconds: rests.isEmpty ? nil : Int((Double(rests.reduce(0, +)) / Double(rests.count)).rounded())))
    }

    private static func records(for sets: [SetLog], prescribed: ResistanceBlock?) -> [SessionRecord.SetRecord] {
        let ordered = sets.sorted { ($0.index, $0.completedAt) < ($1.index, $1.completedAt) }
        var position = 0
        return ordered.map { set in
            var target: PrescribedSet?
            if !set.isWarmup, let prescribed, position < prescribed.sets.count { target = prescribed.sets[position] }
            if !set.isWarmup { position += 1 }
            var reps: String?
            var inRange: Bool?
            var reached: Bool?
            if let target {
                reps = target.repsMin == target.repsMax ? "\(target.repsMin)" : "\(target.repsMin)–\(target.repsMax)"
                inRange = (target.repsMin...max(target.repsMin, target.repsMax)).contains(set.reps)
                if let load = target.targetLoadKg, load > 0 { reached = set.weightKg >= load * 0.975 }
            }
            return .init(id: set.id, number: set.index, weightKg: set.weightKg, reps: set.reps, rpe: set.rpe, restSeconds: set.restTakenSeconds, time: set.completedAt,
                         isWarmup: set.isWarmup, prescribedReps: reps, repsInRange: inRange, loadReached: reached)
        }
    }

    private static func describe(_ block: ResistanceBlock) -> String {
        guard let first = block.sets.first else { return "" }
        let allSame = block.sets.allSatisfy { $0.repsMin == first.repsMin && $0.repsMax == first.repsMax }
        let reps = first.repsMin == first.repsMax ? "\(first.repsMin)" : "\(first.repsMin)–\(first.repsMax)"
        var parts = [allSame ? "\(block.sets.count) × \(reps)" : String(localized: "\(block.sets.count) sets")]
        let loads = Set(block.sets.compactMap(\.targetLoadKg))
        if loads.count == 1, let load = loads.first { parts.append("\(LoadFormat.kg(load)) kg") }
        parts.append(String(localized: "\(SummaryFormat.seconds(block.restSeconds)) rest"))
        return parts.joined(separator: " · ")
    }
}
