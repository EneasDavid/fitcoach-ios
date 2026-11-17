import Foundation
import SecurityKit
import SyncKit
import Domain

/// One locally stored document: queryable plaintext *columns* plus an opaque `payload`.
/// Only non-sensitive columns are plaintext; everything health-related lives inside `payload`,
/// which `SealedRecordStore` encrypts before it reaches disk.
public struct LocalRecord: Equatable, Sendable {
    public var collection: String
    public var id: String
    /// Partition key — the student the data belongs to.
    public var ownerID: String
    public var sortDate: Date
    public var syncState: SyncState
    /// `meta.version` of the stored payload (client revision counter).
    public var localVersion: Int
    /// Last server revision (`_rev`) known for this document; 0 = never reached the server.
    public var remoteVersion: Int
    public var payload: Data

    public init(collection: String, id: String, ownerID: String, sortDate: Date, syncState: SyncState,
                localVersion: Int, remoteVersion: Int, payload: Data) {
        self.collection = collection
        self.id = id
        self.ownerID = ownerID
        self.sortDate = sortDate
        self.syncState = syncState
        self.localVersion = localVersion
        self.remoteVersion = remoteVersion
        self.payload = payload
    }
}

/// Local persistence port. SwiftData implements it in the app target; `InMemoryRecordStore` implements it
/// for tests/previews. `RecordStoreContract` (in the test target) defines the behaviour every
/// implementation must satisfy, so the SwiftData store is verified by the very same assertions.
public protocol LocalRecordStore: Sendable {
    func upsert(_ record: LocalRecord) async throws
    func record(collection: String, id: String) async throws -> LocalRecord?
    /// Newest `sortDate` first.
    func records(collection: String, ownerID: String) async throws -> [LocalRecord]
    func remove(collection: String, id: String) async throws
    /// Atomic read-modify-write of a record's *metadata* (never touch `payload` in `change`).
    /// Returns `false` if the record doesn't exist.
    @discardableResult
    func update(collection: String, id: String, _ change: @Sendable (inout LocalRecord) -> Void) async throws -> Bool
    /// Emits once per change to the partition, so repositories can re-publish.
    func changes(collection: String, ownerID: String) -> AsyncStream<Void>
}

/// Fan-out helper shared by store implementations.
public final class ChangeBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

    public init() {}

    public func stream(collection: String, ownerID: String) -> AsyncStream<Void> {
        let key = Self.key(collection, ownerID)
        return AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[key, default: [:]][id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations[key]?.removeValue(forKey: id) }
            }
        }
    }

    public func notify(collection: String, ownerID: String) {
        let targets = lock.withLock { Array(continuations[Self.key(collection, ownerID)]?.values ?? [:].values) }
        targets.forEach { $0.yield() }
    }

    private static func key(_ collection: String, _ ownerID: String) -> String { "\(collection)|\(ownerID)" }
}

public actor InMemoryRecordStore: LocalRecordStore {
    private var storage: [String: LocalRecord] = [:]
    private nonisolated let broadcaster = ChangeBroadcaster()

    public init() {}

    private static func key(_ collection: String, _ id: String) -> String { "\(collection)/\(id)" }

    public func upsert(_ record: LocalRecord) async throws {
        storage[Self.key(record.collection, record.id)] = record
        broadcaster.notify(collection: record.collection, ownerID: record.ownerID)
    }

    public func record(collection: String, id: String) async throws -> LocalRecord? {
        storage[Self.key(collection, id)]
    }

    public func records(collection: String, ownerID: String) async throws -> [LocalRecord] {
        storage.values
            .filter { $0.collection == collection && $0.ownerID == ownerID }
            .sorted { $0.sortDate > $1.sortDate }
    }

    public func remove(collection: String, id: String) async throws {
        if let removed = storage.removeValue(forKey: Self.key(collection, id)) {
            broadcaster.notify(collection: removed.collection, ownerID: removed.ownerID)
        }
    }

    @discardableResult
    public func update(collection: String, id: String, _ change: @Sendable (inout LocalRecord) -> Void) async throws -> Bool {
        let key = Self.key(collection, id)
        guard var record = storage[key] else { return false }
        change(&record)
        storage[key] = record
        broadcaster.notify(collection: record.collection, ownerID: record.ownerID)
        return true
    }

    public nonisolated func changes(collection: String, ownerID: String) -> AsyncStream<Void> {
        broadcaster.stream(collection: collection, ownerID: ownerID)
    }
}

/// Encrypts `payload` at rest with AES-256-GCM (OWASP M9). Wraps *any* `LocalRecordStore`.
///
/// The record's `collection/id` is bound as authenticated data, so a ciphertext copied onto another
/// row fails to open. Columns used for queries (`ownerID`, `sortDate`, `syncState`, versions) stay
/// plaintext on purpose — they carry no health data — which keeps indexed queries possible.
public struct SealedRecordStore: LocalRecordStore {
    private let inner: any LocalRecordStore
    private let cipher: FieldCipher

    public init(inner: any LocalRecordStore, cipher: FieldCipher) {
        self.inner = inner
        self.cipher = cipher
    }

    private static func context(_ collection: String, _ id: String) -> String { "\(collection)/\(id)" }

    public func upsert(_ record: LocalRecord) async throws {
        var sealed = record
        sealed.payload = try cipher.seal(record.payload, context: Self.context(record.collection, record.id))
        try await inner.upsert(sealed)
    }

    public func record(collection: String, id: String) async throws -> LocalRecord? {
        try await inner.record(collection: collection, id: id).map(open)
    }

    public func records(collection: String, ownerID: String) async throws -> [LocalRecord] {
        try await inner.records(collection: collection, ownerID: ownerID).map(open)
    }

    public func remove(collection: String, id: String) async throws {
        try await inner.remove(collection: collection, id: id)
    }

    @discardableResult
    public func update(collection: String, id: String, _ change: @Sendable (inout LocalRecord) -> Void) async throws -> Bool {
        try await inner.update(collection: collection, id: id, change)   // metadata only; payload stays sealed
    }

    public func changes(collection: String, ownerID: String) -> AsyncStream<Void> {
        inner.changes(collection: collection, ownerID: ownerID)
    }

    private func open(_ record: LocalRecord) throws -> LocalRecord {
        var opened = record
        opened.payload = try cipher.open(record.payload, context: Self.context(record.collection, record.id))
        return opened
    }
}
