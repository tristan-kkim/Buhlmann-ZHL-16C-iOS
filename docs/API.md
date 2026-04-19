# API Reference

## BuhlmannGas

```swift
public struct BuhlmannGas: Sendable, Equatable
```

Represents an inert-gas breathing mix.

| Property / Method | Type | Description |
|-------------------|------|-------------|
| `o2` | `Double` | O₂ fraction (0.0–1.0) |
| `he` | `Double` | He fraction (0.0–1.0) |
| `n2` | `Double` | N₂ fraction (derived: `1 − o2 − he`) |
| `mod(ppO2Limit:surfacePressure:)` | `Double` | Maximum operating depth (m) |
| `.air` | static | 21% O₂, 0% He |
| `.ean32` | static | 32% O₂, 0% He |
| `.ean50` | static | 50% O₂, 0% He |
| `.oxygen` | static | 100% O₂ |

---

## BuhlmannEngine

```swift
public struct BuhlmannEngine: Sendable
```

Core decompression engine holding 16 tissue compartments.

### Initializers

```swift
init(surfacePressure: Double = 1.01325, waterDensity: Double = 1025.0)
```

Creates a fresh engine with tissues at surface equilibrium breathing air.

### Pressure Conversion

```swift
func ambientPressure(depth: Double) -> Double
```

Converts depth (m) to absolute pressure (bar): `P = surfacePressure + ρ·g·h`.

### Segment Processing

```swift
mutating func addSegment(startDepth: Double, endDepth: Double, time: Double, gas: BuhlmannGas)
mutating func addCCRSegment(startDepth: Double, endDepth: Double, time: Double, diluent: BuhlmannGas, setpoint: Double)
```

Advances tissue state for one dive segment. `time` is in **minutes**.

### Decompression Queries

```swift
func ceiling(gfLow: Double, gfHigh: Double) -> Double
```

Returns the ceiling depth (m) using the GF slope. Returns 0 if no decompression is required.

```swift
func ndl(depth: Double, gas: BuhlmannGas, gf: Double) -> Double
```

Returns the no-decompression limit (minutes) at the given depth and gas. Returns 999 if NDL exceeds 999 min.

```swift
func calculateDecoStops(gfLow: Double, gfHigh: Double, currentDepth: Double,
                         bottomGas: BuhlmannGas, decoGases: [BuhlmannGas],
                         config: BuhlmannDecoConfig) throws -> [BuhlmannDiveSegment]
```

Returns a full decompression schedule. Throws `BuhlmannError.maxDurationExceeded` if TTS > `config.maxTotalTime`.

### GF Metrics

```swift
func gf99(ambientPressure: Double) -> Double   // current saturation % at depth
func surfGF() -> Double                         // saturation % if surfacing now
func tissueSaturation() -> [Double]             // [0..1+] per compartment, for display
```

---

## BuhlmannDecoConfig

```swift
public struct BuhlmannDecoConfig: Sendable
```

| Property | Default | Description |
|----------|---------|-------------|
| `ascentRate` | 9.0 m/min | Rate between stops |
| `surfaceRate` | 3.0 m/min | Rate for final 3m |
| `stopIncrement` | 3.0 m | Depth between stops |
| `minStopTime` | 1.0 min | Minimum stop duration |
| `maxTotalTime` | 1440.0 min | Throws if exceeded |

---

## DepthCalculator

```swift
static func pressure(at depth: Double, waterDensity: Double, surfacePressure: Double) -> Double
static func depth(from pressure: Double, waterDensity: Double, surfacePressure: Double) -> Double
```

Converts between depth (m) and absolute pressure (bar) using `P = Psurf + ρ·g·h / 100000`.  
Gravity constant: **9.80665 m/s²** (EN 13319 standard).

---

## AscentRateMonitor

```swift
struct AscentRateMonitor
init(maxRate: Double)  // m/min
func evaluate(ascentRate: Double) -> AscentRateStatus
```

```swift
enum AscentRateStatus {
    case safe
    case warning   // ascentRate > maxRate
    case critical  // ascentRate > maxRate × 1.5
}
```

---

## CeilingViolationDetector

```swift
struct CeilingViolationDetector
init(margin: Double = 0.5)  // metres of tolerance above ceiling
func check(depth: Double, ceiling: Double?) -> CeilingViolation?
```

Returns non-nil when `depth < ceiling − margin`.

---

## OxygenToxicityTracker

```swift
class OxygenToxicityTracker
func update(ppO2: Double, minutes: Double)
var cnsPercent: Double   // 0–100+
var otuTotal: Double
```

Tracks CNS% (NOAA table) and OTU accumulation in real time.

---

## BuhlmannWrapper (Actor)

```swift
actor BuhlmannWrapper
```

Thread-safe actor wrapping `BuhlmannEngine` for use in the real-time dive loop. Exposes:

```swift
func addSegment(startDepth: Double, endDepth: Double, time: Double, gas: BuhlmannGas) async
func ceiling(gfLow: Double, gfHigh: Double) async -> Double
func ndl(depth: Double, gas: BuhlmannGas, gf: Double) async -> Double
func compartmentSnapshot() async -> [(pN2: Double, pHe: Double)]
func loadCompartments(_ snapshot: [(pN2: Double, pHe: Double)], surfaceInterval: Double) async
func gf99(depth: Double) async -> Double
func surfGF() async -> Double
func tissueSaturation() async -> [Double]
```
