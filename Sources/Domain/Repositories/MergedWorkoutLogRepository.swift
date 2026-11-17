import Foundation

/// One `WorkoutLogRepository` over two stores: the student's own workouts and the ones the trainer ran next to them.
///
/// They are different collections on purpose — the student's device is the only writer of the first, the trainer's the only writer of the
/// second, so no document ever has two writers and no write can overwrite the other's. Everything that *reads* history (the calendar, the
/// rotation of workouts, the strength/volume guard, the charts, the trainer's summary) goes through this one type and so sees a coached session
/// like any other. Everything that *writes* is routed by `coachedBy`.
public struct MergedWorkoutLogRepository: WorkoutLogRepository {
    public let own: any WorkoutLogRepository
    public let coached: any WorkoutLogRepository

    public init(own: any WorkoutLogRepository, coached: any WorkoutLogRepository) {
        self.own = own
        self.coached = coached
    }

    @discardableResult
    public func save(_ log: WorkoutLog) async throws -> WorkoutLog {
        try await (log.coachedBy == nil ? own : coached).save(log)
    }

    public func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? {
        if let found = try await own.log(id: id, studentID: studentID) { return found }
        return try await coached.log(id: id, studentID: studentID)
    }

    public func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] {
        async let mine = own.logs(studentID: studentID, planID: planID, since: since)
        async let theirs = coached.logs(studentID: studentID, planID: planID, since: since)
        return Self.merged(try await mine, try await theirs)
    }

    public func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> {
        let ownStream = own.observeLogs(studentID: studentID)
        let coachedStream = coached.observeLogs(studentID: studentID)
        return AsyncStream { continuation in
            let state = Latest()
            let a = Task {
                for await logs in ownStream { if let merged = await state.setOwn(logs) { continuation.yield(merged) } }
                await state.finishOwn()
                if await state.isFinished { continuation.finish() }
            }
            let b = Task {
                for await logs in coachedStream { if let merged = await state.setCoached(logs) { continuation.yield(merged) } }
                await state.finishCoached()
                if await state.isFinished { continuation.finish() }
            }
            continuation.onTermination = { _ in a.cancel(); b.cancel() }
        }
    }

    /// Newest first, one entry per id (the first source wins, though ids never collide in practice: they are random).
    static func merged(_ a: [WorkoutLog], _ b: [WorkoutLog]) -> [WorkoutLog] {
        var seen = Set<LogID>()
        return (a + b).filter { seen.insert($0.id).inserted }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The latest list from each side; a merged value is emitted only once both have reported, so the screen never flashes half a history.
    private actor Latest {
        private var own: [WorkoutLog]?
        private var coached: [WorkoutLog]?
        private var ownDone = false
        private var coachedDone = false

        func setOwn(_ logs: [WorkoutLog]) -> [WorkoutLog]? { own = logs; return combined() }
        func setCoached(_ logs: [WorkoutLog]) -> [WorkoutLog]? { coached = logs; return combined() }
        func finishOwn() { ownDone = true }
        func finishCoached() { coachedDone = true }
        var isFinished: Bool { ownDone && coachedDone }

        private func combined() -> [WorkoutLog]? {
            guard let own, let coached else { return nil }
            return MergedWorkoutLogRepository.merged(own, coached)
        }
    }
}
