import Domain
import Foundation
import Testing
@testable import PresentationKit

@MainActor
@Suite("CountdownTimer & IntervalSchedule")
struct TimerTests {
    func makeTimer(_ clock: FakeClock) -> CountdownTimer {
        CountdownTimer(now: { clock.now() }, autoTick: false)
    }

    @Test("Remaining time is derived from the wall clock, so it survives suspension")
    func derivedFromClock() {
        let clock = FakeClock()
        let timer = makeTimer(clock)
        var finished = 0
        timer.onFinish = { finished += 1 }

        timer.start(90)
        #expect(timer.isRunning && timer.remaining == 90 && timer.endsAt == PFx.t0.addingTimeInterval(90))

        clock.advance(30)                       // app backgrounded for 30 s: no ticks happened
        timer.tick()
        #expect(timer.remaining == 60 && abs(timer.progress - 1.0 / 3) < 1e-9)

        clock.advance(75)                       // …and well past the end
        timer.tick()
        #expect(!timer.isRunning && timer.remaining == 0 && finished == 1 && timer.finishCount == 1)
        timer.tick()                            // idempotent once finished
        #expect(finished == 1)
    }

    @Test("Pause keeps the remaining time; resume continues from it")
    func pauseResume() {
        let clock = FakeClock()
        let timer = makeTimer(clock)
        timer.start(60)
        clock.advance(20)
        timer.pause()
        #expect(!timer.isRunning && timer.remaining == 40)
        clock.advance(500)                      // time passing while paused changes nothing
        timer.tick()
        #expect(timer.remaining == 40)
        timer.resume()
        clock.advance(10)
        timer.tick()
        #expect(timer.remaining == 30)
        timer.pause(); timer.pause()            // pausing twice is harmless
        timer.resume(); timer.resume()
        #expect(timer.isRunning)
    }

    @Test("±15 s adjustments work while running or paused; removing more than is left ends the timer")
    func adjust() {
        let clock = FakeClock()
        let timer = makeTimer(clock)
        timer.start(60)
        timer.adjust(by: 15)
        #expect(timer.remaining == 75 && timer.duration == 75)
        timer.adjust(by: -15)
        #expect(timer.remaining == 60)

        timer.pause()
        timer.adjust(by: 15)
        #expect(timer.remaining == 75)
        timer.adjust(by: -500)
        #expect(timer.remaining == 0)

        timer.start(20)
        timer.adjust(by: -30)                   // running: more than is left → finishes
        #expect(!timer.isRunning && timer.finishCount == 1)
    }

    @Test("Zero-length and stopped timers behave")
    func edges() {
        let clock = FakeClock()
        let timer = makeTimer(clock)
        timer.start(0)
        #expect(!timer.isRunning && timer.finishCount == 1)
        timer.start(30)
        timer.stop()
        #expect(!timer.isRunning && timer.remaining == 0 && timer.progress == 0)
        timer.start(-5)
        #expect(timer.finishCount == 2)
    }

    @Test("The real ticker finishes a short timer on its own")
    func realTicker() async throws {
        let timer = CountdownTimer(autoTick: true)
        var finished = false
        timer.onFinish = { finished = true }
        timer.start(0.3)
        for _ in 0..<100 where !finished { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(finished)
    }

    @Test("Interval schedule: work/rest pairs without a trailing rest")
    func schedule() {
        let schedule = IntervalSchedule(rounds: 3, workSeconds: 20, restSeconds: 10)
        #expect(schedule.segments.map(\.kind) == [.work, .rest, .work, .rest, .work])
        #expect(schedule.segments.map(\.round) == [1, 1, 2, 2, 3])
        #expect(schedule.totalSeconds == 80 && schedule.rounds == 3)
        #expect(IntervalSchedule(rounds: 2, workSeconds: 30, restSeconds: 0).segments.count == 2)
    }

    @Test("Formatting & RPE scale")
    func formatting() {
        #expect(ClockFormat.minutesSeconds(75) == "1:15")
        #expect(ClockFormat.minutesSeconds(0.2) == "0:01")
        #expect(ClockFormat.minutesSeconds(-4) == "0:00")
        #expect([1, 3, 5, 7, 9, 10].map(RPEScale.description(for:)).count == 6)
        #expect(Set((1...10).map(RPEScale.description(for:))).count == 6)
    }
}

@MainActor
@Suite("ResistanceBlockViewModel · real-time logging")
struct ResistanceBlockViewModelTests {
    func lastLog(_ env: Env) -> ResistanceLog? {
        if case .resistance(let log)? = env.sink.logged.last { return log }
        return nil
    }

