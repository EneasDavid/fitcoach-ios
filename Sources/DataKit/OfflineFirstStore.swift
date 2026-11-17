import Foundation
import Domain
import SyncKit

/// Where an entity lives, locally and remotely.
public struct EntityDescriptor<E: Syncable>: Sendable {
    /// Leaf collection name; also the local-store collection and the conflict-policy key.
    public let collection: String
    public let path: @Sendable (E) -> DocumentPath
    public let ownerID: @Sendable (E) -> String
    public let sortDate: @Sendable (E) -> Date

    public init(collection: String,
                path: @escaping @Sendable (E) -> DocumentPath,
                ownerID: @escaping @Sendable (E) -> String,
                sortDate: @escaping @Sendable (E) -> Date) {
        self.collection = collection
        self.path = path
        self.ownerID = ownerID
        self.sortDate = sortDate
    }
}

public protocol SyncTriggering: Sendable {
    func requestSync() async
}

extension SyncDispatcher: SyncTriggering {
    public func requestSync() async { kick() }
}

/// Breaks the construction cycle  stores → dispatcher → observer → stores  in the composition root:
/// hand the stores this trigger first, point it at the dispatcher once that exists.
public final class DeferredSyncTrigger: SyncTriggering, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any SyncTriggering)?

    public init() {}

    public func bind(_ target: any SyncTriggering) { lock.withLock { self.target = target } }

    public func requestSync() async {
        let target = lock.withLock { self.target }
        await target?.requestSync()
    }
}

/// Type-erased inbound entry point, so one Firestore listener / refetch path can feed every collection.
public protocol RemoteDocumentApplying: Sendable {
    @discardableResult
    func applyRemote(_ document: RemoteDocument, overwritePending: Bool) async throws -> ApplyRemoteResult
}

public enum ApplyRemoteResult: Equatable, Sendable {
    case applied
    /// A local edit is queued; the server copy is not allowed to clobber it (the dispatcher reconciles).
    case keptLocalPending
    /// Duplicate or out-of-order snapshot.
    case stale
}

/// Generic offline-first aggregate store — the write path every repository shares:
///
///     save ─► (1) encrypted local write, state = pending ─► (2) durable mutation enqueue ─► (3) kick sync
///
/// The UI reads only from the local store, so it never waits on the network; the dispatcher reconciles
/// in the background. If step 2 fails, step 1 is rolled back so the UI never shows an edit that can't sync.
public final class OfflineFirstStore<E: Syncable>: RemoteDocumentApplying, Sendable {
    private let descriptor: EntityDescriptor<E>
    private let store: any LocalRecordStore
    private let queue: MutationQueue
    private let trigger: any SyncTriggering
    private let deviceID: String
    private let now: @Sendable () -> Date

    public init(descriptor: EntityDescriptor<E>,
                store: any LocalRecordStore,
                queue: MutationQueue,
                trigger: any SyncTriggering,
                deviceID: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.descriptor = descriptor
        self.store = store
        self.queue = queue
        self.trigger = trigger
        self.deviceID = deviceID
        self.now = now
    }

    // MARK: Writes

    /// Persists the entity locally and queues it for sync. Owns `meta`: the version continues from the
    /// *stored* record, never from the caller's copy, so stale copies can't make versions go backwards.
    @discardableResult
    public func save(_ entity: E) async throws -> E {
        let path = descriptor.path(entity)
        let existing = try await store.record(collection: descriptor.collection, id: path.documentID)

        var saved = entity
        saved.meta.version = existing?.localVersion ?? entity.meta.version
        saved.meta.touch(deviceID: deviceID, at: now())
        if saved.meta.isDeleted { saved.meta.state = .pendingDelete }

        let record = LocalRecord(collection: descriptor.collection,
                                 id: path.documentID,
                                 ownerID: descriptor.ownerID(saved),
                                 sortDate: descriptor.sortDate(saved),
                                 syncState: saved.meta.state,
                                 localVersion: saved.meta.version,
                                 remoteVersion: existing?.remoteVersion ?? 0,
                                 payload: try SyncCoding.data(saved))
        try await store.upsert(record)

        do {
            try await queue.enqueue(path: path, kind: .upsert,
                                    payload: try SyncCoding.fields(saved),
                                    baseVersion: record.remoteVersion)
        } catch {
            if let existing { try? await store.upsert(existing) }
            else { try? await store.remove(collection: descriptor.collection, id: path.documentID) }
            throw error
        }
        await trigger.requestSync()
        return saved
    }

