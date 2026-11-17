import DataKit
import Domain
import Foundation
import SecurityKit
import SwiftData
import SyncKit

// NOT COMPILED IN THE AUTHORING ENVIRONMENT (`@Model` needs Xcode's SwiftData macro plugin).
// `SwiftDataRecordStoreTests` runs the shared `RecordStoreContract` against this store.
//
// Design: SwiftData is deliberately dumb storage. Every rule (coalescing, ordering, conflict policy,
// encryption) lives in verified, platform-neutral code, so swapping SwiftData for Core Data/SQLite never
// touches business logic. One generic `PersistedRecord` model serves every aggregate; each operation uses a
// fresh `ModelContext` inside the actor, which keeps contexts off the main thread and never shares one.

@Model
final class PersistedRecord {
    @Attribute(.unique) var key: String            // "collection/id"
    var collection: String
    var id: String
    var ownerID: String
    var sortDate: Date
    var syncStateRaw: String
    var localVersion: Int
    var remoteVersion: Int
    var payload: Data                               // already AES-GCM sealed by SealedRecordStore

    init(_ record: LocalRecord) {
        key = "\(record.collection)/\(record.id)"
        collection = record.collection
        id = record.id
        ownerID = record.ownerID
        sortDate = record.sortDate
        syncStateRaw = record.syncState.rawValue
        localVersion = record.localVersion
        remoteVersion = record.remoteVersion
        payload = record.payload
    }

    func overwrite(with record: LocalRecord) {
        ownerID = record.ownerID
        sortDate = record.sortDate
        syncStateRaw = record.syncState.rawValue
        localVersion = record.localVersion
        remoteVersion = record.remoteVersion
        payload = record.payload
    }

    var asRecord: LocalRecord {
        LocalRecord(collection: collection, id: id, ownerID: ownerID, sortDate: sortDate,
                    syncState: SyncState(rawValue: syncStateRaw) ?? .failed,
                    localVersion: localVersion, remoteVersion: remoteVersion, payload: payload)
    }
}

@Model
final class PersistedMutation {
    @Attribute(.unique) var id: UUID
    var sequence: Int64
    var collectionPath: String
    var documentID: String
    var kindRaw: String
    var sealedPayload: Data                         // JSON of [String: JSONValue], AES-GCM sealed
    var baseVersion: Int?
    var createdAt: Date
    var editedAt: Date
    var attempts: Int
    var nextAttemptAt: Date
    var statusRaw: String
    var lastError: String?

    init(id: UUID, sequence: Int64, collectionPath: String, documentID: String, kindRaw: String, sealedPayload: Data,
         baseVersion: Int?, createdAt: Date, editedAt: Date, attempts: Int, nextAttemptAt: Date, statusRaw: String, lastError: String?) {
        self.id = id
        self.sequence = sequence
        self.collectionPath = collectionPath
        self.documentID = documentID
        self.kindRaw = kindRaw
        self.sealedPayload = sealedPayload
        self.baseVersion = baseVersion
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.statusRaw = statusRaw
        self.lastError = lastError
    }
}

enum PersistenceContainerFactory {
    /// - Parameter inMemory: unit tests, previews and UI tests.
    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([PersistedRecord.self, PersistedMutation.self])
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let storeURL = support.appendingPathComponent("FitCoach.store")
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none))
        harden(storeURL)
        return container
    }

    /// OWASP M9: file-level protection class + excluded from iCloud/iTunes backups. (Field-level encryption
    /// already protects the contents; this protects the file metadata and the queue timing information.)
    private static func harden(_ storeURL: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            // Readable after first unlock so background sync can run while the phone is locked.
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = storeURL
        try? mutableURL.setResourceValues(values)
    }
}

