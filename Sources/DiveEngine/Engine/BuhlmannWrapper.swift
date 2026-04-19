import Foundation

// No external imports — Bühlmann ZHL-16C is implemented natively in Algorithm/

/// Facade isolating the BuhlmannEngine from the rest of DiveEngine.
/// BuhlmannEngine is a mutating struct — this actor owns the only copy,
/// ensuring all mutations happen serially with no data races.
actor BuhlmannWrapper {
    private var engine: BuhlmannEngine
    private var currentGas: BuhlmannGas
    private let decoConfig: BuhlmannDecoConfig
    private let gfLow: Double
    private let gfHigh: Double
    private var storedSurfacePressure: Double
    private let storedWaterDensity: Double

    // MARK: - Init

    init(
        gfLow: Double,
        gfHigh: Double,
        surfacePressure: Double,
        waterDensity: Double,
        ascentRate: Double = 9.0
    ) {
        self.gfLow  = gfLow
        self.gfHigh = gfHigh
        self.storedSurfacePressure = surfacePressure
        self.storedWaterDensity    = waterDensity
        self.engine = BuhlmannEngine(
            surfacePressure: surfacePressure,
            waterDensity:    waterDensity
        )
        self.currentGas = .air
        self.decoConfig = BuhlmannDecoConfig(ascentRate: ascentRate, surfaceRate: 3.0)
    }

    // MARK: - Configuration

    func updateSurfacePressure(_ bar: Double) {
        storedSurfacePressure = bar
        // Carry over compartment state — only change the pressure reference
        let snapshot = engine.tissues
        engine = BuhlmannEngine(
            tissues:         snapshot,
            surfacePressure: bar,
            waterDensity:    storedWaterDensity
        )
    }

    // MARK: - Tissue Snapshot (residual nitrogen carry-over)

    /// Returns current compartment pN₂/pHe values for serialisation.
    func compartmentSnapshot() -> [(pN2: Double, pHe: Double)] {
        engine.compartmentSnapshot()
    }

    /// Restores tissue state from a snapshot and off-gases for the given surface interval.
    func loadCompartments(_ snapshot: [(pN2: Double, pHe: Double)], surfaceInterval: TimeInterval) {
        var tissues = BuhlmannTissue.createAll(surfacePressure: storedSurfacePressure)
        for i in 0..<min(tissues.count, snapshot.count) {
            tissues[i].pN2 = snapshot[i].pN2
            tissues[i].pHe = snapshot[i].pHe
        }
        engine = BuhlmannEngine(
            tissues:         tissues,
            surfacePressure: storedSurfacePressure,
            waterDensity:    storedWaterDensity
        )
        let minutes = surfaceInterval / 60.0
        if minutes > 0 {
            engine.addSegment(startDepth: 0, endDepth: 0, time: minutes, gas: .air)
        }
    }

    // MARK: - Gas Management

    func switchGas(o2: Double, he: Double) throws {
        guard o2 + he <= 1.0, o2 >= 0, he >= 0 else { throw BuhlmannError.invalidGas }
        self.currentGas = BuhlmannGas(o2: o2, he: he)
    }

    // MARK: - Segment Processing

    /// Add a segment using the actual elapsed duration (seconds).
    func addSegment(fromDepth: Double, toDepth: Double, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        engine.addSegment(
            startDepth: fromDepth,
            endDepth:   toDepth,
            time:       seconds / 60.0,
            gas:        currentGas
        )
    }

    /// Convenience: add exactly one second (legacy/test use).
    func addSecondSegment(fromDepth: Double, toDepth: Double) {
        addSegment(fromDepth: fromDepth, toDepth: toDepth, seconds: 1.0)
    }

    // MARK: - Queries

    /// Returns NDL in seconds, or nil if deco required (library returns 999 for unlimited NDL).
    func ndl(at depth: Double) -> TimeInterval? {
        let minutes = engine.ndl(depth: depth, gas: currentGas, gf: gfHigh)
        if minutes <= 0 { return nil }
        if minutes >= 999 { return TimeInterval(999 * 60) }
        return TimeInterval(minutes * 60.0)
    }

    /// Returns ceiling depth in metres, or nil if no ceiling.
    func ceiling() -> Double? {
        let c = engine.ceiling(gfLow: gfLow, gfHigh: gfHigh)
        return c > 0.01 ? c : nil
    }

    /// Calculate decompression schedule — single gas (OC).
    /// EXPENSIVE: call every 5 seconds only.
    func decoSchedule(currentDepth: Double) -> [DecoStopInfo] {
        guard let stops = try? engine.calculateDecoStops(
            gfLow:        gfLow,
            gfHigh:       gfHigh,
            currentDepth: currentDepth,
            bottomGas:    currentGas,
            decoGases:    [],
            config:       decoConfig
        ) else { return [] }

        return stops
            .filter { abs($0.startDepth - $0.endDepth) < 0.01 && $0.startDepth > 0.01 }
            .map { DecoStopInfo(depth: $0.startDepth, durationSeconds: $0.time * 60.0) }
    }

    /// Multi-gas deco schedule — for technical diving.
    func multiGasDecoSchedule(currentDepth: Double, bottomGas: BuhlmannGas, decoGases: [BuhlmannGas]) -> [DecoStopInfo] {
        guard let stops = try? engine.calculateDecoStops(
            gfLow:        gfLow,
            gfHigh:       gfHigh,
            currentDepth: currentDepth,
            bottomGas:    bottomGas,
            decoGases:    decoGases,
            config:       decoConfig
        ) else { return [] }

        return stops
            .filter { abs($0.startDepth - $0.endDepth) < 0.01 && $0.startDepth > 0.01 }
            .map { DecoStopInfo(depth: $0.startDepth, durationSeconds: $0.time * 60.0) }
    }

    /// Tissue saturation snapshot (16 compartments).
    /// Returns ratio of total inert gas load to M-value at surface (0.0–1.0+).
    func tissueSaturation(surfacePressure: Double) -> [Double] {
        engine.tissueSaturation()
    }

    // MARK: - Gradient Factor Metrics

    /// GF99: current GF percentage at the given ambient pressure.
    func gf99(ambientPressure: Double) -> Double {
        engine.gf99(ambientPressure: ambientPressure)
    }

    /// SurfGF: GF percentage if the diver surfaces immediately.
    func surfGF(surfacePressure: Double) -> Double {
        engine.surfGF()
    }

    // MARK: - CCR Support

    func addCCRSecondSegment(fromDepth: Double, toDepth: Double, diluent: BuhlmannGas, setpoint: Double) {
        engine.addCCRSegment(
            startDepth: fromDepth,
            endDepth:   toDepth,
            time:       1.0 / 60.0,
            diluent:    diluent,
            setpoint:   setpoint
        )
    }

    func ccrDecoSchedule(currentDepth: Double, diluent: BuhlmannGas, setpoint: Double) -> [DecoStopInfo] {
        guard let stops = try? engine.calculateCCRDecoStops(
            gfLow:        gfLow,
            gfHigh:       gfHigh,
            currentDepth: currentDepth,
            diluent:      diluent,
            setpoint:     setpoint,
            config:       decoConfig
        ) else { return [] }

        return stops
            .filter { abs($0.startDepth - $0.endDepth) < 0.01 && $0.startDepth > 0.01 }
            .map { DecoStopInfo(depth: $0.startDepth, durationSeconds: $0.time * 60.0) }
    }
}

/// Simplified deco stop — the external interface used by DiveEngine and UI.
struct DecoStopInfo: Sendable {
    let depth: Double           // metres
    let durationSeconds: Double
}
