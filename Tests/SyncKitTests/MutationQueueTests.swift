import Foundation
import Testing
@testable import SyncKit

@Suite("MutationQueue")
struct MutationQueueTests {
    let clock = TestClock()

    func makeQueue(_ store: InMemoryMutationStore = InMemoryMutationStore()) -> (MutationQueue, InMemoryMutationStore) {
        let clock = self.clock
        return (MutationQueue(store: store, now: { clock.now() }), store)
    }

    @Test("Sequences increase and every edit is persisted before enqueue returns")
    func sequencesAndDurability() async throws {
        let (queue, store) = makeQueue()
        let a = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0))
        let b = try #require(try await queue.enqueue(path: P.logB, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0))
        #expect(b.sequence == a.sequence + 1)
        #expect(await store.all().map(\.id) == [a.id, b.id])
    }

    @Test("An enqueue that cannot be persisted throws and leaves the queue untouched")
    func enqueueFailureSurfaces() async {
        let queue = MutationQueue(store: FailingStore())
        await #expect(throws: (any Error).self) {
            try await queue.enqueue(path: P.logA, kind: .upsert, payload: [:], baseVersion: 0)
        }
        #expect(await queue.snapshot().isEmpty)
    }

    @Test("Rapid edits to one document coalesce into a single mutation that keeps its identity and base")
    func coalescesUpserts() async throws {
        let (queue, store) = makeQueue()
        let first = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["sets": .int(1)], baseVersion: 3))
        clock.advance(10)
        let second = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["sets": .int(2)], baseVersion: 4))

        #expect(await queue.snapshot().count == 1)
        #expect(second.id == first.id && second.sequence == first.sequence)
        #expect(second.baseVersion == 3)                          // base of the *first* edit is what the server must match
        #expect(second.payload == ["sets": .int(2)])
        #expect(second.editedAt > first.editedAt)
        #expect(await store.all() == [second])
    }

    @Test("Patches merge field-by-field; a patch folded into an upsert stays an upsert")
    func mergesPatches() async throws {
        let (queue, _) = makeQueue()
        try await queue.enqueue(path: P.logA, kind: .patch, payload: ["a": .int(1), "b": .int(1)], baseVersion: 1)
        let merged = try #require(try await queue.enqueue(path: P.logA, kind: .patch, payload: ["b": .int(2), "c": .int(3)], baseVersion: 1))
        #expect(merged.kind == .patch)
        #expect(merged.payload == ["a": .int(1), "b": .int(2), "c": .int(3)])

        try await queue.enqueue(path: P.logB, kind: .upsert, payload: ["a": .int(1)], baseVersion: 1)
        let folded = try #require(try await queue.enqueue(path: P.logB, kind: .patch, payload: ["b": .int(2)], baseVersion: 1))
        #expect(folded.kind == .upsert)
        #expect(folded.payload == ["a": .int(1), "b": .int(2)])

        let replaced = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["z": .int(9)], baseVersion: 1))
        #expect(replaced.kind == .upsert && replaced.payload == ["z": .int(9)])
    }

    @Test("Create-then-delete while offline cancels out: the server never hears about it")
    func createThenDeleteCancels() async throws {
        let (queue, store) = makeQueue()
        try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0)
        let result = try await queue.enqueue(path: P.logA, kind: .delete, baseVersion: 0)
        #expect(result == nil)
        #expect(await queue.snapshot().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("Updating then deleting an existing document becomes a single delete")
    func updateThenDelete() async throws {
        let (queue, _) = makeQueue()
        try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 4)
        let deletion = try #require(try await queue.enqueue(path: P.logA, kind: .delete, baseVersion: 4))
        #expect(deletion.kind == .delete && deletion.payload.isEmpty && deletion.baseVersion == 4)

        try await queue.enqueue(path: P.logB, kind: .patch, payload: ["v": .int(1)], baseVersion: 2)
        #expect(try await queue.enqueue(path: P.logB, kind: .delete, baseVersion: 2)?.kind == .delete)
    }

    @Test("Recreating a document queued for deletion turns it back into an upsert; later patches/deletes are no-ops")
    func deleteThenRecreate() async throws {
        let (queue, _) = makeQueue()
        try await queue.enqueue(path: P.logA, kind: .delete, baseVersion: 2)
        #expect(try await queue.enqueue(path: P.logA, kind: .patch, payload: ["x": .int(1)], baseVersion: 2)?.kind == .delete)
        #expect(try await queue.enqueue(path: P.logA, kind: .delete, baseVersion: 2)?.kind == .delete)
        #expect(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["x": .int(1)], baseVersion: 2)?.kind == .upsert)
        #expect(await queue.snapshot().count == 1)
    }

    @Test("A mutation that is already in flight is never modified; the new edit queues behind it")
    func doesNotCoalesceIntoInFlight() async throws {
        let (queue, _) = makeQueue()
        let first = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0))
        await queue.markInFlight(first.id)
        let second = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(2)], baseVersion: 0))

        #expect(second.id != first.id)
        #expect(await queue.snapshot().count == 2)
        #expect(await queue.nextEligible(at: clock.now()) == nil)    // second waits for first
        await queue.complete(first.id)
        #expect(await queue.nextEligible(at: clock.now())?.id == second.id)
    }

    @Test("Dead-lettered mutations are not merged into; a fresh edit gets a fresh mutation")
    func doesNotCoalesceIntoFailed() async throws {
        let (queue, _) = makeQueue()
        let first = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0))
        await queue.fail(first.id, error: "denied")
        let second = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(2)], baseVersion: 0))
        #expect(second.id != first.id)
        #expect(await queue.nextEligible(at: clock.now())?.id == second.id)    // failed ones don't block
    }

    @Test("Documents are ordered individually; a backed-off document does not stall the others")
    func perDocumentOrderingWithoutHeadOfLineBlocking() async throws {
        let (queue, _) = makeQueue()
        let a1 = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0))
        let b1 = try #require(try await queue.enqueue(path: P.logB, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0))
        await queue.markInFlight(a1.id)
        await queue.reschedule(a1.id, error: "503", at: clock.now().addingTimeInterval(60))

        #expect(await queue.nextEligible(at: clock.now())?.id == b1.id)
        await queue.complete(b1.id)
        #expect(await queue.nextEligible(at: clock.now()) == nil)
        #expect(await queue.earliestPendingAttempt(after: clock.now()) == clock.now().addingTimeInterval(60))
        #expect(await queue.nextEligible(at: clock.now().addingTimeInterval(61))?.id == a1.id)
        #expect(await queue.snapshot().first?.attempts == 1)
    }

    @Test("After a crash, in-flight mutations are pending again and sequencing continues")
    func crashRecovery() async throws {
        let survivor = Mutation(sequence: 7, path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 0,
                                createdAt: clock.now(), status: .inFlight)
        let (queue, _) = makeQueue(InMemoryMutationStore([survivor]))
        try await queue.prepare()
        #expect(await queue.snapshot().first?.status == .pending)
        #expect(await queue.counts() == MutationQueue.Counts(pending: 1, inFlight: 0, failed: 0))
        #expect(await queue.nextEligible(at: clock.now())?.id == survivor.id)

        let next = try #require(try await queue.enqueue(path: P.logB, kind: .upsert, payload: [:], baseVersion: 0))
        #expect(next.sequence == 8)
    }

    @Test("Edits made while a write was in flight adopt the new server revision")
    func adoptsServerVersion() async throws {
        let (queue, _) = makeQueue()
        let m = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: [:], baseVersion: 2))
        let other = try #require(try await queue.enqueue(path: P.logB, kind: .upsert, payload: [:], baseVersion: 2))
        await queue.adoptServerVersion(9, for: P.logA)
        let snapshot = await queue.snapshot()
        #expect(snapshot.first { $0.id == m.id }?.baseVersion == 9)
        #expect(snapshot.first { $0.id == other.id }?.baseVersion == 2)
    }

    @Test("Failed mutations can be re-armed or discarded; counts and per-document state are reported")
    func failureManagement() async throws {
        let (queue, store) = makeQueue()
        let a = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: [:], baseVersion: 0))
        try await queue.enqueue(path: P.logB, kind: .upsert, payload: [:], baseVersion: 0)
        await queue.fail(a.id, error: "denied")
        #expect(await queue.counts() == MutationQueue.Counts(pending: 1, inFlight: 0, failed: 1))
        #expect(await queue.hasUnsyncedMutations(for: P.logB))
        #expect(!(await queue.hasUnsyncedMutations(for: P.logA)))          // dead-lettered ≠ "will sync"

        await queue.retryFailed()
        #expect(await queue.counts() == MutationQueue.Counts(pending: 2, inFlight: 0, failed: 0))
        #expect(await queue.snapshot().first { $0.id == a.id }?.attempts == 0)

        await queue.fail(a.id, error: "denied")
        await queue.discardFailed()
        #expect(await queue.snapshot().count == 1)
        #expect(await store.all().count == 1)
        #expect(!(await queue.counts().isEmpty))
    }

    @Test("Rebase moves a mutation onto a new server revision and makes it due immediately")
    func rebase() async throws {
        let (queue, _) = makeQueue()
        let m = try #require(try await queue.enqueue(path: P.logA, kind: .upsert, payload: ["v": .int(1)], baseVersion: 1))
        await queue.reschedule(m.id, error: "x", at: clock.now().addingTimeInterval(600))
        await queue.rebase(m.id, baseVersion: 5, payload: ["v": .int(2)])
        let rebased = try #require(await queue.snapshot().first)
        #expect(rebased.baseVersion == 5 && rebased.payload == ["v": .int(2)])
        #expect(await queue.nextEligible(at: clock.now())?.id == m.id)
    }
}
