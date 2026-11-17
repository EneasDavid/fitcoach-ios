import FirebaseFirestore
import Foundation
import SecurityKit
import SwiftData
import SyncKit
import Testing
@testable import DataKit
@testable import FitCoach

// NOT RUN IN THE AUTHORING ENVIRONMENT (needs Xcode + iOS simulator). These are the tests that prove the
// three files the Swift Package can't contain — SwiftData stores, the Firestore gateway mapping — behave
// exactly like their verified in-memory counterparts.
//
// `RecordStoreContract.swift` is compiled into this target from Tests/DataKitTests (see project.yml).

@Suite("SwiftData stores")
struct SwiftDataStoreTests {
    func container() throws -> ModelContainer { try PersistenceContainerFactory.make(inMemory: true) }

    @Test("SwiftDataRecordStore satisfies the shared LocalRecordStore contract")
    func recordStoreContract() async throws {
        try await verifyRecordStoreContract(SwiftDataRecordStore(container: container()))
        try await verifyRecordStoreChangeNotifications(SwiftDataRecordStore(container: container()))
    }

    @Test("…and so does the encrypted decorator on top of it")
    func sealedContract() async throws {
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "records")
        try await verifyRecordStoreContract(SealedRecordStore(inner: SwiftDataRecordStore(container: container()), cipher: cipher))
    }

    @Test("The mutation queue survives an app restart: a new queue over the same store sees the same work")
    func queueSurvivesRestart() async throws {
        let container = try container()
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "mutation-queue")
        let path = DocumentPath(collection: "students/s1/workoutLogs", documentID: "l1")

        let first = MutationQueue(store: SwiftDataMutationStore(container: container, cipher: cipher))
        try await first.enqueue(path: path, kind: .upsert, payload: ["sets": .int(1), "at": .date(Date(timeIntervalSince1970: 100))], baseVersion: 0)
        try await first.enqueue(path: path, kind: .upsert, payload: ["sets": .int(2), "at": .date(Date(timeIntervalSince1970: 100))], baseVersion: 0)

        let relaunched = MutationQueue(store: SwiftDataMutationStore(container: container, cipher: cipher))
        try await relaunched.prepare()
        let restored = await relaunched.snapshot()
        #expect(restored.count == 1)                                   // coalesced before it was ever persisted twice
        #expect(restored.first?.payload["sets"] == .int(2))
        #expect(restored.first?.payload["at"] == .date(Date(timeIntervalSince1970: 100)))
    }

    @Test("Queued payloads are encrypted in the database")
    func queuePayloadsAreSealed() async throws {
        let container = try container()
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "mutation-queue")
        let queue = MutationQueue(store: SwiftDataMutationStore(container: container, cipher: cipher))
        try await queue.enqueue(path: DocumentPath(collection: "students/s1/bodyCheckpoints", documentID: "b1"), kind: .upsert,
                                payload: ["bodyFatPercent": .double(18.5)], baseVersion: 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedMutation>())
        #expect(rows.count == 1)
        #expect(!String(decoding: rows[0].sealedPayload, as: UTF8.self).contains("bodyFatPercent"))
    }
}

@Suite("Firestore gateway mapping")
struct FirestoreMappingTests {
    @Test("JSONValue ⇄ Firestore values: dates become Timestamps and back, numbers keep their type")
    func valueConversion() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let encoded = FirestoreValues.encode(["when": .date(date), "n": .int(3), "x": .double(2.5), "b": .bool(true), "s": .string("a"),
                                              "list": .array([.int(1)]), "nested": .object(["k": .null])])
        #expect((encoded["when"] as? Timestamp)?.dateValue() == date)
        #expect(encoded["n"] as? Int == 3 && encoded["x"] as? Double == 2.5 && encoded["b"] as? Bool == true)

        var serverData = encoded
        serverData["_rev"] = 7                                          // server bookkeeping never reaches the domain
        let decoded = FirestoreValues.decode(serverData)
        #expect(decoded["_rev"] == nil)
        #expect(decoded["when"] == .date(date) && decoded["n"] == .int(3) && decoded["x"] == .double(2.5) && decoded["b"] == .bool(true))
        #expect(decoded["nested"] == .object(["k": .null]))
    }

    @Test("Firestore error codes map onto the dispatcher's failure taxonomy")
    func errorMapping() {
        func error(_ code: FirestoreErrorCode.Code) -> RemoteError {
            FirestoreRemoteGateway.map(NSError(domain: FirestoreErrorDomain, code: code.rawValue))
        }
        #expect(error(.unavailable) == .offline)
        #expect(error(.unauthenticated) == .unauthenticated)
        #expect(error(.permissionDenied) == .permissionDenied)
        #expect(error(.deadlineExceeded) == .transient(retryAfter: nil))
        #expect(error(.resourceExhausted) == .transient(retryAfter: 30))
        #expect(error(.notFound) == .notFound)
        if case .invalid = error(.invalidArgument) {} else { Issue.record("invalidArgument should be permanent") }

        let conflict = NSError(domain: "FitCoach.Sync", code: 1, userInfo: ["serverVersion": 4])
        #expect(FirestoreRemoteGateway.map(conflict) == .conflict(serverVersion: 4))
        #expect(FirestoreRemoteGateway.map(URLError(.notConnectedToInternet)) == .transient(retryAfter: nil))
    }
}
