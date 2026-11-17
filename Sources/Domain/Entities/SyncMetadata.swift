import Foundation

/// Local-only sync flag. Persisted in a dedicated column of the local store and **never**
/// serialised into the Firestore document (see `SyncMetadata.CodingKeys`).
public enum SyncState: String, Codable, Sendable, Equatable {
    /// Local copy equals the last server copy we saw.
    case synced
    /// Created/edited locally; a mutation is queued.
    case pendingUpsert
    /// Tombstoned locally; the tombstone upsert is queued.
    case pendingDelete
    /// A conflict could not be auto-resolved; needs attention.
    case conflict
    /// The server permanently rejected the mutation (dead-lettered).
    case failed
}

/// Per-document sync bookkeeping, embedded as `meta` in every syncable Firestore document.
public struct SyncMetadata: Codable, Equatable, Sendable {
    /// Local-only; defaults to `.synced` when decoding a server document.
    public var state: SyncState
    /// Monotonic revision. The repository bumps it on every write; the server accepts a write only
    /// if the document's current version equals the mutation's `baseVersion` (optimistic concurrency).
    public var version: Int
    /// Client wall-clock time of the last edit (display + last-write-wins tie-breaking).
    public var updatedAt: Date
    public var lastWriterDeviceID: String
    /// Soft-delete tombstone. Firestore rules forbid hard deletes so every device/trainer sees removals.
    public var deletedAt: Date?

    private enum CodingKeys: String, CodingKey { case version, updatedAt, lastWriterDeviceID, deletedAt }

    public init(version: Int = 0,
                updatedAt: Date,
                lastWriterDeviceID: String,
                deletedAt: Date? = nil,
                state: SyncState = .pendingUpsert) {
        self.version = version
        self.updatedAt = updatedAt
        self.lastWriterDeviceID = lastWriterDeviceID
        self.deletedAt = deletedAt
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastWriterDeviceID = try c.decode(String.self, forKey: .lastWriterDeviceID)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        state = .synced
    }

    public var isDeleted: Bool { deletedAt != nil }

    public mutating func touch(deviceID: String, at now: Date) {
        version += 1
        updatedAt = now
        lastWriterDeviceID = deviceID
        state = .pendingUpsert
    }

    public mutating func tombstone(deviceID: String, at now: Date) {
        touch(deviceID: deviceID, at: now)
        deletedAt = now
        state = .pendingDelete
    }
}

/// An aggregate root that is stored locally and mirrored to Firestore.
public protocol Syncable: Codable, Identifiable, Sendable where ID: CustomStringConvertible & Sendable {
    var meta: SyncMetadata { get set }
}

public enum DomainError: Error, Equatable, Sendable {
    case validation(String)
    case notFound(String)
    case invalidState(String)
}
