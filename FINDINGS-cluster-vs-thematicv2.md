# Diagnostic: Is cluster-based thematicScore good enough as a "first pass"?

*2026-06-12 — read-only DB diagnostic, no code changes. DB snapshot: 1,047 active images (all captioned), 128,108 pairs.*

## TL;DR

Cluster thematicScore is **weakly discriminative but not actively misleading at the very top**. In a 13-pair sample of the top-50 unscored pairs, roughly **3 looked genuinely reviewable, 2 were borderline, and 8 were "that's a stretch"** — mostly shared-scene-vocabulary matches (two festivals, two dogs, two car interiors). Meanwhile, the headline number for the progressive-enhancement decision isn't about quality at all: **the ThematicV2 candidate pool is 127,521 pairs (99.5% of the table)**, which at current 3B throughput is ~2 days of continuous warm inference, and ~11–22 days at projected 11B speeds. "The longer you use it, the better it gets" is, at current pool definitions, "weeks of background inference per library."

A second headline: **the existing 498 V2-scored pairs are 99.4% accent_echo pairs** (495/498), because the candidate ordering is `MAX(aesthetic, geometric) DESC`. Every agreement statistic below is therefore measured on a color-echo-biased slice, not the pair space — this both confirms backlog #91 and limits what Step 1 can tell us.

---

## Step 1 — Agreement / divergence (n = 498 pairs with both scores)

