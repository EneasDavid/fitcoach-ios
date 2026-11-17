import Foundation

/// The optimistic local write queue.
///
/// Guarantees
///  * **Durability point = `enqueue`.** It throws if the edit could not be persisted, so callers never
///    believe a write is safe when it isn't. Later state transitions are best-effort: losing one only
///    means a replay after restart, which the idempotency key makes harmless.
///  * **Per-document ordering.** A mutation is never handed out while an earlier one for the same
///    document is pending or in flight — but different documents don't block each other.
///  * **Coalescing.** Rapid edits to one document collapse into a single pending mutation (a workout
///    logged set-by-set becomes one upsert), and create-then-delete while offline cancels out entirely.
///  * **Crash recovery.** `.inFlight` is memory-only; after a restart those mutations are `.pending` again.
public actor MutationQueue {
    public struct Counts: Equatable, Sendable {
        public var pending = 0
        public var inFlight = 0
        public var failed = 0
        public var isEmpty: Bool { pending + inFlight + failed == 0 }
    }

    private let store: any MutationStore
    private let now: @Sendable () -> Date
    private var items: [Mutation] = []
    private var nextSequence: Int64 = 1
    private var prepared = false

    public init(store: any MutationStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Loads persisted mutations. Idempotent; called lazily by every mutating method.
    public func prepare() async throws {
        guard !prepared else { return }
        var loaded = try await store.loadAll().sorted { $0.sequence < $1.sequence }
        for index in loaded.indices where loaded[index].status == .inFlight {
            loaded[index].status = .pending
        }
        items = loaded
        nextSequence = (loaded.last?.sequence ?? 0) + 1
        prepared = true
    }

    // MARK: Enqueue

    /// Adds an edit, coalescing it into an existing pending mutation for the same document when possible.
    /// - Returns: the resulting mutation, or `nil` when the edit cancelled a never-synced create.
    @discardableResult
    public func enqueue(path: DocumentPath,
                        kind: MutationKind,
                        payload: [String: JSONValue] = [:],
                        baseVersion: Int?) async throws -> Mutation? {
        try await prepare()
        let timestamp = now()

        if let index = items.lastIndex(where: { $0.path == path }), items[index].status == .pending {
            switch Self.coalesce(existing: items[index], kind: kind, payload: payload, baseVersion: baseVersion) {
            case .cancel:
                let id = items[index].id
                try await store.remove(ids: [id])
                items.remove(at: index)
                return nil
            case .unchanged:
                return items[index]
            case .replace(var merged):
                merged.editedAt = timestamp
                merged.attempts = 0
                merged.nextAttemptAt = timestamp
                merged.lastError = nil
                try await store.save(merged)
                items[index] = merged
                return merged
            }
        }

        let mutation = Mutation(sequence: nextSequence, path: path, kind: kind, payload: payload,
                                baseVersion: baseVersion, createdAt: timestamp)
        try await store.save(mutation)
        nextSequence += 1
        items.append(mutation)
        return mutation
    }

    enum CoalesceResult {
        case replace(Mutation)
        case cancel
        case unchanged
    }

    static func coalesce(existing: Mutation, kind: MutationKind, payload: [String: JSONValue], baseVersion: Int?) -> CoalesceResult {
        var merged = existing
        switch (existing.kind, kind) {
        case (.upsert, .upsert), (.patch, .upsert), (.delete, .upsert):
            merged.kind = .upsert
            merged.payload = payload
        case (.upsert, .patch), (.patch, .patch):
            merged.payload = existing.payload.merging(payload) { _, new in new }
        case (.upsert, .delete):
            // Created offline and deleted before it ever synced: the server never needs to hear of it.
            if existing.baseVersion == 0 { return .cancel }
            merged.kind = .delete
            merged.payload = [:]
        case (.patch, .delete):
            merged.kind = .delete
            merged.payload = [:]
        case (.delete, .patch), (.delete, .delete):
            return .unchanged
        }
        return .replace(merged)
    }

    // MARK: Dispatching

    /// Oldest mutation that is due and not blocked by an earlier one for the same document.
    public func nextEligible(at date: Date) -> Mutation? {
        for (index, mutation) in items.enumerated() where mutation.status == .pending && mutation.nextAttemptAt <= date {
            let blocked = items[..<index].contains {
                $0.path == mutation.path && ($0.status == .pending || $0.status == .inFlight)
            }
            if !blocked { return mutation }
        }
        return nil
    }

    /// Earliest future time a backed-off mutation becomes due.
    public func earliestPendingAttempt(after date: Date) -> Date? {
        items.filter { $0.status == .pending && $0.nextAttemptAt > date }.map(\.nextAttemptAt).min()
    }

    public func markInFlight(_ id: UUID) {
        update(id) { $0.status = .inFlight }   // memory-only on purpose
    }

    public func complete(_ id: UUID) async {
        items.removeAll { $0.id == id }
        try? await store.remove(ids: [id])
    }

    /// Returns a mutation to `.pending` without consuming an attempt (e.g. we turned out to be offline).
    public func release(_ id: UUID) async {
        await persistUpdate(id) { $0.status = .pending }
    }

    public func reschedule(_ id: UUID, error: String, at date: Date) async {
        await persistUpdate(id) {
            $0.status = .pending
            $0.attempts += 1
            $0.nextAttemptAt = date
            $0.lastError = error
        }
    }

    public func fail(_ id: UUID, error: String) async {
        await persistUpdate(id) {
            $0.status = .failed
            $0.attempts += 1
            $0.lastError = error
        }
    }

    /// After a conflict: retry now against the server's current revision, optionally with a merged payload.
    public func rebase(_ id: UUID, baseVersion: Int, payload: [String: JSONValue]?) async {
        let timestamp = now()
        await persistUpdate(id) {
            $0.status = .pending
            $0.baseVersion = baseVersion
            if let payload { $0.payload = payload }
            $0.nextAttemptAt = timestamp
        }
    }

    /// After a successful apply, later edits to the same document were made against the *old* revision;
    /// move them onto the new one so we don't conflict with ourselves.
    public func adoptServerVersion(_ version: Int, for path: DocumentPath) async {
        for index in items.indices where items[index].path == path && items[index].status == .pending {
            items[index].baseVersion = version
            try? await store.save(items[index])
        }
    }

    /// Re-arms dead-lettered mutations (e.g. after the user re-authenticated or rules were fixed).
    public func retryFailed() async {
        let timestamp = now()
        for index in items.indices where items[index].status == .failed {
            items[index].status = .pending
            items[index].attempts = 0
            items[index].nextAttemptAt = timestamp
            try? await store.save(items[index])
        }
    }

    public func discardFailed() async {
        let ids = items.filter { $0.status == .failed }.map(\.id)
        items.removeAll { $0.status == .failed }
        try? await store.remove(ids: ids)
    }

    // MARK: Inspection

    public func counts() -> Counts {
        var counts = Counts()
        for item in items {
            switch item.status {
            case .pending: counts.pending += 1
            case .inFlight: counts.inFlight += 1
            case .failed: counts.failed += 1
            }
        }
        return counts
    }

    public func hasUnsyncedMutations(for path: DocumentPath) -> Bool {
        items.contains { $0.path == path && $0.status != .failed }
    }

    public func snapshot() -> [Mutation] { items }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout Mutation) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func persistUpdate(_ id: UUID, _ change: (inout Mutation) -> Void) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        try? await store.save(items[index])
    }
}
