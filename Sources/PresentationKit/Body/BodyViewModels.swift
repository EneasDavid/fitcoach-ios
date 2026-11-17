import Domain
import Foundation
import Observation

// MARK: - The form (what the trainer types after a bioimpedance reading)

/// Everything typed as text, parsed on demand: a half-typed field never throws, it just isn't a number yet.
@MainActor
@Observable
public final class BodyMeasurementDraft {
    public enum Field: String, CaseIterable, Sendable {
        case weight, bodyFat, fatMass, leanMass, muscleMass, water, visceral, bone, metabolicRate, metabolicAge, waist, hip
    }

    public var date: Date
    public var weight = ""
    public var bodyFat = ""
    public var fatMass = ""
    public var leanMass = ""
    public var muscleMass = ""
    public var water = ""
    public var visceral = ""
    public var bone = ""
    public var metabolicRate = ""
    public var metabolicAge = ""
    public var waist = ""
    public var hip = ""
    public var notes = ""

    public init(now: Date = Date()) { date = now }

    public func reset(now: Date = Date()) {
        date = now
        weight = ""; bodyFat = ""; fatMass = ""; leanMass = ""; muscleMass = ""; water = ""; visceral = ""; bone = ""
        metabolicRate = ""; metabolicAge = ""; waist = ""; hip = ""; notes = ""
    }

    private func text(_ field: Field) -> String {
        switch field {
        case .weight: return weight
        case .bodyFat: return bodyFat
        case .fatMass: return fatMass
        case .leanMass: return leanMass
        case .muscleMass: return muscleMass
        case .water: return water
        case .visceral: return visceral
        case .bone: return bone
        case .metabolicRate: return metabolicRate
        case .metabolicAge: return metabolicAge
        case .waist: return waist
        case .hip: return hip
        }
    }

    private static let wholeNumbers: Set<Field> = [.visceral, .metabolicRate, .metabolicAge]

    private func decimal(_ field: Field) -> Double? { DecimalInput.parse(text(field)) }
    private func whole(_ field: Field) -> Int? {
        guard let value = decimal(field), value == value.rounded() else { return nil }
        return Int(value)
    }

    public var weightKg: Double? { decimal(.weight) }

    /// Fields with something typed that isn't a number (or isn't a whole number where one is needed).
    public var unreadable: [Field] {
        Field.allCases.filter { field in
            let typed = text(field).trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { return false }
            return Self.wholeNumbers.contains(field) ? whole(field) == nil : decimal(field) == nil
        }
    }

    public var canSave: Bool { weightKg != nil && unreadable.isEmpty }

    /// BMI with the weight being typed, so the trainer sees the effect before saving.
    public func bmiPreview(heightCm: Double?) -> Double? {
        guard let weightKg, let heightCm else { return nil }
        return BodyMassIndex.value(weightKg: weightKg, heightCm: heightCm)
    }

    /// `nil` until the weight is a number. Range checks stay in `BodyCompositionCheckpoint.validated()`, the single source of truth.
    public func checkpoint(studentID: UserID, trainerID: UserID, planID: PlanID?, deviceID: String) -> BodyCompositionCheckpoint? {
        guard canSave, let weightKg else { return nil }
        return BodyCompositionCheckpoint(
            studentID: studentID, trainerID: trainerID, planID: planID, recordedAt: date, bodyWeightKg: weightKg,
            bodyFatPercent: decimal(.bodyFat), measuredFatMassKg: decimal(.fatMass), measuredLeanMassKg: decimal(.leanMass),
            skeletalMuscleMassKg: decimal(.muscleMass), bodyWaterPercent: decimal(.water), visceralFatLevel: whole(.visceral),
            boneMassKg: decimal(.bone), basalMetabolicRateKcal: whole(.metabolicRate), metabolicAge: whole(.metabolicAge),
            waistCm: decimal(.waist), hipCm: decimal(.hip), notes: notes,
            meta: SyncMetadata(updatedAt: date, lastWriterDeviceID: deviceID))
    }
}

// MARK: - The screen model (trainer: read + add · student: read only)

@MainActor
@Observable
public final class StudentBodyViewModel {
    /// What the evolution chart can plot. Only metrics with at least one value are offered.
    public enum ChartMetric: String, CaseIterable, Sendable {
        case weight, bodyFat, leanMass, fatMass, muscleMass, waist

