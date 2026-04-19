import Foundation

// MARK: - Ceiling & NDL

extension BuhlmannEngine {

    // MARK: Ceiling

    /// First stop depth (m): deepest compartment ceiling using gfLow.
    /// This is the GF slope anchor depth.
    public func firstStopDepth(gfLow: Double) -> Double {
        var maxAmbient = surfacePressure
        for t in tissues {
            let p = t.tolerableAmbient(gf: gfLow)
            if p > maxAmbient { maxAmbient = p }
        }
        let depth = (maxAmbient - surfacePressure) * 100_000.0 / (waterDensity * 9.80665)
        return max(0.0, depth)
    }

    /// GF at a given depth, interpolating linearly from gfHigh (surface)
    /// down to gfLow (firstStop).
    public func gfAtDepth(_ depth: Double, gfLow: Double, gfHigh: Double, firstStop: Double) -> Double {
        guard firstStop > 0 else { return gfHigh }
        if depth >= firstStop { return gfLow }
        return gfHigh - (gfHigh - gfLow) * (depth / firstStop)
    }

    /// Ceiling depth (m) using the GF slope.  Returns 0 if no ceiling.
    /// Uses binary search for O(log n) precision to 0.01 m.
    public func ceiling(gfLow: Double, gfHigh: Double) -> Double {
        let first = firstStopDepth(gfLow: gfLow)

        // Binary search: find shallowest depth where every compartment is safe
        var lo = 0.0
        var hi = first + 3.0   // start just below first stop
        if hi < 0.1 { return 0.0 }

        // Quick check: are we already safe at surface?
        if isSafe(at: 0.0, gfLow: gfLow, gfHigh: gfHigh, firstStop: first) { return 0.0 }

        for _ in 0..<50 {   // 50 iterations → precision < 0.0001 m
            let mid = (lo + hi) / 2.0
            if isSafe(at: mid, gfLow: gfLow, gfHigh: gfHigh, firstStop: first) {
                hi = mid
            } else {
                lo = mid
            }
            if hi - lo < 0.001 { break }
        }
        // Round up to nearest 0.1 m
        let rawCeiling = hi
        return ceil(rawCeiling * 10.0) / 10.0
    }

    /// Returns true when all 16 compartments are safe at the given depth.
    private func isSafe(at depth: Double, gfLow: Double, gfHigh: Double, firstStop: Double) -> Bool {
        let pAmb = ambientPressure(depth: depth)
        let gf   = gfAtDepth(depth, gfLow: gfLow, gfHigh: gfHigh, firstStop: firstStop)
        for t in tissues {
            if t.pN2 + t.pHe > t.mValue(at: pAmb) * gf + pAmb * (1.0 - gf) {
                // Equivalent to: tolerableAmbient(gf) > pAmb
                // (Cheaper to re-check via mValue to avoid repeated blending)
                let pTol = t.tolerableAmbient(gf: gf)
                if pAmb < pTol { return false }
            }
        }
        return true
    }

    // MARK: NDL

    /// No-decompression limit (minutes) at the given depth and gas.
    /// NDL is the time remaining before a decompression ceiling appears —
    /// i.e., the point where the diver can no longer ascend directly to the surface.
    /// Uses a fixed gradient factor (gfHigh) for both gfLow and gfHigh (flat M-value slope).
    /// Returns 999 when NDL exceeds 999 minutes.
    public func ndl(depth: Double, gas: BuhlmannGas, gf: Double) -> Double {
        var sim = self    // value-type copy
        for minute in 1...999 {
            sim.addSegment(startDepth: depth, endDepth: depth, time: 1.0, gas: gas)
            // NDL expires when a decompression ceiling appears at the surface
            if sim.ceiling(gfLow: gf, gfHigh: gf) > 0 {
                return Double(minute - 1)
            }
        }
        return 999.0
    }
}

// MARK: - Decompression Stop Planning

extension BuhlmannEngine {

