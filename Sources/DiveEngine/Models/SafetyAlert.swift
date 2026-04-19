import Foundation

public struct SafetyAlert: Sendable, Identifiable {
    public let id = UUID()
    public let type: AlertType
    public let severity: AlertSeverity
    public let triggeredAt: Date
    public let depth: Double

    public init(type: AlertType, severity: AlertSeverity, triggeredAt: Date, depth: Double) {
        self.type = type
        self.severity = severity
        self.triggeredAt = triggeredAt
        self.depth = depth
    }

    public enum AlertType: Sendable, Equatable {
        case ascentRate(current: Double, max: Double)
        case ceilingViolation(currentDepth: Double, ceiling: Double)
        case decoRequired
        case lowBattery(level: Int)
        case oxygenToxicity(cns: Double)          // CNS ≥ 80 %
        case ppO2High(ppO2: Double, limit: Double) // ppO2 ≥ 1.4 bar
        // Suunto mandatory alarms
        case ndlLow(minutes: Int)        // NDL < 5 min
        case ooam                         // Out Of Allowed Margin: ceiling missed ≥ 3 min
        case safetyStopBroken            // left safety stop zone while stop was active
        case otuHigh(otu: Double, limit: Double) // OTU at 80%/100% of daily limit
        // User-configurable alarms
        case userDepthAlarm(depth: Double)
        case userNDLAlarm(ndlMinutes: Int)
    }

    public enum AlertSeverity: Sendable, Comparable {
        case info
        case warning
        case critical
    }
}
