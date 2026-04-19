import Foundation

/// Real-time snapshot of the dive computer state. Produced by DiveEngine every second.
public struct DiveState: Sendable {
    public let timestamp: Date
    public let depth: Double              // meters
    public let ascentRate: Double         // m/min (negative = descending)
    public let ndl: TimeInterval?         // seconds; nil means decompression required
    public let ceiling: Double?           // meters; nil means no ceiling
    public let decoStops: [DecoStop]
    public let tissueSaturation: [Double] // 16 compartments, 0.0–1.0+ (% of M-value)
    public let phase: DivePhase
    public let alerts: [SafetyAlert]
    public let bottomTime: TimeInterval   // seconds since dive start
    public let waterTemperature: Double?  // °C
    public let activeGas: GasInfo

    // MARK: - Extended fields (Phase C additions)

    /// Time To Surface in seconds. nil when no deco stops required.
    public let tts: TimeInterval?
    /// Current gradient factor % (0–100+). ≥100 means tissue exceeds M-value at current depth.
    public let gf99: Double
    /// Surface gradient factor %: what GF would be if diver surfaced immediately.
    public let surfGF: Double
    /// CNS oxygen toxicity % (0–100+). ≥80 = caution; ≥100 = emergency.
    public let cns: Double
    /// Cumulative OTU (oxygen tolerance units). ≥250 = caution; ≥300 = warning.
    public let otu: Double
    /// Current O₂ partial pressure in bar. ppO2 > 1.4 = caution; > 1.6 = critical.
    public let ppO2: Double
    /// True when an automatic safety stop is pending or active (NDL dive, max depth ≥ 10 m).
    public let safetyStopRequired: Bool
    /// Remaining safety-stop time in seconds. nil when not currently in a safety stop.
    public let safetyStopRemaining: TimeInterval?
    /// Running average depth in meters.
    public let averageDepth: Double

    // MARK: - Init

    public init(
        timestamp: Date,
        depth: Double,
        ascentRate: Double,
        ndl: TimeInterval?,
        ceiling: Double?,
        decoStops: [DecoStop],
        tissueSaturation: [Double],
        phase: DivePhase,
        alerts: [SafetyAlert],
        bottomTime: TimeInterval,
        waterTemperature: Double?,
        activeGas: GasInfo,
        tts: TimeInterval? = nil,
        gf99: Double = 0,
        surfGF: Double = 0,
        cns: Double = 0,
        otu: Double = 0,
        ppO2: Double = 0,
        safetyStopRequired: Bool = false,
        safetyStopRemaining: TimeInterval? = nil,
        averageDepth: Double = 0
    ) {
        self.timestamp = timestamp
        self.depth = depth
        self.ascentRate = ascentRate
        self.ndl = ndl
        self.ceiling = ceiling
        self.decoStops = decoStops
        self.tissueSaturation = tissueSaturation
        self.phase = phase
        self.alerts = alerts
        self.bottomTime = bottomTime
        self.waterTemperature = waterTemperature
        self.activeGas = activeGas
        self.tts = tts
        self.gf99 = gf99
        self.surfGF = surfGF
        self.cns = cns
        self.otu = otu
        self.ppO2 = ppO2
        self.safetyStopRequired = safetyStopRequired
        self.safetyStopRemaining = safetyStopRemaining
        self.averageDepth = averageDepth
    }

    // MARK: - Surface sentinel

    public static let surface = DiveState(
        timestamp: .now,
        depth: 0,
        ascentRate: 0,
        ndl: nil,
        ceiling: nil,
        decoStops: [],
        tissueSaturation: Array(repeating: 0, count: 16),
        phase: .surface,
        alerts: [],
        bottomTime: 0,
        waterTemperature: nil,
        activeGas: .air
    )
}

// MARK: - Phase

public enum DivePhase: Sendable {
    case surface
    case descent
    case bottom
    case ascent
    case safetyStop(remainingSeconds: Int)
    case decompression
}

// MARK: - DecoStop

public struct DecoStop: Sendable, Identifiable {
    public let id = UUID()
    public let depth: Double         // meters
    public let duration: TimeInterval // seconds
    public let gas: GasInfo
}

// MARK: - GasInfo

public struct GasInfo: Sendable {
    public let name: String
    public let o2Fraction: Double
    public let heFraction: Double
    public var n2Fraction: Double { 1.0 - o2Fraction - heFraction }
    public let maxOperatingDepth: Double // meters at ppO2 1.4

    public init(
        name: String,
        o2Fraction: Double,
        heFraction: Double,
        maxOperatingDepth: Double
    ) {
        self.name = name
        self.o2Fraction = o2Fraction
        self.heFraction = heFraction
        self.maxOperatingDepth = maxOperatingDepth
    }

    public static let air = GasInfo(
        name: "Air",
        o2Fraction: 0.21,
        heFraction: 0.0,
        maxOperatingDepth: (1.4 / 0.21 - 1.0) * 10.0  // ≈ 56.7 m
    )
}
