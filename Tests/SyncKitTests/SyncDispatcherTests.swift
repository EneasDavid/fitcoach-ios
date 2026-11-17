import Foundation
import Testing
@testable import SyncKit

@Suite("SyncDispatcher · connectivity & retry")
struct SyncDispatcherConnectivityTests {
    @Test("Drains the queue to the server in order and reports a clean status")
    func drainsEverything() async throws {
        let h = Harness()
        try await h.enqueue(P.logA)
        try await h.enqueue(P.logB)
        try await h.enqueue(P.logC)

        let report = await h.dispatcher.drain()
        #expect(report.applied == 3 && report.stopped == .idle)
        #expect(await h.server.appliedPaths == [P.logA, P.logB, P.logC])
        #expect(await h.queue.counts().isEmpty)
        #expect(await h.observer.applied.count == 3)

        let status = await h.dispatcher.currentStatus()
        #expect(status.isFullySynced && status.lastSyncedAt == h.clock.now() && !status.isSyncing)
    }

    @Test("Offline: nothing is sent and nothing is lost; reconnecting drains automatically")
    func offlineThenReconnect() async throws {
        let h = Harness(online: false)
        try await h.enqueue(P.logA)
        await h.dispatcher.start()

        #expect(await eventually { await h.dispatcher.currentStatus().isOnline == false })
        #expect(await h.server.attempts.isEmpty)
        #expect(await h.dispatcher.currentStatus().pending == 1)

        await h.network.setOnline(true)
        #expect(await eventually { await h.server.documents[P.logA] != nil })
        #expect(await eventually { await h.dispatcher.currentStatus().isFullySynced })
        await h.dispatcher.stop()
    }

    @Test("Edits made offline are coalesced, so reconnecting sends one write, not one per set")
    func offlineEditsCoalesce() async throws {
        let h = Harness(online: false)
        for sets in 1...5 { try await h.enqueue(P.logA, .upsert, ["sets": .int(sets)], base: 0) }
        await h.network.setOnline(true)

        let report = await h.dispatcher.drain()
        #expect(report.applied == 1)
        #expect(await h.server.documents[P.logA]?.fields == ["sets": .int(5)])
    }

    @Test("Transient failures back off exponentially, and a failed document is not retried before it is due")
    func exponentialBackoff() async throws {
        let h = Harness()
        try await h.enqueue(P.logA)
        await h.server.failNext([.transient(retryAfter: nil), .transient(retryAfter: nil)])

        let first = await h.dispatcher.drain()
        #expect(first.retried == 1)
        #expect(await h.queue.snapshot().first?.nextAttemptAt == h.clock.now().addingTimeInterval(2))
        #expect(await eventually { await h.sleeps.delays == [2] })     // wake-up scheduled for when it is due

        let tooEarly = await h.dispatcher.drain()
        #expect(tooEarly.applied == 0 && tooEarly.retried == 0)
        #expect(await h.server.attempts.count == 1)

        h.clock.advance(2.1)
        #expect(await h.dispatcher.drain().retried == 1)
        #expect(await h.queue.snapshot().first?.nextAttemptAt == h.clock.now().addingTimeInterval(4))   // doubled

        h.clock.advance(4.1)
        #expect(await h.dispatcher.drain().applied == 1)
        #expect(await h.queue.counts().isEmpty)
        #expect(await h.server.attempts.count == 3)
        await h.dispatcher.stop()
    }

    @Test("A server-supplied retry-after wins over a shorter backoff")
    func retryAfterIsHonoured() async throws {
        let h = Harness()
        try await h.enqueue(P.logA)
        await h.server.failNext([.transient(retryAfter: 60)])
        await h.dispatcher.drain()
        #expect(await h.queue.snapshot().first?.nextAttemptAt == h.clock.now().addingTimeInterval(60))
        await h.dispatcher.stop()
    }

    @Test("After max attempts a mutation is dead-lettered and reported, not retried forever")
    func exhaustedRetries() async throws {
        let h = Harness(backoff: BackoffPolicy(jitter: 0, maxAttempts: 3))
        let m = try #require(try await h.enqueue(P.logA))
        await h.server.failNext(Array(repeating: .transient(retryAfter: nil), count: 3))

        for _ in 0..<3 {
            await h.dispatcher.drain()
            h.clock.advance(60)
        }
        #expect(await h.queue.counts() == MutationQueue.Counts(pending: 0, inFlight: 0, failed: 1))
        #expect(await h.observer.failed == [m.id])
        #expect(await h.dispatcher.currentStatus().failed == 1)
        await h.dispatcher.stop()
    }