    // MARK: Prefill & summary

    @Test("Loads prefill from last session, then the prescription, then the previous set; last time is remembered per set")
    func prefill() {
        let env = Env()
        let previous = PFx.completedSquatSession(weights: [100, 105], start: PFx.t0.addingTimeInterval(-7 * 86_400))
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 4, targets: [nil, nil, 90, nil]), context: env.context(previous: previous))
        #expect(vm.rows.map(\.weightKg) == [100, 105, 90, 90])        // history, history, target, carry-forward
        #expect(vm.rows.map(\.reps) == [5, 5, 5, 5])
        #expect(vm.rows.map(\.lastWeightKg) == [100, 105, nil, nil])   // "Last time: 100 kg × 5" is shown per set
        #expect(vm.rows.map(\.lastReps) == [5, 5, nil, nil])
        #expect(vm.title == "Back Squat" && vm.kind == .resistance && !vm.isComplete)
    }

    @Test("Summary, status and icon for the overview row")
    func overviewFields() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, targets: [40, 40, 40]), context: env.context())
        #expect(vm.summary == "3 × 5–8 reps · 40 kg")
        #expect(vm.statusText == nil && vm.iconName == "dumbbell.fill")
        vm.complete(set: 1)
        #expect(vm.statusText == "1/3")
        #expect(ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context()).summary == "2 × 5–8 reps")
    }

    // MARK: Entering loads

    @Test("Loads can be typed (set directly) or nudged ±1, and are clamped")
    func typingAndNudging() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 2, targets: [50, 50]), context: env.context())
        vm.setWeight(62.5, forSet: 1)
        #expect(vm.rows[0].weightKg == 62.5)
        vm.nudgeWeight(by: 1, forSet: 1)
        #expect(vm.rows[0].weightKg == 63.5)
        vm.nudgeWeight(by: -1, forSet: 1); vm.nudgeWeight(by: -1, forSet: 1)
        #expect(vm.rows[0].weightKg == 61.5)
        vm.setWeight(62.555, forSet: 2)
        #expect(vm.rows[1].weightKg == 62.56)                              // two decimals at most
        vm.setWeight(-5, forSet: 2); #expect(vm.rows[1].weightKg == 0)
        vm.nudgeWeight(by: -1, forSet: 2); #expect(vm.rows[1].weightKg == 0)
        vm.setWeight(50_000, forSet: 2); #expect(vm.rows[1].weightKg == 1_000)
        vm.setReps(0, forSet: 1); #expect(vm.rows[0].reps == 1)
        vm.nudgeReps(by: 1, forSet: 1); #expect(vm.rows[0].reps == 2)
        vm.setReps(5_000, forSet: 1); #expect(vm.rows[0].reps == 100)
        vm.setWeight(10, forSet: 99); vm.setReps(10, forSet: 99); vm.nudgeWeight(by: 1, forSet: 99); vm.nudgeReps(by: 1, forSet: 99)
        #expect(!vm.complete(set: 99))                                      // unknown sets are ignored
    }

    // MARK: Same load

    @Test("Turning on 'same load' keeps the load that is already there and locks the pending sets to it")
    func sameLoadKeepsAndLocks() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 4, targets: [50, 50, 50, 50]), context: env.context())
        vm.setWeight(60, forSet: 2)                                         // sets differ: [50, 60, 50, 50]
        vm.setSameLoad(true)

        #expect(vm.sameLoadForAllSets && vm.sharedLoadKg == 50)
        #expect(vm.rows.map(\.weightKg) == [50, 50, 50, 50])               // nothing reset to zero; they follow the first pending set
        #expect(vm.rows.allSatisfy { vm.isLoadLocked($0) })

        vm.setWeight(99, forSet: 3); vm.nudgeWeight(by: 1, forSet: 3)       // locked: individual entry is refused
        #expect(vm.rows.map(\.weightKg) == [50, 50, 50, 50])
    }

    @Test("One shared field drives every pending set; finished sets are untouched")
    func sharedLoadDrivesPendingOnly() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 4, targets: [50, 50, 50, 50]), context: env.context())
        vm.setSameLoad(true)
        vm.setSharedLoad(80)
        #expect(vm.rows.map(\.weightKg) == [80, 80, 80, 80])
        vm.nudgeSharedLoad(by: 1)
        #expect(vm.sharedLoadKg == 81)

        vm.complete(set: 1); vm.complete(set: 2)
        vm.setSharedLoad(70)
        #expect(vm.rows.map(\.weightKg) == [81, 81, 70, 70])               // done sets keep what was lifted
        #expect(vm.rows.map { vm.isLoadLocked($0) } == [false, false, true, true])

        vm.complete(set: 3); vm.complete(set: 4)
        #expect(vm.sharedLoadKg == 70)                                      // everything done → the last set's load
        let off = ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context())
        off.setSharedLoad(99)                                               // ignored while the option is off
        #expect(off.rows.map(\.weightKg) == [0, 0])
    }

    @Test("A completed set is locked: load and reps can't be changed — not by typing, not by ±1, not through 'same load'")
    func completedSetsAreLocked() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, targets: [50, 50, 50]), context: env.context())
        vm.setWeight(52, forSet: 1)
        vm.complete(set: 1)
        let done = vm.rows[0]
        #expect(!vm.isEditable(done) && vm.isEditable(vm.rows[1]))

        vm.setWeight(55, forSet: 1)
        vm.setReps(9, forSet: 1)
        vm.nudgeWeight(by: 1, forSet: 1)
        vm.nudgeReps(by: 1, forSet: 1)
        vm.editLoad(70, forSet: 1)
        #expect(vm.rows[0].weightKg == 52 && vm.rows[0].reps == done.reps)
        vm.setSameLoad(true); vm.setSharedLoad(80)
        #expect(vm.rows[0].weightKg == 52)                                  // the shared load only moves pending sets
        #expect(vm.rows[1].weightKg == 80)
        #expect(lastLog(env)?.sets.first?.weightKg == 52)                   // and nothing leaked into the saved log
    }

    @Test("Un-marking reverts only the last performed set; earlier ones stay completed and locked")
    func undoIsLastInFirstOut() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, targets: [50, 50, 50]), context: env.context())
        vm.complete(set: 1); env.clock.advance(90)
        vm.complete(set: 2); env.clock.advance(90)
        #expect(vm.lastDoneSetNumber == 2)

        #expect(vm.undo(set: 1) == false)                                   // out of order: refused
        #expect(vm.rows[0].isDone && vm.rows[1].isDone)

        #expect(vm.undoLast())                                              // reverts set 2 only
        #expect(vm.rows.map(\.isDone) == [true, false, false])
        #expect(vm.isEditable(vm.rows[1]) && !vm.isEditable(vm.rows[0]))
        #expect(lastLog(env)?.sets.map(\.index) == [1])                     // saved log keeps set 1 and drops set 2

        #expect(vm.lastDoneSetNumber == 1 && vm.undoLast())
        #expect(vm.lastDoneSetNumber == nil && vm.undoLast() == false)
        #expect(lastLog(env)?.sets.isEmpty == true)
    }

    @Test("Turning 'same load' off unlocks the sets and keeps their values")
    func sameLoadOff() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, targets: [50, 50, 50]), context: env.context())
        vm.setSameLoad(true); vm.setSharedLoad(70)
        vm.setSameLoad(false)
        #expect(vm.rows.map(\.weightKg) == [70, 70, 70] && !vm.rows.contains { vm.isLoadLocked($0) })
        vm.setWeight(75, forSet: 2)
        #expect(vm.rows.map(\.weightKg) == [70, 75, 70])
    }

    @Test("The plan's default for 'same load' is applied from the start")
    func sameLoadDefault() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, sameLoad: true, targets: [40, 45, 50]), context: env.context())
        #expect(vm.sameLoadForAllSets)
        #expect(vm.rows.map(\.weightKg) == [40, 40, 40])
    }

    // MARK: One set in focus

    @Test("The big card follows the next pending set; tapping another set brings it into focus; completing moves on")
    func focus() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3), context: env.context())
        #expect(vm.activeSetNumber == 1)
        vm.complete(set: 1)
        #expect(vm.activeSetNumber == 2)

        vm.focus(set: 3)                                                    // look ahead at a pending set
        #expect(vm.activeSetNumber == 3 && vm.focusedSetNumber == 3)
        vm.focus(set: 99)                                                   // unknown sets are ignored
        #expect(vm.activeSetNumber == 3)
        vm.complete(set: 3)                                                 // completing releases the focus
        #expect(vm.focusedSetNumber == nil && vm.activeSetNumber == 2)      // back to the first pending set

        env.clock.advance(60)
        vm.complete(set: 2)
        #expect(vm.activeSetNumber == 2 && vm.isComplete)                  // all done → the last-completed set stays on screen
        vm.undoLast()
        #expect(vm.activeSetNumber == 2 && !vm.rows[1].isDone)              // undoing focuses that set again
    }

    @Test("The card's load control edits the shared load for a pending set, and the set itself once it's done")
    func loadRouting() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, targets: [50, 50, 50]), context: env.context())
        vm.editLoad(55, forSet: 1)                                          // same load off → just this set
        #expect(vm.rows.map(\.weightKg) == [55, 50, 50] && vm.loadShown(forSet: 2) == 50)

        vm.setSameLoad(true)                                                // shared = 55 (first pending set)
        vm.editLoad(60, forSet: 2)                                          // a pending set edits the shared load
        #expect(vm.rows.map(\.weightKg) == [60, 60, 60] && vm.loadShown(forSet: 3) == 60)

        vm.complete(set: 1)
        vm.editLoad(62, forSet: 1)                                          // a done set is locked: the edit is ignored
        #expect(vm.rows.map(\.weightKg) == [60, 60, 60])
        vm.editLoad(70, forSet: 3)                                          // pending sets follow the shared load
        #expect(vm.rows.map(\.weightKg) == [60, 70, 70])
        vm.editLoad(5, forSet: 99); #expect(vm.loadShown(forSet: 99) == 0)
    }

    // MARK: Completing, undoing, resting

    @Test("Completing a set persists it, gives feedback and starts the rest timer")
    func completeSet() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, rest: 90), context: env.context())
        vm.setWeight(100, forSet: 1)
        vm.setReps(6, forSet: 1)

        #expect(vm.complete(set: 1))
        #expect(!vm.complete(set: 1))                                       // can't complete twice
        #expect(vm.rows[0].isDone && vm.completedSetCount == 1 && vm.nextSetNumber == 2)
        #expect(env.feedback.count("setLogged") == 1)
        #expect(vm.restTimer.isRunning && vm.restTimer.remaining == 90)
        #expect(env.feedback.restAlerts == [PFx.t0.addingTimeInterval(90)])

        let log = lastLog(env)
        #expect(log?.sets.count == 1 && log?.sets[0].weightKg == 100 && log?.sets[0].reps == 6 && log?.sets[0].index == 1)
        #expect(log?.exercise == PFx.squat && log?.substitutedFor == nil)
        #expect(vm.currentLog() != nil)
    }

    @Test("Undo reverts a mistaken tap: the set goes back to pending and disappears from the saved log")
    func undo() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context())
        vm.complete(set: 1)
        env.clock.advance(100)
        vm.complete(set: 2)
        #expect(vm.rows[1].restTakenSeconds == 85)                          // gap 100 s − 5 reps × 3 s

        #expect(vm.undo(set: 2))
        #expect(!vm.rows[1].isDone && vm.rows[1].restTakenSeconds == nil && vm.completedSetCount == 1)
        #expect(lastLog(env)?.sets.map(\.index) == [1])
        #expect(!vm.undo(set: 2))                                            // already pending
        #expect(vm.undo(set: 1))
        #expect(lastLog(env)?.sets.isEmpty == true)                         // an empty log is emitted so the stored block is removed
        #expect(vm.currentLog() == nil)
    }

    @Test("Rest taken = gap between sets minus the estimated time under tension; the last set ends the rest")
    func restTakenAndLastSet() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context())
        vm.complete(set: 1)
        #expect(vm.rows[0].restTakenSeconds == nil && vm.restTimer.isRunning)
        env.clock.advance(100)
        vm.complete(set: 2)
        #expect(vm.rows[1].restTakenSeconds == 85)
        #expect(vm.isComplete && !vm.restTimer.isRunning && env.feedback.cancelledAlerts == 1)
    }

    @Test("When the rest runs out the student is told, until they act")
    func restFinished() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, rest: 60), context: env.context())
        vm.complete(set: 1)
        env.clock.advance(61)
        vm.restTimer.tick()
        #expect(env.feedback.count("restFinished") == 1 && vm.restFinishedWaiting)

        vm.dismissRestFinished()
        #expect(!vm.restFinishedWaiting)

        vm.restTimer.start(1); env.clock.advance(2); vm.restTimer.tick()
        #expect(vm.restFinishedWaiting)
        vm.complete(set: 2)                                                 // starting the next set clears it
        #expect(!vm.restFinishedWaiting && vm.restTimer.isRunning)
        vm.skipRest()
        #expect(!vm.restFinishedWaiting && !vm.restTimer.isRunning)
    }

    @Test("Pause, resume and ±15 s work on the rest timer, with sane limits and background alerts kept in sync")
    func restControls() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 3, rest: 60), context: env.context())
        vm.pauseRest(); vm.resumeRest()                                     // no-ops when nothing is running
        vm.adjustRest(by: 15)
        #expect(vm.restSeconds == 75)

        vm.complete(set: 1)
        env.clock.advance(20)
        vm.pauseRest()
        #expect(vm.restTimer.isPaused && vm.restTimer.remaining == 55)
        #expect(env.feedback.cancelledAlerts == 1)                          // no alert while paused

        vm.adjustRest(by: 15)                                               // adjusting while paused
        #expect(vm.restTimer.remaining == 70 && vm.restSeconds == 90)
        vm.resumeRest()
        #expect(vm.restTimer.isRunning && env.feedback.restAlerts.last == PFx.t0.addingTimeInterval(20 + 70))

        vm.setRestSeconds(5); #expect(vm.restSeconds == 15)
        vm.setRestSeconds(9_999); #expect(vm.restSeconds == 600)
        vm.setRestSeconds(120); #expect(vm.restSeconds == 120)
        vm.adjustRest(by: -1_000); #expect(vm.restSeconds == 15)
        vm.adjustRest(by: 10_000); #expect(vm.restSeconds == 600)
    }

    // MARK: Substitution

    @Test("The student can swap the exercise before the first set; the log records both names")
    func substitution() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context())
        let dumbbell = Exercise(id: "db-press", name: "Dumbbell Press", primaryMuscles: [.chest], equipment: .dumbbell)
        #expect(vm.canSubstitute && vm.substitutedFor == nil)

        vm.substitute(with: dumbbell)
        #expect(vm.title == "Dumbbell Press" && vm.substitutedFor == PFx.squat && vm.detail.shownRef.id == "db-press")

        vm.complete(set: 1)
        let log = lastLog(env)
        #expect(log?.exercise.id == "db-press" && log?.substitutedFor == PFx.squat)

        #expect(!vm.canSubstitute)                                          // locked after the first set
        vm.revertSubstitution()
        vm.substitute(with: Exercise(id: "other", name: "Other", primaryMuscles: [.chest], equipment: .machine))
        #expect(vm.title == "Dumbbell Press")
    }

    @Test("Reverting, or 'swapping' to the planned exercise, restores the original")
    func revertSubstitution() {
        let env = Env()
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context())
        let alt = Exercise(id: "alt", name: "Alt", primaryMuscles: [.quadriceps], equipment: .machine)
        vm.substitute(with: alt)
        vm.revertSubstitution()
        #expect(vm.title == "Back Squat" && vm.substitutedFor == nil && !vm.detail.isSubstituted)

        vm.substitute(with: alt)
        vm.substitute(with: Exercise(id: PFx.squat.id, name: "Back Squat", primaryMuscles: [.quadriceps], equipment: .barbell))
        #expect(vm.substitutedFor == nil && vm.title == "Back Squat")
    }

    @Test("Resuming restores completed sets, the chosen substitute, and prefills the rest from last session")
    func restore() {
        let env = Env()
        let saved = ResistanceLog(blockID: "blk-squat", exercise: ExerciseRef(id: "alt", name: "Alt Squat"), substitutedFor: PFx.squat, sets: [
            SetLog(index: 1, weightKg: 100, reps: 5, completedAt: PFx.t0),
            SetLog(index: 2, weightKg: 102.5, reps: 5, restTakenSeconds: 80, completedAt: PFx.t0.addingTimeInterval(120)),
        ])
        let vm = ResistanceBlockViewModel(block: PFx.resistance(sets: 4), context: env.context(restored: ["blk-squat": .resistance(saved)]))
        #expect(vm.rows.map(\.isDone) == [true, true, false, false])
        #expect(vm.rows[1].restTakenSeconds == 80)
        #expect(vm.rows[2].weightKg == 102.5)                                // pending sets continue from the last load
        #expect(vm.title == "Alt Squat" && vm.substitutedFor == PFx.squat && vm.detail.isSubstituted)
        #expect(ResistanceBlockViewModel(block: PFx.resistance(sets: 2), context: env.context()).currentLog() == nil)

        // …and a restored block with "same load" on keeps finished sets while pending ones follow the shared load.
        let sameLoad = ResistanceBlockViewModel(block: PFx.resistance(sets: 4, sameLoad: true), context: env.context(restored: ["blk-squat": .resistance(saved)]))
        #expect(sameLoad.rows.map(\.weightKg) == [100, 102.5, 102.5, 102.5])
    }
}

