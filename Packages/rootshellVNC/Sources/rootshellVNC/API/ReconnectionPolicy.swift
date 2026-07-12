import Foundation

/// Controls automatic recovery after an established connection is lost.
public struct VNCReconnectionPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var maximumAttempts: Int
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var multiplier: Double
    public var jitter: Double

    public init(
        isEnabled: Bool = true,
        maximumAttempts: Int = 8,
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 30,
        multiplier: Double = 2,
        jitter: Double = 0.2
    ) {
        let safeInitialDelay = initialDelay.isFinite ? max(0, initialDelay) : 1
        let safeMaximumDelay = maximumDelay.isFinite
            ? max(safeInitialDelay, maximumDelay)
            : max(safeInitialDelay, 30)
        let safeMultiplier = multiplier.isFinite ? max(1, multiplier) : 2
        let safeJitter = jitter.isFinite ? min(max(0, jitter), 1) : 0.2
        self.isEnabled = isEnabled
        self.maximumAttempts = max(0, maximumAttempts)
        self.initialDelay = safeInitialDelay
        self.maximumDelay = safeMaximumDelay
        self.multiplier = safeMultiplier
        self.jitter = safeJitter
    }

    /// Exponential backoff capped at `maximumDelay`, with symmetric jitter to
    /// prevent many clients retrying a recovered server at the same instant.
    func delay(forAttempt attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let base = min(maximumDelay, initialDelay * pow(multiplier, exponent))
        let clampedRandom = min(max(0, randomUnit), 1)
        let jitterFactor = 1 + ((clampedRandom * 2 - 1) * jitter)
        return max(0, min(maximumDelay, base * jitterFactor))
    }
}
