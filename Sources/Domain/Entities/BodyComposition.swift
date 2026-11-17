import Foundation

// MARK: - BMI

/// Body-mass index (IMC). A screening number, not a diagnosis: it can't tell muscle from fat, which is exactly why the trainer's
/// bioimpedance readings sit next to it.
public enum BodyMassIndex {
    /// WHO adult bands. They don't apply to under-18s, so `category(_:age:)` returns `nil` for them.
    public enum Category: String, Sendable, CaseIterable {
        case underweight, normal, overweight, obese
    }

    public static let adultAge = 18

    /// kg / m². `nil` for impossible inputs, so a half-typed field never shows a number.
    public static func value(weightKg: Double, heightCm: Double) -> Double? {
        guard weightKg > 0, heightCm > 0 else { return nil }
        let meters = heightCm / 100
        return weightKg / (meters * meters)
    }

    public static func category(_ bmi: Double, age: Int?) -> Category? {
        if let age, age < adultAge { return nil }
        switch bmi {
        case ..<18.5: return .underweight
        case ..<25: return .normal
        case ..<30: return .overweight
        default: return .obese
        }
    }
}

// MARK: - Checkpoint

/// One body measurement, entered by the trainer for a student: the weight plus whatever a bioimpedance scale or a tape measure gave.
/// Everything except the weight is optional — scales differ, and a trainer may only have the fat percentage.
public struct BodyCompositionCheckpoint: Syncable, Equatable {
    public var id: CheckpointID
    public var studentID: UserID
    public var trainerID: UserID
    public var planID: PlanID?
    public var recordedAt: Date
    public var bodyWeightKg: Double
    /// Body fat, %.
    public var bodyFatPercent: Double?
    /// As printed by the device; when absent they are derived from weight and body fat.
    public var measuredFatMassKg: Double?
    public var measuredLeanMassKg: Double?
    public var skeletalMuscleMassKg: Double?
    /// Total body water, % of body weight.
    public var bodyWaterPercent: Double?
    /// The scale's visceral-fat rating (a unit-less index, usually 1–30).
    public var visceralFatLevel: Int?
    public var boneMassKg: Double?
    public var basalMetabolicRateKcal: Int?
    public var metabolicAge: Int?
    /// Tape measurements, cm.
    public var waistCm: Double?
    public var hipCm: Double?
    public var notes: String?
    public var meta: SyncMetadata

    public init(id: CheckpointID = .generate(),
                studentID: UserID,
                trainerID: UserID,
                planID: PlanID? = nil,
                recordedAt: Date,
                bodyWeightKg: Double,
                bodyFatPercent: Double? = nil,
                measuredFatMassKg: Double? = nil,
                measuredLeanMassKg: Double? = nil,
                skeletalMuscleMassKg: Double? = nil,
                bodyWaterPercent: Double? = nil,
                visceralFatLevel: Int? = nil,
                boneMassKg: Double? = nil,
                basalMetabolicRateKcal: Int? = nil,
                metabolicAge: Int? = nil,
                waistCm: Double? = nil,
                hipCm: Double? = nil,
                notes: String? = nil,
                meta: SyncMetadata) {
        self.id = id
        self.studentID = studentID
        self.trainerID = trainerID
        self.planID = planID
        self.recordedAt = recordedAt
        self.bodyWeightKg = bodyWeightKg
        self.bodyFatPercent = bodyFatPercent
        self.measuredFatMassKg = measuredFatMassKg
        self.measuredLeanMassKg = measuredLeanMassKg
        self.skeletalMuscleMassKg = skeletalMuscleMassKg
        self.bodyWaterPercent = bodyWaterPercent
        self.visceralFatLevel = visceralFatLevel
        self.boneMassKg = boneMassKg
        self.basalMetabolicRateKcal = basalMetabolicRateKcal
        self.metabolicAge = metabolicAge
        self.waistCm = waistCm
        self.hipCm = hipCm
        self.notes = notes
        self.meta = meta
    }

    /// What the device printed, else weight × body fat. `nil` when neither is known.
    public var fatMassKg: Double? {
        if let measuredFatMassKg { return measuredFatMassKg }
        return bodyFatPercent.map { bodyWeightKg * $0 / 100 }
    }

    /// What the device printed, else weight − fat mass.
    public var leanMassKg: Double? {
        if let measuredLeanMassKg { return measuredLeanMassKg }
        return fatMassKg.map { bodyWeightKg - $0 }
    }

    /// Body fat as a percentage, also recovered from a measured fat mass when the percentage wasn't typed.
    public var resolvedBodyFatPercent: Double? {
        if let bodyFatPercent { return bodyFatPercent }
        return measuredFatMassKg.map { $0 / bodyWeightKg * 100 }
    }

    public var waistToHipRatio: Double? {
        guard let waistCm, let hipCm, hipCm > 0 else { return nil }
        return waistCm / hipCm
    }

    /// True when only the weight was recorded.
    public var hasOnlyWeight: Bool {
        resolvedBodyFatPercent == nil && measuredLeanMassKg == nil && skeletalMuscleMassKg == nil && bodyWaterPercent == nil && visceralFatLevel == nil
            && boneMassKg == nil && basalMetabolicRateKcal == nil && metabolicAge == nil && waistCm == nil && hipCm == nil
    }

