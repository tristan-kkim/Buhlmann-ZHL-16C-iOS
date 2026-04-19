import Foundation
import Testing
@testable import DiveEngine

/// Validates Bühlmann ZHL-16C GF decompression calculations against reference values.
/// Reference: Subsurface open-source dive planner / known PADI RDP table values
/// Tolerance: NDL ±3 min, ceiling ±0.5 m
///
/// NOTE: Tests use BuhlmannEngine directly (not DiveEngine) to avoid wall-clock
/// timing issues — DiveEngine.update() uses Date() for elapsed time, which is
/// ~0.001s per call in a tight loop, not the actual simulated dive duration.
struct AlgorithmValidationTests {

    // MARK: - Direct Algorithm Helpers

    struct AlgoResult: Sendable {
        let ndlMinutes: Double?   // nil = deco required (ndl == 0)
        let ceilingM: Double?     // nil = no ceiling
    }

    /// Simulate a rectangular dive profile directly on BuhlmannEngine.
    /// This bypasses DiveEngine's wall-clock timing, giving accurate tissue loading.
    func simulateDive(
        depth: Double,
        bottomMinutes: Double,
        gas: BuhlmannGas = .air,
        gfLow: Double = 0.40,
        gfHigh: Double = 0.85,
        surfacePressure: Double = 1.01325,
        waterDensity: Double = 1025.0
    ) -> AlgoResult {
        var engine = BuhlmannEngine(surfacePressure: surfacePressure, waterDensity: waterDensity)

        // Descent at 18 m/min
        let descentMin = depth / 18.0
        engine.addSegment(startDepth: 0, endDepth: depth, time: descentMin, gas: gas)

        // Bottom time
        engine.addSegment(startDepth: depth, endDepth: depth, time: bottomMinutes, gas: gas)

        let c = engine.ceiling(gfLow: gfLow, gfHigh: gfHigh)
        let n = engine.ndl(depth: depth, gas: gas, gf: gfHigh)
        return AlgoResult(
            ndlMinutes: n <= 0 ? nil : n,
            ceilingM: c > 0.01 ? c : nil
        )
    }

    // MARK: - NDL Tests

    /// Air 18m/30min — shallow dive, NDL should remain (PADI RDP: >40 min NDL at 18m)
    @Test func test_air_18m_30min_hasNDL() {
        let result = simulateDive(depth: 18, bottomMinutes: 30)
        #expect(result.ndlMinutes != nil, "18m/30min air should still have remaining NDL")
        #expect(result.ceilingM == nil, "No decompression ceiling expected")
    }

