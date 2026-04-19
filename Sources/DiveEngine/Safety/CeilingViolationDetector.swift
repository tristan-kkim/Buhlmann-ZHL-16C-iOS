import Foundation

/// Detects when a diver ascends above the required decompression ceiling.
public struct CeilingViolationDetector: Sendable {
    /// Safety margin in meters — trigger alert only when this far above ceiling
    public let margin: Double

    public init(margin: Double = 0.5) {
        self.margin = margin
    }

    public struct ViolationInfo: Sendable {
        public let currentDepth: Double
        public let ceiling: Double
        public let overshoot: Double  // how far above ceiling (positive = violation)
    }

    /// Returns violation info if the diver is above (ceiling - margin).
    public func check(depth: Double, ceiling: Double?) -> ViolationInfo? {
        guard let ceiling else { return nil }
        let overshoot = ceiling - depth  // positive when shallower than ceiling
        guard overshoot > margin else { return nil }
        return ViolationInfo(
            currentDepth: depth,
            ceiling: ceiling,
            overshoot: overshoot
        )
    }
}
