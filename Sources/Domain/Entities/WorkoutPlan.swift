import Foundation

// MARK: - Plan

/// A trainer-authored plan assigned to exactly one student (plans are per-individual, never shared).
public struct WorkoutPlan: Syncable, Equatable {
    public var id: PlanID
    public var trainerID: UserID
    public var studentID: UserID
    public var name: String
    /// Ordered rotation, e.g. A → B → C. The student's *next* workout is derived from the last
    /// completed template, never from the weekday (see `WorkoutSequencer`).
    public var templates: [WorkoutTemplate]
    public var periodization: PeriodizationPlan?
    /// The trainer's alternation of strength weeks (heavy, few reps) and volume weeks (lighter, many reps). Optional.
    public var focusCycle: FocusCycle?
    /// Used by the trainer dashboard to compute "scheduled vs. completed".
    public var targetSessionsPerWeek: Int
    public var startDate: Date
    public var isActive: Bool
    public var meta: SyncMetadata

    public init(id: PlanID = .generate(),
                trainerID: UserID,
                studentID: UserID,
                name: String,
                templates: [WorkoutTemplate],
                periodization: PeriodizationPlan? = nil,
                focusCycle: FocusCycle? = nil,
                targetSessionsPerWeek: Int,
                startDate: Date,
                isActive: Bool = true,
                meta: SyncMetadata) {
        self.id = id
        self.trainerID = trainerID
        self.studentID = studentID
        self.name = name
        self.templates = templates
        self.periodization = periodization
        self.focusCycle = focusCycle
        self.targetSessionsPerWeek = targetSessionsPerWeek
        self.startDate = startDate
        self.isActive = isActive
        self.meta = meta
    }

    public var orderedTemplates: [WorkoutTemplate] { templates.sorted { $0.order < $1.order } }

    public func template(id: TemplateID) -> WorkoutTemplate? { templates.first { $0.id == id } }
}

public struct WorkoutTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id: TemplateID
    public var label: String
    public var order: Int
    /// Heterogeneous and ordered: HIIT/cardio blocks sit *inside* the resistance flow
    /// (e.g. squat → squat → HIIT finisher → 10 min cooldown cardio).
    public var blocks: [WorkoutBlock]

    public init(id: TemplateID = .generate(), label: String, order: Int, blocks: [WorkoutBlock]) {
        self.id = id
        self.label = label
        self.order = order
        self.blocks = blocks
    }
}

// MARK: - Blocks

public enum WorkoutBlockKind: String, Codable, Sendable, CaseIterable, Hashable {
    case resistance, hiit, cardio
    /// A block type written by a newer app version. Preserved (not a decode failure) so an older
    /// student build can still open the rest of the plan and render a placeholder.
    case unsupported
}

public enum WorkoutBlock: Identifiable, Equatable, Sendable {
    case resistance(ResistanceBlock)
    case hiit(HIITBlock)
    case cardio(CardioBlock)
    case unsupported(UnsupportedBlock)

    public var id: BlockID {
        switch self {
        case .resistance(let b): return b.id
        case .hiit(let b): return b.id
        case .cardio(let b): return b.id
        case .unsupported(let b): return b.id
        }
    }

    public var kind: WorkoutBlockKind {
        switch self {
        case .resistance: return .resistance
        case .hiit: return .hiit
        case .cardio: return .cardio
        case .unsupported: return .unsupported
        }
    }
}

/// Wire format is flat with a discriminator — `{"type":"hiit","id":…,"rounds":8,…}` — rather than
/// Swift's synthesised `{"hiit":{"_0":{…}}}`, so Firestore documents stay readable and queryable.
extension WorkoutBlock: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch WorkoutBlockKind(rawValue: type) {
        case .resistance: self = .resistance(try ResistanceBlock(from: decoder))
        case .hiit: self = .hiit(try HIITBlock(from: decoder))
        case .cardio: self = .cardio(try CardioBlock(from: decoder))
        case .unsupported, .none: self = .unsupported(UnsupportedBlock(originalType: type))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resistance(let b):
            try container.encode(WorkoutBlockKind.resistance.rawValue, forKey: .type)
            try b.encode(to: encoder)
        case .hiit(let b):
            try container.encode(WorkoutBlockKind.hiit.rawValue, forKey: .type)
            try b.encode(to: encoder)
        case .cardio(let b):
            try container.encode(WorkoutBlockKind.cardio.rawValue, forKey: .type)
            try b.encode(to: encoder)
        case .unsupported(let b):
            try container.encode(b.originalType, forKey: .type)
        }
    }
}

public struct UnsupportedBlock: Equatable, Sendable {
    public let originalType: String
    public var id: BlockID { BlockID("unsupported-\(originalType)") }
    public init(originalType: String) { self.originalType = originalType }
}

public struct PrescribedSet: Identifiable, Codable, Equatable, Sendable {
    public var index: Int
    public var repsMin: Int
    public var repsMax: Int
    public var targetLoadKg: Double?
    public var targetRPE: Double?
    public var id: Int { index }

    public init(index: Int, repsMin: Int, repsMax: Int, targetLoadKg: Double? = nil, targetRPE: Double? = nil) {
        self.index = index
        self.repsMin = repsMin
        self.repsMax = repsMax
        self.targetLoadKg = targetLoadKg
        self.targetRPE = targetRPE
    }
}

public struct ResistanceBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: BlockID
    public var exercise: ExerciseRef
    public var sets: [PrescribedSet]
    public var restSeconds: Int
    public var notes: String?
    /// Default for the "same load across all sets" quick-logging toggle.
    public var sameLoadAcrossSets: Bool

    public init(id: BlockID = .generate(),
                exercise: ExerciseRef,
                sets: [PrescribedSet],
                restSeconds: Int = 90,
                notes: String? = nil,
                sameLoadAcrossSets: Bool = false) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.restSeconds = restSeconds
        self.notes = notes
        self.sameLoadAcrossSets = sameLoadAcrossSets
    }
}

public struct HIITBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: BlockID
    public var title: String
    public var rounds: Int
    public var workSeconds: Int
    public var restSeconds: Int
    public var movements: [String]
    public var targetRPE: Double?

    public init(id: BlockID = .generate(),
                title: String,
                rounds: Int,
                workSeconds: Int,
                restSeconds: Int,
                movements: [String] = [],
                targetRPE: Double? = nil) {
        self.id = id
        self.title = title
        self.rounds = rounds
        self.workSeconds = workSeconds
        self.restSeconds = restSeconds
        self.movements = movements
        self.targetRPE = targetRPE
    }

    public var totalSeconds: Int { rounds * (workSeconds + restSeconds) }
}

public enum CardioModality: String, Codable, Sendable, CaseIterable {
    case run, walk, bike, row, elliptical, swim, stairs
}

public struct CardioBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: BlockID
    public var modality: CardioModality
    public var targetDurationSeconds: Int
    /// Heart-rate zone 1...5 for steady-state work.
    public var targetZone: Int?
    public var notes: String?

    public init(id: BlockID = .generate(),
                modality: CardioModality,
                targetDurationSeconds: Int,
                targetZone: Int? = nil,
                notes: String? = nil) {
        self.id = id
        self.modality = modality
        self.targetDurationSeconds = targetDurationSeconds
        self.targetZone = targetZone
        self.notes = notes
    }
}
