import Foundation
import Testing
import Domain
import SyncKit
@testable import DataKit

@Suite("OfflineFirstStore · write path")
struct OfflineFirstWriteTests {
    @Test("Save = encrypted local write + queued mutation; the UI never waits on the network")
    func saveWritesLocallyAndQueues() async throws {
        let stack = Stack(online: false)
        let saved = try await stack.logs.save(DFx.log(id: "l1"))

        #expect(saved.meta.version == 1 && saved.meta.state == .pendingUpsert)
        let record = try #require(try await stack.backing.record(collection: "workoutLogs", id: "l1"))
        #expect(record.syncState == .pendingUpsert && record.remoteVersion == 0 && record.localVersion == 1)
        #expect(record.ownerID == "s1")

        let mutation = try #require(await stack.queue.snapshot().first)
        #expect(mutation.path == DocumentPath(collection: "students/s1/workoutLogs", documentID: "l1"))
        #expect(mutation.baseVersion == 0)
        #expect(mutation.payload["meta"]?["version"] == .int(1))
        #expect(mutation.payload["startedAt"] == .date(DFx.t0))           // a real Timestamp, not a number
        #expect(mutation.payload["meta"]?["state"] == nil)                // local-only flag never leaves the device
    }

    @Test("Logging set after set coalesces into one queued write whose base is still the original server revision")
    func repeatedSavesCoalesce() async throws {
        let stack = Stack(online: false)
        var log = try await stack.logs.save(DFx.log(id: "l1"))
        for sets in 1...4 {
            log = DFx.log(id: "l1", sets: sets)                            // deliberately a *stale* copy each time
            log = try await stack.logs.save(log)
        }
        #expect(log.meta.version == 5)                                     // versions continue from the stored record
        let queued = await stack.queue.snapshot()
        #expect(queued.count == 1 && queued[0].baseVersion == 0)
        #expect(try await stack.logs.get(id: "l1")?.blocks.count == 1)
    }

    @Test("If the queue can't persist, the local write is rolled back so the UI never shows an unsyncable edit")
    func rollbackOnEnqueueFailure() async throws {
        let queue = MutationQueue(store: FailingQueueStore())
        let store = OfflineFirstStore(descriptor: .workoutLog, store: InMemoryRecordStore(), queue: queue,
                                      trigger: DeferredSyncTrigger(), deviceID: "d")
        await #expect(throws: (any Error).self) { try await store.save(DFx.log(id: "l1")) }
        #expect(try await store.get(id: "l1") == nil)
    }

    @Test("…and an existing record is restored, not lost, when a later save fails")
    func rollbackRestoresPrevious() async throws {
        let backing = InMemoryRecordStore()
        let good = OfflineFirstStore(descriptor: .workoutLog, store: backing, queue: MutationQueue(store: InMemoryMutationStore()),
                                     trigger: DeferredSyncTrigger(), deviceID: "d")
        try await good.save(DFx.log(id: "l1", sets: 1))

        let broken = OfflineFirstStore(descriptor: .workoutLog, store: backing, queue: MutationQueue(store: FailingQueueStore()),
                                       trigger: DeferredSyncTrigger(), deviceID: "d")
        await #expect(throws: (any Error).self) { try await broken.save(DFx.log(id: "l1", sets: 3)) }
        #expect(try await good.get(id: "l1")?.meta.version == 1)
    }

    @Test("Delete writes a tombstone: hidden from lists, still stored, and queued so other devices see it")
    func softDelete() async throws {
        let stack = Stack(online: false)
        let saved = try await stack.logs.save(DFx.log(id: "l1"))
        let deleted = try await stack.logs.delete(saved)

        #expect(deleted.meta.isDeleted && deleted.meta.state == .pendingDelete)
        #expect(try await stack.logs.list(ownerID: "s1").isEmpty)
        #expect(try await stack.logs.list(ownerID: "s1", includeDeleted: true).count == 1)
        #expect(await stack.queue.snapshot().first?.payload["meta"]?["deletedAt"] != nil)
    }

