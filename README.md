# DiveEngine

A pure Swift implementation of the **Bühlmann ZHL-16C GF** decompression algorithm — the same algorithm used in professional dive computers (Shearwater, Suunto, Garmin).  
No external dependencies. Runs natively on Apple platforms.

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-watchOS%2010%20%7C%20iOS%2017%20%7C%20macOS%2014-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Overview

DiveEngine provides:

| Feature | Details |
|---------|---------|
| **Decompression model** | Bühlmann ZHL-16C, 16 compartments (Bühlmann 1995) |
| **Gradient factors** | Full GF Low / GF High slope (Wienke 2002) |
| **Gas support** | OC multi-gas (air, nitrox, trimix), CCR |
| **Deco planning** | `ceiling()`, `ndl()`, `calculateDecoStops()` |
| **Oxygen toxicity** | CNS% (NOAA table), OTU accumulation |
| **Sensor pipeline** | Depth from pressure (EN 13319), ascent rate monitor |
| **Platform** | watchOS 10, iOS 17, macOS 14 — no UIKit dependency |

---

## Algorithm

### Bühlmann ZHL-16C

The ZHL-16C model tracks gas loading across **16 parallel tissue compartments**, each representing a hypothetical body tissue with a different half-time.

#### Compartment Table (standard values, Bühlmann 1995)

| # | N₂ t½ (min) | N₂ a (bar) | N₂ b | He t½ (min) | He a (bar) | He b |
|---|------------|-----------|------|------------|-----------|------|
| 1 | 5.0 | 1.1696 | 0.5578 | 1.88 | 1.6189 | 0.4770 |
| 2 | 8.0 | 1.0000 | 0.6514 | 3.02 | 1.3830 | 0.5747 |
| 3 | 12.5 | 0.8618 | 0.7222 | 4.72 | 1.1919 | 0.6527 |
| 4 | 18.5 | 0.7562 | 0.7825 | 6.99 | 1.0458 | 0.7223 |
| 5 | 27.0 | 0.6200 | 0.8126 | 10.21 | 0.9220 | 0.7582 |
| 6 | 38.3 | 0.5043 | 0.8434 | 14.48 | 0.8205 | 0.7957 |
| 7 | 54.3 | 0.4410 | 0.8693 | 20.53 | 0.7305 | 0.8279 |
| 8 | 77.0 | 0.4000 | 0.8910 | 29.11 | 0.6502 | 0.8553 |
| 9 | 109.0 | 0.3750 | 0.9092 | 41.20 | 0.5950 | 0.8757 |
| 10 | 146.0 | 0.3500 | 0.9222 | 55.19 | 0.5545 | 0.8903 |
| 11 | 187.0 | 0.3295 | 0.9319 | 70.69 | 0.5333 | 0.8997 |
| 12 | 239.0 | 0.3065 | 0.9403 | 90.34 | 0.5189 | 0.9073 |
| 13 | 305.0 | 0.2835 | 0.9477 | 115.29 | 0.5181 | 0.9122 |
| 14 | 390.0 | 0.2610 | 0.9544 | 147.42 | 0.5176 | 0.9171 |
| 15 | 498.0 | 0.2480 | 0.9602 | 188.24 | 0.5172 | 0.9217 |
| 16 | 635.0 | 0.2327 | 0.9653 | 240.03 | 0.5119 | 0.9267 |

#### Schreiner Equation

Gas loading for each segment uses the **Schreiner equation** (handles both constant-depth and linear ascent/descent):

```
P(t) = Palv₀ + R·(t − 1/k) − (Palv₀ − Pi₀ − R/k)·exp(−k·t)

where:
  k     = ln(2) / halfTime
  Palv₀ = (Pamb_start − 0.0627) × gasFraction
  R     = (Palv_end − Palv₀) / minutes   [rate of change, bar/min]
  Pi₀   = initial tissue partial pressure
  0.0627 bar = alveolar water vapour pressure (constant)
```

At constant depth (R = 0), this reduces to the standard Haldane equation:  
`P(t) = Palv + (Pi₀ − Palv)·exp(−k·t)`

N₂ and He are tracked independently in each compartment.

#### Gradient Factor Ceiling

The tolerable ambient pressure for a compartment at a given gradient factor:

```
P_tolerable = (P_i − GF × a) × b / ((1 − GF) × b + GF)

where:
  P_i = pN₂ + pHe  (total inert gas tension)
  a, b = N₂/He blended M-value coefficients (weighted by partial pressure)
```

The **GF slope** interpolates linearly between GF Low (at the first stop depth) and GF High (at the surface), following the Wienke 2002 formulation used by Shearwater and other professional computers.

---

## Installation

### Swift Package Manager

Add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tristan-kkim/DiveEngine", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies…** → paste the URL above.

---

## Quick Start

```swift
import DiveEngine

// 1. Create engine (salt water, sea level)
var engine = BuhlmannEngine(surfacePressure: 1.01325, waterDensity: 1025.0)

// 2. Simulate a 30m air dive, 25 minutes bottom time
let gas = BuhlmannGas.air
engine.addSegment(startDepth: 0, endDepth: 30, time: 30.0/18.0, gas: gas) // descent
engine.addSegment(startDepth: 30, endDepth: 30, time: 25.0, gas: gas)      // bottom

// 3. Query decompression state
let ceiling = engine.ceiling(gfLow: 0.40, gfHigh: 0.85)  // → 0.0 (no deco)
let ndl     = engine.ndl(depth: 30, gas: gas, gf: 0.85)   // → remaining NDL (min)

print("Ceiling: \(ceiling)m, Remaining NDL: \(ndl) min")
```

