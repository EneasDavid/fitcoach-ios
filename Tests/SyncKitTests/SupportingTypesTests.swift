import Foundation
import Testing
@testable import SyncKit

@Suite("Backoff")
struct BackoffTests {
    @Test("Delays double, then cap at maxDelay")
    func growth() {
        let policy = BackoffPolicy(baseDelay: 2, multiplier: 2, maxDelay: 30, jitter: 0)
        #expect([1, 2, 3, 4, 5, 6].map { policy.delay(forAttempt: $0, random: 0.5) } == [2, 4, 8, 16, 30, 30])
    }

    @Test("Jitter spreads retries by ±20 % and attempt numbers below 1 are clamped")
    func jitter() {
        let policy = BackoffPolicy(baseDelay: 10, jitter: 0.2)
        #expect(abs(policy.delay(forAttempt: 1, random: 0) - 8) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 1, random: 1) - 12) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 1, random: 0.5) - 10) < 1e-9)
        #expect(policy.delay(forAttempt: 0, random: 0.5) == 10)
        #expect(policy.delay(forAttempt: 1, random: 7) == 12)         // out-of-range randomness is clamped
    }
}

@Suite("Conflict policies")
struct ConflictResolverTests {
    let remote = RemoteDocument(fields: ["role": .string("student"), "name": .string("srv")], version: 4,
                                updatedAt: Date(timeIntervalSince1970: 1_000))

    func local(_ kind: MutationKind = .upsert, editedAt: TimeInterval) -> Mutation {
        Mutation(path: P.logA, kind: kind, payload: ["name": .string("loc"), "role": .string("trainer")],
                 baseVersion: 1, createdAt: Date(timeIntervalSince1970: editedAt))
    }

    @Test("Last-write-wins compares the edit time with the server's write time")
    func lastWriteWins() {
        let resolver = PolicyConflictResolver(policies: [:], defaultPolicy: .lastWriteWins)
        #expect(resolver.resolve(local: local(editedAt: 2_000), remote: remote) == .keepLocal)
        #expect(resolver.resolve(local: local(editedAt: 500), remote: remote) == .keepRemote)
        let untimed = RemoteDocument(fields: [:], version: 1, updatedAt: nil)
        #expect(resolver.resolve(local: local(editedAt: 500), remote: untimed) == .keepLocal)
    }

    @Test("Policies are looked up by collection; unknown collections use the default")
    func perCollection() {
        let resolver = PolicyConflictResolver(policies: ["workoutLogs": .serverWins], defaultPolicy: .clientWins)
        #expect(resolver.resolve(local: local(editedAt: 1), remote: remote) == .keepRemote)
        let other = Mutation(path: DocumentPath(collection: "students/s1/checkIns", documentID: "x"), kind: .upsert, createdAt: Date())
        #expect(resolver.resolve(local: other, remote: remote) == .keepLocal)
    }

    @Test("Merge keeps remote-owned fields; for patches it drops them instead; deletes always win locally")
    func merge() {
        let resolver = PolicyConflictResolver(policies: ["workoutLogs": .mergePreferringRemote(fields: ["role"])])
        #expect(resolver.resolve(local: local(editedAt: 1), remote: remote) ==
                .merged(["name": .string("loc"), "role": .string("student")]))
        #expect(resolver.resolve(local: local(.patch, editedAt: 1), remote: remote) ==
                .merged(["name": .string("loc")]))
        #expect(resolver.resolve(local: local(.delete, editedAt: 1), remote: remote) == .keepLocal)
    }
}

@Suite("JSONValue & SyncCoding")
struct JSONValueTests {
    struct Sample: Codable, Equatable {
        var name: String
        var count: Int
        var ratio: Double
        var flag: Bool
        var when: Date
        var tags: [String]
        var nested: Nested?
        struct Nested: Codable, Equatable { var at: Date; var note: String? }
    }

    let sample = Sample(name: "A", count: 3, ratio: 0.5, flag: true,
                        when: Date(timeIntervalSince1970: 1_700_000_000.25), tags: ["x", "y"],
                        nested: .init(at: Date(timeIntervalSince1970: 1_600_000_000), note: nil))

    @Test("Dates become first-class `.date` values — i.e. Firestore Timestamps — not numbers")
    func datesAreTimestamps() throws {
        let fields = try SyncCoding.fields(sample)
        #expect(fields["when"] == .date(Date(timeIntervalSince1970: 1_700_000_000.25)))
        #expect(fields["nested"]?["at"] == .date(Date(timeIntervalSince1970: 1_600_000_000)))
        #expect(fields["count"] == .int(3))
        #expect(fields["ratio"] == .double(0.5))
        #expect(fields["flag"] == .bool(true))
        #expect(fields["tags"] == .array([.string("x"), .string("y")]))
    }

    @Test("Entities round-trip through the JSON tree")
    func roundTrip() throws {
        #expect(try SyncCoding.decode(Sample.self, from: SyncCoding.fields(sample)) == sample)
        #expect(try SyncCoding.decode(Sample.self, from: SyncCoding.data(sample)) == sample)
    }

    @Test("The JSON tree itself survives a Codable round trip, including every case")
    func treeRoundTrip() throws {
        let tree = JSONValue.object([
            "n": .null, "b": .bool(false), "i": .int(-4), "d": .double(2.5), "s": .string("é"),
            "a": .array([.int(1), .object(["k": .date(Date(timeIntervalSince1970: 42))])]),
        ])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tree))
        #expect(decoded == tree)
    }

    @Test("Timestamps may arrive as plain seconds and decode into Date")
    func lenientDates() throws {
        struct Holder: Codable { var at: Date }
        #expect(try SyncCoding.decode(Holder.self, from: ["at": .int(100)]).at == Date(timeIntervalSince1970: 100))
        #expect(try SyncCoding.decode(Holder.self, from: ["at": .double(100.5)]).at == Date(timeIntervalSince1970: 100.5))
        #expect(throws: (any Error).self) { try SyncCoding.decode(Holder.self, from: ["at": .string("tomorrow")]) }
    }

    @Test("Only objects can be document fields")
    func fieldsMustBeObject() {
        #expect(throws: SyncCodingError.notAnObject) { try SyncCoding.fields([1, 2, 3]) }
    }

    @Test("A one-key object that merely looks like a date marker but isn't numeric stays an object")
    func notADate() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"$date":"nope"}"#.utf8))
        #expect(value == .object(["$date": .string("nope")]))
    }

    @Test("Document paths expose their leaf collection")
    func documentPath() {
        #expect(P.logA.leafCollection == "workoutLogs")
        #expect(P.logA.description == "students/s1/workoutLogs/a")
        #expect(DocumentPath(collection: "plans", documentID: "p").leafCollection == "plans")
    }
}

@Suite("Network monitors")
struct NetworkMonitorTests {
    @Test("Subscribers receive the current state first, then changes")
    func controllableMonitor() async {
        let monitor = ControllableNetworkMonitor(online: false)
        var iterator = monitor.updates().makeAsyncIterator()
        #expect(await iterator.next() == false)
        await monitor.setOnline(true)
        #expect(await iterator.next() == true)
        #expect(await monitor.isOnline)
        await monitor.setOnline(true)           // no change → no event
        await monitor.setOnline(false)
        #expect(await iterator.next() == false)
    }

    @Test("The NWPathMonitor-backed monitor reports a state immediately")
    func pathMonitorSmoke() async {
        let monitor = PathNetworkMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        _ = await monitor.isOnline
    }
}