        func value(in entry: BodyCompositionCheckpoint) -> Double? {
            switch self {
            case .weight: return entry.bodyWeightKg
            case .bodyFat: return entry.resolvedBodyFatPercent
            case .leanMass: return entry.leanMassKg
            case .fatMass: return entry.fatMassKg
            case .muscleMass: return entry.skeletalMuscleMassKg
            case .waist: return entry.waistCm
            }
        }
    }

    public struct ChartPoint: Identifiable, Equatable, Sendable {
        public let date: Date
        public let value: Double
        public var id: Date { date }
    }

    public private(set) var snapshot: BodySnapshot
    /// Newest first.
    public private(set) var entries: [BodyCompositionCheckpoint] = []
    public private(set) var isLoaded = false
    public private(set) var loadFailed = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public var chartMetric: ChartMetric = .weight
    public var isAdding = false
    public let draft: BodyMeasurementDraft
    /// Only the trainer who owns the student can add measurements.
    public let canEdit: Bool

    @ObservationIgnored private let profile: BodyProfile
    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let trainerID: UserID?
    @ObservationIgnored private let planID: PlanID?
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let repository: any BodyCompositionRepository
    @ObservationIgnored private let recorder: RecordBodyCompositionUseCase
    @ObservationIgnored private let now: () -> Date

    public init(profile: BodyProfile, studentID: UserID, trainerID: UserID? = nil, planID: PlanID? = nil, deviceID: String = "",
                repository: any BodyCompositionRepository, now: @escaping () -> Date = { Date() }) {
        self.profile = profile
        self.studentID = studentID
        self.trainerID = trainerID
        self.planID = planID
        self.deviceID = deviceID
        self.repository = repository
        self.recorder = RecordBodyCompositionUseCase(repository: repository)
        self.now = now
        self.canEdit = trainerID != nil
        self.draft = BodyMeasurementDraft(now: now())
        self.snapshot = BodySnapshot(profileWeightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age, checkpoints: [])
    }

    public func load() async {
        do {
            let all = try await repository.checkpoints(studentID: studentID)
            apply(all)
            loadFailed = false
        } catch {
            loadFailed = true
        }
        isLoaded = true
    }

    private func apply(_ all: [BodyCompositionCheckpoint]) {
        entries = all.filter { !$0.meta.isDeleted }.sorted { $0.recordedAt > $1.recordedAt }
        snapshot = BodySnapshot(profileWeightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age, checkpoints: entries)
        if !availableMetrics.contains(chartMetric) { chartMetric = .weight }
    }

    // MARK: Adding a measurement

    public func startAdding() {
        draft.reset(now: now())
        errorMessage = nil
        isAdding = true
    }

    @discardableResult
    public func save() async -> Bool {
        guard canEdit, let trainerID else { return false }
        guard let checkpoint = draft.checkpoint(studentID: studentID, trainerID: trainerID, planID: planID, deviceID: deviceID) else {
            errorMessage = String(localized: "Check the numbers you typed.")
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await recorder.execute(checkpoint)
            await load()
            isAdding = false
            return true
        } catch let error as DomainError {
            if case .validation = error { errorMessage = String(localized: "One of the values is outside what is possible. Check the numbers.") }
            else { errorMessage = String(localized: "Couldn't save the measurement.") }
            return false
        } catch {
            errorMessage = String(localized: "Couldn't save the measurement.")
            return false
        }
    }

    // MARK: Chart

    public var availableMetrics: [ChartMetric] {
        ChartMetric.allCases.filter { metric in entries.contains { metric.value(in: $0) != nil } }
    }

    /// Oldest first, as a line needs them.
    public var chartPoints: [ChartPoint] {
        entries.reversed().compactMap { entry in chartMetric.value(in: entry).map { ChartPoint(date: entry.recordedAt, value: $0) } }
    }

    public var showsChart: Bool { chartPoints.count >= 2 }

    /// Change since the measurement before, per entry id (newest first list).
    public func weightChange(for entry: BodyCompositionCheckpoint) -> Double? {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), index + 1 < entries.count else { return nil }
        return entry.bodyWeightKg - entries[index + 1].bodyWeightKg
    }

    public var hasHeight: Bool { snapshot.heightCm != nil }
}

public extension BodyMassIndex.Category {
    var title: String {
        switch self {
        case .underweight: return String(localized: "Underweight")
        case .normal: return String(localized: "Healthy weight")
        case .overweight: return String(localized: "Overweight")
        case .obese: return String(localized: "Obesity")
        }
    }
}

