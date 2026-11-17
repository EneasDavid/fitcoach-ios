import Foundation

public struct SyncStatus: Equatable, Sendable {
    public var pending = 0
    public var inFlight = 0
    public var failed = 0
    public var isOnline = true
    public var isSyncing = false
    public var lastSyncedAt: Date?
    /// The session expired; the queue is paused until `resumeAfterAuthentication()`.
    public var authRequired = false

    public init(pending: Int = 0, inFlight: Int = 0, failed: Int = 0, isOnline: Bool = true,
                isSyncing: Bool = false, lastSyncedAt: Date? = nil, authRequired: Bool = false) {
        self.pending = pending
        self.inFlight = inFlight
        self.failed = failed
        self.isOnline = isOnline
        self.isSyncing = isSyncing
        self.lastSyncedAt = lastSyncedAt
        self.authRequired = authRequired
    }

    public var isFullySynced: Bool { pending == 0 && inFlight == 0 && failed == 0 }
}

public enum DropReason: Sendable, Equatable {
    /// A conflict was resolved in the server's favour; the local edit was discarded.
    case remoteWonConflict
    /// A delete for a document that is already gone.
    case alreadyDeleted
}

/// Callbacks that let the data layer reconcile local rows (e.g. flip `syncState` to `.synced`).
public protocol SyncObserver: Sendable {
    func mutationApplied(_ mutation: Mutation, result: RemoteApplyResult) async
    func mutationDropped(_ mutation: Mutation, reason: DropReason) async
    func mutationFailed(_ mutation: Mutation, error: RemoteError) async
}

public extension SyncObserver {
    func mutationApplied(_ mutation: Mutation, result: RemoteApplyResult) async {}
    func mutationDropped(_ mutation: Mutation, reason: DropReason) async {}
    func mutationFailed(_ mutation: Mutation, error: RemoteError) async {}
}

public struct DrainReport: Equatable, Sendable {
    public enum Stop: Equatable, Sendable {
        /// Nothing more is due (the queue may still hold backed-off mutations).
        case idle
        case offline
        case authRequired
        /// Another drain was already running; it will pick up the new work.
        case alreadyRunning
    }

    public var applied = 0
    public var retried = 0
    public var failed = 0
    public var conflicts = 0
    public var dropped = 0
    public var stopped: Stop = .idle
}

