import Foundation
import Testing
@testable import Domain

actor InMemoryBodyRepository: BodyCompositionRepository {
    private(set) var stored: [CheckpointID: BodyCompositionCheckpoint] = [:]
    func save(_ checkpoint: BodyCompositionCheckpoint) async throws -> BodyCompositionCheckpoint { stored[checkpoint.id] = checkpoint; return checkpoint }
    func checkpoints(studentID: UserID) async throws -> [BodyCompositionCheckpoint] {
        stored.values.filter { $0.studentID == studentID }.sorted { $0.recordedAt > $1.recordedAt }
    }
}

@Suite("Body mass index")
struct BodyMassIndexTests {
    @Test("kg / m², and nothing for impossible input")
    func value() throws {
        #expect(abs(try #require(BodyMassIndex.value(weightKg: 82, heightCm: 178)) - 25.88) < 0.01)
        #expect(abs(try #require(BodyMassIndex.value(weightKg: 70, heightCm: 175)) - 22.86) < 0.01)
        #expect(BodyMassIndex.value(weightKg: 0, heightCm: 175) == nil)
        #expect(BodyMassIndex.value(weightKg: 70, heightCm: 0) == nil)
        #expect(BodyMassIndex.value(weightKg: -5, heightCm: 175) == nil)
    }

    @Test("WHO adult bands, edges included; under-18s get a number but no label")
    func categories() {
        #expect(BodyMassIndex.category(18.4, age: 30) == .underweight)
        #expect(BodyMassIndex.category(18.5, age: 30) == .normal)
        #expect(BodyMassIndex.category(24.9, age: 30) == .normal)
        #expect(BodyMassIndex.category(25, age: 30) == .overweight)
        #expect(BodyMassIndex.category(29.9, age: 30) == .overweight)
        #expect(BodyMassIndex.category(30, age: 30) == .obese)
        #expect(BodyMassIndex.category(22, age: 17) == nil)
        #expect(BodyMassIndex.category(22, age: 18) == .normal)
        #expect(BodyMassIndex.category(22, age: nil) == .normal)
    }
}

@Suite("Body composition checkpoints")
struct BodyCheckpointTests {
    func checkpoint(day: Int = 0, weight: Double = 80, _ configure: (inout BodyCompositionCheckpoint) -> Void = { _ in }) -> BodyCompositionCheckpoint {
        var c = BodyCompositionCheckpoint(studentID: Fx.student, trainerID: Fx.trainer, recordedAt: Fx.date(day: max(day, 1)), bodyWeightKg: weight, meta: Fx.meta())
        configure(&c)
        return c
    }

    @Test("Only the weight is required; everything else is optional and absent values stay absent")
    func weightOnly() throws {
        let c = try checkpoint().validated()
        #expect(c.hasOnlyWeight && c.resolvedBodyFatPercent == nil && c.fatMassKg == nil && c.leanMassKg == nil && c.waistToHipRatio == nil)
    }

    @Test("Device-printed masses win over derived ones; the body-fat percentage is recovered from a printed fat mass")
    func measuredBeatsDerived() {
        let derived = checkpoint { $0.bodyFatPercent = 20 }
        #expect(derived.fatMassKg == 16 && derived.leanMassKg == 64)
        let printed = checkpoint { $0.bodyFatPercent = 20; $0.measuredFatMassKg = 15; $0.measuredLeanMassKg = 62 }
        #expect(printed.fatMassKg == 15 && printed.leanMassKg == 62)
        let onlyMass = checkpoint { $0.measuredFatMassKg = 12 }
        #expect(onlyMass.resolvedBodyFatPercent == 15 && onlyMass.leanMassKg == 68)
    }

    @Test("A full bioimpedance reading validates and reports the waist-to-hip ratio")
    func full() throws {
        let c = try checkpoint {
            $0.bodyFatPercent = 18.4; $0.measuredFatMassKg = 14.7; $0.measuredLeanMassKg = 65.3; $0.skeletalMuscleMassKg = 36.2; $0.bodyWaterPercent = 57.1
            $0.visceralFatLevel = 7; $0.boneMassKg = 3.1; $0.basalMetabolicRateKcal = 1850; $0.metabolicAge = 27; $0.waistCm = 84; $0.hipCm = 100
        }.validated()
        #expect(c.hasOnlyWeight == false && c.waistToHipRatio == 0.84)
    }