@MainActor
@Suite("HIIT & cardio view models")
struct IntervalAndCardioTests {
    @Test("HIIT runs work/rest segments, signals each change, and logs rounds and time")
    func hiitFlow() {
        let env = Env()
        let vm = HIITBlockViewModel(block: PFx.hiit, context: env.context())     // 2 rounds of 20 s / 10 s → W R W
        #expect(vm.state == .ready && vm.currentSegment?.kind == .work && !vm.isComplete && vm.currentLog() == nil)

        vm.start()
        #expect(vm.state == .running && vm.timer.remaining == 20)
        env.clock.advance(20); vm.timer.tick()
        #expect(vm.currentSegment?.kind == .rest && vm.roundsCompleted == 1)
        env.clock.advance(10); vm.timer.tick()
        #expect(vm.currentSegment?.kind == .work && vm.currentSegment?.round == 2)
        #expect(env.feedback.count("intervalChanged") == 2)

        env.clock.advance(5)
        #expect(vm.elapsedSeconds == 35)
        env.clock.advance(15); vm.timer.tick()
        #expect(vm.state == .finished && vm.isComplete && vm.roundsCompleted == 2)
        guard case .hiit(let log)? = env.sink.logged.last else { Issue.record("HIIT not logged"); return }
        #expect(log.roundsCompleted == 2 && log.totalSeconds == 50)
    }

