import Foundation
import Testing
@testable import Domain

@Suite("Periodization")
struct PeriodizationTests {
    @Test("alternating() builds H H H D repeated")
    func alternatingPattern() {
        let macro = Macrocycle.alternating(name: "m", highWeeks: 3, deloadWeeks: 1, cycles: 3)
        #expect(macro.microcycles.count == 12)
        #expect(macro.microcycles.map(\.phase) ==
                Array(repeating: [LoadPhase.high, .high, .high, .deload], count: 3).flatMap { $0 })
        #expect(macro.microcycles[3].volumeMultiplier == 0.5)
    }

    @Test("resolve(): in range, past the end, looping")
    func resolveWeeks() {
        var plan = Fx.threeOneProgram
        #expect(plan.totalWeeks == 12)
        #expect(plan.resolve(weekIndex: 3)?.microcycle.phase == .deload)
        #expect(plan.resolve(weekIndex: 12) == nil)
        #expect(plan.resolve(weekIndex: -1) == nil)
        plan.loops = true
        #expect(plan.resolve(weekIndex: 15)?.microcycle.phase == .deload)
        #expect(plan.resolve(weekIndex: 15)?.weekIndex == 15)
        #expect(PeriodizationPlan(macrocycles: [], startDate: Fx.monday).resolve(weekIndex: 0) == nil)
    }

    @Test("Sequence-based weeks follow completed rotations; calendar-based weeks follow the date")
    func advancement() {
        var plan = Fx.threeOneProgram
        #expect(plan.weekIndex(rotationIndex: 3, now: Fx.date(day: 40), calendar: Fx.calendar) == 3)
        plan.advancement = .byCalendar
        #expect(plan.weekIndex(rotationIndex: 3, now: Fx.date(day: 15), calendar: Fx.calendar) == 2)
        #expect(plan.weekIndex(rotationIndex: 3, now: Fx.date(day: -10), calendar: Fx.calendar) == 0)
    }

    @Test("Deload indices")
    func deloadIndices() {
        #expect(Fx.threeOneProgram.deloadWeekIndices(upTo: 8) == [3, 7])
        #expect(Fx.threeOneProgram.deloadWeekIndices(upTo: -1).isEmpty)
    }

    @Test("Only deload opts out of progression")
    func phaseSemantics() {
        #expect(LoadPhase.high.countsTowardProgression)
        #expect(LoadPhase.moderate.countsTowardProgression)
        #expect(!LoadPhase.deload.countsTowardProgression)
    }
}

@Suite("Serialisation")
struct SerialisationTests {
    @Test("Blocks use a flat discriminated wire format")
    func flatWireFormat() throws {
        let block = WorkoutBlock.hiit(HIITBlock(id: "h1", title: "Finisher", rounds: 8, workSeconds: 20, restSeconds: 10))
        let json = try #require(String(data: JSONEncoder().encode(block), encoding: .utf8))
        #expect(json.contains("\"type\":\"hiit\""))
        #expect(json.contains("\"rounds\":8"))
        #expect(!json.contains("_0"))
    }

    @Test("A plan with heterogeneous blocks round-trips")
    func planRoundTrip() throws {
        let template = Fx.template("A", order: 0, blocks: [
            .resistance(Fx.resistanceBlock()),
            .hiit(HIITBlock(id: "h", title: "Finisher", rounds: 6, workSeconds: 30, restSeconds: 30)),
            .cardio(CardioBlock(id: "c", modality: .bike, targetDurationSeconds: 600, targetZone: 2)),
        ])
        let plan = Fx.plan(templates: [template], periodization: Fx.threeOneProgram)
        let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded.templates == plan.templates)
        #expect(decoded.periodization == plan.periodization)
        #expect(decoded.templates[0].blocks.map(\.kind) == [.resistance, .hiit, .cardio])
    }

    @Test("A block type from a newer app version decodes as `unsupported` instead of failing the whole plan")
    func unknownBlockIsForwardCompatible() throws {
        let json = #"{"type":"mobility","id":"m1","poses":3}"#
        let block = try JSONDecoder().decode(WorkoutBlock.self, from: Data(json.utf8))
        #expect(block.kind == .unsupported)
        #expect(block == .unsupported(UnsupportedBlock(originalType: "mobility")))
        // …and re-encodes with its original discriminator.
        #expect(try String(data: JSONEncoder().encode(block), encoding: .utf8)?.contains("mobility") == true)
    }

    @Test("Logs round-trip and `meta.state` never reaches the wire")
    func logRoundTripAndLocalStateStaysLocal() throws {
        var log = Fx.log(plan: Fx.plan(), template: Fx.threeTemplates[0], at: Fx.date(day: 1))
        log.meta.state = .pendingUpsert
        let data = try JSONEncoder().encode(log)
        #expect(!String(decoding: data, as: UTF8.self).contains("pendingUpsert"))

        let decoded = try JSONDecoder().decode(WorkoutLog.self, from: data)
        #expect(decoded.blocks == log.blocks)
        #expect(decoded.meta.state == .synced)        // server documents are synced by definition
        #expect(decoded.meta.version == log.meta.version)
    }

    @Test("Hiit/cardio logs can be stored in a workout log")
    func allLogKinds() throws {
        var log = Fx.log(plan: Fx.plan(), template: Fx.threeTemplates[0], at: Fx.date(day: 1))
        log.record(.hiit(HIITLog(blockID: "h", roundsCompleted: 6, totalSeconds: 360)))
        log.record(.cardio(CardioLog(blockID: "c", modality: .run, durationSeconds: 900, distanceMeters: 2_500)))
        log.record(.hiit(HIITLog(blockID: "h", roundsCompleted: 8, totalSeconds: 480)))   // replaces, not appends
        #expect(log.blocks.count == 3)
        let decoded = try JSONDecoder().decode(WorkoutLog.self, from: JSONEncoder().encode(log))
        #expect(decoded.blocks == log.blocks)
    }

    @Test("Typed identifiers serialise as bare strings")
    func identifiers() throws {
        #expect(try String(data: JSONEncoder().encode(["id": UserID("u-1")]), encoding: .utf8) == #"{"id":"u-1"}"#)
        #expect(UserID("a").description == "a")
        #expect(UserID.generate() != UserID.generate())
    }

    @Test("Metadata: touch bumps the version; tombstone marks deletion")
    func metadata() {
        var meta = SyncMetadata(version: 3, updatedAt: Fx.monday, lastWriterDeviceID: "a", state: .synced)
        meta.touch(deviceID: "b", at: Fx.date(day: 1))
        #expect(meta.version == 4)
        #expect(meta.lastWriterDeviceID == "b")
        #expect(meta.state == .pendingUpsert)
        meta.tombstone(deviceID: "b", at: Fx.date(day: 2))
        #expect(meta.isDeleted)
        #expect(meta.version == 5)
        #expect(meta.state == .pendingDelete)
    }
}

