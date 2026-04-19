import Foundation

/// Converts ambient pressure to depth in meters.
public enum DepthCalculator {
    private static let gravity: Double = 9.80665 // m/s²

    /// - Parameters:
    ///   - ambientPressure: Total ambient pressure in bar (including surface pressure)
    ///   - surfacePressure: Surface atmospheric pressure in bar (default 1.0133 bar = 1 atm)
    ///   - waterDensity: Water density in kg/m³ (salt: 1025, fresh: 1000)
    /// - Returns: Depth in meters (0 when at surface)
    public static func depth(
        from ambientPressure: Double,
        surfacePressure: Double = 1.0133,
        waterDensity: Double = 1025.0
    ) -> Double {
        let deltaPressure = ambientPressure - surfacePressure // bar
        guard deltaPressure > 0 else { return 0 }
        // depth = ΔP / (ρ × g) ; convert bar → Pa (×100000)
        return (deltaPressure * 100_000.0) / (waterDensity * gravity)
    }

    /// - Parameters:
    ///   - depth: Depth in meters
    ///   - surfacePressure: Surface atmospheric pressure in bar
    ///   - waterDensity: Water density in kg/m³
    /// - Returns: Ambient pressure in bar
    public static func pressure(
        at depth: Double,
        surfacePressure: Double = 1.0133,
        waterDensity: Double = 1025.0
    ) -> Double {
        surfacePressure + (depth * waterDensity * gravity) / 100_000.0
    }
}
