import Foundation
import Network

public protocol NetworkMonitoring: Sendable {
    var isOnline: Bool { get async }
    /// Emits the *current* state immediately on subscription, then every change.
    func updates() -> AsyncStream<Bool>
}

/// Production monitor backed by `NWPathMonitor`.
public final class PathNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "fitcoach.network-monitor")
    private let lock = NSLock()
    private var online = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public var isOnline: Bool {
        get async { lock.withLock { online } }
    }

    public func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = lock.withLock { () -> Bool in
                continuations[id] = continuation
                return online
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
        }
    }

    private func set(_ value: Bool) {
        let targets = lock.withLock { () -> [AsyncStream<Bool>.Continuation] in
            guard online != value else { return [] }
            online = value
            return Array(continuations.values)
        }
        targets.forEach { $0.yield(value) }
    }
}

/// Scriptable monitor for unit tests, previews and UI tests (launch with `-UITestOffline`).
public actor ControllableNetworkMonitor: NetworkMonitoring {
    private var online: Bool
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(online: Bool = true) {
        self.online = online
    }

    public var isOnline: Bool { online }

    public nonisolated func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }

    public func setOnline(_ value: Bool) {
        guard online != value else { return }
        online = value
        for continuation in continuations.values { continuation.yield(value) }
    }

    private func register(_ id: UUID, _ continuation: AsyncStream<Bool>.Continuation) {
        continuations[id] = continuation
        continuation.yield(online)
    }

    private func unregister(_ id: UUID) {
        continuations[id] = nil
    }
}