    @Test("Every value is range-checked, at the edges and just outside them")
    func ranges() throws {
        let edges: [(String, (inout BodyCompositionCheckpoint) -> Void, (inout BodyCompositionCheckpoint) -> Void, (inout BodyCompositionCheckpoint) -> Void)] = [
            ("body fat", { $0.bodyFatPercent = 2 }, { $0.bodyFatPercent = 1.9 }, { $0.bodyFatPercent = 60.1 }),
            ("water", { $0.bodyWaterPercent = 30 }, { $0.bodyWaterPercent = 29 }, { $0.bodyWaterPercent = 80.5 }),
            ("visceral", { $0.visceralFatLevel = 1 }, { $0.visceralFatLevel = 0 }, { $0.visceralFatLevel = 61 }),
            ("bone", { $0.boneMassKg = 0.5 }, { $0.boneMassKg = 0.4 }, { $0.boneMassKg = 10.1 }),
            ("bmr", { $0.basalMetabolicRateKcal = 500 }, { $0.basalMetabolicRateKcal = 499 }, { $0.basalMetabolicRateKcal = 6001 }),
            ("metabolic age", { $0.metabolicAge = 5 }, { $0.metabolicAge = 4 }, { $0.metabolicAge = 121 }),
            ("waist", { $0.waistCm = 40 }, { $0.waistCm = 39 }, { $0.waistCm = 251 }),
            ("hip", { $0.hipCm = 250 }, { $0.hipCm = 39 }, { $0.hipCm = 251 }),
            ("muscle", { $0.skeletalMuscleMassKg = 5 }, { $0.skeletalMuscleMassKg = 4 }, { $0.skeletalMuscleMassKg = 151 }),
        ]
        for (name, ok, low, high) in edges {
            _ = try checkpoint(weight: 200, ok).validated()
            #expect(throws: DomainError.self, "\(name) below") { try checkpoint(weight: 200, low).validated() }
            #expect(throws: DomainError.self, "\(name) above") { try checkpoint(weight: 200, high).validated() }
        }
    }

    @Test("Masses can't be larger than the person; weight and notes are bounded")
    func consistency() {
        #expect(throws: DomainError.self) { try checkpoint { $0.measuredFatMassKg = 80 }.validated() }
        #expect(throws: DomainError.self) { try checkpoint { $0.measuredLeanMassKg = 81 }.validated() }
        #expect(throws: DomainError.self) { try checkpoint { $0.skeletalMuscleMassKg = 81 }.validated() }
        #expect(throws: DomainError.self) { try checkpoint(weight: 19.9).validated() }
        #expect(throws: DomainError.self) { try checkpoint(weight: 400.1).validated() }
        #expect(throws: DomainError.self) { try checkpoint { $0.notes = String(repeating: "x", count: 501) }.validated() }
    }

    @Test("Older stored measurements (just a weight and a fat percentage) still decode")
    func backwardCompatible() throws {
        let c = checkpoint { $0.bodyFatPercent = 18 }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        for key in ["measuredFatMassKg", "measuredLeanMassKg", "skeletalMuscleMassKg", "bodyWaterPercent", "visceralFatLevel", "boneMassKg",
                    "basalMetabolicRateKcal", "metabolicAge", "waistCm", "hipCm"] { json[key] = nil }
        let back = try JSONDecoder().decode(BodyCompositionCheckpoint.self, from: JSONSerialization.data(withJSONObject: json))
        let derivedFat = try #require(back.fatMassKg)
        #expect(back.bodyFatPercent == 18 && back.measuredLeanMassKg == nil && abs(derivedFat - 14.4) < 1e-9)
    }

    @Test("The cycle report compares what both ends have, and leaves out what one end lacks")
    func cycleWithGaps() throws {
        let report = try #require(CycleReportBuilder.build(from: [checkpoint(day: 1, weight: 80), checkpoint(day: 20, weight: 78) { $0.bodyFatPercent = 15 }]))
        #expect(report.weightDeltaKg == -2)
        #expect(report.bodyFatDeltaPoints == nil && report.leanMassDeltaKg == nil && report.fatMassDeltaKg == nil)
    }
}

@Suite("BodySnapshot")
struct BodySnapshotTests {
    func checkpoint(day: Int, weight: Double, fat: Double? = nil) -> BodyCompositionCheckpoint {
        BodyCompositionCheckpoint(studentID: Fx.student, trainerID: Fx.trainer, recordedAt: Fx.date(day: day), bodyWeightKg: weight, bodyFatPercent: fat, meta: Fx.meta())
    }

    @Test("Before any measurement the sign-up weight and height give the BMI")
    func fromProfile() throws {
        let snapshot = BodySnapshot(profileWeightKg: 82, heightCm: 178, age: 29, checkpoints: [])
        #expect(snapshot.weightKg == 82 && snapshot.latest == nil && snapshot.weightChangeKg == nil)
        #expect(abs(try #require(snapshot.bmi) - 25.88) < 0.01 && snapshot.bmiCategory == .overweight)
    }

    @Test("The newest measurement replaces the sign-up weight, and the BMI follows it")
    func newestWins() throws {
        let snapshot = BodySnapshot(profileWeightKg: 82, heightCm: 178, age: 29,
                                    checkpoints: [checkpoint(day: 3, weight: 79, fat: 17), checkpoint(day: 10, weight: 76.5, fat: 15), checkpoint(day: 1, weight: 80)])
        #expect(snapshot.weightKg == 76.5 && snapshot.latest?.bodyFatPercent == 15)
        #expect(snapshot.weightChangeKg == -2.5)
        #expect(snapshot.bmiCategory == .normal)
    }