- **Pearson r = −0.114** — no correlation between the scorers.
- ThematicV2 is effectively **binary**: 313 pairs at 0.9, 151 at 0.8, 34 at 0.0. Nothing in between (known 3B calibration problem, decision #85).
- V2 says "connected" on **93%** of what it scored; 368/498 typed `echo` (the catch-all problem).

Buckets at cluster-high ≥ 0.3 / V2-high > 0:

| Bucket | n | Note |
|---|---|---|
| Agree-high | 156 | |
| Agree-low | 20 | |
| Cluster-high, V2-low | 14 | potential cluster false positives |
| Cluster-low, V2-high | 308 | mostly V2 over-acceptance, *not* cluster misses |

**However** — the library-wide cluster distribution is heavily compressed (median 0.39, p90 0.50, p99 0.62), so ≥ 0.3 is really just "at or above median." Re-bucketing at the top-decile threshold (≥ 0.5):

| Bucket | n |
|---|---|
| Cluster ≥ 0.5, V2-yes | 6 |
| Cluster < 0.5, V2-no | 34 |
| Cluster < 0.5, V2-yes | 458 |
| Cluster ≥ 0.5, V2-no | 0 |

Read together with the sample bias (495/498 accent_echo): the overlap set is a slice where cluster thematic is structurally low (mean 0.17 vs library median 0.39) and V2 says yes to almost everything. **Step 1 cannot validate either scorer against the other on this data.** The −0.114 correlation is a property of the biased slice plus V2's binary output, not evidence that the scorers measure different things well.

## Step 2 — Spot-checks of the disagreement buckets

**Cluster-high, V2-low (8 examples, cluster 0.35–0.41, V2 = 0 / "none"):**
Pride parade + rodeo; coffee-shop portrait + rodeo; protest drummers + van interior with toy truck; protest + Renaissance fair (×2); yelling politician + Superman-cape figure; fairground + ringed fists.

- My read: **6–7 of 8 are cluster false positives** — Dice firing on shared crowd/energy/event vocabulary (`community_gathering`, `movement_energy`, `tension_conflict`, `joy_celebration`). "Protest + Renaissance fair" is the canonical failure shape: both captions are dense in collective-energy words, the images share nothing relational.
- One arguable miss by V2: yelling politician + bowed Superman-cape figure (power-as-performance vs. quiet aspiration) has a defensible third meaning. V2's rationale — "vastly different scenes, no connection" — is notable: **the 3B model rejects pairs for surface dissimilarity**, which is precisely backwards relative to the Third Meaning Test (divergent images are where third meaning lives). So V2's "none" verdicts are not a trustworthy gold standard either.

**Cluster-low, V2-high (8 examples, cluster = 0.0, V2 = 0.9):**
Mostly **same-event pairs**: protest + protest (×3), rodeo + rodeo-adjacent (×2), fair + Tesla-protest megaphone. These fail the Third Meaning Test by restatement ("there are two protests"). One rationale hallucinates ("the Ukrainian flag held by him in Image B" — conflating the two images); the "complementary source-receiver" rationales are template-shaped rather than observed.

- My read: **cluster's 0.0 was more right than wrong here.** Cluster zeroing protest+protest pairs (likely via the meaningful-asymmetry gate) is the gate working as designed. The bucket the user feared — "cluster missed it, LLM caught it" — is, in this sample, mostly "LLM said yes to everything."

## Step 3 — Simulated initial grid (top-50 cluster-thematic among V2-unscored)

Sampled 13 of the top 50 with full captions. Judgment by Third Meaning Test:

| Verdict | n | Examples |
|---|---|---|
| Plausible, worth reviewing | 3 | dove-flag in garden + weathered "APPLAUSE" door (0.837); woman with flowers on curb + melancholic domestic interior (0.833); photographer's shadow + "Don't miss us too much" sign vs. long-shadow courtyard figure (0.787) |
| Borderline | 2 | driver's seat + backseat passenger (0.743); SUV at dusk + man assisting woman with walker (0.777) |
| Stretch / fail | 8 | festival crowd + medieval fair crowd (0.848, the #1 pair); two shots of the same faire 1 hr apart (0.803); husky + dog-in-car (0.775); dog-in-backpack + family-around-dog (0.762); strollers + strollers (0.795); etc. |

Structural issues in the top 50 beyond pair quality:

- **Same-burst leakage:** ~5 pairs with capture deltas of 0–55 s (e.g. `_DSF3629`/`_DSF3631` at Δ55 s, score 0.818). Temporal penalty knocks these down in composite-ish sorts, but in a raw thematic sort they'd sit near the top. The V2 burst guard (identical captureDate) doesn't catch Δ44–55 s.
- **Hub concentration:** 50 pairs draw on only 69 distinct images; 7 images appear 3–5× each (`20240427-DSCF2143` and `32-20250308-_R012720` 5× each). A user's first screen would feel repetitive.

**Core answer: roughly 1 in 4 or 5 top pairs is reviewable; the mode failure is "two of the same scene type," which a user reads instantly as a stretch.** It is not pure noise — the genuine pairs in the sample (dove/applause, flowers/domestic melancholy) are exactly the kind of quiet thematic rhyme the tool exists for, and they were found by clusters alone. But they're outnumbered ~3:1 by vocabulary-overlap matches.

## Step 4 — Coverage math

| Quantity | Value |
|---|---|
| Total pairs | 128,108 |
| Cluster thematicScore non-null | 128,108 (100%) |
| ThematicV2 non-null | 498 (0.39%) |
| V2 candidate pool (aesthetic > 0.3 OR geometric > 0.3, both captioned, unscored, burst-guarded) | **127,521 (99.5%)** |

Throughput to close the gap:

- **3B, warm (~1–2 s/pair):** 127,521 pairs ≈ **35–71 hours** of continuous inference ≈ 255 passes of 500.
- **11B (5–10× slower, per #85):** ≈ **7–30 days** of continuous inference.
- Passes only run after page-0 grid loads, so wall-clock time is realistically much longer than inference time.

The `> 0.3` axis floor does essentially no filtering (88% of pairs clear 0.3 on aesthetic or geometric alone). Any progressive-enhancement story needs either a much tighter candidate definition or acceptance that V2 coverage will be permanently sparse and concentrated wherever the ordering points it — currently, at color echoes.

## Caveats

- All pair-quality judgments are from captions, not the images themselves; captions are qwen-generated and occasionally unreliable.
- Step 2/3 samples are small (8 + 8 + 13) and the Step 1 overlap set is structurally biased (accent_echo-only, see above).
- The cluster score distribution may shift after the #50 caption redesign re-caption; these numbers describe the current captions.
- "Top by raw thematicScore" approximates but doesn't exactly reproduce the grid's thematic sort (temporal penalty, cap-2 per image, and effectiveThematic substitution all modify display order; cap-2 in particular would mitigate the hub-concentration issue).

## What this says about the two strategies (data only, no recommendation)

- **For progressive enhancement:** the initial cluster grid is ~20–25% signal at the top, with a recognizable and *bounded* failure mode (same-scene-vocabulary matching, burst leakage, hubs) — arguably fixable with targeted gates rather than an overhaul. The genuine pairs cluster found are real finds.
- **Against it:** the enhancement layer as currently configured would spend its first weeks scoring color-echo pairs with a scorer that says "echo, 0.85" to 93% of them — V2 is not yet a reliable improver, and the pool math makes full coverage a multi-day-to-multi-week proposition (worse at 11B).
- **For cut-over to V2-only:** nothing in this data supports that today — V2's discrimination (binary scores, catch-all echo, surface-similarity "none" verdicts, occasional hallucinated rationales) is currently *worse* than the cluster scorer at the one thing the cluster scorer does reliably: saying no.