/// Drains the mutation queue to the backend. All state lives inside this actor and all I/O is
/// `async`, so nothing here ever blocks the main thread.
///
///  * connectivity: drains on reconnect, stops when offline (without burning retry attempts);
///  * retry: exponential backoff with jitter, honouring server `retryAfter`; dead-letters after
///    `maxAttempts` or on permanent errors without blocking unrelated documents;
///  * auth: pauses everything on `.unauthenticated` until the app signs in again;
///  * conflicts: delegated to a `ConflictResolving` policy, bounded to `maxConflictRetries`.
public actor SyncDispatcher {
    private let queue: MutationQueue
    private let gateway: any RemoteGateway
    private let network: any NetworkMonitoring
    private let resolver: any ConflictResolving
    private let backoff: BackoffPolicy
    private let observer: (any SyncObserver)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let random: @Sendable () -> Double
    private let maxConflictRetries: Int
    private let offlineProbeDelay: TimeInterval

    private var isOnline = true
    private var authRequired = false
    private var isDraining = false
    private var rerunRequested = false
    private var lastSyncedAt: Date?
    private var conflictAttempts: [UUID: Int] = [:]
    private var monitorTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    public init(queue: MutationQueue,
                gateway: any RemoteGateway,
                network: any NetworkMonitoring,
                resolver: any ConflictResolving,
                observer: (any SyncObserver)? = nil,
                backoff: BackoffPolicy = BackoffPolicy(),
                maxConflictRetries: Int = 3,
                offlineProbeDelay: TimeInterval = 15,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.queue = queue
        self.gateway = gateway
        self.network = network
        self.resolver = resolver
        self.observer = observer
        self.backoff = backoff
        self.maxConflictRetries = maxConflictRetries
        self.offlineProbeDelay = offlineProbeDelay
        self.now = now
        self.sleep = sleep
        self.random = random
    }

    // MARK: Lifecycle

    /// Loads the queue, starts watching connectivity and drains whatever is pending.
    public func start() async {
        guard monitorTask == nil else { return }
        try? await queue.prepare()
        isOnline = await network.isOnline
        let updates = network.updates()
        monitorTask = Task { [weak self] in
            for await online in updates {
                await self?.networkChanged(online)
            }
        }
        await publish(syncing: false)
        kick()
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        wakeTask?.cancel()
        wakeTask = nil
    }

    /// Requests a drain without waiting for it (call after enqueueing).
    public func kick() {
        Task { _ = await self.drain() }
    }

    public func resumeAfterAuthentication() {
        authRequired = false
        kick()
    }

    public func retryFailed() async {
        await queue.retryFailed()
        kick()
    }

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
            Task { continuation.yield(await self.currentStatus(syncing: self.isDraining)) }
        }
    }

    public func currentStatus() async -> SyncStatus {
        await currentStatus(syncing: isDraining)
    }

    // MARK: Draining

    @discardableResult
    public func drain() async -> DrainReport {
        guard !isDraining else {
            rerunRequested = true
            return DrainReport(stopped: .alreadyRunning)
        }
        isDraining = true
        wakeTask?.cancel()
        wakeTask = nil
        try? await queue.prepare()
        isOnline = await network.isOnline

        var report = DrainReport()
        await publish(syncing: true)

        repeat {
            rerunRequested = false
            report.stopped = await drainPass(into: &report)
        } while rerunRequested

        isDraining = false
        await scheduleWake(after: report.stopped)
        await publish(syncing: false)
        return report
    }

    private func drainPass(into report: inout DrainReport) async -> DrainReport.Stop {
        while true {
            guard isOnline else { return .offline }
            guard !authRequired else { return .authRequired }
            guard let mutation = await queue.nextEligible(at: now()) else { return .idle }

            await queue.markInFlight(mutation.id)
            do {
                let result = try await gateway.apply(mutation)
                await queue.complete(mutation.id)
                await queue.adoptServerVersion(result.version, for: mutation.path)
                conflictAttempts[mutation.id] = nil
                lastSyncedAt = now()
                report.applied += 1
                await observer?.mutationApplied(mutation, result: result)
            } catch let error as RemoteError {
                if let stop = await handle(error, for: mutation, report: &report) { return stop }
            } catch {
                // Unknown failures are treated as transient: never lose a write because of a surprise.
                if let stop = await handle(.transient(retryAfter: nil), for: mutation, report: &report) { return stop }
            }
            await publish(syncing: true)
        }
    }

    /// - Returns: a stop reason if draining must halt, `nil` to continue with the next mutation.
    private func handle(_ error: RemoteError, for mutation: Mutation, report: inout DrainReport) async -> DrainReport.Stop? {
        switch error {
        case .offline:
            await queue.release(mutation.id)
            isOnline = false
            return .offline

        case .unauthenticated:
            await queue.release(mutation.id)
            authRequired = true
            return .authRequired

        case .transient(let retryAfter):
            let attempt = mutation.attempts + 1
            if attempt >= backoff.maxAttempts {
                await deadLetter(mutation, error: error, reason: "retries exhausted", report: &report)
            } else {
                let delay = max(retryAfter ?? 0, backoff.delay(forAttempt: attempt, random: random()))
                await queue.reschedule(mutation.id, error: "\(error)", at: now().addingTimeInterval(delay))
                report.retried += 1
            }
            return nil

        case .permissionDenied, .invalid:
            await deadLetter(mutation, error: error, reason: "\(error)", report: &report)
            return nil

        case .notFound:
            if mutation.kind == .delete {
                await queue.complete(mutation.id)
                await observer?.mutationDropped(mutation, reason: .alreadyDeleted)
                report.dropped += 1
            } else {
                await deadLetter(mutation, error: error, reason: "document does not exist", report: &report)
            }
            return nil

        case .conflict:
            return await resolveConflict(mutation, report: &report)
        }
    }

    private func resolveConflict(_ mutation: Mutation, report: inout DrainReport) async -> DrainReport.Stop? {
        let attempts = (conflictAttempts[mutation.id] ?? 0) + 1
        conflictAttempts[mutation.id] = attempts
        guard attempts <= maxConflictRetries else {
            await deadLetter(mutation, error: .conflict(serverVersion: nil), reason: "conflict unresolved after \(maxConflictRetries) tries", report: &report)
            return nil
        }

        let remote: RemoteDocument?
        do {
            remote = try await gateway.fetch(mutation.path)
        } catch let error as RemoteError {
            return await handle(error == .conflict(serverVersion: nil) ? .transient(retryAfter: nil) : error, for: mutation, report: &report)
        } catch {
            return await handle(.transient(retryAfter: nil), for: mutation, report: &report)
        }

        report.conflicts += 1

        guard let remote else {
            // The server copy is gone (or never existed).
            switch mutation.kind {
            case .upsert:
                await queue.rebase(mutation.id, baseVersion: 0, payload: nil)      // re-create it
            case .delete:
                await queue.complete(mutation.id)
                await observer?.mutationDropped(mutation, reason: .alreadyDeleted)
                report.dropped += 1
            case .patch:
                await deadLetter(mutation, error: .notFound, reason: "patched document was deleted remotely", report: &report)
            }
            return nil
        }

        switch resolver.resolve(local: mutation, remote: remote) {
        case .keepLocal:
            await queue.rebase(mutation.id, baseVersion: remote.version, payload: nil)
        case .merged(let payload):
            await queue.rebase(mutation.id, baseVersion: remote.version, payload: payload)
        case .keepRemote:
            await queue.complete(mutation.id)
            conflictAttempts[mutation.id] = nil
            report.dropped += 1
            await observer?.mutationDropped(mutation, reason: .remoteWonConflict)
        }
        return nil
    }

    private func deadLetter(_ mutation: Mutation, error: RemoteError, reason: String, report: inout DrainReport) async {
        await queue.fail(mutation.id, error: reason)
        conflictAttempts[mutation.id] = nil
        report.failed += 1
        await observer?.mutationFailed(mutation, error: error)
    }

    // MARK: Scheduling & status

    private func networkChanged(_ online: Bool) async {
        isOnline = online
        await publish(syncing: isDraining)
        if online { kick() }
    }

    private func scheduleWake(after stop: DrainReport.Stop) async {
        wakeTask?.cancel()
        wakeTask = nil

        let delay: TimeInterval
        switch stop {
        case .idle:
            guard let due = await queue.earliestPendingAttempt(after: now()) else { return }
            delay = max(0, due.timeIntervalSince(now()))
        case .offline:
            // The monitor says we're online but the gateway disagrees (captive portal, flaky radio): probe later.
            guard await network.isOnline else { return }
            delay = offlineProbeDelay
        case .authRequired, .alreadyRunning:
            return
        }

        wakeTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            await self?.kick()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func currentStatus(syncing: Bool) async -> SyncStatus {
        let counts = await queue.counts()
        return SyncStatus(pending: counts.pending, inFlight: counts.inFlight, failed: counts.failed,
                          isOnline: isOnline, isSyncing: syncing, lastSyncedAt: lastSyncedAt, authRequired: authRequired)
    }

    private func publish(syncing: Bool) async {
        guard !subscribers.isEmpty else { return }
        let status = await currentStatus(syncing: syncing)
        for continuation in subscribers.values { continuation.yield(status) }
    }
}