@Suite("Body composition & substitutions")
struct BodyCompositionTests {
    func checkpoint(_ day: Int, weight: Double, fat: Double) -> BodyCompositionCheckpoint {
        BodyCompositionCheckpoint(studentID: Fx.student, trainerID: Fx.trainer, recordedAt: Fx.date(day: day),
                                  bodyWeightKg: weight, bodyFatPercent: fat, meta: Fx.meta())
    }

    @Test("Lean and fat mass derive from weight and body-fat percentage")
    func compositionMath() {
        let c = checkpoint(0, weight: 80, fat: 20)
        #expect(c.fatMassKg == 16)
        #expect(c.leanMassKg == 64)
        #expect(c.resolvedBodyFatPercent == 20)
    }

    @Test("Implausible measurements are rejected (input validation)")
    func validation() throws {
        #expect(throws: DomainError.self) { try checkpoint(0, weight: 10, fat: 20).validated() }
        #expect(throws: DomainError.self) { try checkpoint(0, weight: 80, fat: 1).validated() }
        #expect(throws: DomainError.self) { try checkpoint(0, weight: 80, fat: 75).validated() }
        _ = try checkpoint(0, weight: 80, fat: 20).validated()
    }

    @Test("End-of-cycle report: lean-mass gain with fat loss")
    func cycleReport() throws {
        let report = try #require(CycleReportBuilder.build(from: [
            checkpoint(84, weight: 82, fat: 16),
            checkpoint(0, weight: 80, fat: 20),
        ]))
        #expect(abs(report.weightDeltaKg - 2) < 1e-9)
        let fatDelta = try #require(report.bodyFatDeltaPoints), leanDelta = try #require(report.leanMassDeltaKg), fatMassDelta = try #require(report.fatMassDeltaKg)
        #expect(abs(fatDelta + 4) < 1e-9)
        #expect(abs(leanDelta - (82 * 0.84 - 64)) < 1e-9)
        #expect(leanDelta > 0)
        #expect(fatMassDelta < 0)
        #expect(CycleReportBuilder.build(from: [checkpoint(0, weight: 80, fat: 20)]) == nil)
    }

    @Test("Substitutions rank by muscle overlap and respect the reason")
    func substitutions() {
        let bench = Exercise(id: "bench", name: "Barbell Bench", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .shoulders], equipment: .barbell)
        let db = Exercise(id: "db", name: "Dumbbell Press", primaryMuscles: [.chest], secondaryMuscles: [.triceps], equipment: .dumbbell)
        let machine = Exercise(id: "mc", name: "Chest Press Machine", primaryMuscles: [.chest, .triceps], equipment: .machine)
        let row = Exercise(id: "row", name: "Row", primaryMuscles: [.back], equipment: .cable)
        let recommender = SubstitutionRecommender()

        let busy = recommender.rank(original: bench, candidates: [bench, row, db, machine], reason: .equipmentBusy)
        #expect(busy.map(\.candidate.id.rawValue) == ["db", "mc"])      // original and unrelated back exercise excluded
        #expect(busy.allSatisfy { $0.score > 0 && $0.original == bench.id })

        let sameGear = Exercise(id: "bb2", name: "Incline Barbell", primaryMuscles: [.chest], equipment: .barbell)
        let injury = recommender.rank(original: bench, candidates: [db, sameGear], reason: .injury)
        #expect(injury.first?.candidate.id == sameGear.id)
        #expect(recommender.rank(original: bench, candidates: [db, machine, sameGear], reason: .preference, limit: 1).count == 1)
    }

    @Test("SameLoadPropagation fills only the remaining sets")
    func sameLoad() {
        var loads = [60.0, 62.5, 0, 0]
        SameLoadPropagation.apply(weightKg: 65, to: &loads, from: 2)
        #expect(loads == [60, 62.5, 65, 65])
        SameLoadPropagation.apply(weightKg: 1, to: &loads, from: 9)   // out of range is a no-op
        #expect(loads == [60, 62.5, 65, 65])
    }
}
