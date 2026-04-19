# Algorithm Reference — Bühlmann ZHL-16C GF

## Background

The **Bühlmann ZHL-16C** model is a parallel multi-tissue decompression model published by Prof. Albert Bühlmann (ETH Zürich) in 1995. It is the basis for virtually all modern recreational and technical dive computers, including Shearwater, Suunto Eon Core/Steel, Garmin Descent, and Divetools.

---

## Tissue Compartments

The model tracks **16 parallel tissue compartments**. Each compartment represents a hypothetical body tissue with a characteristic nitrogen (and helium) half-time. Tissues with short half-times (e.g., compartment 1 at 5 min) equilibrate quickly with ambient pressure, while slow tissues (compartment 16 at 635 min) take many hours to off-gas.

### Key Parameters per Compartment

- **Half-time (t½)**: The time it takes for the tissue to reach 50% equilibration
- **a coefficient**: Controls the intercept of the M-value line
- **b coefficient**: Controls the slope of the M-value line

For a mixed N₂/He gas, `a` and `b` are blended by partial pressure:
```
a_blend = (a_N2 × pN2 + a_He × pHe) / (pN2 + pHe)
b_blend = (b_N2 × pN2 + b_He × pHe) / (pN2 + pHe)
```

---

## Gas Loading: Schreiner Equation

For each segment (constant depth or linear ascent/descent), tissue loading is computed using the **Schreiner equation**:

```
P(t) = Palv₀ + R·(t − 1/k) − (Palv₀ − Pi₀ − R/k)·exp(−k·t)
```

| Symbol | Meaning |
|--------|---------|
| `P(t)` | Tissue partial pressure at end of segment (bar) |
| `Palv₀` | Alveolar partial pressure at start: `(Pamb_start − 0.0627) × gasFraction` |
| `R` | Rate of change: `(Palv_end − Palv₀) / minutes` (bar/min) |
| `k` | Decay constant: `ln(2) / halfTime` (min⁻¹) |
| `Pi₀` | Initial tissue partial pressure (bar) |
| `0.0627` | Alveolar water vapour pressure (bar, constant) |

At constant depth (R = 0), this simplifies to the classic **Haldane equation**:
```
P(t) = Palv + (Pi₀ − Palv)·exp(−k·t)
```

---

## M-values and Ceiling

The M-value is the maximum tolerable tissue tension at a given ambient pressure:
```
M(Pamb) = Pamb / b + a
```

A compartment violates the M-value when `(pN₂ + pHe) > M(Pamb)`.

### GF Ceiling

The **ceiling** is the minimum ambient pressure at which all compartments are safe. Using a gradient factor GF:

```
P_tolerable = (P_i − GF × a) × b / ((1 − GF) × b + GF)
```

Where:
- GF = 1.0 → standard Bühlmann M-value (most liberal)
- GF = 0.0 → zero-pressure limit (maximally conservative)

DiveEngine uses binary search to find the ceiling to 0.01m precision.

---

## Gradient Factor Slope (GF Low / GF High)

The GF slope, introduced by Baker (1998) and Wienke (2002), interpolates between two gradient factors:

```
GF(depth) = GF_High + (GF_High − GF_Low) × (depth / firstStop)
```

- **GF Low** applies at the deepest stop (maximally conservative)
- **GF High** applies at the surface (most liberal)

This produces a linear ramp that becomes progressively more conservative as the diver ascends. It matches the approach used by Shearwater Perdix, Suunto Eon Steel, and Garmin Descent.

### Standard GF Presets

| Preset | GF Low | GF High |
|--------|--------|---------|
| Conservative | 35% | 75% |
| Moderate | 40% | 85% |
| Aggressive | 45% | 95% |

---

## NDL Calculation

The no-decompression limit (NDL) is computed by simulation:

1. Make a value-type copy of the current tissue state
2. Add 1-minute segments at the target depth, one by one
3. After each minute, check `ceiling(gfLow = gf, gfHigh = gf) > 0`
4. The NDL expires when a ceiling first appears

This guarantees accuracy regardless of the current tissue state (residual nitrogen, surface interval, etc.).

---

## Decompression Stop Planning

`calculateDecoStops()` implements the standard GF slope ascent algorithm:

1. Determine the first stop depth from `firstStopDepth(gfLow)`
2. Ascend at `ascentRate` m/min (default 9 m/min) to next 3m increment
3. At each stop depth, hold until `ceiling(gfLow, gfHigh) < depth − 1.5m`
4. Switch to the highest available deco gas at or shallower than its MOD
5. Last 3m: ascent rate slows to `surfaceRate` (default 3 m/min)

---

## Oxygen Toxicity

### CNS (Central Nervous System)

Based on the NOAA single-dose table. Each minute at a given ppO₂ accumulates CNS%:

| ppO₂ (bar) | Limit (min) | Rate (%/min) |
|-----------|------------|-------------|
| 0.6 | 720 | 0.139 |
| 0.7 | 570 | 0.175 |
| 0.8 | 450 | 0.222 |
| 0.9 | 360 | 0.278 |
| 1.0 | 300 | 0.333 |
| 1.1 | 240 | 0.417 |
| 1.2 | 210 | 0.476 |
| 1.3 | 180 | 0.556 |
| 1.4 | 150 | 0.667 |
| 1.5 | 120 | 0.833 |
| 1.6 | 45 | 2.222 |

### OTU (Oxygen Tolerance Units)

```
ΔOTU/min = ((ppO₂ − 0.5) / 0.5)^(5/6)
```

Daily limit: 300–650 OTU depending on exposure frequency.

---

## References

1. Bühlmann, A.A. (1995). *Tauchmedizin*. 4th ed. Springer.
2. Baker, E.C. (1998). *Understanding M-values*. Immersed Vol. 3 No. 3.
3. Wienke, B.R. (2002). *Diving Decompression Models and Gradient Factors*.
4. EN 13319:2000 — *Diving accessories: Depth gauges and combined instruments*.
5. NOAA Diving Manual, 6th ed. — Oxygen tolerance tables.
6. Subsurface Project — cross-validation reference implementation.