    @Test("A dead-lettered mutation can be re-armed and then goes through")
    func retryFailed() async throws {
        let h = Harness()
        try await h.enqueue(P.logA)
        await h.server.failNext([.permissionDenied])
        await h.dispatcher.drain()
        #expect(await h.queue.counts().failed == 1)

        await h.dispatcher.retryFailed()
        #expect(await eventually { await h.server.documents[P.logA] != nil })
    }

    @Test("A gateway-reported offline stops the pass without burning an attempt, and schedules a probe")
    func gatewayOffline() async throws {
        let h = Harness()
        try await h.enqueue(P.logA)
        await h.server.failNext([.offline])

        let report = await h.dispatcher.drain()
        #expect(report.stopped == .offline)
        #expect(await h.queue.snapshot().first?.attempts == 0)
        #expect(await eventually { await h.sleeps.delays == [15] })
        await h.dispatcher.stop()
    }

    @Test("Auth expiry pauses the whole queue until the user signs in again")
    func authPause() async throws {
        let h = Harness()
        try await h.enqueue(P.logA)
        try await h.enqueue(P.logB)
        await h.server.failNext([.unauthenticated])

        #expect(await h.dispatcher.drain().stopped == .authRequired)
        #expect(await h.dispatcher.currentStatus().authRequired)
        #expect(await h.dispatcher.drain().stopped == .authRequired)
        #expect(await h.server.attempts.count == 1)                    // not even tried again while paused

        await h.dispatcher.resumeAfterAuthentication()
        #expect(await eventually { await h.server.documents.count == 2 })
        #expect(await h.dispatcher.currentStatus().authRequired == false)
    }

    @Test("Permission-denied is dead-lettered and does not block unrelated documents")
    func permissionDenied() async throws {
        let h = Harness()
        let denied = try #require(try await h.enqueue(P.logA))
        try await h.enqueue(P.logB)
        await h.server.failNext([.permissionDenied])

        let report = await h.dispatcher.drain()
        #expect(report.failed == 1 && report.applied == 1)
        #expect(await h.observer.failed == [denied.id])
        #expect(await h.server.documents[P.logB] != nil)
    }

    @Test("A delete for a document that is already gone is simply dropped; a patch to it is dead-lettered")
    func notFound() async throws {
        let h = Harness()
        let deletion = try #require(try await h.enqueue(P.logA, .delete, [:], base: nil))
        let patch = try #require(try await h.enqueue(P.logB, .patch, ["x": .int(1)], base: nil))

        let report = await h.dispatcher.drain()
        #expect(report.dropped == 1 && report.failed == 1)
        #expect(await h.observer.dropped.map(\.id) == [deletion.id])
        #expect(await h.observer.failed == [patch.id])
    }

    @Test("Replaying a write whose acknowledgement was lost is applied exactly once")
    func idempotentReplay() async throws {
        let h = Harness()
        let m = try #require(try await h.enqueue(P.logA))
        await h.server.loseNextAcknowledgements(1)

        await h.dispatcher.drain()                                     // server applied it; the client never heard
        #expect(await h.server.documents[P.logA]?.rev == 1)
        #expect(await h.queue.counts().pending == 1)

        h.clock.advance(5)
        await h.dispatcher.drain()
        #expect(await h.server.documents[P.logA]?.rev == 1)            // not applied a second time
        #expect(await h.observer.applied.last?.result.alreadyApplied == true)
        #expect(await h.observer.applied.last?.id == m.id)
        #expect(await h.queue.counts().isEmpty)
        await h.dispatcher.stop()
    }

    @Test("An edit made while the previous write is in flight does not conflict with it")
    func editDuringFlight() async throws {
        let h = Harness()
        let gate = AsyncGate()
        await h.server.block(on: gate)
        try await h.enqueue(P.logA, .upsert, ["sets": .int(1)], base: 0)

        let firstDrain = Task { await h.dispatcher.drain() }
        #expect(await eventually { await h.server.attempts.count == 1 })

        // The student logs another set while set 1 is still being uploaded: same document, stale base.
        try await h.enqueue(P.logA, .patch, ["sets": .int(2)], base: 0)
        #expect(await h.dispatcher.drain().stopped == .alreadyRunning)  // joins the running drain

        await gate.open()
        let report = await firstDrain.value
        #expect(report.applied == 2 && report.conflicts == 0)
        #expect(await h.server.documents[P.logA]?.rev == 2)
        #expect(await h.server.documents[P.logA]?.fields == ["sets": .int(2)])
    }

