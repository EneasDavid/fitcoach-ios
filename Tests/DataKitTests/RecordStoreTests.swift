import Foundation
import Testing
import Domain
import SecurityKit
import SyncKit
@testable import DataKit

@Suite("LocalRecordStore")
struct RecordStoreTests {
    let secrets = InMemorySecureStore()
    var cipher: FieldCipher { FieldCipher(keys: KeychainKeyProvider(store: secrets), purpose: "records") }

    @Test("In-memory store satisfies the contract")
    func inMemory() async throws {
        try await verifyRecordStoreContract(InMemoryRecordStore())
        try await verifyRecordStoreChangeNotifications(InMemoryRecordStore())
    }

    @Test("Sealed store satisfies the same contract — encryption is invisible to callers")
    func sealed() async throws {
        try await verifyRecordStoreContract(SealedRecordStore(inner: InMemoryRecordStore(), cipher: cipher))
        try await verifyRecordStoreChangeNotifications(SealedRecordStore(inner: InMemoryRecordStore(), cipher: cipher))
    }

    @Test("Payloads are ciphertext on disk, while query columns stay plaintext")
    func encryptedAtRest() async throws {
        let backing = InMemoryRecordStore()
        let sealed = SealedRecordStore(inner: backing, cipher: cipher)
        let secret = #"{"bodyFatPercent":18.5,"studentName":"Maria"}"#
        try await sealed.upsert(RecordStoreContract.record("a", payload: secret))

        let onDisk = try #require(try await backing.record(collection: "logs", id: "a"))
        #expect(onDisk.payload != Data(secret.utf8))
        #expect(!String(decoding: onDisk.payload, as: UTF8.self).contains("Maria"))
        #expect(onDisk.ownerID == "o1" && onDisk.syncState == .synced)
        #expect(try await sealed.record(collection: "logs", id: "a")?.payload == Data(secret.utf8))
    }

    @Test("A ciphertext copied onto another row cannot be opened")
    func rowSwapDetected() async throws {
        let backing = InMemoryRecordStore()
        let sealed = SealedRecordStore(inner: backing, cipher: cipher)
        try await sealed.upsert(RecordStoreContract.record("a", payload: "secret-a"))
        try await sealed.upsert(RecordStoreContract.record("b", payload: "secret-b"))

        var stolen = try #require(try await backing.record(collection: "logs", id: "a"))
        stolen.id = "b"                                                     // attacker pastes row A's blob into row B
        try await backing.upsert(stolen)
        await #expect(throws: CipherError.authenticationFailed) { try await sealed.record(collection: "logs", id: "b") }
    }

    @Test("After the key is destroyed (logout), stored records are unreadable")
    func cryptoShredding() async throws {
        let provider = KeychainKeyProvider(store: secrets)
        let sealed = SealedRecordStore(inner: InMemoryRecordStore(), cipher: FieldCipher(keys: provider, purpose: "records"))
        try await sealed.upsert(RecordStoreContract.record("a"))
        try provider.destroyKeys()
        await #expect(throws: CipherError.authenticationFailed) { try await sealed.record(collection: "logs", id: "a") }
    }
}
