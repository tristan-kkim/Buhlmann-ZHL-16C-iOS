import Foundation

/// Monitors ascent rate history and provides trend analysis.
public struct AscentRateMonitor: Sendable {
    private let maxRate: Double // m/min
    private let warningThreshold: Double
    private let criticalThreshold: Double

    public init(maxRate: Double = 9.0, criticalMultiplier: Double = 1.5) {
        self.maxRate = maxRate
        self.warningThreshold = maxRate
        self.criticalThreshold = maxRate * criticalMultiplier
    }

    public enum Status: Sendable {
        case safe
        case warning(current: Double)
        case critical(current: Double)
    }

    public func evaluate(ascentRate: Double) -> Status {
        if ascentRate > criticalThreshold {
            return .critical(current: ascentRate)
        } else if ascentRate > warningThreshold {
            return .warning(current: ascentRate)
        }
        return .safe
    }

    /// Progress bar value 0.0–1.0+ (> 1.0 = over limit)
    public func ratioToLimit(ascentRate: Double) -> Double {
        ascentRate / maxRate
    }
}