    @Test("Start-up recovers a queue persisted by a previous run and drains it")
    func recoversPersistedQueue() async throws {
        let leftover = Mutation(sequence: 3, path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .inFlight)
        let h = Harness(storedMutations: [leftover])
        await h.dispatcher.start()
        #expect(await eventually { await h.server.documents[P.logA] != nil })
        await h.dispatcher.stop()
    }

    @Test("Status updates stream the badge state to the UI")
    func statusStream() async throws {
        let h = Harness()
        let collected = StatusCollector()
        let task = Task {
            for await status in await h.dispatcher.statusUpdates() { await collected.add(status) }
        }
        #expect(await eventually { await collected.statuses.count >= 1 })   // subscription replays the current state
        try await h.enqueue(P.logA)
        await h.dispatcher.drain()

        #expect(await eventually { await collected.statuses.contains { $0.isSyncing } })
        #expect(await eventually { await collected.statuses.last?.isFullySynced == true })
        task.cancel()
    }
}

actor StatusCollector {
    private(set) var statuses: [SyncStatus] = []
    func add(_ status: SyncStatus) { statuses.append(status) }
}

@Suite("SyncDispatcher · conflicts")
struct SyncDispatcherConflictTests {
    @Test("clientWins: the edit is rebased on the server revision and applied")
    func clientWins() async throws {
        let h = Harness(resolver: PolicyConflictResolver(policies: ["workoutLogs": .clientWins]))
        await h.server.seed(P.logA, fields: ["v": .int(0), "other": .string("remote")], rev: 5)
        try await h.enqueue(P.logA, .upsert, ["v": .int(9)], base: 3)

        let report = await h.dispatcher.drain()
        #expect(report.conflicts == 1 && report.applied == 1)
        let doc = try #require(await h.server.documents[P.logA])
        #expect(doc.rev == 6)
        #expect(doc.fields["v"] == .int(9) && doc.fields["other"] == .string("remote"))
    }

    @Test("serverWins: the local edit is dropped and the observer is told")
    func serverWins() async throws {
        let h = Harness(resolver: PolicyConflictResolver(policies: [:], defaultPolicy: .serverWins))
        await h.server.seed(P.logA, fields: ["v": .int(0)], rev: 5)
        let m = try #require(try await h.enqueue(P.logA, .upsert, ["v": .int(9)], base: 3))

        let report = await h.dispatcher.drain()
        #expect(report.dropped == 1 && report.applied == 0)
        #expect(await h.server.documents[P.logA]?.fields == ["v": .int(0)])
        #expect(await h.observer.dropped.first?.id == m.id)
        #expect(await h.observer.dropped.first?.reason == .remoteWonConflict)
        #expect(await h.queue.counts().isEmpty)
    }

    @Test("merge: server-owned fields survive, the rest of the local edit lands")
    func mergePreservesServerOwnedFields() async throws {
        let policy = ConflictPolicy.mergePreferringRemote(fields: ["role"])
        let h = Harness(resolver: PolicyConflictResolver(policies: ["workoutLogs": policy]))
        await h.server.seed(P.logA, fields: ["name": .string("old"), "role": .string("student")], rev: 2)
        try await h.enqueue(P.logA, .upsert, ["name": .string("new"), "role": .string("trainer")], base: 1)

        await h.dispatcher.drain()
        #expect(await h.server.documents[P.logA]?.fields == ["name": .string("new"), "role": .string("student")])
    }

    @Test("A conflict that never resolves is dead-lettered after the retry limit")
    func conflictGivesUp() async throws {
        let h = Harness(maxConflictRetries: 2)
        await h.server.seed(P.logA, fields: [:], rev: 5)
        await h.server.failNext(Array(repeating: .conflict(serverVersion: 5), count: 10))
        try await h.enqueue(P.logA, .upsert, ["v": .int(1)], base: 1)

        let report = await h.dispatcher.drain()
        #expect(report.failed == 1)
        #expect(await h.queue.counts().failed == 1)
        #expect(report.conflicts == 2)
    }

    @Test("Server copy gone: an upsert re-creates it, a delete is dropped, a patch is dead-lettered")
    func remoteDeleted() async throws {
        let h = Harness()   // the server has none of these documents, but every mutation claims to be based on rev 4
        try await h.enqueue(P.logA, .upsert, ["v": .int(1)], base: 4)
        try await h.enqueue(P.logB, .delete, [:], base: 4)
        try await h.enqueue(P.logC, .patch, ["v": .int(1)], base: 4)

        let report = await h.dispatcher.drain()
        #expect(report.conflicts == 3)
        #expect(await h.server.documents[P.logA]?.rev == 1)            // re-created
        #expect(report.dropped == 1)
        #expect(report.failed == 1)
    }
}
