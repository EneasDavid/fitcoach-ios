import Foundation
import Testing
@testable import Domain

@Suite("WorkoutSequencer · smart progression")
struct WorkoutSequencerTests {
    let sequencer = WorkoutSequencer()
    let plan = Fx.plan()
    var a: WorkoutTemplate { plan.templates[0] }
    var b: WorkoutTemplate { plan.templates[1] }
    var c: WorkoutTemplate { plan.templates[2] }
    let now = Fx.date(day: 10)

    @Test("No history → first template of the rotation")
    func firstWorkout() throws {
        let next = try #require(sequencer.next(plan: plan, logs: [], now: now))
        #expect(next.template.id == a.id)
        #expect(next.reason == .firstWorkout)
        #expect(next.rotationIndex == 0)
    }

    @Test("Next workout follows the last completed one — the weekday is irrelevant")
    func continuesSequence() throws {
        // A was done on a Monday; the student returns on a Saturday → still B.
        let logs = [Fx.log(plan: plan, template: a, at: Fx.date(day: 0))]
        let next = try #require(sequencer.next(plan: plan, logs: logs, now: Fx.date(day: 5)))
        #expect(next.template.id == b.id)
        #expect(next.reason == .continuedSequence)
    }

    @Test("Finishing the last template wraps to the first and bumps the rotation")
    func wrapsAround() throws {
        let logs = [Fx.log(plan: plan, template: c, at: Fx.date(day: 4), rotation: 2)]
        let next = try #require(sequencer.next(plan: plan, logs: logs, now: now))
        #expect(next.template.id == a.id)
        #expect(next.rotationIndex == 3)
        #expect(next.reason == .startedNewRotation)
    }

    @Test("Abandoned workouts do not advance the rotation; skipped ones do")
    func abandonedVsSkipped() throws {
        let completedA = Fx.log(plan: plan, template: a, at: Fx.date(day: 0))
        let abandonedB = Fx.log(plan: plan, template: b, at: Fx.date(day: 1), status: .abandoned)
        #expect(try #require(sequencer.next(plan: plan, logs: [completedA, abandonedB], now: now)).template.id == b.id)

        let skippedB = Fx.log(plan: plan, template: b, at: Fx.date(day: 1), status: .skipped)
        #expect(try #require(sequencer.next(plan: plan, logs: [completedA, skippedB], now: now)).template.id == c.id)
    }

    @Test("A fresh in-progress workout is resumed, not duplicated")
    func resumesLiveSession() throws {
        let live = Fx.log(plan: plan, template: b, at: now.addingTimeInterval(-3_600), status: .inProgress, rotation: 4)
        let next = try #require(sequencer.next(plan: plan, logs: [Fx.log(plan: plan, template: a, at: Fx.date(day: 0)), live], now: now))
        #expect(next.reason == .resumedInProgress)
        #expect(next.resumableLogID == live.id)
        #expect(next.template.id == b.id)
        #expect(next.rotationIndex == 4)
    }

    @Test("An in-progress workout left open for a day is stale and ignored")
    func staleSessionIgnored() throws {
        let stale = Fx.log(plan: plan, template: b, at: now.addingTimeInterval(-24 * 3_600), status: .inProgress)
        #expect(sequencer.isStale(stale, now: now))
        let logs = [Fx.log(plan: plan, template: a, at: Fx.date(day: 0)), stale]
        let next = try #require(sequencer.next(plan: plan, logs: logs, now: now))
        #expect(next.reason == .continuedSequence)
        #expect(next.template.id == b.id)
        #expect(next.resumableLogID == nil)
    }

    @Test("If the last template was deleted from the plan, the least-recently-performed one is next")
    func recoversFromPlanEdit() throws {
        let edited = Fx.plan(templates: [a, c])                       // B was removed
        let logs = [
            Fx.log(plan: edited, template: a, at: Fx.date(day: 0)),
            Fx.log(plan: edited, template: c, at: Fx.date(day: 2)),
            Fx.log(plan: edited, template: b, at: Fx.date(day: 4)),   // last performed = the deleted B
        ]
        let next = try #require(sequencer.next(plan: edited, logs: logs, now: now))
        #expect(next.reason == .recoveredFromPlanEdit)
        #expect(next.template.id == a.id)                              // A was done longest ago
    }

    @Test("A never-performed template wins the recovery tie-break")
    func recoveryPrefersUnperformed() throws {
        let d = Fx.template("D", order: 3)
        let edited = Fx.plan(templates: [a, c, d])
        let logs = [
            Fx.log(plan: edited, template: a, at: Fx.date(day: 0)),
            Fx.log(plan: edited, template: c, at: Fx.date(day: 1)),
            Fx.log(plan: edited, template: b, at: Fx.date(day: 2)),
        ]
        #expect(try #require(sequencer.next(plan: edited, logs: logs, now: now)).template.id == d.id)
    }

    @Test("Template order — not array order — defines the rotation")
    func respectsOrderField() throws {
        let shuffled = Fx.plan(templates: [c, a, b])
        let logs = [Fx.log(plan: shuffled, template: a, at: Fx.date(day: 0))]
        #expect(try #require(sequencer.next(plan: shuffled, logs: logs, now: now)).template.id == b.id)
    }

    @Test("Logs from another plan and soft-deleted logs are ignored")
    func ignoresForeignAndDeleted() throws {
        let otherPlan = WorkoutPlan(id: "other", trainerID: Fx.trainer, studentID: Fx.student, name: "Old",
                                    templates: plan.templates, targetSessionsPerWeek: 3, startDate: Fx.monday, meta: Fx.meta())
        var deleted = Fx.log(plan: plan, template: b, at: Fx.date(day: 3))
        deleted.meta.deletedAt = Fx.date(day: 4)
        let logs = [Fx.log(plan: otherPlan, template: c, at: Fx.date(day: 5)), deleted]
        #expect(try #require(sequencer.next(plan: plan, logs: logs, now: now)).reason == .firstWorkout)
    }

    @Test("An empty plan has no next workout")
    func emptyPlan() {
        #expect(sequencer.next(plan: Fx.plan(templates: []), logs: [], now: now) == nil)
    }

    @Test("A 4-day split (A–D) rotates A → B → C → D → A, one pass per rotation, regardless of weekday")
    func fourDayRoutine() throws {
        let templates = ["A", "B", "C", "D"].enumerated().map { Fx.template($1, order: $0) }
        let plan = Fx.plan(templates: templates, sessionsPerWeek: 4)
        var logs: [WorkoutLog] = []
        var seen: [String] = []
        for step in 0..<9 {
            let next = try #require(sequencer.next(plan: plan, logs: logs, now: Fx.date(day: step * 2 + 1)))
            seen.append(next.template.label)
            #expect(next.rotationIndex == step / 4)
            logs.append(Fx.log(plan: plan, template: next.template, at: Fx.date(day: step * 2 + 1), rotation: next.rotationIndex))
        }
        #expect(seen == ["A", "B", "C", "D", "A", "B", "C", "D", "A"])
    }
}
