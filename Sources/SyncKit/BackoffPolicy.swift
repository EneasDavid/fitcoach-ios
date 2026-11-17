import Foundation

/// Exponential backoff with symmetric jitter, so a fleet of devices that lost connectivity at the
/// same moment doesn't retry in lock-step against Firestore.
public struct BackoffPolicy: Equatable, Sendable {
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// ±fraction applied to the delay (0.2 → between 80 % and 120 %).
    public var jitter: Double
    /// After this many failed attempts the mutation is dead-lettered.
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 2,
                multiplier: Double = 2,
                maxDelay: TimeInterval = 300,
                jitter: Double = 0.2,
                maxAttempts: Int = 8) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.maxAttempts = maxAttempts
    }

    /// - Parameters:
    ///   - attempt: 1-based number of the attempt that just failed.
    ///   - random: a value in `0..<1` (injected for deterministic tests).
    public func delay(forAttempt attempt: Int, random: Double) -> TimeInterval {
        let exponent = Double(max(attempt, 1) - 1)
        let raw = min(maxDelay, baseDelay * pow(multiplier, exponent))
        let factor = 1 + jitter * (2 * min(max(random, 0), 1) - 1)
        return raw * factor
    }
}