    /// Input validation (OWASP M4): reject physiologically impossible values before they reach storage.
    public func validated() throws -> BodyCompositionCheckpoint {
        func check(_ value: Double?, _ range: ClosedRange<Double>, _ name: String) throws {
            if let value, !range.contains(value) { throw DomainError.validation("\(name) is outside \(range.lowerBound)–\(range.upperBound)") }
        }
        guard (20...400).contains(bodyWeightKg) else { throw DomainError.validation("Body weight must be between 20 and 400 kg") }
        try check(bodyFatPercent, 2...60, "Body fat %")
        try check(measuredFatMassKg, 0.5...250, "Fat mass")
        try check(measuredLeanMassKg, 5...300, "Lean mass")
        try check(skeletalMuscleMassKg, 5...150, "Skeletal muscle mass")
        try check(bodyWaterPercent, 30...80, "Body water %")
        try check(boneMassKg, 0.5...10, "Bone mass")
        try check(waistCm, 40...250, "Waist")
        try check(hipCm, 40...250, "Hip")
        if let visceralFatLevel, !(1...60).contains(visceralFatLevel) { throw DomainError.validation("Visceral fat level must be between 1 and 60") }
        if let basalMetabolicRateKcal, !(500...6000).contains(basalMetabolicRateKcal) { throw DomainError.validation("Basal metabolic rate must be between 500 and 6000 kcal") }
        if let metabolicAge, !(5...120).contains(metabolicAge) { throw DomainError.validation("Metabolic age must be between 5 and 120") }
        if let measuredFatMassKg, measuredFatMassKg >= bodyWeightKg { throw DomainError.validation("Fat mass can't exceed the body weight") }
        if let measuredLeanMassKg, measuredLeanMassKg > bodyWeightKg { throw DomainError.validation("Lean mass can't exceed the body weight") }
        if let skeletalMuscleMassKg, skeletalMuscleMassKg > bodyWeightKg { throw DomainError.validation("Muscle mass can't exceed the body weight") }
        if let notes, notes.count > 500 { throw DomainError.validation("Notes can have up to 500 characters") }
        return self
    }
}

// MARK: - Where the student stands now

/// Today's picture: the latest weight (a trainer's measurement beats the weight the student typed at sign-up), the height from sign-up,
/// the BMI that follows, and the newest bioimpedance values.
public struct BodySnapshot: Equatable, Sendable {
    public let weightKg: Double?
    public let heightCm: Double?
    public let age: Int?
    public let latest: BodyCompositionCheckpoint?
    /// Weight change since the previous measurement (needs two).
    public let weightChangeKg: Double?

    public init(profileWeightKg: Double?, heightCm: Double?, age: Int?, checkpoints: [BodyCompositionCheckpoint]) {
        let live = checkpoints.filter { !$0.meta.isDeleted }.sorted { $0.recordedAt > $1.recordedAt }
        self.latest = live.first
        self.weightKg = live.first?.bodyWeightKg ?? profileWeightKg
        self.heightCm = heightCm
        self.age = age
        self.weightChangeKg = live.count >= 2 ? live[0].bodyWeightKg - live[1].bodyWeightKg : nil
    }

    public var bmi: Double? {
        guard let weightKg, let heightCm else { return nil }
        return BodyMassIndex.value(weightKg: weightKg, heightCm: heightCm)
    }

    public var bmiCategory: BodyMassIndex.Category? { bmi.flatMap { BodyMassIndex.category($0, age: age) } }
}

// MARK: - Recording (trainer)

public struct RecordBodyCompositionUseCase: Sendable {
    public let repository: any BodyCompositionRepository

    public init(repository: any BodyCompositionRepository) { self.repository = repository }

    /// Validates, then stores. The notes are trimmed; blank means none.
    @discardableResult
    public func execute(_ checkpoint: BodyCompositionCheckpoint) async throws -> BodyCompositionCheckpoint {
        var clean = checkpoint
        let trimmed = clean.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.notes = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return try await repository.save(try clean.validated())
    }
}

// MARK: - Cycle report

public struct CycleReport: Equatable, Sendable {
    public let studentID: UserID
    public let from: Date
    public let to: Date
    public let weightDeltaKg: Double
    /// `nil` when either end has no body-fat reading.
    public let bodyFatDeltaPoints: Double?
    public let leanMassDeltaKg: Double?
    public let fatMassDeltaKg: Double?
}

public enum CycleReportBuilder {
    /// Compares the first and last checkpoint of a cycle. Returns nil with fewer than two checkpoints.
    public static func build(from checkpoints: [BodyCompositionCheckpoint]) -> CycleReport? {
        let live = checkpoints.filter { !$0.meta.isDeleted }.sorted { $0.recordedAt < $1.recordedAt }
        guard let first = live.first, let last = live.last, first.id != last.id else { return nil }
        func delta(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return b - a
        }
        return CycleReport(studentID: last.studentID,
                           from: first.recordedAt,
                           to: last.recordedAt,
                           weightDeltaKg: last.bodyWeightKg - first.bodyWeightKg,
                           bodyFatDeltaPoints: delta(first.resolvedBodyFatPercent, last.resolvedBodyFatPercent),
                           leanMassDeltaKg: delta(first.leanMassKg, last.leanMassKg),
                           fatMassDeltaKg: delta(first.fatMassKg, last.fatMassKg))
    }
}

// MARK: - What the student typed at first access

/// Height, weight and age as given at first access. The student's own device reads them from their account; the trainer reads them from the
/// registration. The weight is only a starting point — a trainer's measurement replaces it as soon as there is one.
public struct BodyProfile: Equatable, Sendable {
    public var heightCm: Double?
    public var weightKg: Double?
    public var age: Int?

    public init(heightCm: Double? = nil, weightKg: Double? = nil, age: Int? = nil) {
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.age = age
    }

    public init(_ registration: StudentRegistration) {
        self.init(heightCm: registration.heightCm, weightKg: registration.weightKg, age: registration.age)
    }
}
