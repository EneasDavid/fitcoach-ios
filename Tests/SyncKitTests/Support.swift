import Foundation
@testable import SyncKit

// MARK: - Time & waiting

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Polls an async condition; keeps tests deterministic without fixed sleeps.
func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

actor SleepRecorder {
    private(set) var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

// MARK: - Server simulator (same contract as the Firestore gateway)

actor ServerSimulator: RemoteGateway {
    struct Document: Equatable {
        var fields: [String: JSONValue]
        var rev: Int
        var mutationID: UUID?
        var updatedAt: Date
    }

    private(set) var documents: [DocumentPath: Document] = [:]
    private(set) var attempts: [UUID] = []
    private(set) var appliedPaths: [DocumentPath] = []
    private var failures: [RemoteError] = []
    private var lostAcks = 0
    private var gate: AsyncGate?
    private let clock: TestClock

    init(clock: TestClock) { self.clock = clock }

    func seed(_ path: DocumentPath, fields: [String: JSONValue], rev: Int, updatedAt: Date? = nil) {
        documents[path] = Document(fields: fields, rev: rev, mutationID: nil, updatedAt: updatedAt ?? clock.now())
    }

    /// Errors thrown, in order, *before* a call touches any state.
    func failNext(_ errors: [RemoteError]) { failures.append(contentsOf: errors) }
    /// The server applies the write but the response never reaches the client.
    func loseNextAcknowledgements(_ count: Int) { lostAcks = count }
    func block(on gate: AsyncGate) { self.gate = gate }

    func apply(_ mutation: Mutation) async throws -> RemoteApplyResult {
        attempts.append(mutation.id)
        if let gate { await gate.wait() }
        if !failures.isEmpty { throw failures.removeFirst() }

        let existing = documents[mutation.path]
        if let existing, existing.mutationID == mutation.id {
            return RemoteApplyResult(version: existing.rev, alreadyApplied: true)
        }
        let current = existing?.rev ?? 0
        if let base = mutation.baseVersion, base != current { throw RemoteError.conflict(serverVersion: current) }

        switch mutation.kind {
        case .upsert:
            documents[mutation.path] = Document(fields: (existing?.fields ?? [:]).merging(mutation.payload) { _, new in new },
                                                rev: current + 1, mutationID: mutation.id, updatedAt: clock.now())
        case .patch:
            guard let existing else { throw RemoteError.notFound }
            documents[mutation.path] = Document(fields: existing.fields.merging(mutation.payload) { _, new in new },
                                                rev: current + 1, mutationID: mutation.id, updatedAt: clock.now())
        case .delete:
            guard existing != nil else { throw RemoteError.notFound }
            documents[mutation.path] = nil
        }
        appliedPaths.append(mutation.path)

        if lostAcks > 0 {
            lostAcks -= 1
            throw RemoteError.transient(retryAfter: nil)
        }
        return RemoteApplyResult(version: current + 1)
    }

    func fetch(_ path: DocumentPath) async throws -> RemoteDocument? {
        documents[path].map { RemoteDocument(fields: $0.fields, version: $0.rev, updatedAt: $0.updatedAt) }
    }
}

actor RecordingObserver: SyncObserver {
    private(set) var applied: [(id: UUID, result: RemoteApplyResult)] = []
    private(set) var dropped: [(id: UUID, reason: DropReason)] = []
    private(set) var failed: [UUID] = []

    func mutationApplied(_ mutation: Mutation, result: RemoteApplyResult) async { applied.append((mutation.id, result)) }
    func mutationDropped(_ mutation: Mutation, reason: DropReason) async { dropped.append((mutation.id, reason)) }
    func mutationFailed(_ mutation: Mutation, error: RemoteError) async { failed.append(mutation.id) }
}

actor FailingStore: MutationStore {
    var failSaves = true
    func loadAll() async throws -> [Mutation] { [] }
    func save(_ mutation: Mutation) async throws { if failSaves { throw StoreFailure() } }
    func remove(ids: [UUID]) async throws {}
    struct StoreFailure: Error {}
}

// MARK: - Harness

enum P {
    static let logA = DocumentPath(collection: "students/s1/workoutLogs", documentID: "a")
    static let logB = DocumentPath(collection: "students/s1/workoutLogs", documentID: "b")
    static let logC = DocumentPath(collection: "students/s1/workoutLogs", documentID: "c")
}

struct Harness {
    let clock = TestClock()
    let store: InMemoryMutationStore
    let queue: MutationQueue
    let server: ServerSimulator
    let network: ControllableNetworkMonitor
    let observer = RecordingObserver()
    let sleeps = SleepRecorder()
    let dispatcher: SyncDispatcher

    init(online: Bool = true,
         resolver: any ConflictResolving = PolicyConflictResolver(policies: [:], defaultPolicy: .clientWins),
         backoff: BackoffPolicy = BackoffPolicy(jitter: 0, maxAttempts: 8),
         maxConflictRetries: Int = 3,
         storedMutations: [Mutation] = []) {
        let clock = self.clock
        let store = InMemoryMutationStore(storedMutations)
        let queue = MutationQueue(store: store, now: { clock.now() })
        let server = ServerSimulator(clock: clock)
        let network = ControllableNetworkMonitor(online: online)
        let sleeps = self.sleeps
        self.store = store
        self.queue = queue
        self.server = server
        self.network = network
        self.dispatcher = SyncDispatcher(queue: queue, gateway: server, network: network, resolver: resolver,
                                         observer: observer, backoff: backoff, maxConflictRetries: maxConflictRetries,
                                         now: { clock.now() },
                                         sleep: { delay in
                                             await sleeps.record(delay)
                                             try await Task.sleep(nanoseconds: 3_600_000_000_000)   // until cancelled
                                         },
                                         random: { 0.5 })
    }

    @discardableResult
    func enqueue(_ path: DocumentPath, _ kind: MutationKind = .upsert, _ payload: [String: JSONValue] = ["v": .int(1)], base: Int? = 0) async throws -> Mutation? {
        try await queue.enqueue(path: path, kind: kind, payload: payload, baseVersion: base)
    }
}
