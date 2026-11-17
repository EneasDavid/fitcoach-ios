import Foundation
import Domain

/// Arrival source for demos, UI tests and a debug-menu "Simulate arrival" button.
public final class SimulatedGymArrivalProvider: GymArrivalProviding, @unchecked Sendable {
    public let provider: GymProvider
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<GymArrivalEvent>.Continuation] = [:]
    private var monitoring = false

    public init(provider: GymProvider = .simulated) {
        self.provider = provider
    }

    public var isMonitoring: Bool { lock.withLock { monitoring } }

    public func arrivals() -> AsyncStream<GymArrivalEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func startMonitoring() async throws { lock.withLock { monitoring = true } }
    public func stopMonitoring() async { lock.withLock { monitoring = false } }

    /// Delivers an event as if the student had just walked in (only while monitoring).
    public func simulateArrival(at venue: GymVenue, date: Date = Date()) {
        let targets = lock.withLock { monitoring ? Array(continuations.values) : [] }
        let event = GymArrivalEvent(provider: provider, venue: venue, arrivedAt: date, externalReference: "sim-\(UUID().uuidString)")
        targets.forEach { $0.yield(event) }
    }
}

/// Merges several arrival sources (e.g. geofence + Wellhub) into one stream.
/// Duplicate reports of the same visit are removed downstream by `GymArrivalCoordinator`.
public final class CompositeGymArrivalProvider: GymArrivalProviding, @unchecked Sendable {
    public let provider: GymProvider = .manual
    private let children: [any GymArrivalProviding]

    public init(_ children: [any GymArrivalProviding]) {
        self.children = children
    }

    public func arrivals() -> AsyncStream<GymArrivalEvent> {
        let streams = children.map { $0.arrivals() }
        return AsyncStream { continuation in
            let tasks = streams.map { stream in
                Task { for await event in stream { continuation.yield(event) } }
            }
            continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        }
    }

    public func startMonitoring() async throws {
        for child in children { try await child.startMonitoring() }
    }

    public func stopMonitoring() async {
        for child in children { await child.stopMonitoring() }
    }
}

/// Factory: builds the set of arrival sources the user enabled. The app registers the real adapters
/// (CoreLocation geofence; partner SDKs once an agreement exists) — this module never imports them.
public struct GymArrivalProviderFactory: Sendable {
    public typealias Builder = @Sendable () -> any GymArrivalProviding

    private var builders: [GymProvider: Builder] = [:]

    public init() {}

    public mutating func register(_ provider: GymProvider, builder: @escaping Builder) {
        builders[provider] = builder
    }

    /// Unregistered providers are skipped (e.g. a partner the installed build doesn't support yet).
    public func make(enabled: [GymProvider]) -> CompositeGymArrivalProvider {
        CompositeGymArrivalProvider(enabled.compactMap { builders[$0]?() })
    }
}


/// Presence source for demos, UI tests and a debug-menu "simulate a gym visit". Same contract as the CoreLocation one.
public final class SimulatedGymPresenceProvider: GymPresenceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<GymPresenceEvent>.Continuation] = [:]
    private var monitoring = false

    public init() {}

    public func presenceEvents() -> AsyncStream<GymPresenceEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func startMonitoring() async throws { lock.withLock { monitoring = true } }
    public func stopMonitoring() async { lock.withLock { monitoring = false } }

    /// Delivers an event as if the phone had crossed the gym's perimeter (only while monitoring).
    public func simulate(_ kind: GymPresenceKind, venue: GymVenue, at date: Date = Date()) {
        let targets = lock.withLock { monitoring ? Array(continuations.values) : [] }
        let event = GymPresenceEvent(kind: kind, venue: venue, at: date, provider: .simulated)
        targets.forEach { $0.yield(event) }
    }
}