public extension StudentBodyViewModel.ChartMetric {
    var title: String {
        switch self {
        case .weight: return String(localized: "Weight")
        case .bodyFat: return String(localized: "Body fat")
        case .leanMass: return String(localized: "Lean mass")
        case .fatMass: return String(localized: "Fat mass")
        case .muscleMass: return String(localized: "Muscle mass")
        case .waist: return String(localized: "Waist")
        }
    }

    var unit: String {
        switch self {
        case .weight, .leanMass, .fatMass, .muscleMass: return "kg"
        case .bodyFat: return "%"
        case .waist: return "cm"
        }
    }
}

public extension BodyMeasurementDraft.Field {
    var title: String {
        switch self {
        case .weight: return String(localized: "Weight (kg)")
        case .bodyFat: return String(localized: "Body fat (%)")
        case .fatMass: return String(localized: "Fat mass (kg)")
        case .leanMass: return String(localized: "Lean mass (kg)")
        case .muscleMass: return String(localized: "Skeletal muscle (kg)")
        case .water: return String(localized: "Body water (%)")
        case .visceral: return String(localized: "Visceral fat (level)")
        case .bone: return String(localized: "Bone mass (kg)")
        case .metabolicRate: return String(localized: "Basal metabolic rate (kcal)")
        case .metabolicAge: return String(localized: "Metabolic age (years)")
        case .waist: return String(localized: "Waist (cm)")
        case .hip: return String(localized: "Hip (cm)")
        }
    }
}

// MARK: - Text for one measurement

public enum BodyFormat {
    public static func number(_ value: Double, digits: Int = 1, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never).locale(locale))
    }

    public static func bmi(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// "+1.2 kg" / "−0.8 kg"; a change too small to matter reads as "0 kg".
    public static func signedKg(_ value: Double, locale: Locale = .current) -> String {
        guard abs(value) >= 0.05 else { return "0 kg" }
        return value.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always()).locale(locale)) + " kg"
    }
}

public extension BodyCompositionCheckpoint {
    /// Every recorded value as (label, text), in reading order: the one list the detail screen and the tests share. The BMI is derived,
    /// never stored, so it always follows the height on file.
    func displayRows(heightCm: Double?, locale: Locale = .current) -> [(title: String, value: String)] {
        var rows: [(String, String)] = [(String(localized: "Weight"), BodyFormat.number(bodyWeightKg, locale: locale) + " kg")]
        if let heightCm, let bmi = BodyMassIndex.value(weightKg: bodyWeightKg, heightCm: heightCm) {
            rows.append((String(localized: "BMI"), BodyFormat.bmi(bmi, locale: locale)))
        }
        if let value = resolvedBodyFatPercent { rows.append((String(localized: "Body fat"), BodyFormat.number(value, locale: locale) + " %")) }
        if let value = fatMassKg { rows.append((String(localized: "Fat mass"), BodyFormat.number(value, locale: locale) + " kg")) }
        if let value = leanMassKg { rows.append((String(localized: "Lean mass"), BodyFormat.number(value, locale: locale) + " kg")) }
        if let value = skeletalMuscleMassKg { rows.append((String(localized: "Skeletal muscle"), BodyFormat.number(value, locale: locale) + " kg")) }
        if let value = bodyWaterPercent { rows.append((String(localized: "Body water"), BodyFormat.number(value, locale: locale) + " %")) }
        if let value = visceralFatLevel { rows.append((String(localized: "Visceral fat"), "\(value)")) }
        if let value = boneMassKg { rows.append((String(localized: "Bone mass"), BodyFormat.number(value, locale: locale) + " kg")) }
        if let value = basalMetabolicRateKcal { rows.append((String(localized: "Basal metabolic rate"), "\(value) kcal")) }
        if let value = metabolicAge { rows.append((String(localized: "Metabolic age"), String(localized: "\(value) years"))) }
        if let value = waistCm { rows.append((String(localized: "Waist"), BodyFormat.number(value, locale: locale) + " cm")) }
        if let value = hipCm { rows.append((String(localized: "Hip"), BodyFormat.number(value, locale: locale) + " cm")) }
        if let value = waistToHipRatio { rows.append((String(localized: "Waist-to-hip ratio"), value.formatted(.number.precision(.fractionLength(2)).locale(locale)))) }
        return rows
    }
}