actor SwiftDataRecordStore: LocalRecordStore {
    private let container: ModelContainer
    private nonisolated let broadcaster = ChangeBroadcaster()

    init(container: ModelContainer) {
        self.container = container
    }

    private func fetch(_ context: ModelContext, collection: String, id: String) throws -> PersistedRecord? {
        let key = "\(collection)/\(id)"
        var descriptor = FetchDescriptor<PersistedRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func upsert(_ record: LocalRecord) async throws {
        let context = ModelContext(container)
        if let existing = try fetch(context, collection: record.collection, id: record.id) {
            existing.overwrite(with: record)
        } else {
            context.insert(PersistedRecord(record))
        }
        try context.save()
        broadcaster.notify(collection: record.collection, ownerID: record.ownerID)
    }

    func record(collection: String, id: String) async throws -> LocalRecord? {
        try fetch(ModelContext(container), collection: collection, id: id)?.asRecord
    }

    func records(collection: String, ownerID: String) async throws -> [LocalRecord] {
        let descriptor = FetchDescriptor<PersistedRecord>(
            predicate: #Predicate { $0.collection == collection && $0.ownerID == ownerID },
            sortBy: [SortDescriptor(\.sortDate, order: .reverse)])
        return try ModelContext(container).fetch(descriptor).map(\.asRecord)
    }

    func remove(collection: String, id: String) async throws {
        let context = ModelContext(container)
        guard let existing = try fetch(context, collection: collection, id: id) else { return }
        let owner = existing.ownerID
        context.delete(existing)
        try context.save()
        broadcaster.notify(collection: collection, ownerID: owner)
    }

    @discardableResult
    func update(collection: String, id: String, _ change: @Sendable (inout LocalRecord) -> Void) async throws -> Bool {
        let context = ModelContext(container)
        guard let existing = try fetch(context, collection: collection, id: id) else { return false }
        var record = existing.asRecord
        change(&record)
        existing.overwrite(with: record)
        try context.save()
        broadcaster.notify(collection: collection, ownerID: record.ownerID)
        return true
    }

    nonisolated func changes(collection: String, ownerID: String) -> AsyncStream<Void> {
        broadcaster.stream(collection: collection, ownerID: ownerID)
    }
}

/// Persists the offline mutation queue. Payloads are sealed (they contain workout and body-composition data).
actor SwiftDataMutationStore: MutationStore {
    private let container: ModelContainer
    private let cipher: FieldCipher

    init(container: ModelContainer, cipher: FieldCipher) {
        self.container = container
        self.cipher = cipher
    }

    func loadAll() async throws -> [Mutation] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedMutation>(sortBy: [SortDescriptor(\.sequence)]))
        return try rows.compactMap { row -> Mutation? in
            guard let kind = MutationKind(rawValue: row.kindRaw), let status = MutationStatus(rawValue: row.statusRaw) else { return nil }
            let plaintext = try cipher.open(row.sealedPayload, context: "mutation/\(row.id)")
            return Mutation(id: row.id, sequence: row.sequence,
                            path: DocumentPath(collection: row.collectionPath, documentID: row.documentID),
                            kind: kind, payload: try JSONDecoder().decode([String: JSONValue].self, from: plaintext),
                            baseVersion: row.baseVersion, createdAt: row.createdAt, editedAt: row.editedAt,
                            attempts: row.attempts, nextAttemptAt: row.nextAttemptAt, status: status, lastError: row.lastError)
        }
    }

    func save(_ mutation: Mutation) async throws {
        let context = ModelContext(container)
        let sealed = try cipher.seal(try JSONEncoder().encode(mutation.payload), context: "mutation/\(mutation.id)")
        let id = mutation.id
        var descriptor = FetchDescriptor<PersistedMutation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let row = try context.fetch(descriptor).first ?? {
            let created = PersistedMutation(id: mutation.id, sequence: mutation.sequence, collectionPath: mutation.path.collection,
                                            documentID: mutation.path.documentID, kindRaw: mutation.kind.rawValue, sealedPayload: sealed,
                                            baseVersion: mutation.baseVersion, createdAt: mutation.createdAt, editedAt: mutation.editedAt,
                                            attempts: mutation.attempts, nextAttemptAt: mutation.nextAttemptAt,
                                            statusRaw: mutation.status.rawValue, lastError: mutation.lastError)
            context.insert(created)
            return created
        }()
        row.kindRaw = mutation.kind.rawValue
        row.sealedPayload = sealed
        row.baseVersion = mutation.baseVersion
        row.editedAt = mutation.editedAt
        row.attempts = mutation.attempts
        row.nextAttemptAt = mutation.nextAttemptAt
        row.statusRaw = mutation.status.rawValue
        row.lastError = mutation.lastError
        try context.save()
    }

    func remove(ids: [UUID]) async throws {
        let context = ModelContext(container)
        for id in ids {
            let descriptor = FetchDescriptor<PersistedMutation>(predicate: #Predicate { $0.id == id })
            for row in try context.fetch(descriptor) { context.delete(row) }
        }
        try context.save()
    }
}