    /// Soft delete: writes a tombstone so every device (and the trainer) sees the removal.
    @discardableResult
    public func delete(_ entity: E) async throws -> E {
        var tombstoned = entity
        tombstoned.meta.deletedAt = now()
        return try await save(tombstoned)
    }

    // MARK: Reads

    public func get(id: String) async throws -> E? {
        try await store.record(collection: descriptor.collection, id: id).map(decode)
    }

    public func list(ownerID: String, includeDeleted: Bool = false) async throws -> [E] {
        try await store.records(collection: descriptor.collection, ownerID: ownerID)
            .map(decode)
            .filter { includeDeleted || !$0.meta.isDeleted }
    }

    /// Emits the current list immediately, then again after every change.
    public func observe(ownerID: String) -> AsyncStream<[E]> {
        let changes = store.changes(collection: descriptor.collection, ownerID: ownerID)
        return AsyncStream { continuation in
            let task = Task { [self] in
                continuation.yield((try? await list(ownerID: ownerID)) ?? [])
                for await _ in changes {
                    continuation.yield((try? await list(ownerID: ownerID)) ?? [])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Inbound

    /// Applies a server document (Firestore snapshot listener, or a refetch after a lost conflict).
    @discardableResult
    public func applyRemote(_ document: RemoteDocument, overwritePending: Bool = false) async throws -> ApplyRemoteResult {
        let entity = try SyncCoding.decode(E.self, from: document.fields)
        let path = descriptor.path(entity)

        if let existing = try await store.record(collection: descriptor.collection, id: path.documentID) {
            let hasLocalEdits = existing.syncState != .synced
            if hasLocalEdits && !overwritePending { return .keptLocalPending }
            if !hasLocalEdits && document.version <= existing.remoteVersion { return .stale }
        }

        var applied = entity
        applied.meta.state = .synced
        try await store.upsert(LocalRecord(collection: descriptor.collection,
                                           id: path.documentID,
                                           ownerID: descriptor.ownerID(applied),
                                           sortDate: descriptor.sortDate(applied),
                                           syncState: .synced,
                                           localVersion: applied.meta.version,
                                           remoteVersion: document.version,
                                           payload: try SyncCoding.data(applied)))
        return .applied
    }

    private func decode(_ record: LocalRecord) throws -> E {
        var entity = try SyncCoding.decode(E.self, from: record.payload)
        entity.meta.state = record.syncState
        return entity
    }
}

/// Reconciles local rows with what the dispatcher learns (OWASP-neutral, but it is what makes the
/// "pending / synced / failed" badges truthful). Also pulls the server copy back down when the local
/// edit lost a conflict.
public struct LocalSyncStateUpdater: SyncObserver {
    private let store: any LocalRecordStore
    private let queue: MutationQueue
    private let appliers: [String: any RemoteDocumentApplying]
    private let gateway: (any RemoteGateway)?

    /// - Parameter appliers: keyed by leaf collection name (`workoutLogs`, `plans`, …).
    public init(store: any LocalRecordStore,
                queue: MutationQueue,
                appliers: [String: any RemoteDocumentApplying] = [:],
                gateway: (any RemoteGateway)? = nil) {
        self.store = store
        self.queue = queue
        self.appliers = appliers
        self.gateway = gateway
    }

    public func mutationApplied(_ mutation: Mutation, result: RemoteApplyResult) async {
        let stillQueued = await queue.hasUnsyncedMutations(for: mutation.path)
        _ = try? await store.update(collection: mutation.path.leafCollection, id: mutation.path.documentID) { record in
            record.remoteVersion = max(record.remoteVersion, result.version)
            if !stillQueued { record.syncState = .synced }
        }
    }

    public func mutationDropped(_ mutation: Mutation, reason: DropReason) async {
        let collection = mutation.path.leafCollection
        guard reason == .remoteWonConflict,
              let gateway, let applier = appliers[collection],
              let remote = try? await gateway.fetch(mutation.path) else {
            _ = try? await store.update(collection: collection, id: mutation.path.documentID) { $0.syncState = .conflict }
            return
        }
        _ = try? await applier.applyRemote(remote, overwritePending: true)
    }

    public func mutationFailed(_ mutation: Mutation, error: RemoteError) async {
        _ = try? await store.update(collection: mutation.path.leafCollection, id: mutation.path.documentID) { $0.syncState = .failed }
    }
}
