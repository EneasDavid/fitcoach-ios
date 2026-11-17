import Foundation

/// Location of a Firestore document. `collection` is the full path of the parent collection,
/// e.g. `students/u1/workoutLogs`.
public struct DocumentPath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let collection: String
    public let documentID: String

    public init(collection: String, documentID: String) {
        self.collection = collection
        self.documentID = documentID
    }

    public var description: String { "\(collection)/\(documentID)" }

    /// Last collection segment (`workoutLogs`). Used as the key for conflict policies and local storage.
    public var leafCollection: String {
        collection.split(separator: "/").last.map(String.init) ?? collection
    }
}

public enum MutationKind: String, Codable, Sendable {
    /// Create or replace the document with `payload` — the *complete* entity, so fields the client cleared
    /// disappear on the server too (the gateway re-stamps its own `_`-prefixed bookkeeping fields).
    case upsert
    /// Update only the fields in `payload`.
    case patch
    /// Hard delete. Domain entities normally use tombstone upserts instead.
    case delete
}

public enum MutationStatus: String, Codable, Sendable {
    case pending
    case inFlight
    /// Dead-lettered: will not be retried automatically. Surfaced to the UI; `retryFailed()` re-arms it.
    case failed
}

/// One locally-made write that still has to reach the server.
///
/// `id` doubles as the **idempotency key**: the gateway stamps it on the document, so if the
/// app dies between "server applied it" and "we recorded that", the replay is recognised and not
/// applied twice (at-least-once delivery, exactly-once effect).
public struct Mutation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// Total order of enqueueing; assigned by the queue.
    public var sequence: Int64
    public let path: DocumentPath
    public var kind: MutationKind
    public var payload: [String: JSONValue]
    /// Server revision (`_rev`) this edit was based on; `0` = the document does not exist yet;
    /// `nil` = unconditional write.
    public var baseVersion: Int?
    public let createdAt: Date
    /// Client time of the latest edit folded into this mutation (last-write-wins tie-break).
    public var editedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var status: MutationStatus
    public var lastError: String?

    public init(id: UUID = UUID(),
                sequence: Int64 = 0,
                path: DocumentPath,
                kind: MutationKind,
                payload: [String: JSONValue] = [:],
                baseVersion: Int? = nil,
                createdAt: Date,
                editedAt: Date? = nil,
                attempts: Int = 0,
                nextAttemptAt: Date? = nil,
                status: MutationStatus = .pending,
                lastError: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.path = path
        self.kind = kind
        self.payload = payload
        self.baseVersion = baseVersion
        self.createdAt = createdAt
        self.editedAt = editedAt ?? createdAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.status = status
        self.lastError = lastError
    }
}

/// Durable storage for the queue (SwiftData in the app, in-memory in tests). Deliberately tiny:
/// all queue *logic* lives in `MutationQueue` so it is identical — and testable — on every store.
public protocol MutationStore: Sendable {
    func loadAll() async throws -> [Mutation]
    /// Insert or replace by `id`.
    func save(_ mutation: Mutation) async throws
    func remove(ids: [UUID]) async throws
}

public actor InMemoryMutationStore: MutationStore {
    private var storage: [UUID: Mutation] = [:]

    public init(_ initial: [Mutation] = []) {
        for mutation in initial { storage[mutation.id] = mutation }
    }

    public func loadAll() async throws -> [Mutation] { storage.values.sorted { $0.sequence < $1.sequence } }
    public func save(_ mutation: Mutation) async throws { storage[mutation.id] = mutation }
    public func remove(ids: [UUID]) async throws { ids.forEach { storage[$0] = nil } }
    public func all() -> [Mutation] { storage.values.sorted { $0.sequence < $1.sequence } }
}