    @Test("Lists are newest-first and partitioned per student")
    func listing() async throws {
        let stack = Stack(online: false)
        try await stack.logs.save(DFx.log(id: "old", start: DFx.t0))
        try await stack.logs.save(DFx.log(id: "new", start: DFx.t0.addingTimeInterval(86_400)))
        try await stack.logs.save(DFx.log(id: "other", student: "s2", start: DFx.t0))
        #expect(try await stack.logs.list(ownerID: "s1").map(\.id.rawValue) == ["new", "old"])
        #expect(try await stack.logs.list(ownerID: "s2").map(\.id.rawValue) == ["other"])
    }

    @Test("observe() emits the current list, then every change")
    func observing() async throws {
        let stack = Stack(online: false)
        var iterator = stack.logs.observe(ownerID: "s1").makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await stack.logs.save(DFx.log(id: "l1"))
        #expect(await iterator.next()?.map(\.id.rawValue) == ["l1"])
        try await stack.logs.save(DFx.log(id: "l2", start: DFx.t0.addingTimeInterval(10)))
        #expect(await iterator.next()?.map(\.id.rawValue) == ["l2", "l1"])
    }
}

@Suite("OfflineFirstStore · inbound")
struct OfflineFirstInboundTests {
    func remote(_ log: WorkoutLog, rev: Int) throws -> RemoteDocument {
        RemoteDocument(fields: try SyncCoding.fields(log), version: rev, updatedAt: nil)
    }

    @Test("A server document is stored as synced, with its revision")
    func appliesRemote() async throws {
        let stack = Stack(online: false)
        var serverLog = DFx.log(id: "l1", sets: 2)
        serverLog.meta.version = 4
        #expect(try await stack.logs.applyRemote(remote(serverLog, rev: 3), overwritePending: false) == .applied)

        let record = try #require(try await stack.backing.record(collection: "workoutLogs", id: "l1"))
        #expect(record.syncState == .synced && record.remoteVersion == 3 && record.localVersion == 4)
        #expect(try await stack.logs.get(id: "l1")?.meta.state == .synced)
        #expect(try await stack.queue.snapshot().isEmpty)                  // inbound never creates outbound work
    }

    @Test("Duplicate and out-of-order snapshots are ignored")
    func ignoresStale() async throws {
        let stack = Stack(online: false)
        try await stack.logs.applyRemote(remote(DFx.log(id: "l1"), rev: 5), overwritePending: false)
        #expect(try await stack.logs.applyRemote(remote(DFx.log(id: "l1", sets: 1), rev: 5), overwritePending: false) == .stale)
        #expect(try await stack.logs.applyRemote(remote(DFx.log(id: "l1", sets: 1), rev: 4), overwritePending: false) == .stale)
        #expect(try await stack.logs.applyRemote(remote(DFx.log(id: "l1", sets: 1), rev: 6), overwritePending: false) == .applied)
    }

    @Test("A server copy never clobbers a queued local edit — unless explicitly told to")
    func protectsPendingEdits() async throws {
        let stack = Stack(online: false)
        try await stack.logs.save(DFx.log(id: "l1", sets: 3))
        #expect(try await stack.logs.applyRemote(remote(DFx.log(id: "l1"), rev: 9), overwritePending: false) == .keptLocalPending)
        #expect(try await stack.logs.get(id: "l1")?.blocks.count == 1)

        #expect(try await stack.logs.applyRemote(remote(DFx.log(id: "l1"), rev: 9), overwritePending: true) == .applied)
        #expect(try await stack.logs.get(id: "l1")?.blocks.isEmpty == true)
    }

    @Test("Malformed server documents are rejected instead of corrupting the store")
    func rejectsGarbage() async {
        let stack = Stack(online: false)
        await #expect(throws: (any Error).self) {
            try await stack.logs.applyRemote(RemoteDocument(fields: ["id": .string("x")], version: 1), overwritePending: false)
        }
    }
}