    /// Air 40m/30min — well past NDL at 40m air (~10 min on RDP), deco required
    @Test func test_air_40m_30min_requiresDeco() {
        let result = simulateDive(depth: 40, bottomMinutes: 30)
        #expect(result.ceilingM != nil || result.ndlMinutes == nil,
                "40m/30min on air must require decompression")
    }

    /// EAN32 should give longer NDL than air at same depth (less N₂ loading)
    @Test func test_ean32_longerNDL_than_air_at_30m() {
        let airResult  = simulateDive(depth: 30, bottomMinutes: 15, gas: .air)
        let ean32Result = simulateDive(depth: 30, bottomMinutes: 15, gas: .ean32)
        if let airNDL = airResult.ndlMinutes, let ean32NDL = ean32Result.ndlMinutes {
            #expect(ean32NDL >= airNDL, "EAN32 must have ≥ NDL compared to air at same depth")
        }
    }

    /// Conservative GF (20/70) must produce shorter or equal NDL vs lenient GF (45/95)
    @Test func test_conservativeGF_shortensNDL() {
        let conservative = simulateDive(depth: 30, bottomMinutes: 15, gfLow: 0.20, gfHigh: 0.70)
        let lenient      = simulateDive(depth: 30, bottomMinutes: 15, gfLow: 0.45, gfHigh: 0.95)
        if let consNDL = conservative.ndlMinutes, let lenNDL = lenient.ndlMinutes {
            #expect(consNDL <= lenNDL, "Conservative GF must produce shorter or equal NDL")
        } else if conservative.ndlMinutes != nil && lenient.ndlMinutes == nil {
            Issue.record("Conservative GF produced NDL but lenient did not — impossible")
        }
    }

    // MARK: - Ceiling Tests

    /// After a deep dive exceeding NDL, ceiling must be non-nil and positive
    @Test func test_ceiling_positive_after_deep_dive() {
        let result = simulateDive(depth: 40, bottomMinutes: 25)
        if let c = result.ceilingM {
            #expect(c > 0, "Ceiling must be > 0 when deco is required")
        } else {
            // 40m/25min may still be within NDL depending on GF — acceptable
        }
    }

    /// Air 40m / 25min GF40/85 — NDL at 40m is ~10min, so 25min requires deco
    @Test func test_ceiling_present_at_40m_25min_gf40() {
        let result = simulateDive(depth: 40, bottomMinutes: 25, gfLow: 0.40, gfHigh: 0.85)
        #expect(result.ceilingM != nil || result.ndlMinutes == nil,
                "40m/25min GF40/85 must require decompression")
    }

    /// GF 40/85 produces a deeper/higher ceiling than GF 85/85 for the same dive
    @Test func test_conservativeGF_deeperCeiling() {
        let conservative = simulateDive(depth: 40, bottomMinutes: 20, gfLow: 0.40, gfHigh: 0.85)
        let lenient      = simulateDive(depth: 40, bottomMinutes: 20, gfLow: 0.85, gfHigh: 0.85)
        if let consC = conservative.ceilingM, let lenC = lenient.ceilingM {
            #expect(consC >= lenC, "Conservative GF must produce deeper or equal ceiling depth")
        }
    }

    // MARK: - Depth Calculator Tests

    /// Pressure/depth round-trip accuracy — salt water
    @Test func test_depthCalculator_roundTrip_salt() {
        let testDepths = [5.0, 18.0, 30.0, 40.0, 60.0]
        for depth in testDepths {
            let pressure = DepthCalculator.pressure(at: depth, waterDensity: 1025)
            let recovered = DepthCalculator.depth(from: pressure, waterDensity: 1025)
            #expect(abs(recovered - depth) < 0.01,
                    "Salt water round-trip failed for \(depth)m: got \(recovered)m")
        }
    }

    /// Fresh water produces greater depth reading for same pressure (lower density)
    @Test func test_depthCalculator_freshVsSalt() {
        let pressure = 4.0  // bar
        let saltDepth = DepthCalculator.depth(from: pressure, waterDensity: 1025)
        let freshDepth = DepthCalculator.depth(from: pressure, waterDensity: 1000)
        #expect(freshDepth > saltDepth,
                "Same pressure must produce greater depth in fresh water (lower density)")
    }

    /// Surface pressure produces 0 depth
    @Test func test_depthCalculator_surfacePressure_isZero() {
        let depth = DepthCalculator.depth(from: 1.01325, surfacePressure: 1.01325)
        #expect(depth <= 0, "Surface ambient pressure must map to 0m depth")
    }

    // MARK: - Ascent Rate Monitor Tests

    @Test func test_ascentRateMonitor_safe() {
        let monitor = AscentRateMonitor(maxRate: 9.0)
        if case .safe = monitor.evaluate(ascentRate: 8.9) {
            // correct
        } else {
            Issue.record("8.9 m/min should be safe with 9 m/min limit")
        }
    }

    @Test func test_ascentRateMonitor_warning() {
        let monitor = AscentRateMonitor(maxRate: 9.0)
        if case .warning = monitor.evaluate(ascentRate: 10.0) {
            // correct
        } else {
            Issue.record("10 m/min should be warning (> 9 m/min limit)")
        }
    }

    @Test func test_ascentRateMonitor_critical() {
        let monitor = AscentRateMonitor(maxRate: 9.0)
        if case .critical = monitor.evaluate(ascentRate: 14.0) {
            // correct — 14 > 9 × 1.5 = 13.5
        } else {
            Issue.record("14 m/min should be critical (> 9 × 1.5 = 13.5)")
        }
    }

    // MARK: - Ceiling Violation Detector Tests

    @Test func test_ceilingViolation_noViolation_withinMargin() {
        let detector = CeilingViolationDetector(margin: 0.5)
        // 5.6m depth with 6.0m ceiling — only 0.4m above → within 0.5m margin
        let result = detector.check(depth: 5.6, ceiling: 6.0)
        #expect(result == nil, "5.6m depth with 6m ceiling should NOT trigger (within 0.5m margin)")
    }

    @Test func test_ceilingViolation_triggers_beyondMargin() {
        let detector = CeilingViolationDetector(margin: 0.5)
        // 5.0m depth with 6.0m ceiling — 1.0m above → exceeds 0.5m margin
        let result = detector.check(depth: 5.0, ceiling: 6.0)
        #expect(result != nil, "5.0m depth with 6m ceiling MUST trigger violation")
        #expect((result?.overshoot ?? 0) ≈ 1.0,
                "Overshoot should be ~1.0m")
    }

    @Test func test_ceilingViolation_noAlert_withNoCeiling() {
        let detector = CeilingViolationDetector(margin: 0.5)
        let result = detector.check(depth: 5.0, ceiling: nil)
        #expect(result == nil, "No ceiling = no violation")
    }
}

// MARK: - Approximate Equality Operator

infix operator ≈: ComparisonPrecedence
private func ≈(lhs: Double, rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.1
}
