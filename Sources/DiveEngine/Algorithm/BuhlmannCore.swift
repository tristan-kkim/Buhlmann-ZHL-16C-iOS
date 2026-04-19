import Foundation

// MARK: - Gas

/// An inert-gas mixture for Bühlmann calculations.
/// Fractions must sum to ≤ 1.0 (remainder is O₂).
public struct BuhlmannGas: Sendable, Equatable {
    /// O₂ fraction (0.0–1.0)
    public let o2: Double
    /// He fraction (0.0–1.0)
    public let he: Double
    /// N₂ fraction (derived)
    public var n2: Double { max(0.0, 1.0 - o2 - he) }

    public init(o2: Double, he: Double = 0.0) {
        self.o2 = o2
        self.he = he
    }

    public static let air     = BuhlmannGas(o2: 0.21, he: 0.0)
    public static let ean32   = BuhlmannGas(o2: 0.32, he: 0.0)
    public static let ean50   = BuhlmannGas(o2: 0.50, he: 0.0)
    public static let oxygen  = BuhlmannGas(o2: 1.00, he: 0.0)

    /// Maximum operating depth (m) at given ppO₂ limit (default 1.4 bar)
    public func mod(ppO2Limit: Double = 1.4, surfacePressure: Double = 1.01325) -> Double {
        guard o2 > 0 else { return 0 }
        return ((ppO2Limit / o2) - 1.0) * 10.0 * (1.01325 / surfacePressure)
    }
}

// MARK: - Deco Config

/// Parameters controlling the decompression stop calculation algorithm.
public struct BuhlmannDecoConfig: Sendable {
    /// Ascent rate between stops (m/min). Default: 9 m/min (PADI/SSI standard).
    public let ascentRate: Double
    /// Ascent rate for the last 3 m to surface (m/min). Default: 3 m/min.
    public let surfaceRate: Double
    /// Depth increment between stops (m). Default: 3 m.
    public let stopIncrement: Double
    /// Minimum stop time (minutes). Default: 1 min.
    public let minStopTime: Double
    /// Maximum total deco time before throwing (minutes). Default: 1440 (24 h).
    public let maxTotalTime: Double

    public init(
        ascentRate: Double = 9.0,
        surfaceRate: Double = 3.0,
        stopIncrement: Double = 3.0,
        minStopTime: Double = 1.0,
        maxTotalTime: Double = 1440.0
    ) {
        self.ascentRate    = ascentRate
        self.surfaceRate   = surfaceRate
        self.stopIncrement = stopIncrement
        self.minStopTime   = minStopTime
        self.maxTotalTime  = maxTotalTime
    }

    public static let `default` = BuhlmannDecoConfig()
}

// MARK: - Dive Segment

/// A planned segment used in decompression schedules.
public struct BuhlmannDiveSegment: Sendable {
    public let startDepth: Double  // m
    public let endDepth:   Double  // m
    public let time:       Double  // minutes
    public let gas:        BuhlmannGas
}

// MARK: - Error

public enum BuhlmannError: Error, Sendable {
    case maxDurationExceeded
    case invalidGas
}

// MARK: - BuhlmannEngine

/// Core Bühlmann ZHL-16C decompression engine.
/// Holds the 16 tissue compartments and the ambient pressure reference.
/// This struct is value-type and not thread-safe by itself;
/// thread safety is handled by the surrounding `BuhlmannWrapper` actor.
public struct BuhlmannEngine: Sendable {

    // ── State ─────────────────────────────────────────────────────────────
    var tissues: [BuhlmannTissue]   // always 16 compartments
    public let surfacePressure: Double     // bar (≈ 1.01325 at sea level)
    public let waterDensity: Double        // kg/m³ (salt ≈ 1025, fresh ≈ 1000)

    // MARK: - Initializers

    /// Create a fresh engine with tissues at surface equilibrium breathing air.
    public init(surfacePressure: Double = 1.01325, waterDensity: Double = 1025.0) {
        self.surfacePressure = surfacePressure
        self.waterDensity    = waterDensity
        self.tissues = BuhlmannTissue.createAll(surfacePressure: surfacePressure)
    }

    /// Restore a previous tissue state (for surface interval off-gassing).
    init(
        tissues: [BuhlmannTissue],
        surfacePressure: Double,
        waterDensity: Double
    ) {
        self.tissues         = tissues
        self.surfacePressure = surfacePressure
        self.waterDensity    = waterDensity
    }

    // MARK: - Pressure Conversion

    /// Convert depth (m) to absolute ambient pressure (bar).
    /// Formula: P = surfacePressure + ρ·g·h (in bar)
    public func ambientPressure(depth: Double) -> Double {
        surfacePressure + depth * waterDensity * 9.80665 / 100_000.0
    }

