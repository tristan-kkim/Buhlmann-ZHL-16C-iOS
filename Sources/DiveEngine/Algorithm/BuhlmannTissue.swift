import Foundation

// MARK: - ZHL-16C Standard Compartment Table

/// One of 16 parallel tissue compartments in the Bühlmann ZHL-16C model.
/// Stores the current inert gas partial pressures and the fixed physiological
/// constants for that compartment.
struct BuhlmannTissue: Sendable {

    // ── Current tissue gas tensions ──────────────────────────────────────
    var pN2: Double   // N₂ partial pressure in tissue (bar)
    var pHe: Double   // He partial pressure in tissue (bar)

    // ── Compartment constants (Bühlmann ZHL-16C, 1995) ───────────────────
    let n2HalfTime: Double  // minutes
    let n2A: Double         // bar
    let n2B: Double         // dimensionless
    let heHalfTime: Double  // minutes
    let heA: Double         // bar
    let heB: Double         // dimensionless

    // ── Constants ────────────────────────────────────────────────────────

    /// Alveolar water vapour pressure (bar). Constant for human lungs.
    static let waterVapour: Double = 0.0627

    // MARK: - Schreiner Equation

    /// Update one gas compartment for a segment using the Schreiner equation.
    /// Handles both constant-depth (R == 0) and linear ramp segments.
    ///
    /// P(t) = Palv₀ + R·(t − 1/k) − (Palv₀ − Pi₀ − R/k)·e^(−kt)
    ///
    /// - Parameters:
    ///   - pAmbStart: Ambient pressure at start of segment (bar)
    ///   - pAmbEnd:   Ambient pressure at end of segment (bar)
    ///   - minutes:   Segment duration (minutes)
    ///   - fraction:  Gas fraction for this inert gas (e.g. 0.79 for N₂ in air)
    ///   - halfTime:  Compartment half-time (minutes)
    ///   - pInitial:  Initial tissue partial pressure for this gas (bar)
    /// - Returns: New tissue partial pressure after the segment.
    static func schreiner(
        pAmbStart: Double,
        pAmbEnd: Double,
        minutes: Double,
        fraction: Double,
        halfTime: Double,
        pInitial: Double
    ) -> Double {
        guard minutes > 0, fraction > 0 else { return pInitial }

        let k     = Foundation.log(2.0) / halfTime
        let pAlv0 = (pAmbStart - waterVapour) * fraction
        let pAlv1 = (pAmbEnd   - waterVapour) * fraction
        let R     = (pAlv1 - pAlv0) / minutes   // rate of change (bar/min)

        // Constant-depth shorthand (Haldane formula) avoids R/k division-by-zero risk
        if abs(R) < 1e-10 {
            return pAlv0 + (pInitial - pAlv0) * Foundation.exp(-k * minutes)
        }

        return pAlv0 + R * (minutes - 1.0 / k)
             - (pAlv0 - pInitial - R / k) * Foundation.exp(-k * minutes)
    }

    // MARK: - Segment Update

    /// Update both N₂ and He partial pressures for a segment.
    mutating func addSegment(
        pAmbStart: Double,
        pAmbEnd: Double,
        minutes: Double,
        gas: BuhlmannGas
    ) {
        pN2 = BuhlmannTissue.schreiner(
            pAmbStart: pAmbStart,
            pAmbEnd:   pAmbEnd,
            minutes:   minutes,
            fraction:  gas.n2,
            halfTime:  n2HalfTime,
            pInitial:  pN2
        )
        pHe = BuhlmannTissue.schreiner(
            pAmbStart: pAmbStart,
            pAmbEnd:   pAmbEnd,
            minutes:   minutes,
            fraction:  gas.he,
            halfTime:  heHalfTime,
            pInitial:  pHe
        )
    }

    // MARK: - M-value (blended for mixed N₂/He)

    /// Effective a and b constants, weighted by current N₂/He partial pressures.
    var blendedA: Double {
        let total = pN2 + pHe
        guard total > 1e-10 else { return n2A }
        return (n2A * pN2 + heA * pHe) / total
    }

    var blendedB: Double {
        let total = pN2 + pHe
        guard total > 1e-10 else { return n2B }
        return (n2B * pN2 + heB * pHe) / total
    }

    /// Bühlmann M-value at a given ambient pressure (bar).
    /// A compartment is safe when (pN₂ + pHe) ≤ mValue(ambient).
    func mValue(at ambient: Double) -> Double {
        ambient / blendedB + blendedA
    }

    /// Tolerable ambient pressure (bar) for a given gradient factor.
    ///
    /// Derived from the GF ceiling condition:
    ///   (P_i − P_amb) = GF × (M(P_amb) − P_amb)
    /// Solving for P_amb:
    ///   P_amb = (P_i − GF × a) × b / ((1 − GF) × b + GF)
    func tolerableAmbient(gf: Double) -> Double {
        let pI  = pN2 + pHe
        let a   = blendedA
        let b   = blendedB
        let num = pI - gf * a
        let den = (1.0 - gf) * b + gf
        guard den > 1e-10 else { return 0.0 }
        return num * b / den
    }
}

// MARK: - Standard ZHL-16C Compartment Factory

extension BuhlmannTissue {
    /// Initialise all 16 ZHL-16C compartments at surface equilibrium breathing air.
    static func createAll(surfacePressure: Double = 1.01325) -> [BuhlmannTissue] {
        let airN2 = BuhlmannGas.air.n2
        let initialPN2 = (surfacePressure - waterVapour) * airN2

        return zhl16cTable.map { row in
            BuhlmannTissue(
                pN2: initialPN2,
                pHe: 0.0,
                n2HalfTime: row.0,
                n2A:        row.1,
                n2B:        row.2,
                heHalfTime: row.3,
                heA:        row.4,
                heB:        row.5
            )
        }
    }

    // ZHL-16C standard values (Bühlmann, 1995)
    // (n2HalfTime, n2A, n2B, heHalfTime, heA, heB)
    private static let zhl16cTable: [(Double, Double, Double, Double, Double, Double)] = [
        (  5.0,  1.1696, 0.5578,   1.88, 1.6189, 0.4770),
        (  8.0,  1.0000, 0.6514,   3.02, 1.3830, 0.5747),
        ( 12.5,  0.8618, 0.7222,   4.72, 1.1919, 0.6527),
        ( 18.5,  0.7562, 0.7825,   6.99, 1.0458, 0.7223),
        ( 27.0,  0.6200, 0.8126,  10.21, 0.9220, 0.7582),
        ( 38.3,  0.5043, 0.8434,  14.48, 0.8205, 0.7957),
        ( 54.3,  0.4410, 0.8693,  20.53, 0.7305, 0.8279),
        ( 77.0,  0.4000, 0.8910,  29.11, 0.6502, 0.8553),
        (109.0,  0.3750, 0.9092,  41.20, 0.5950, 0.8757),
        (146.0,  0.3500, 0.9222,  55.19, 0.5545, 0.8903),
        (187.0,  0.3295, 0.9319,  70.69, 0.5333, 0.8997),
        (239.0,  0.3065, 0.9403,  90.34, 0.5189, 0.9073),
        (305.0,  0.2835, 0.9477, 115.29, 0.5181, 0.9122),
        (390.0,  0.2610, 0.9544, 147.42, 0.5176, 0.9171),
        (498.0,  0.2480, 0.9602, 188.24, 0.5172, 0.9217),
        (635.0,  0.2327, 0.9653, 240.03, 0.5119, 0.9267),
    ]
}