    @Test("Pause/resume, skipping an interval, and ending early")
    func hiitControls() {
        let env = Env()
        let vm = HIITBlockViewModel(block: PFx.hiit, context: env.context())
        vm.pause(); vm.resume(); vm.skipSegment()                          // no-ops before starting
        #expect(vm.state == .ready)

        vm.start(); vm.start()
        env.clock.advance(8)
        vm.pause()
        #expect(vm.state == .paused)
        vm.resume()
        vm.skipSegment()                                                    // bail out of work interval 1: not counted
        #expect(vm.currentSegment?.kind == .rest && vm.roundsCompleted == 0)

        vm.perceivedRPE = 9
        env.clock.advance(4)
        vm.finishEarly()
        #expect(vm.isComplete)
        guard case .hiit(let log)? = env.sink.logged.last else { Issue.record("HIIT not logged"); return }
        #expect(log.roundsCompleted == 0 && log.totalSeconds == 12 && log.rpe == 9)
        vm.finishEarly()                                                    // idempotent
        #expect(env.sink.logged.count == 1)
    }

    @Test("Skipping through every segment ends the block")
    func hiitSkipToEnd() {
        let env = Env()
        let vm = HIITBlockViewModel(block: PFx.hiit, context: env.context())
        vm.start()
        for _ in 0..<3 { vm.skipSegment() }
        #expect(vm.state == .finished)
    }