### Decompression Schedule

```swift
var engine = BuhlmannEngine()
let bottomGas = BuhlmannGas.air
let ean50     = BuhlmannGas.ean50

// Simulate 40m / 30min
engine.addSegment(startDepth: 0, endDepth: 40, time: 40.0/18.0, gas: bottomGas)
engine.addSegment(startDepth: 40, endDepth: 40, time: 30.0, gas: bottomGas)

// Calculate deco schedule
let schedule = try engine.calculateDecoStops(
    gfLow:        0.40,
    gfHigh:       0.85,
    currentDepth: 40.0,
    bottomGas:    bottomGas,
    decoGases:    [ean50]   // switch to EAN50 at its MOD during ascent
)

for seg in schedule {
    if seg.startDepth == seg.endDepth {
        print("Stop \(Int(seg.startDepth))m — \(Int(seg.time)) min on \(Int(seg.gas.o2 * 100))% O₂")
    }
}
```

### Custom Gas (Trimix)

```swift
// Trimix 21/35 (21% O₂, 35% He, 44% N₂)
let tx2135 = BuhlmannGas(o2: 0.21, he: 0.35)
print("MOD (ppO₂ 1.4): \(tx2135.mod())m")

engine.addSegment(startDepth: 0, endDepth: 60, time: 60.0/18.0, gas: tx2135)
engine.addSegment(startDepth: 60, endDepth: 60, time: 20.0, gas: tx2135)
```

### CCR (Closed-Circuit Rebreather)

```swift
let diluent = BuhlmannGas(o2: 0.21, he: 0.50)  // heliair diluent
engine.addCCRSegment(
    startDepth: 0, endDepth: 60,
    time: 60.0/18.0,
    diluent: diluent,
    setpoint: 1.2   // ppO₂ setpoint (bar)
)
```

---

## GF Metrics (Live Dive)

```swift
let pAmb = engine.ambientPressure(depth: 20.0)

// GF99: current saturation % relative to M-value at current depth
let gf99 = engine.gf99(ambientPressure: pAmb)

// SurfGF: saturation % if diver surfaced immediately
let surfGF = engine.surfGF()

// Tissue saturation bars (0–1+) for display
let bars = engine.tissueSaturation()   // [Double], length 16
```

---

## Depth & Pressure

```swift
// Depth → pressure
let p = DepthCalculator.pressure(at: 30.0, waterDensity: 1025)   // bar

// Pressure → depth
let d = DepthCalculator.depth(from: p, waterDensity: 1025)         // m

// Ascent rate monitoring
let monitor = AscentRateMonitor(maxRate: 9.0)   // m/min
switch monitor.evaluate(ascentRate: 11.5) {
case .safe:    print("OK")
case .warning: print("Too fast")
case .critical:print("DANGER")
}
```

---

## Gradient Factor Presets

These GF presets are used in the Divetools app, aligned with Shearwater/Suunto/Garmin defaults:

| Preset | GF Low | GF High | Notes |
|--------|--------|---------|-------|
| Conservative | 35% | 75% | Extra bubble mitigation |
| Moderate | 40% | 85% | Industry standard |
| Aggressive | 45% | 95% | Shorter deco, experienced divers |

---

## Testing

```bash
swift test
```

Tests cover:
- NDL accuracy vs. PADI RDP reference values (±3 min tolerance)
- Ceiling presence/absence after known dive profiles
- GF sensitivity: conservative GF must shorten NDL
- EAN32 vs. air NDL comparison at 30m
- Depth calculator round-trip accuracy (<0.01m error)
- Ascent rate monitor thresholds (warning = max × 1.0, critical = max × 1.5)
- Ceiling violation detector with configurable margin

---

## Architecture

```
DiveEngine/Sources/DiveEngine/
├── Algorithm/
│   ├── BuhlmannTissue.swift   — 16-compartment table, Schreiner equation, M-values
│   ├── BuhlmannCore.swift     — BuhlmannGas, BuhlmannEngine (tissue state machine)
│   └── DecoPlanner.swift      — ceiling(), ndl(), calculateDecoStops(), CCR deco
├── Engine/
│   ├── BuhlmannWrapper.swift  — Actor-based wrapper with GF99/SurfGF/snapshot API
│   ├── DiveEngine.swift       — Real-time dive state machine (DiveState, alerts)
├── Models/
│   ├── DiveSession.swift      — DiveSession, GasSlot, WaterType
│   ├── DiveState.swift        — DiveState, PhaseState
│   └── GasProfile.swift       — GasProfile, OxygenToxicityTracker (CNS/OTU)
├── Safety/
│   └── SafetyAlert.swift      — SafetyAlert, AscentRateMonitor, CeilingViolationDetector
└── Sensors/
    ├── SensorDataProcessor.swift — Depth sensor pipeline (median filter, 1Hz)
    └── SensorSimulator.swift     — Sine-wave dive profile for simulator
```

---

## Reference

- Bühlmann, A.A. (1995). *Tauchmedizin*. Springer.  
- Wienke, B.R. (2002). *Diving Decompression Models and Gradient Factors*.  
- EN 13319:2000 — *Diving accessories — Depth gauges and combined depth and time measuring devices*.  
- NOAA Diving Manual, 6th Edition — CNS oxygen toxicity tables.  
- Subsurface Project — open-source dive computer software (cross-validation reference).

---

## License

MIT License. See [LICENSE](LICENSE).

---

## Related

- **Divetools** — watchOS dive computer app using this engine  
  (Available on the App Store for Apple Watch Ultra)
