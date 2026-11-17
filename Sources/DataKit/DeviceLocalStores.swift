import Foundation
import Domain
import SyncKit

/// Data that lives **only on this device** — it never enters the sync queue and never reaches Firestore.
/// The record store underneath is the sealed (AES-256-GCM) one, so it is encrypted at rest, and sign-out shreds it.

/// Listening history. Raw plays stay local (data minimisation, OWASP M6): only the few tracks a *post* quotes are synced.
/// Old plays are pruned, so the app never accumulates a life-long listening log.
public struct TrackPlayRepositoryImpl: TrackPlayRepository {
    static let collection = "trackPlays"

    private let local: any LocalRecordStore
    private let owner: UserID
    private let retention: TimeInterval
    private let now: @Sendable () -> Date

    public init(local: any LocalRecordStore, owner: UserID, retention: TimeInterval = 90 * 86_400,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.local = local
        self.owner = owner
        self.retention = retention
        self.now = now
    }

    public func save(_ plays: [TrackPlay]) async throws {
        let cutoff = now().addingTimeInterval(-retention)
        for play in plays where play.startedAt >= cutoff {
            try await local.upsert(LocalRecord(collection: Self.collection, id: play.id, ownerID: owner.rawValue,
                                               sortDate: play.startedAt, syncState: .synced, localVersion: 0, remoteVersion: 0,
                                               payload: try SyncCoding.data(play)))
        }
        for record in try await local.records(collection: Self.collection, ownerID: owner.rawValue) where record.sortDate < cutoff {
            try await local.remove(collection: Self.collection, id: record.id)
        }
    }

    public func plays(studentID: UserID, from: Date, to: Date) async throws -> [TrackPlay] {
        guard studentID == owner else { return [] }
        return try await local.records(collection: Self.collection, ownerID: owner.rawValue)
            .filter { $0.sortDate >= from && $0.sortDate <= to }
            .compactMap { try? SyncCoding.decode(TrackPlay.self, from: $0.payload) }
            .sorted { $0.startedAt < $1.startedAt }
    }
}

/// Gym visits in progress. Coordinates + times are location history, so they get the same treatment as plays.
public struct PendingVisitStoreImpl: PendingVisitStoring {
    static let collection = "presence"
    static let id = "pending-visits"

    private let local: any LocalRecordStore
    private let owner: UserID

    public init(local: any LocalRecordStore, owner: UserID) {
        self.local = local
        self.owner = owner
    }

    public func load() async throws -> [PendingVisit] {
        guard let record = try await local.record(collection: Self.collection, id: Self.id), record.ownerID == owner.rawValue else { return [] }
        return (try? SyncCoding.decode([PendingVisit].self, from: record.payload)) ?? []
    }

    public func save(_ visits: [PendingVisit]) async throws {
        if visits.isEmpty {
            try await local.remove(collection: Self.collection, id: Self.id)
            return
        }
        try await local.upsert(LocalRecord(collection: Self.collection, id: Self.id, ownerID: owner.rawValue,
                                           sortDate: visits.map(\.enteredAt).max() ?? Date(), syncState: .synced,
                                           localVersion: 0, remoteVersion: 0, payload: try SyncCoding.data(visits)))
    }
}

/// The gym(s) the student chose to watch (at most `limit`). Where you train is personal data: local, sealed, shredded on sign-out.
public struct SelectedGymsStore: Sendable {
    static let collection = "presence"
    static let id = "selected-gyms"

    private let local: any LocalRecordStore
    private let owner: UserID
    public let limit: Int

    public init(local: any LocalRecordStore, owner: UserID, limit: Int = 3) {
        self.local = local
        self.owner = owner
        self.limit = limit
    }

    public func load() async -> [GymVenue] {
        guard let record = try? await local.record(collection: Self.collection, id: Self.id), record.ownerID == owner.rawValue else { return [] }
        return (try? SyncCoding.decode([GymVenue].self, from: record.payload)) ?? []
    }

    /// Adds a gym (deduplicated by id); the oldest selection is dropped once over the limit. Returns the new list.
    @discardableResult
    public func add(_ venue: GymVenue) async throws -> [GymVenue] {
        var venues = await load().filter { $0.id != venue.id }
        venues.append(venue)
        venues = Array(venues.suffix(limit))
        try await write(venues)
        return venues
    }

    public func clear() async throws { try await write([]) }

    private func write(_ venues: [GymVenue]) async throws {
        if venues.isEmpty { try await local.remove(collection: Self.collection, id: Self.id); return }
        try await local.upsert(LocalRecord(collection: Self.collection, id: Self.id, ownerID: owner.rawValue, sortDate: Date(), syncState: .synced,
                                           localVersion: 0, remoteVersion: 0, payload: try SyncCoding.data(venues)))
    }
}
