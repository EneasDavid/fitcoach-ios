import Foundation
import Domain
import SyncKit

/// The third-party exercise database, reached **through our own Cloud Function proxy** — the vendor
/// API key stays server-side (OWASP M1) and requests can be pinned, rate-limited and cached centrally.
public protocol RemoteExerciseAPI: Sendable {
    /// One exercise by our id (hydrated), or nil when the catalogue doesn't know it.
    func exercise(id: ExerciseID) async throws -> Exercise?
    /// Hydrated entries: machine imagery, demonstration video, instructions.
    func search(query: String, limit: Int) async throws -> [Exercise]
    /// Vendor-ranked alternatives (same stimulus, different equipment…).
    func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution]
}

/// Remote-first catalogue with an offline cache: every successful search is stored locally, so
/// the exercise picker, images' metadata and substitution suggestions keep working in a gym basement
/// with no signal. Falls back to the on-device `SubstitutionRecommender` when the API can't help.
public final class CachedExerciseCatalogRepository: ExerciseCatalogRepository, Sendable {
    private static let collection = "exerciseCache"
    private static let owner = "catalog"

    private let remote: any RemoteExerciseAPI
    private let store: any LocalRecordStore
    private let recommender: SubstitutionRecommender

    public init(remote: any RemoteExerciseAPI,
                store: any LocalRecordStore,
                recommender: SubstitutionRecommender = SubstitutionRecommender()) {
        self.remote = remote
        self.store = store
        self.recommender = recommender
    }

    public func search(query: String, limit: Int) async throws -> [Exercise] {
        if let fresh = try? await remote.search(query: query, limit: limit) {
            for exercise in fresh { try? await cache(exercise) }
            return Array(fresh.prefix(limit))
        }
        return Array(try await cachedMatches(query).prefix(limit))
    }

    /// Cache first (works offline); otherwise fetch from the catalogue and remember it.
    public func exercise(id: ExerciseID) async throws -> Exercise? {
        if let cached = try await store.record(collection: Self.collection, id: id.rawValue) {
            return try SyncCoding.decode(Exercise.self, from: cached.payload)
        }
        guard let fetched = try? await remote.exercise(id: id) else { return nil }
        try? await cache(fetched)
        return fetched
    }

    public func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution] {
        if let suggested = try? await remote.substitutions(for: exercise, reason: reason, limit: limit), !suggested.isEmpty {
            for suggestion in suggested { try? await cache(suggestion.candidate) }
            return Array(suggested.prefix(limit))
        }
        return recommender.rank(original: exercise, candidates: try await allCached(), reason: reason, limit: limit)
    }

    // MARK: Cache

    private func cache(_ exercise: Exercise) async throws {
        try await store.upsert(LocalRecord(collection: Self.collection, id: exercise.id.rawValue, ownerID: Self.owner,
                                           sortDate: .distantPast, syncState: .synced, localVersion: 0, remoteVersion: 0,
                                           payload: try SyncCoding.data(exercise)))
    }

    private func allCached() async throws -> [Exercise] {
        try await store.records(collection: Self.collection, ownerID: Self.owner)
            .compactMap { try? SyncCoding.decode(Exercise.self, from: $0.payload) }
    }

    /// Case- and diacritic-insensitive ("agachamento" finds "Agachamento Búlgaro"); prefix matches first.
    private func cachedMatches(_ query: String) async throws -> [Exercise] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return try await allCached().sorted { $0.name < $1.name } }
        return try await allCached()
            .filter { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle) }
            .sorted { lhs, rhs in
                let lp = lhs.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(needle)
                let rp = rhs.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(needle)
                return lp != rp ? lp : lhs.name < rhs.name
            }
    }
}
