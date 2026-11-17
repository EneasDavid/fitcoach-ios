import Foundation
import Testing
import Domain
import SyncKit
@testable import DataKit

// This file is compiled into BOTH `DataKitTests` (in-memory + sealed stores) and the app's `FitCoachTests`
// (SwiftData store, see project.yml) — so every LocalRecordStore implementation is held to the same behaviour.

enum RecordStoreContract {
    static func record(_ id: String, owner: String = "o1", collection: String = "logs", sort: TimeInterval = 0,
                       state: SyncState = .synced, payload: String = "payload") -> LocalRecord {
        LocalRecord(collection: collection, id: id, ownerID: owner, sortDate: Date(timeIntervalSince1970: sort),
                    syncState: state, localVersion: 1, remoteVersion: 0, payload: Data(payload.utf8))
    }
}

/// Behavioural contract for any `LocalRecordStore`. Run against every implementation.
func verifyRecordStoreContract(_ store: any LocalRecordStore) async throws {
    typealias C = RecordStoreContract

    #expect(try await store.record(collection: "logs", id: "a") == nil)

    // upsert + get, replace in place
    try await store.upsert(C.record("a", sort: 10, payload: "one"))
    try await store.upsert(C.record("a", sort: 10, payload: "two"))
    #expect(try await store.record(collection: "logs", id: "a")?.payload == Data("two".utf8))

    // partitioning by collection and owner; newest first
    try await store.upsert(C.record("b", sort: 30))
    try await store.upsert(C.record("c", sort: 20))
    try await store.upsert(C.record("x", owner: "o2", sort: 99))
    try await store.upsert(C.record("y", collection: "plans", sort: 99))
    #expect(try await store.records(collection: "logs", ownerID: "o1").map(\.id) == ["b", "c", "a"])
    #expect(try await store.records(collection: "logs", ownerID: "o2").map(\.id) == ["x"])
    #expect(try await store.records(collection: "logs", ownerID: "nobody").isEmpty)

    // metadata update is atomic and leaves the payload alone
    let updated = try await store.update(collection: "logs", id: "a") { $0.syncState = .pendingUpsert; $0.remoteVersion = 7 }
    #expect(updated)
    let after = try #require(try await store.record(collection: "logs", id: "a"))
    #expect(after.syncState == .pendingUpsert && after.remoteVersion == 7 && after.payload == Data("two".utf8))
    #expect(try await store.update(collection: "logs", id: "ghost") { $0.remoteVersion = 1 } == false)

    // remove
    try await store.remove(collection: "logs", id: "a")
    #expect(try await store.record(collection: "logs", id: "a") == nil)
    try await store.remove(collection: "logs", id: "a")        // idempotent
}

func verifyRecordStoreChangeNotifications(_ store: any LocalRecordStore) async throws {
    var iterator = store.changes(collection: "logs", ownerID: "o1").makeAsyncIterator()
    try await store.upsert(RecordStoreContract.record("a"))
    #expect(await iterator.next() != nil)
    try await store.update(collection: "logs", id: "a") { $0.localVersion = 2 }
    #expect(await iterator.next() != nil)
    try await store.upsert(RecordStoreContract.record("other", owner: "o2"))          // other partition: silent
    try await store.remove(collection: "logs", id: "a")
    #expect(await iterator.next() != nil)
}