@Suite("Offline → online, end to end")
struct EndToEndTests {
    @Test("A workout logged in a basement gym syncs by itself once the signal returns")
    func offlineWorkoutSyncsOnReconnect() async throws {
        let stack = Stack(online: false)
        await stack.dispatcher.start()

        // Student logs three sets with no connectivity. UI reads come straight from local storage.
        var log = try await stack.logs.save(DFx.log(id: "l1"))
        for sets in 1...3 { log = try await stack.logs.save(DFx.log(id: "l1", sets: sets)) }
        #expect(try await stack.logs.get(id: "l1")?.meta.state == .pendingUpsert)
        #expect(await stack.server.docs.isEmpty)

        await stack.network.setOnline(true)

        let path = DocumentPath(collection: "students/s1/workoutLogs", documentID: "l1")
        #expect(await eventually { await stack.server.docs[path] != nil })
        #expect(await eventually { (try? await stack.logs.get(id: "l1"))??.meta.state == .synced })
        #expect(await stack.server.docs[path]?.rev == 1)                   // three sets, one write
        let record = try #require(try await stack.backing.record(collection: "workoutLogs", id: "l1"))
        #expect(record.remoteVersion == 1 && record.syncState == .synced)

        // The device that wrote it can read what the server now holds.
        let onServer = try SyncCoding.decode(WorkoutLog.self, from: try #require(await stack.server.docs[path]).fields)
        #expect(onServer.blocks.count == 1 && onServer.meta.version == 4)
        await stack.dispatcher.stop()
    }

    @Test("Losing a conflict pulls the server copy down and clears the pending flag")
    func remoteWinsConflict() async throws {
        let stack = Stack(resolver: PolicyConflictResolver(policies: ["plans": .serverWins]))
        let planA = try await stack.plans.save(DFx.plan(id: "p1"))        // saving kicks the dispatcher in the background
        let path = DocumentPath(collection: "plans", documentID: "p1")
        #expect(await eventually { await stack.server.docs[path]?.rev == 1 })
        #expect(await eventually { await stack.queue.counts().isEmpty })

        // The trainer edits the plan on another device (server rev 2), then this device edits offline from rev 1.
        var trainerEdit = planA
        trainerEdit.name = "Trainer's version"
        trainerEdit.meta.version = 50
        await stack.server.seed(path, fields: try SyncCoding.fields(trainerEdit), rev: 2)
        var localEdit = planA
        localEdit.name = "Student-side edit"
        try await stack.plans.save(localEdit)

        // The local edit lost; the server's version is now what this device shows, and nothing is left pending.
        #expect(await eventually { (try? await stack.plans.get(id: "p1"))??.name == "Trainer's version" })
        #expect(await eventually { await stack.queue.counts().isEmpty })
        let record = try #require(try await stack.backing.record(collection: "plans", id: "p1"))
        #expect(record.syncState == .synced && record.remoteVersion == 2)
    }

    @Test("A permanently rejected write flags the local record so the UI can offer a retry")
    func failedMutationFlagsRecord() async throws {
        let stack = Stack()
        let saved = try await stack.logs.save(DFx.log(id: "l1"))
        await stack.queue.fail(try #require(await stack.queue.snapshot().first).id, error: "denied")
        let path = DocumentPath(collection: "students/s1/workoutLogs", documentID: "l1")
        let updater = LocalSyncStateUpdater(store: stack.records, queue: stack.queue)
        await updater.mutationFailed(Mutation(path: path, kind: .upsert, createdAt: DFx.t0), error: .permissionDenied)
        #expect(try await stack.logs.get(id: saved.id.rawValue)?.meta.state == .failed)
    }

    @Test("Dropped without a way to refetch: the record is marked conflicted rather than silently left pending")
    func droppedWithoutRefetch() async throws {
        let stack = Stack(online: false)
        try await stack.logs.save(DFx.log(id: "l1"))
        let path = DocumentPath(collection: "students/s1/workoutLogs", documentID: "l1")
        let updater = LocalSyncStateUpdater(store: stack.records, queue: stack.queue)
        await updater.mutationDropped(Mutation(path: path, kind: .upsert, createdAt: DFx.t0), reason: .remoteWonConflict)
        #expect(try await stack.logs.get(id: "l1")?.meta.state == .conflict)
    }
}
