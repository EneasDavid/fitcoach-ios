import Foundation

public enum WorkoutStatus: String, Codable, Sendable {
    case inProgress
    /// Finished by the student. Advances the rotation.
    case completed
    /// Left unfinished (or timed out). Does **not** advance the rotation.
    case abandoned
    /// Explicitly skipped by the student. Advances the rotation.
    case skipped
}

public struct SetLog: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var index: Int
    public var weightKg: Double
    public var reps: Int
    public var rpe: Double?
    /// Seconds actually rested *before* this set (nil for the first set).
    public var restTakenSeconds: Int?
    public var completedAt: Date
    public var isWarmup: Bool

    public init(id: String = UUID().uuidString,
                index: Int,
                weightKg: Double,
                reps: Int,
                rpe: Double? = nil,
                restTakenSeconds: Int? = nil,
                completedAt: Date,
                isWarmup: Bool = false) {
        self.id = id
        self.index = index
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.restTakenSeconds = restTakenSeconds
        self.completedAt = completedAt
        self.isWarmup = isWarmup
    }

    public var volumeKg: Double { weightKg * Double(reps) }
}

public struct ResistanceLog: Codable, Equatable, Sendable {
    public var blockID: BlockID
    /// What was actually performed.
    public var exercise: ExerciseRef
    /// Set when the student swapped the prescribed exercise for a substitute in this session.
    /// Progression analytics follow `exercise` (the substitute), so a swap never pollutes the original's history.
    public var substitutedFor: ExerciseRef?
    public var sets: [SetLog]

    public init(blockID: BlockID, exercise: ExerciseRef, substitutedFor: ExerciseRef? = nil, sets: [SetLog] = []) {
        self.blockID = blockID
        self.exercise = exercise
        self.substitutedFor = substitutedFor
        self.sets = sets
    }
}

public struct HIITLog: Codable, Equatable, Sendable {
    public var blockID: BlockID
    public var roundsCompleted: Int
    public var totalSeconds: Int
    public var averageHeartRate: Int?
    public var rpe: Double?

    public init(blockID: BlockID, roundsCompleted: Int, totalSeconds: Int, averageHeartRate: Int? = nil, rpe: Double? = nil) {
        self.blockID = blockID
        self.roundsCompleted = roundsCompleted
        self.totalSeconds = totalSeconds
        self.averageHeartRate = averageHeartRate
        self.rpe = rpe
    }
}

public struct CardioLog: Codable, Equatable, Sendable {
    public var blockID: BlockID
    public var modality: CardioModality
    public var durationSeconds: Int
    public var distanceMeters: Double?
    public var averageHeartRate: Int?

    public init(blockID: BlockID, modality: CardioModality, durationSeconds: Int, distanceMeters: Double? = nil, averageHeartRate: Int? = nil) {
        self.blockID = blockID
        self.modality = modality
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.averageHeartRate = averageHeartRate
    }
}

public enum BlockLog: Equatable, Sendable {
    case resistance(ResistanceLog)
    case hiit(HIITLog)
    case cardio(CardioLog)

    public var blockID: BlockID {
        switch self {
        case .resistance(let l): return l.blockID
        case .hiit(let l): return l.blockID
        case .cardio(let l): return l.blockID
        }
    }
}

extension BlockLog: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(WorkoutBlockKind.self, forKey: .type)
        switch kind {
        case .resistance: self = .resistance(try ResistanceLog(from: decoder))
        case .hiit: self = .hiit(try HIITLog(from: decoder))
        case .cardio: self = .cardio(try CardioLog(from: decoder))
        case .unsupported:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Logs cannot be of an unsupported block type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resistance(let l):
            try container.encode(WorkoutBlockKind.resistance, forKey: .type)
            try l.encode(to: encoder)
        case .hiit(let l):
            try container.encode(WorkoutBlockKind.hiit, forKey: .type)
            try l.encode(to: encoder)
        case .cardio(let l):
            try container.encode(WorkoutBlockKind.cardio, forKey: .type)
            try l.encode(to: encoder)
        }
    }
}

/// One execution of a `WorkoutTemplate` by a student. Owned and written only by the student.
public struct WorkoutLog: Syncable, Equatable {
    public var id: LogID
    public var planID: PlanID
    public var templateID: TemplateID
    /// Snapshot of the template label ("Workout B – Pull") so history survives plan edits.
    public var templateLabel: String
    public var studentID: UserID
    public var status: WorkoutStatus
    public var startedAt: Date
    public var completedAt: Date?
    /// How many full passes through the template rotation precede this session.
    public var rotationIndex: Int
    /// Frozen periodization context; `nil` for plans without periodization (treated as `.high`).
    public var periodization: PeriodizationSnapshot?
    /// Whether this was a strength or a volume week, frozen when the workout started (like `periodization`).
    public var focus: TrainingFocus?
    public var blocks: [BlockLog]
    /// Post-workout perceived exertion, 1...10.
    public var sessionRPE: Int?
    public var feedbackNote: String?
    public var checkInID: CheckInID?
    /// The trainer who ran this session on their own device, with the student next to them ("treino acompanhado"). `nil` = the student's own.
    /// Such a session lives in the trainer-written collection, so a student's device can neither create nor edit it.
    public var coachedBy: UserID?
    public var meta: SyncMetadata

    public init(id: LogID = .generate(),
                planID: PlanID,
                templateID: TemplateID,
                templateLabel: String,
                studentID: UserID,
                status: WorkoutStatus = .inProgress,
                startedAt: Date,
                completedAt: Date? = nil,
                rotationIndex: Int = 0,
                periodization: PeriodizationSnapshot? = nil,
                focus: TrainingFocus? = nil,
                blocks: [BlockLog] = [],
                sessionRPE: Int? = nil,
                feedbackNote: String? = nil,
                checkInID: CheckInID? = nil,
                coachedBy: UserID? = nil,
                meta: SyncMetadata) {
        self.id = id
        self.planID = planID
        self.templateID = templateID
        self.templateLabel = templateLabel
        self.studentID = studentID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.rotationIndex = rotationIndex
        self.periodization = periodization
        self.focus = focus
        self.blocks = blocks
        self.sessionRPE = sessionRPE
        self.feedbackNote = feedbackNote
        self.checkInID = checkInID
        self.coachedBy = coachedBy
        self.meta = meta
    }

    public var effectiveDate: Date { completedAt ?? startedAt }
    public var loadPhase: LoadPhase { periodization?.phase ?? .high }

    /// Replaces the log for `blockID` (or appends it). A strength log with no sets left (the student undid
    /// their only completed set) removes the block's entry instead of storing an empty one.
    public mutating func record(_ blockLog: BlockLog) {
        if case .resistance(let log) = blockLog, log.sets.isEmpty {
            blocks.removeAll { $0.blockID == log.blockID }
            return
        }
        if let index = blocks.firstIndex(where: { $0.blockID == blockLog.blockID }) {
            blocks[index] = blockLog
        } else {
            blocks.append(blockLog)
        }
    }

    public mutating func complete(at date: Date, sessionRPE: Int, note: String?) throws {
        guard status == .inProgress else {
            throw DomainError.invalidState("Only an in-progress workout can be completed")
        }
        guard (1...10).contains(sessionRPE) else {
            throw DomainError.validation("Session RPE must be between 1 and 10")
        }
        self.status = .completed
        self.completedAt = date
        self.sessionRPE = sessionRPE
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.feedbackNote = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
