import Foundation
import Observation

/// Haptics, sounds and background alerts. Implemented in the app target with UIKit / AudioToolbox /
/// UserNotifications, so this module stays free of platform specifics and trivially testable.
@MainActor
public protocol FeedbackProviding: AnyObject {
    /// Light tap when a set is logged.
    func setLogged()
    /// Sound + haptic when the rest period ends.
    func restFinished()
    /// Haptic when a HIIT segment switches between work and rest.
    func intervalChanged()
    /// The app may be backgrounded while resting: schedule a local notification for the end of the rest.
    func scheduleRestAlert(at date: Date)
    func cancelRestAlert()
    /// A gentle "hold on" haptic (e.g. the load is the wrong way round for this week).
    func warning()
}

public extension FeedbackProviding {
    func warning() {}
}

@MainActor
public final class NoopFeedback: FeedbackProviding {
    public init() {}
    public func setLogged() {}
    public func restFinished() {}
    public func intervalChanged() {}
    public func scheduleRestAlert(at date: Date) {}
    public func cancelRestAlert() {}
}

/// Wall-clock countdown. Remaining time is always *derived from an end date* rather than decremented,
/// so it stays correct when the app is suspended, the screen locks, or a tick is delayed.
@MainActor
@Observable
public final class CountdownTimer {
    public private(set) var remaining: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isRunning = false
    /// Increments on every natural finish — lets SwiftUI react with `.onChange`.
    public private(set) var finishCount = 0

    @ObservationIgnored public var onFinish: (@MainActor () -> Void)?
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// - Parameter autoTick: `false` in unit tests, which drive `tick()` by hand with a fake clock.
    public init(now: @escaping @MainActor () -> Date = { Date() }, autoTick: Bool = true) {
        self.now = now
        self.autoTick = autoTick
    }

    public var endsAt: Date? { endDate }
    /// Paused: stopped with time left on the clock.
    public var isPaused: Bool { !isRunning && remaining > 0 }
    public var progress: Double { duration > 0 ? min(1, max(0, 1 - remaining / duration)) : 0 }

    /// Remaining time *right now*, without waiting for the next tick and without side effects.
    public var liveRemaining: TimeInterval {
        if isRunning, let endDate { return max(0, endDate.timeIntervalSince(now())) }
        return remaining
    }

    public func start(_ seconds: TimeInterval) {
        let seconds = max(0, seconds)
        duration = seconds
        remaining = seconds
        guard seconds > 0 else { finish(); return }
        run(for: seconds)
    }

    public func pause() {
        guard isRunning, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSince(now()))
        stopTicking()
    }

    public func resume() {
        guard !isRunning, remaining > 0 else { return }
        run(for: remaining)
    }

    public func stop() {
        stopTicking()
        remaining = 0
        duration = 0
    }

    /// Adds or removes time (the +15 s / −15 s buttons). Removing more than is left ends the timer.
    public func adjust(by seconds: TimeInterval) {
        if isRunning, let current = endDate {
            endDate = current.addingTimeInterval(seconds)
            duration = max(duration + seconds, 0)
            tick()
        } else {
            remaining = max(0, remaining + seconds)
            duration = max(duration + seconds, remaining)
        }
    }

    public func tick() {
        guard isRunning, let endDate else { return }
        let left = endDate.timeIntervalSince(now())
        if left <= 0 { finish() } else { remaining = left }
    }

    private func run(for seconds: TimeInterval) {
        endDate = now().addingTimeInterval(seconds)
        isRunning = true
        ticker?.cancel()
        guard autoTick else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        endDate = nil
        isRunning = false
    }

    private func finish() {
        stopTicking()
        remaining = 0
        finishCount += 1
        onFinish?()
    }
}

/// HIIT timeline: `rounds × (work, rest)`, without a trailing rest after the final round.
public struct IntervalSegment: Equatable, Sendable {
    public enum Kind: String, Sendable { case work, rest }
    public let kind: Kind
    /// 1-based.
    public let round: Int
    public let duration: Int
}

public struct IntervalSchedule: Equatable, Sendable {
    public let segments: [IntervalSegment]

    public init(rounds: Int, workSeconds: Int, restSeconds: Int) {
        var built: [IntervalSegment] = []
        for round in 1...max(rounds, 1) {
            if workSeconds > 0 { built.append(IntervalSegment(kind: .work, round: round, duration: workSeconds)) }
            if restSeconds > 0 && round < max(rounds, 1) { built.append(IntervalSegment(kind: .rest, round: round, duration: restSeconds)) }
        }
        segments = built
    }

    public var totalSeconds: Int { segments.reduce(0) { $0 + $1.duration } }
    public var rounds: Int { segments.last?.round ?? 0 }
}