    @Test("A restored HIIT block comes back finished")
    func hiitRestore() {
        let env = Env()
        let saved = BlockLog.hiit(HIITLog(blockID: "hiit", roundsCompleted: 2, totalSeconds: 50, rpe: 8))
        let vm = HIITBlockViewModel(block: PFx.hiit, context: env.context(restored: ["hiit": saved]))
        #expect(vm.isComplete && vm.roundsCompleted == 2 && vm.perceivedRPE == 8)
        vm.start()                                                          // can't restart a finished block
        #expect(vm.state == .finished)
    }

    @Test("Cardio tracks elapsed time across pauses and validates what the student types")
    func cardioFlow() {
        let env = Env()
        let vm = CardioBlockViewModel(block: PFx.cardio, context: env.context())
        #expect(vm.title == "Bike" && vm.progress(at: PFx.t0) == 0 && vm.currentLog() == nil)

        vm.pause()                                                          // no-op
        vm.start(); vm.start()
        env.clock.advance(300)
        #expect(vm.elapsed(at: env.clock.now()) == 300 && abs(vm.progress(at: env.clock.now()) - 0.5) < 1e-9)
        vm.pause()
        env.clock.advance(1_000)                                            // paused time doesn't count
        vm.start()
        env.clock.advance(120)

        vm.distanceText = "5,25"
        vm.heartRateText = "148"
        vm.finish()
        guard case .cardio(let log)? = env.sink.logged.last else { Issue.record("cardio not logged"); return }
        #expect(log.durationSeconds == 420 && log.distanceMeters == 5_250 && log.averageHeartRate == 148 && log.modality == .bike)
        #expect(vm.isComplete && env.feedback.count("setLogged") == 1)
        vm.finish(); vm.start()
        #expect(env.sink.logged.count == 1 && !vm.isRunning)
    }

    @Test("Implausible cardio inputs are dropped, not stored; a restored block comes back finished")
    func cardioValidationAndRestore() {
        let env = Env()
        let vm = CardioBlockViewModel(block: PFx.cardio, context: env.context())
        vm.distanceText = "9000"; vm.heartRateText = "999"
        vm.finish()
        guard case .cardio(let log)? = vm.currentLog() else { Issue.record("no log"); return }
        #expect(log.distanceMeters == nil && log.averageHeartRate == nil)

        let saved = BlockLog.cardio(CardioLog(blockID: "cardio", modality: .bike, durationSeconds: 600, distanceMeters: 4_000, averageHeartRate: 140))
        let restored = CardioBlockViewModel(block: PFx.cardio, context: env.context(restored: ["cardio": saved]))
        #expect(restored.isComplete && restored.distanceText == "4.0" && restored.heartRateText == "140")
        #expect(restored.elapsed(at: PFx.t0) == 600)
        #expect(CardioBlockViewModel(block: CardioBlock(id: "z", modality: .run, targetDurationSeconds: 0), context: env.context()).progress(at: PFx.t0) == 0)
    }
}
