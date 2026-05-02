# Couplet — Claude Code Reference

## Project Overview
Couplet is a macOS app for street and documentary photographers. It discovers meaningful image pairs in a photo library — not duplicates or sequential shots, but conceptually resonant connections the photographer might not have noticed.

- **Bundle ID:** `com.toastbrigade.Couplet`
- **Deployment target:** macOS 14.0
- **Language:** Swift

## Directory Layout
```
_couplet/
├── ConjunctEngine/          # Swift Package — engine, scoring, DB
├── Couplet MacOS App/       # Xcode app project
│   └── Couplet/
├── clip-vit-base-patch32.mlpackage   # CLIP model (gitignored)
├── DECISIONS.md             # Full architectural decisions log
└── CLAUDE.md                # This file
```

Database: `~/Library/Application Support/Conjunct/conjunct.db`
Thumbnail cache: `~/Library/Caches/Conjunct/thumbnails/{imageID}.jpg`
Mid-res preview cache: `~/Library/Caches/Conjunct/previews/{imageID}.jpg`

## Architecture

### Indexing Pipeline (6 phases)
1. **Scan** — FileScanner reads EXIF captureDate, colorProfile from CGImageSource
2. **Duplicate detection** — dHash perceptual hashing, Hamming threshold=6
3. **Thumbnails** — 512px via CGImageSourceCreateThumbnailAtIndex (prevents IOSurface exhaustion)
4. **CLIP extraction** — CLIPCoreMLEngine, 224px input, cosine similarity embeddings
5. **Captioning** — OllamaCaptioningEngine → `qwen2.5vl-caption` via localhost:11434; captions ALL uncaptioned active images each run
6. **Pair scoring** — PairScorer, dual topK (composite top-150 + thematic top-10); two-phase: intra-folder first (blocking), cross-folder in background (cancellable) — decision #34

### Three Scoring Axes (PairScorer.swift)
- **Aesthetic (weight 0.40)** — HSL histogram intersection (harmony) + LAB palette contrast
- **Geometric (weight 0.20)** — edge orientation cosine similarity + composition grid cosine similarity
- **Thematic (weight 0.40, boosted to 0.60 when ≥0.20)** — weighted Dice coefficient on ConceptClusters matched from qwen captions; CLIP cosine fallback when no captions

### ConceptClusters
29 semantic clusters with three tiers:
- **Tier 1.0 (emotional/dramatic):** grief_sorrow, vulnerability_exposure, isolation_solitude, ritual_ceremony, tension_conflict, tenderness_care, devotion_belief, power_dominance, sensory_overwhelm, transformation_change, uncanny_ordinary, economic_precarity, solitude_in_crowd, domestic_intimacy
- **Tier 0.75 (contextual):** skilled_performance, sound_music, labor_effort, stillness_rest, waiting_anticipation, movement_energy, bodily_gesture, looking_watching, confinement_freedom, youth_age, joy_celebration, humor_absurdity
- **Tier 0.5 → 0.2 (ambient):** urban_street, nature_landscape, community_gathering

Four clusters use two-signal gating (require ≥1 keyword from each of two vocabulary groups): `humor_absurdity`, `uncanny_ordinary`, `solitude_in_crowd`, `domestic_intimacy`.

## Known Gotchas

**GRDB returns INTEGER columns as Int64, not Int** — `as? Int` silently returns nil on GRDB Row even on 64-bit macOS. Use the `intCol()` helper or explicit coercion: `(row["col"] as? Int) ?? (row["col"] as? Int64).map(Int.init) ?? 0`. Affects COUNT(*) results too.

**captureDate stored as INTEGER in SQLite** — GRDB's `as? Double` returns nil for Int64 column values. Explicit coercion required in `fetchRepresentativePairs` and `fetchPairs`: `(row["captureDateA"] as? Double) ?? (row["captureDateA"] as? Int64).map { Double($0) }`. Without this, temporal penalty never fires (all dates arrive as nil → penalty=1.0). See decision #26.

**Titlebar (NSTitlebarBackgroundView)** — the frosted-glass effect comes from a private `NSTitlebarBackgroundView` at subview index 0 of `NSTitlebarView`, NOT from an NSVisualEffectView. The fix is `SolidTitlebarCover` (a plain CALayer-backed NSView) inserted at subview index 1 in `CoupletTheme.swift → installSolidTitlebar`. Re-applies from `didBecomeKeyNotification` and `didBecomeMainNotification`. Read decision #30 in full before touching any titlebar rendering — prior approaches (targeting VEVs, setting layer.backgroundColor on NSThemeFrame) do not work.

**weightedDice ambient floor** — `weightedDice()` in ConceptClusters requires ≥1 cluster in the shared intersection with weight ≥ 0.75; pairs sharing only ambient-tier clusters (urban_street/nature_landscape/community_gathering, all weight 0.2) return `kAmbientFloor = 0.1`. Any new ambient cluster must stay at weight ≤ 0.24 or the gate logic breaks. See decision #29.

**Temporal penalty must be replayed in convertToPair** — `EngineController.convertToPair` must replay the temporal penalty using `captureDateA/B` (already fetched by the query). Never recompute `displayComposite` from raw component scores without the penalty — sequential pairs inflate to the top otherwise. See decision #26.

**Orphan pair sweep runs before per-run DELETE** — `IndexingEngine.reindex()` sweeps pairs where either image `isActive=0` before the scoped per-run DELETE+INSERT. Preserve this ordering if touching `reindex()`. See decision #19.

**Two-phase scoring scope** — Phase 1 (blocking) scores batch × batch only; Phase 2 (background) scores batch × all-other-active. DELETE scoping is separate for each phase. `crossFolderTask` is cancelled before any new `index()` call. See decision #34.

## Open Backlog Items
| # | Title | Notes |
|---|-------|-------|
| 21 | Caption UI in lightbox | Collapsed-by-default display; "show more" toggle; strip redundant openers |
| 25 | Full re-caption pass | 57% of captions truncated mid-sentence; num_predict raised to 400 but DB not yet refreshed |
| 27 | Aesthetic score inflation | 0.968 for weak pair — investigate harmony sub-score; consider cross-axis confidence penalty |
| 28 | Same-subject discount | Dogs/cars pairing with no cross-context resonance; possible CLIP secondary ceiling (>0.75 → ×0.65) |

## Commit Convention
Use `#ID` prefix matching the decisions log:
```
fix(#26): replay temporal penalty in convertToPair
feat(#21): add collapsed caption display to info rail
chore: initial commit
```
