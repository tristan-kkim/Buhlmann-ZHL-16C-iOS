import Foundation
import SwiftData

/// A complete recorded dive session.
@Model
public final class DiveSession {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date?
    public var maxDepth: Double           // meters
    public var bottomTime: TimeInterval   // seconds
    public var waterTemperature: Double?  // °C
    public var gfLow: Double
    public var gfHigh: Double
    public var waterType: WaterType
    public var notes: String?
    public var safetyAlertCount: Int

    // GPS — entry point recorded at dive start; exit point recorded on surface
    public var startLatitude: Double?
    public var startLongitude: Double?
    public var endLatitude: Double?
    public var endLongitude: Double?

    // Weather snapshot at dive time (fetched from Open-Meteo on first view)
    public var weatherTempC: Double?        // °C
    public var weatherWindKph: Double?      // km/h
    public var weatherWindBearing: Double?  // 0–360°
    public var weatherCode: Int?            // WMO code
    public var waveHeightM: Double?         // m
    public var waveDirectionDeg: Double?    // 0–360°
    public var wavePeriodSec: Double?       // seconds

    // Tidal conditions at dive time (fetched from Open-Meteo Marine)
    public var tideStatusAtDive: String?   // "Rising" / "Falling" / "High" / "Low"
    public var tideHeightAtDive: Double?   // metres relative to MSL
    public var tideNextHighTime: Date?
    public var tideNextHighM: Double?
    public var tideNextLowTime: Date?
    public var tideNextLowM: Double?

    @Relationship(deleteRule: .cascade)
    public var readings: [DiveReading] = []

    public enum WaterType: String, Codable, Sendable, CaseIterable {
        case salt    = "salt"
        case fresh   = "fresh"
        case en13319 = "en13319"  // EN 13319 standard water: 1020 kg/m³

        public var density: Double {
            switch self {
            case .salt:    return 1025.0 // kg/m³
            case .fresh:   return 1000.0
            case .en13319: return 1020.0 // EN 13319 standard
            }
        }
    }

    public var duration: TimeInterval? {
        guard let end = endDate else { return nil }
        return end.timeIntervalSince(startDate)
    }

    public var isActive: Bool { endDate == nil }

    public init(
        gfLow: Double = 0.35,
        gfHigh: Double = 0.75,
        waterType: WaterType = .salt
    ) {
        self.id = UUID()
        self.startDate = .now
        self.maxDepth = 0
        self.bottomTime = 0
        self.gfLow = gfLow
        self.gfHigh = gfHigh
        self.waterType = waterType
        self.safetyAlertCount = 0
    }
}

/// A single depth reading recorded every second.
@Model
public final class DiveReading {
    public var id: UUID
    public var timestamp: Date
    public var depth: Double            // meters
    public var ascentRate: Double       // m/min
    public var ndl: TimeInterval?       // nil = deco required
    public var ceiling: Double?         // nil = no ceiling
    public var ambientPressure: Double  // bar

    public init(
        timestamp: Date,
        depth: Double,
        ascentRate: Double,
        ndl: TimeInterval?,
        ceiling: Double?,
        ambientPressure: Double
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.depth = depth
        self.ascentRate = ascentRate
        self.ndl = ndl
        self.ceiling = ceiling
        self.ambientPressure = ambientPressure
    }
}