    @Test("Removed measurements are ignored")
    func ignoresDeleted() {
        var gone = checkpoint(day: 10, weight: 50)
        gone.meta.deletedAt = Fx.date(day: 11)
        let snapshot = BodySnapshot(profileWeightKg: 82, heightCm: 178, age: 29, checkpoints: [gone, checkpoint(day: 3, weight: 79)])
        #expect(snapshot.weightKg == 79 && snapshot.weightChangeKg == nil)
    }

    @Test("Without a height there is no BMI; for a minor there is a number but no adult label")
    func partial() {
        #expect(BodySnapshot(profileWeightKg: 70, heightCm: nil, age: 30, checkpoints: []).bmi == nil)
        #expect(BodySnapshot(profileWeightKg: nil, heightCm: 170, age: 30, checkpoints: []).bmi == nil)
        let teen = BodySnapshot(profileWeightKg: 60, heightCm: 170, age: 15, checkpoints: [])
        #expect(teen.bmi != nil && teen.bmiCategory == nil)
    }

    @Test("A registration carries the profile numbers over")
    func fromRegistration() {
        let registration = StudentRegistration(id: "r", trainerID: "t", fullName: "Ana Lima", cpfMasked: "***", status: .active, studentID: "s", age: 30,
                                               heightCm: 165, weightKg: 60, createdAt: Fx.date(day: 1), meta: Fx.meta())
        #expect(BodyProfile(registration) == BodyProfile(heightCm: 165, weightKg: 60, age: 30))
    }
}

@Suite("RecordBodyCompositionUseCase")
struct RecordBodyCompositionTests {
    @Test("Validates before storing, trims the notes, and keeps invalid readings out of storage")
    func records() async throws {
        let repo = InMemoryBodyRepository()
        let uc = RecordBodyCompositionUseCase(repository: repo)
        var ok = BodyCompositionCheckpoint(studentID: Fx.student, trainerID: Fx.trainer, recordedAt: Fx.date(day: 2), bodyWeightKg: 80, bodyFatPercent: 18,
                                           notes: "  After 8 weeks.  ", meta: Fx.meta())
        let saved = try await uc.execute(ok)
        #expect(saved.notes == "After 8 weeks.")
        ok.id = .generate(); ok.notes = "   "
        #expect(try await uc.execute(ok).notes == nil)

        var impossible = ok
        impossible.id = .generate(); impossible.bodyFatPercent = 90
        await #expect(throws: DomainError.self) { try await uc.execute(impossible) }
        #expect(try await repo.checkpoints(studentID: Fx.student).count == 2)
    }
}

@Suite("CPF mask")
struct CPFMaskTests {
    @Test("Dots and the dash appear as the digits are typed")
    func progressive() {
        let typed = ["7", "71", "714", "7148", "71488", "714880", "7148808", "71488086", "714880864", "7148808642", "71488086427"]
        let masked = ["7", "71", "714", "714.8", "714.88", "714.880", "714.880.8", "714.880.86", "714.880.864", "714.880.864-2", "714.880.864-27"]
        #expect(typed.map(CPFMask.apply) == masked)
    }

    @Test("Backspace works: removing a digit takes the punctuation that no longer has a digit after it")
    func backspace() {
        #expect(CPFMask.apply("714.880.864-2") == "714.880.864-2")
        #expect(CPFMask.apply("714.880.864-") == "714.880.864")
        #expect(CPFMask.apply("714.880.") == "714.880")
        #expect(CPFMask.apply("714.") == "714")
    }

    @Test("Pasting a formatted or messy CPF, extra digits and non-digits")
    func messy() {
        #expect(CPFMask.apply("714.880.864-27") == "714.880.864-27")
        #expect(CPFMask.apply(" 714 880 864 27 ") == "714.880.864-27")
        #expect(CPFMask.apply("71488086427999") == "714.880.864-27")
        #expect(CPFMask.apply("abc") == "")
        #expect(CPFMask.apply("") == "")
        #expect(CPFMask.apply("٧١٤") == "")                          // other scripts' digits are not CPF digits
    }

    @Test("A masked CPF is still a valid CPF to the recognizer")
    func recognised() {
        #expect(BrazilianCredentialRecognizer().recognize(CPFMask.apply("39053344705")) == .cpf("39053344705"))
    }

    @Test("The sign-in field masks a CPF but never reshuffles a CREF")
    func loginIdentifier() {
        for cref in ["0", "012", "012345", "012345-", "012345-G", "012345-G/", "012345-G/AL", "000123-g/sp", "G/AL"] {
            #expect(CPFMask.loginIdentifier(cref) == cref, "\(cref)")
        }
        #expect(CPFMask.loginIdentifier("3905334") == "390.533.4")                   // more digits than a CREF number can have: it is a CPF
        #expect(CPFMask.loginIdentifier("39053344705") == "390.533.447-05")
        #expect(CPFMask.loginIdentifier("390.533.447-05") == "390.533.447-05")
    }
}
