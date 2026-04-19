import Foundation

/// Core dive computer engine.
/// Processes depth readings at 1 Hz and emits DiveState snapshots.
public actor DiveEngine {

    // MARK: - Configuration

    public struct Config: Sendable {
        public var gfLow: Double
        public var gfHigh: Double
        public var maxAscentRate: Double   // m/min; warn above this (industry standard: 10 m/min)
        public var surfacePressure: Double // bar
        public var waterDensity: Double    // kg/m³
        public var ppO2Warning: Double     // bar; default 1.4
        public var ppO2Critical: Double    // bar; default 1.6

        public init(
            gfLow: Double = 0.40,
            gfHigh: Double = 0.85,
            maxAscentRate: Double = 10.0,
            surfacePressure: Double = 1.01325,
            waterDensity: Double = 1025.0,
            ppO2Warning: Double = 1.4,
            ppO2Critical: Double = 1.6
        ) {
            self.gfLow = gfLow
            self.gfHigh = gfHigh
            self.maxAscentRate = maxAscentRate
            self.surfacePressure = surfacePressure
            self.waterDensity = waterDensity
            self.ppO2Warning = ppO2Warning
            self.ppO2Critical = ppO2Critical
        }
    }

    // MARK: - Persistent State

    public let config: Config
    private var buhlmann: BuhlmannWrapper
    private var oxygenTracker = OxygenToxicityTracker()
    private var activeGas: GasInfo = .air

    private var sessionStart: Date?
    private var previousDepth: Double = 0
    private var previousTimestamp: Date = .now
    private var ticksSinceDecoCalc: Int = 5
    private var cachedDecoStops: [DecoStop] = []
    private var alertThrottle: [Int: Date] = [:]
    private var bottomTime: TimeInterval = 0

    // Average depth (trapezoidal integration)
    private var depthTimeProduct: Double = 0

    // Safety stop state machine
    private var maxDepthReached: Double = 0
    private var safetyStopState: SafetyStopState = .notNeeded

    private enum SafetyStopState {
        case notNeeded     // max depth never ≥ 10 m
        case pending       // max depth ≥ 10 m, haven't reached 3–6 m yet
        case active(startTime: Date, accumulated: TimeInterval)  // in-window, timer running
        case paused(accumulated: TimeInterval)                   // out of window (too deep), timer paused
        case completed
    }

    private let safetyStopMinDepth: Double = 3.0
    private let safetyStopMaxDepth: Double = 6.0
    private let safetyStopDuration: TimeInterval = 180  // 3 minutes

    // OOAM: track start of ceiling violation for 3-minute threshold
    private var ceilingViolationStart: Date? = nil
    // NDL low: track last NDL minute when < 5 min alert fired (avoid repeating)
    private var ndlLowAlertFiredAt: Int = 99

    // MARK: - Init

    public init(config: Config = Config()) {
        self.config = config
        self.buhlmann = BuhlmannWrapper(
            gfLow: config.gfLow,
            gfHigh: config.gfHigh,
            surfacePressure: config.surfacePressure,
            waterDensity: config.waterDensity,
            ascentRate: config.maxAscentRate  // keeps DecoConfig in sync with user setting
        )
    }

    // MARK: - Session Control

    public func startDive() {
        sessionStart = .now
        previousDepth = 0
        previousTimestamp = .now   // reset so first update() tick doesn't use stale elapsed time
        bottomTime = 0
        depthTimeProduct = 0
        maxDepthReached = 0
        ticksSinceDecoCalc = 5
        cachedDecoStops = []
        alertThrottle = [:]
        safetyStopState = .notNeeded
        ceilingViolationStart = nil
        ndlLowAlertFiredAt = 99
        Task { await oxygenTracker.reset() }
    }

    public func endDive() {
        sessionStart = nil
    }

    public func switchGas(_ gasInfo: GasInfo) async throws {
        activeGas = gasInfo
        try await buhlmann.switchGas(o2: gasInfo.o2Fraction, he: gasInfo.heFraction)
    }

    /// Update surface pressure (e.g. when CMWaterSubmersionMeasurement delivers a fresh baseline).
    public func updateSurfacePressure(_ bar: Double) async {
        await buhlmann.updateSurfacePressure(bar)
    }

    /// Returns tissue compartment pressures for serialisation (residual nitrogen carry-over).
    public func snapshotTissues() async -> [(pN2: Double, pHe: Double)] {
        await buhlmann.compartmentSnapshot()
    }

    /// Restores tissue state from a previous dive, off-gassing for the given surface interval.
    public func loadTissueSnapshot(_ snapshot: [(pN2: Double, pHe: Double)],
                                    surfaceInterval: TimeInterval) async throws {
        await buhlmann.loadCompartments(snapshot, surfaceInterval: surfaceInterval)
    }

    // MARK: - Core 1 Hz Update

    public func update(depth: Double, waterTemperature: Double? = nil) async -> DiveState {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(previousTimestamp), 0.001)

        // Ascent rate (positive = ascending, negative = descending)
        let ascentRate = (previousDepth - depth) / (elapsed / 60.0)

        // Bottom time and average depth only accumulate when actually submerged (>= 1.0 m).
        // Pressing the Dive button at the surface must not start the timer.
        if sessionStart != nil && depth >= 1.0 {
            bottomTime += elapsed
            // Trapezoidal depth integration for average depth
            depthTimeProduct += (depth + previousDepth) / 2.0 * elapsed
        }

        // Track max depth
        if depth > maxDepthReached { maxDepthReached = depth }

        // Ambient pressure at current depth (bar)
        let ambientPressure = self.ambientPressure(at: depth)

        // Current O₂ partial pressure
        let ppO2 = activeGas.o2Fraction * ambientPressure

        // Feed Bühlmann engine with actual elapsed time (not a fixed 1-second tick).
        // This ensures accurate saturation at any sensor sample rate (1 Hz real device,
        // 10 Hz simulator, etc.).
        await buhlmann.addSegment(fromDepth: previousDepth, toDepth: depth, seconds: elapsed)
        previousDepth = depth
        previousTimestamp = now

        // Accumulate oxygen toxicity
        await oxygenTracker.addSegment(ppO2: ppO2, durationSeconds: elapsed)
        let cns = await oxygenTracker.cns
        let otu = await oxygenTracker.otu

        // NDL and ceiling (cheap, every second)
        let ndl = await buhlmann.ndl(at: depth)
        let ceiling = await buhlmann.ceiling()

        // Deco schedule (expensive, every 5 seconds).
        // Only compute when the diver is actually in decompression (ndl == nil or ceiling present).
        // calculateDecoStops() includes the safety stop at 3 m in its output even during
        // within-NDL dives, which would incorrectly trigger DECO mode. Clearing the cache
        // while NDL is positive prevents that false positive.
        ticksSinceDecoCalc += 1
        if ticksSinceDecoCalc >= 5 {
            ticksSinceDecoCalc = 0
            if ndl == nil || ceiling != nil {
                let stops = await buhlmann.decoSchedule(currentDepth: depth)
                cachedDecoStops = stops.map { DecoStop(depth: $0.depth, duration: $0.durationSeconds, gas: activeGas) }
            } else {
                cachedDecoStops = []
            }
        } else if ndl != nil && ceiling == nil {
            // Clear stale deco stops between 5-second recalc windows when back within NDL
            cachedDecoStops = []
        }

        // TTS — computed from cached deco stops
        let tts = calculateTTS(currentDepth: depth, stops: cachedDecoStops)

        // Tissue saturation (visualisation)
        let saturation = await buhlmann.tissueSaturation(surfacePressure: config.surfacePressure)

        // GF99 / SurfGF
        let gf99  = await buhlmann.gf99(ambientPressure: ambientPressure)
        let surfGF = await buhlmann.surfGF(surfacePressure: config.surfacePressure)

        // Average depth
        let averageDepth = bottomTime > 0 ? depthTimeProduct / bottomTime : depth

        // Safety stop state machine
        let (safetyStopRequired, safetyStopRemaining, safetyStopBroken) = updateSafetyStop(
            depth: depth,
            ceiling: ceiling,
            now: now
        )

        let phase = determinePhase(
            depth: depth,
            ascentRate: ascentRate,
            ceiling: ceiling,
            safetyStopRequired: safetyStopRequired,
            safetyStopRemaining: safetyStopRemaining
        )

        let alerts = evaluateAlerts(
            depth: depth,
            ascentRate: ascentRate,
            ndl: ndl,
            ceiling: ceiling,
            cns: cns,
            ppO2: ppO2,
            safetyStopBroken: safetyStopBroken,
            now: now
        )

        return DiveState(
            timestamp: now,
            depth: depth,
            ascentRate: ascentRate,
            ndl: ndl,
            ceiling: ceiling,
            decoStops: cachedDecoStops,
            tissueSaturation: saturation,
            phase: phase,
            alerts: alerts,
            bottomTime: bottomTime,
            waterTemperature: waterTemperature,
            activeGas: activeGas,
            tts: tts,
            gf99: gf99,
            surfGF: surfGF,
            cns: cns,
            otu: otu,
            ppO2: ppO2,
            safetyStopRequired: safetyStopRequired,
            safetyStopRemaining: safetyStopRemaining,
            averageDepth: averageDepth
        )
    }

    // MARK: - Safety Stop State Machine

    /// Returns (required, remainingSeconds, broken). `broken` = true when diver left active stop zone.
    private func updateSafetyStop(
        depth: Double,
        ceiling: Double?,
        now: Date
    ) -> (required: Bool, remaining: TimeInterval?, broken: Bool) {
        guard ceiling == nil else {
            return (false, nil, false)
        }

        switch safetyStopState {
        case .notNeeded:
            if maxDepthReached >= 10.0 { safetyStopState = .pending }
            return (false, nil, false)

        case .pending:
            if depth >= safetyStopMinDepth && depth <= safetyStopMaxDepth {
                safetyStopState = .active(startTime: now, accumulated: 0)
            }
            return (maxDepthReached >= 10.0, nil, false)

        case .active(startTime: let startTime, accumulated: let accumulated):
            let elapsed = now.timeIntervalSince(startTime)
            let total = accumulated + elapsed
            // Diver went deeper than stop zone — pause timer
            if depth > safetyStopMaxDepth {
                safetyStopState = .paused(accumulated: total)
                return (true, max(0, safetyStopDuration - total), false)
            }
            // Diver ascended above stop zone — safety stop broken (no penalty per spec)
            if depth < safetyStopMinDepth - 0.5 {
                safetyStopState = .pending
                return (true, nil, true)   // broken = true
            }
            let remaining = max(0, safetyStopDuration - total)
            if remaining == 0 {
                safetyStopState = .completed
                return (false, nil, false)
            }
            return (true, remaining, false)

        case .paused(let accumulated):
            // Resume timer when diver re-enters the safety stop window
            if depth >= safetyStopMinDepth && depth <= safetyStopMaxDepth {
                safetyStopState = .active(startTime: now, accumulated: accumulated)
            }
            return (true, max(0, safetyStopDuration - accumulated), false)

        case .completed:
            return (false, nil, false)
        }
    }

    // MARK: - Phase Detection

    private func determinePhase(
        depth: Double,
        ascentRate: Double,
        ceiling: Double?,
        safetyStopRequired: Bool,
        safetyStopRemaining: TimeInterval?
    ) -> DivePhase {
        guard sessionStart != nil else { return .surface }
        if depth < 0.3 { return .surface }

        if ceiling != nil || !cachedDecoStops.isEmpty { return .decompression }

        if let remaining = safetyStopRemaining {
            return .safetyStop(remainingSeconds: Int(remaining))
        }
        if safetyStopRequired && depth >= safetyStopMinDepth && depth <= safetyStopMaxDepth {
            return .safetyStop(remainingSeconds: Int(safetyStopDuration))
        }

        if ascentRate > 1.0 { return .ascent }
        if ascentRate < -1.0 { return .descent }
        return .bottom
    }

    // MARK: - TTS Calculation

    private func calculateTTS(currentDepth: Double, stops: [DecoStop]) -> TimeInterval? {
        guard !stops.isEmpty else { return nil }
        let ascentMPS = config.maxAscentRate / 60.0
        // Final few metres ascent at 3 m/min — matches DecoConfig.surfaceRate and
        // standard practice (PADI/SSI) for the last stop to surface segment.
        let surfaceMPS = 3.0 / 60.0

        // Sort stops deepest first
        let sorted = stops.sorted { $0.depth > $1.depth }
        var tts: TimeInterval = 0
        var prevDepth = currentDepth

        for stop in sorted {
            let travel = (prevDepth - stop.depth) / ascentMPS
            tts += travel + stop.duration
            prevDepth = stop.depth
        }
        // Final ascent from last stop to surface at slow surface rate
        tts += prevDepth / surfaceMPS
        return tts
    }

    // MARK: - Alert Evaluation

    private enum ThrottleKey: Int {
        case ascentRateWarning  = 0
        case ascentRateCritical = 1
        case ceilingViolation   = 2
        case decoRequired       = 3
        case oxygenToxicity     = 4
        case ppO2High           = 5
        case ooam               = 6
    }

    private func evaluateAlerts(
        depth: Double,
        ascentRate: Double,
        ndl: TimeInterval?,
        ceiling: Double?,
        cns: Double,
        ppO2: Double,
        safetyStopBroken: Bool,
        now: Date
    ) -> [SafetyAlert] {
        var alerts: [SafetyAlert] = []

        // Ascent rate (>maxRate warning, >1.5×maxRate critical — dive industry standard)
        if ascentRate > config.maxAscentRate {
            let isCritical = ascentRate > config.maxAscentRate * 1.5
            let key: ThrottleKey = isCritical ? .ascentRateCritical : .ascentRateWarning
            if throttleAllows(key: key, now: now, interval: isCritical ? 5 : 10) {
                alerts.append(SafetyAlert(
                    type: .ascentRate(current: ascentRate, max: config.maxAscentRate),
                    severity: isCritical ? .critical : .warning,
                    triggeredAt: now, depth: depth
                ))
            }
        }

        // Ceiling violation + OOAM (ceiling missed ≥ 3 min)
        // 0.6m hysteresis: alert only when diver is >0.6m below ceiling.
        // Intentional — reduces nuisance alerts from sensor noise at the ceiling boundary.
        if let ceil = ceiling, depth < ceil - 0.6 {
            if ceilingViolationStart == nil { ceilingViolationStart = now }
            let violationDuration = now.timeIntervalSince(ceilingViolationStart!)
            if throttleAllows(key: .ceilingViolation, now: now, interval: 5) {
                alerts.append(SafetyAlert(
                    type: .ceilingViolation(currentDepth: depth, ceiling: ceil),
                    severity: .critical, triggeredAt: now, depth: depth
                ))
            }
            // OOAM: ceiling missed ≥ 3 min
            if violationDuration >= 180 {
                if throttleAllows(key: .ooam, now: now, interval: 30) {
                    alerts.append(SafetyAlert(
                        type: .ooam, severity: .critical, triggeredAt: now, depth: depth
                    ))
                }
            }
        } else {
            ceilingViolationStart = nil   // reset when back below ceiling
        }

        // Decompression required
        if !cachedDecoStops.isEmpty {
            if throttleAllows(key: .decoRequired, now: now, interval: 30) {
                alerts.append(SafetyAlert(
                    type: .decoRequired, severity: .warning, triggeredAt: now, depth: depth
                ))
            }
        }

        // NDL < 5 min warning (once per each minute boundary: 5, 4, 3, 2, 1 min)
        if let ndl {
            let ndlMin = Int(ndl / 60)
            if ndlMin < 5 && ndlMin != ndlLowAlertFiredAt {
                ndlLowAlertFiredAt = ndlMin
                alerts.append(SafetyAlert(
                    type: .ndlLow(minutes: ndlMin), severity: .warning,
                    triggeredAt: now, depth: depth
                ))
            }
        } else {
            ndlLowAlertFiredAt = 99   // reset when in deco (ndl = nil)
        }

        // Safety stop broken
        if safetyStopBroken {
            alerts.append(SafetyAlert(
                type: .safetyStopBroken, severity: .warning, triggeredAt: now, depth: depth
            ))
        }

        // Oxygen toxicity (CNS 80%/100%)
        if cns >= 80 {
            if throttleAllows(key: .oxygenToxicity, now: now, interval: 60) {
                alerts.append(SafetyAlert(
                    type: .oxygenToxicity(cns: cns),
                    severity: cns >= 100 ? .critical : .warning,
                    triggeredAt: now, depth: depth
                ))
            }
        }

        // High ppO2 — thresholds from config (user-configurable)
        if ppO2 >= config.ppO2Warning {
            if throttleAllows(key: .ppO2High, now: now, interval: 15) {
                let limit = ppO2 >= config.ppO2Critical ? config.ppO2Critical : config.ppO2Warning
                alerts.append(SafetyAlert(
                    type: .ppO2High(ppO2: ppO2, limit: limit),
                    severity: ppO2 >= config.ppO2Critical ? .critical : .warning,
                    triggeredAt: now, depth: depth
                ))
            }
        }

        return alerts
    }

    private func throttleAllows(key: ThrottleKey, now: Date, interval: TimeInterval) -> Bool {
        if let last = alertThrottle[key.rawValue],
           now.timeIntervalSince(last) < interval { return false }
        alertThrottle[key.rawValue] = now
        return true
    }

    // MARK: - Helpers

    private func ambientPressure(at depth: Double) -> Double {
        // P = P_surface + ρgh / 100 000  (Pa → bar)
        config.surfacePressure + depth * config.waterDensity * 9.80665 / 100_000.0
    }
}