    /// Calculate a full decompression schedule using the GF slope.
    /// Returns an array of segments covering: any ascent legs, stop holds, and
    /// the final ascent to surface.
    ///
    /// - Parameters:
    ///   - gfLow:        Gradient factor at deepest stop (e.g. 0.40)
    ///   - gfHigh:       Gradient factor at surface (e.g. 0.85)
    ///   - currentDepth: Diver's current depth (m)
    ///   - bottomGas:    Gas currently being breathed
    ///   - decoGases:    List of available deco gases (sorted by O₂ desc, picked at MOD)
    ///   - config:       Ascent rate, stop increment, etc.
    public func calculateDecoStops(
        gfLow: Double,
        gfHigh: Double,
        currentDepth: Double,
        bottomGas: BuhlmannGas,
        decoGases: [BuhlmannGas],
        config: BuhlmannDecoConfig = .default
    ) throws -> [BuhlmannDiveSegment] {

        var sim = self
        var segments: [BuhlmannDiveSegment] = []
        var totalTime = 0.0
        var activeGas = bottomGas
        var usedDecoGases = Set<Int>()

        // Sort deco gases: highest O₂ first (best for deco)
        let sortedDecoGases = decoGases
            .enumerated()
            .sorted { $0.element.o2 > $1.element.o2 }

        var depth = currentDepth

        // Round current depth up to nearest stop increment
        let inc = config.stopIncrement
        var nextStop = Foundation.ceil(depth / inc) * inc
        if nextStop > depth { nextStop -= inc }   // start at or above current depth

        while depth > 0 {
            // ── Gas switch opportunity at this depth ──────────────────────
            for (idx, entry) in sortedDecoGases.enumerated() {
                guard !usedDecoGases.contains(idx) else { continue }
                let mod = entry.element.mod(surfacePressure: sim.surfacePressure)
                let switchDepth = Foundation.floor(mod / inc) * inc
                if depth <= switchDepth {
                    // 1 min stop on new gas (minimum gas-switch stop)
                    let switchSeg = BuhlmannDiveSegment(
                        startDepth: depth, endDepth: depth,
                        time: 1.0, gas: entry.element
                    )
                    sim.addSegment(startDepth: depth, endDepth: depth,
                                    time: 1.0, gas: entry.element)
                    segments.append(switchSeg)
                    totalTime += 1.0
                    activeGas = entry.element
                    usedDecoGases.insert(idx)
                }
            }

            // ── Ascend to next stop ───────────────────────────────────────
            let targetDepth = max(0.0, nextStop - inc)
            let ascentTime  = (depth - targetDepth) / config.ascentRate
            if ascentTime > 0 {
                let rate = depth <= 3.0 ? config.surfaceRate : config.ascentRate
                let adjustedTime = (depth - targetDepth) / rate
                segments.append(BuhlmannDiveSegment(
                    startDepth: depth, endDepth: targetDepth,
                    time: adjustedTime, gas: activeGas
                ))
                sim.addSegment(startDepth: depth, endDepth: targetDepth,
                                time: adjustedTime, gas: activeGas)
                totalTime += adjustedTime
            }
            depth = targetDepth

            if depth <= 0 { break }

            // ── Hold at stop until ceiling clears ────────────────────────
            var stopTime = 0.0
            while sim.ceiling(gfLow: gfLow, gfHigh: gfHigh) > depth - inc / 2.0 {
                sim.addSegment(startDepth: depth, endDepth: depth,
                                time: config.minStopTime, gas: activeGas)
                stopTime  += config.minStopTime
                totalTime += config.minStopTime
                if totalTime > config.maxTotalTime { throw BuhlmannError.maxDurationExceeded }
            }

            if stopTime > 0 {
                segments.append(BuhlmannDiveSegment(
                    startDepth: depth, endDepth: depth,
                    time: stopTime, gas: activeGas
                ))
            }

            nextStop = depth
        }

        return segments
    }

    // MARK: CCR Deco

    /// Calculate decompression schedule for CCR diving.
    public func calculateCCRDecoStops(
        gfLow: Double,
        gfHigh: Double,
        currentDepth: Double,
        diluent: BuhlmannGas,
        setpoint: Double,
        config: BuhlmannDecoConfig = .default
    ) throws -> [BuhlmannDiveSegment] {
        // For CCR, there are no switchable deco gases (loop handles O₂ automatically)
        // We model ascent on CCR using the diluent + setpoint until surface.
        var sim = self
        var segments: [BuhlmannDiveSegment] = []
        var totalTime = 0.0

        let inc = config.stopIncrement
        var depth = currentDepth
        var nextStop = Foundation.ceil(depth / inc) * inc
        if nextStop > depth { nextStop -= inc }

        while depth > 0 {
            let targetDepth = max(0.0, nextStop - inc)
            let rate = depth <= 3.0 ? config.surfaceRate : config.ascentRate
            let ascentTime = (depth - targetDepth) / rate
            if ascentTime > 0 {
                segments.append(BuhlmannDiveSegment(
                    startDepth: depth, endDepth: targetDepth,
                    time: ascentTime, gas: diluent  // approximate gas for segment record
                ))
                sim.addCCRSegment(startDepth: depth, endDepth: targetDepth,
                                   time: ascentTime, diluent: diluent, setpoint: setpoint)
                totalTime += ascentTime
            }
            depth = targetDepth
            if depth <= 0 { break }

            var stopTime = 0.0
            while sim.ceiling(gfLow: gfLow, gfHigh: gfHigh) > depth - inc / 2.0 {
                sim.addCCRSegment(startDepth: depth, endDepth: depth,
                                   time: config.minStopTime, diluent: diluent, setpoint: setpoint)
                stopTime  += config.minStopTime
                totalTime += config.minStopTime
                if totalTime > config.maxTotalTime { throw BuhlmannError.maxDurationExceeded }
            }
            if stopTime > 0 {
                segments.append(BuhlmannDiveSegment(
                    startDepth: depth, endDepth: depth,
                    time: stopTime, gas: diluent
                ))
            }
            nextStop = depth
        }

        return segments
    }
}
