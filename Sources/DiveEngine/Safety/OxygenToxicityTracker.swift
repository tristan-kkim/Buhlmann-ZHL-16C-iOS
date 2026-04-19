import Foundation

/// Tracks oxygen toxicity exposure during a dive.
///
/// - **CNS %**: Central Nervous System toxicity, based on NOAA single-exposure time limits by ppO₂.
///   ≥ 80 % = caution; ≥ 100 % = emergency.
/// - **OTU**: Oxygen Tolerance Units (pulmonary toxicity). ≥ 250 = caution; ≥ 300 = warning.
actor OxygenToxicityTracker {

    // MARK: - Accumulated State

    private(set) var cns: Double = 0  // 0–300+ %
    private(set) var otu: Double = 0  // cumulative units

    // MARK: - NOAA CNS Single-Exposure Limits

    /// Ordered from highest ppO₂ downward. Matched by first threshold ≥ actual ppO₂.
    private static let cnsTable: [(threshold: Double, limitSeconds: Double)] = [
        (1.60, 45 * 60),
        (1.50, 120 * 60),
        (1.40, 150 * 60),
        (1.30, 180 * 60),
        (1.20, 210 * 60),
        (1.10, 240 * 60),
        (0.50, 360 * 60),   // 0.50–1.09: 6 h limit
    ]

    // MARK: - API

    /// Accumulate toxicity for one time segment.
    /// - Parameters:
    ///   - ppO2: O₂ partial pressure in bar during this segment.
    ///   - durationSeconds: Length of segment in seconds.
    func addSegment(ppO2: Double, durationSeconds: Double) {
        guard ppO2 >= 0.5, durationSeconds > 0 else { return }

        // CNS: fraction of NOAA limit consumed, expressed as percent
        let limitSec = Self.cnsLimit(for: ppO2)
        cns = min(cns + (durationSeconds / limitSec) * 100.0, 300.0)

        // OTU: NOAA formula — OTU/min = ((ppO2 − 0.5) / 0.5)^0.833
        let otuPerMin = pow((ppO2 - 0.5) / 0.5, 0.833)
        otu += otuPerMin * (durationSeconds / 60.0)
    }

    /// Reset all accumulators (call at dive start).
    func reset() {
        cns = 0
        otu = 0
    }

    // MARK: - Private

    private static func cnsLimit(for ppO2: Double) -> Double {
        for entry in cnsTable where ppO2 >= entry.threshold {
            return entry.limitSeconds
        }
        return 360 * 60  // ≥ 0.5 but not matched — use 6 h
    }
}
