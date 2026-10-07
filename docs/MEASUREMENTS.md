# Measurements

The numbers behind Open Glow's tuning and performance claims, with how each was measured. All
measurements are on a 15-inch MacBook Air (Apple silicon) running macOS 26 unless noted.

## Beat detection on real music

**Test bench:** 45 tracks of 20–30 s each, built from Apple Loops — multi-instrument mixes (house,
hip-hop, funk, dubstep, chillwave, breaks, R&B, a live drummer), beatless pads, hats-and-percussion
only, full songs, and level tests (a 12 dB and a 24 dB drop, a fade-in, a breakdown). In the mixes,
the isolated drum stem gives the true kick and hi-hat times. Every track was also analysed with the
audio delivered in 480-, 1024- and 2048-sample chunks to check the result doesn't depend on how
ScreenCaptureKit splits its delivery.

**Detection** (which moments count as beats):

| Measure | Result |
|---|---|
| Kicks caught at full strength (mixes) | 56% |
| Precision of full-strength beats | 78% |
| False full-strength flashes on beatless pads | ≈ 0.08 per second |
| Beat times across chunk sizes | identical |

**Graded beat sizes** (how big each beat looks; beat times unchanged on all 45 tracks):

| Measure | Before (kick = 1, other = 0.5) | After (graded) |
|---|---|---|
| Beats on a real kick: mean size / share ≥ 0.8 | 0.79 / 58% | 0.89 / 84% |
| Beats on a hi-hat only: mean size / share ≤ 0.3 | 0.56 / 0% | 0.28 / 73% |
| Steady four-on-the-floor kicks ≥ 0.8 | 93% | 92% |
| False beats on beatless pads: mean size | 0.60 | 0.29 |
| Hats-only material: share ≤ 0.3 | 0% | 94% |
| Mean rank correlation of size with real kick strength, mixes with real dynamics | −0.27 | +0.22 |

## Edge-light falloff

Brightness relative to the edge, measured across the middle of the bottom edge: the target look
(from a reference recording, background subtracted) against Open Glow's rendered output at default
settings.

| Distance from the edge | Target | Open Glow |
|---|---|---|
| 6 pt | 63% | 78% |
| 12 pt | 39% | 46% |
| 18 pt | 25% | 32% |
| 30 pt | 14% | 17% |
| 36 pt | 11% | 12% |

The default thickness was then trimmed from 11 to 10 pt to tighten the first few points.

**Motion targets** from the same recording, used to set the defaults: colors travel
counter-clockwise at roughly 1,700–2,800 pt/s in the fast flow style; music swells rise over
0.5–1 s and fall over ~0.7 s; at its peak the glow reaches about three times as far inward.

## Rendering cost

One frame of the edge light on a 1710 × 1112 pt display (about 96,000 cells in four strips),
release build unless noted:

| Version | Time per frame |
|---|---|
| First version, debug build | 10.3 ms |
| Release build, floating-point pixel loop | 0.40 ms |
| Release build, packed-integer pixel loop | 0.15 ms |

Frame pacing: 60 fps while music is playing, 30 fps for the idle flow, nothing at all while the
glow holds still or is hidden.

## CPU in the running app

Measured with `top` over several 2 s samples.

| State | Open Glow | Extra WindowServer load |
|---|---|---|
| Before the color-space fix, idle flow | 11–15% | — |
| Idle flow, 30 fps | 5–6% | — |
| Music Sync, 60 fps | 8–11% | 10–13% |

These are the numbers going into the Phase 6 performance work; results will be added here.

## Album colors

| Measure | Result |
|---|---|
| Time from a track starting to new colors (player artwork or catalog lookup) | 170–470 ms |
| A track played before | instant (palettes are cached per track) |
| Catalog lookup alone | ≈ 0.2 s warm, ≈ 1.3 s cold |
| Color extraction, 1000 × 1000 image, release | ≈ 0.35 ms (decoding a PNG of that size ≈ 15 ms) |

## Opening sweep

2.2 s: the two fronts climb from the bottom center and meet at the top after about 70% of that,
then the bright heads fade into the idle flow.
