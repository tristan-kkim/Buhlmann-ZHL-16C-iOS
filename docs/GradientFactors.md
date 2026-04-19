# Gradient Factors — Practical Guide

## What is a Gradient Factor?

A **Gradient Factor (GF)** scales the Bühlmann M-value. It was introduced by Erik Baker in 1998 as a way to add conservatism without changing the fundamental algorithm.

- **GF 100%** = Standard Bühlmann M-value (maximum allowed tissue saturation)
- **GF 50%** = Tissues can only reach 50% of the M-value — much more conservative

## GF Low / GF High Slope

Rather than a single GF, modern dive computers use a **two-value slope**:

```
       Surface  ←  diver ascends  ←  Deep stop
         GF_High                      GF_Low
          85%       ────────────       40%
```

- **GF Low** is applied at the **deepest decompression stop**. A lower value forces deeper, longer stops (more conservative deep stops).
- **GF High** is applied at the **surface**. A lower value forces more time at the final 3–6m stop.

The interpolation is linear with depth:
```
GF(depth) = GF_High − (GF_High − GF_Low) × (depth / firstStopDepth)
```

## How DiveEngine Uses GF

1. `firstStopDepth(gfLow:)` — finds the deepest depth where any compartment hits its GF_Low ceiling
2. `ceiling(gfLow:gfHigh:)` — at each depth during ascent, uses the interpolated GF
3. `ndl(depth:gas:gf:)` — uses `gf = gfHigh` (flat, surface value) to compute remaining no-deco time

## Choosing GF Values

| Use case | GF Low | GF High | Notes |
|----------|--------|---------|-------|
| First dives, conservative | 30–35% | 70–75% | Matches SSI/PADI TDI conservative |
| Recreational technical | 40% | 85% | Shearwater default, Suunto default |
| Experienced technical | 45–50% | 90–95% | Still within recommended range |
| Above 50/95 | — | — | Not recommended for decompression diving |

## GF and NDL

For no-decompression (recreational) diving, GF Low has no effect — the diver surfaces directly. Only GF High matters for NDL calculation.

A lower GF High → shorter NDL at any given depth:

```
Air 30m, GF 85/85: NDL ≈ 22 min
Air 30m, GF 40/85: NDL ≈ 22 min   (GF_Low doesn't affect NDL)
Air 30m, GF 40/75: NDL ≈ 17 min   (GF_High 75 is more conservative)
```

## GF99 and SurfGF

DiveEngine also provides two real-time GF metrics:

- **GF99**: The current gradient factor (% of M-value) at the diver's present depth. Analogous to what Shearwater displays as "GF".
- **SurfGF**: What GF99 would be *if the diver surfaced right now* (ignoring stops). Shearwater Perdix shows this to warn of bubble risk on direct ascent.

Both are displayed in real time during a dive.

## References

- Baker, E.C. (1998). *Understanding M-values*. Immersed Vol. 3, No. 3.  
- Baker, E.C. (1998). *Clearing Up the Confusion about 'Deep Stops'*.  
- Shearwater Research. *Gradient Factors in Shearwater Computers* (user manual appendix).