    // MARK: - Segment Processing

    /// Add an open-circuit segment, updating all 16 tissue compartments.
    public mutating func addSegment(
        startDepth: Double,
        endDepth: Double,
        time: Double,        // minutes
        gas: BuhlmannGas
    ) {
        guard time > 0 else { return }
        let pStart = ambientPressure(depth: startDepth)
        let pEnd   = ambientPressure(depth: endDepth)
        for i in tissues.indices {
            tissues[i].addSegment(pAmbStart: pStart, pAmbEnd: pEnd, minutes: time, gas: gas)
        }
    }

    /// Add a CCR (closed-circuit rebreather) segment.
    /// The effective N₂ and He fractions are computed from the diluent and
    /// the metabolic O₂ consumption implied by the setpoint.
    ///
    /// fO₂_eff = setpoint / P_amb  (fraction of O₂ in notional breathing loop gas)
    /// The remaining gas is split between He and N₂ in the same ratio as the diluent.
    public mutating func addCCRSegment(
        startDepth: Double,
        endDepth: Double,
        time: Double,       // minutes
        diluent: BuhlmannGas,
        setpoint: Double    // ppO₂ (bar)
    ) {
        guard time > 0 else { return }
        // Compute average ambient pressure for the segment
        let pStart = ambientPressure(depth: startDepth)
        let pEnd   = ambientPressure(depth: endDepth)
        let pAvg   = (pStart + pEnd) / 2.0

        // O₂ fraction delivered by the loop at this ambient pressure
        let fO2 = min(setpoint / max(pAvg, 0.01), 1.0)
        // Remaining fraction for inert gases
        let inert  = max(0.0, 1.0 - fO2)
        // Split inert between N₂ and He per diluent ratio
        let dilInert = diluent.n2 + diluent.he
        let fN2  = dilInert > 1e-10 ? inert * diluent.n2 / dilInert : inert
        let fHe  = dilInert > 1e-10 ? inert * diluent.he / dilInert : 0.0
        let ccrGas = BuhlmannGas(o2: fO2, he: fHe)
        // (n2 is derived as 1 - o2 - he = fN2 as long as fractions sum correctly)
        _ = fN2 // used implicitly via BuhlmannGas.n2

        for i in tissues.indices {
            tissues[i].addSegment(pAmbStart: pStart, pAmbEnd: pEnd, minutes: time, gas: ccrGas)
        }
    }

    // MARK: - Tissue Snapshot

    /// Extract (pN₂, pHe) pairs for all 16 compartments — used for serialisation.
    func compartmentSnapshot() -> [(pN2: Double, pHe: Double)] {
        tissues.map { (pN2: $0.pN2, pHe: $0.pHe) }
    }

    /// Restore tissue state from a snapshot and run a surface-interval off-gas segment.
    mutating func restoreSnapshot(
        _ snapshot: [(pN2: Double, pHe: Double)],
        surfaceInterval: Double   // seconds
    ) {
        for i in 0..<min(tissues.count, snapshot.count) {
            tissues[i].pN2 = snapshot[i].pN2
            tissues[i].pHe = snapshot[i].pHe
        }
        let minutes = surfaceInterval / 60.0
        if minutes > 0 {
            addSegment(startDepth: 0, endDepth: 0, time: minutes, gas: .air)
        }
    }

    // MARK: - GF Metrics

    /// GF99: current gradient factor percentage at given ambient pressure.
    /// = max over compartments of (pInert − P_amb) / (M_value(P_amb) − P_amb) × 100.
    /// Returns 0 when all compartments are undersaturated at this depth.
    func gf99(ambientPressure pAmb: Double) -> Double {
        var maxGF = 0.0
        for t in tissues {
            let pI   = t.pN2 + t.pHe
            let mVal = t.mValue(at: pAmb)
            let denom = mVal - pAmb
            guard denom > 1e-10 else { continue }
            let gf = (pI - pAmb) / denom * 100.0
            if gf > maxGF { maxGF = gf }
        }
        return max(0, maxGF)
    }

    /// SurfGF: GF% if the diver ascended directly to the surface right now.
    func surfGF() -> Double {
        gf99(ambientPressure: surfacePressure)
    }

    /// Tissue saturation (0–1+) relative to M-value at surface — for bar-graph display.
    func tissueSaturation() -> [Double] {
        let pSurf = surfacePressure
        return tissues.map { t in
            let mVal = t.mValue(at: pSurf)
            guard mVal > 1e-10 else { return 0.0 }
            return (t.pN2 + t.pHe) / mVal
        }
    }
}
