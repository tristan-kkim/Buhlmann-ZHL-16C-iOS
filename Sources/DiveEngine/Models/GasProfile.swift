import Foundation
import SwiftData

/// Persistent gas mixture profile stored in SwiftData.
@Model
public final class GasProfile {
    public var id: UUID
    public var name: String
    public var oxygenFraction: Double   // 0.0–1.0
    public var heliumFraction: Double   // 0.0–1.0 (0 for air/nitrox)
    public var isActive: Bool           // currently selected gas
    public var createdAt: Date

    public var nitrogenFraction: Double { 1.0 - oxygenFraction - heliumFraction }

    /// Max operating depth at ppO2 1.4 bar (meters)
    public var maxOperatingDepth: Double {
        (1.4 / oxygenFraction - 1.0) * 10.0
    }

    /// Max operating depth at ppO2 1.6 bar (meters, contingency)
    public var contingencyMOD: Double {
        (1.6 / oxygenFraction - 1.0) * 10.0
    }

    public var gasInfo: GasInfo {
        GasInfo(
            name: name,
            o2Fraction: oxygenFraction,
            heFraction: heliumFraction,
            maxOperatingDepth: maxOperatingDepth
        )
    }

    public init(
        name: String,
        oxygenFraction: Double,
        heliumFraction: Double = 0.0,
        isActive: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.oxygenFraction = oxygenFraction
        self.heliumFraction = heliumFraction
        self.isActive = isActive
        self.createdAt = .now
    }

    // MARK: - Presets

    public static var air: GasProfile {
        GasProfile(name: "Air", oxygenFraction: 0.21, isActive: true)
    }

    public static var ean32: GasProfile {
        GasProfile(name: "EAN32", oxygenFraction: 0.32)
    }

    public static var ean36: GasProfile {
        GasProfile(name: "EAN36", oxygenFraction: 0.36)
    }

    public static var ean50: GasProfile {
        GasProfile(name: "EAN50", oxygenFraction: 0.50)
    }

    public static var oxygen: GasProfile {
        GasProfile(name: "O₂ 100%", oxygenFraction: 1.0)
    }
}
