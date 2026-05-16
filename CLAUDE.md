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

### Indexing Pipeline (8 phases)
1. **Scan** — FileScanner reads EXIF captureDate, colorProfile from CGImageSource
2. **Duplicate detection** — dHash perceptual hashing, Hamming threshold=6
3. **Thumbnails** — 512px via CGImageSourceCreateThumbnailAtIndex (prevents IOSurface exhaustion)
4. **CLIP extraction** — CLIPCoreMLEngine, 224px input, cosine similarity embeddings
5. **Captioning** — OllamaCaptioningEngine → `qwen2.5vl-caption` via localhost:11434; captions ALL uncaptioned active images each run
6. **Accent color extraction** — backfills `accentHue` / `accentSaturation` for all active images WHERE accentHue IS NULL; uses 256px downsample, 24 hue bins (15°), prominence = area × mean saturation, 5–40% pixel fraction window, saturation floor 0.25; NULL for B&W/neutral images — decision #54
7. **Saliency centroid extraction** — backfills `weightCentroidX` / `weightCentroidY` for all active images WHERE weightCentroidX IS NULL; runs `VNGenerateAttentionBasedSaliencyImageRequest` on cached 512px thumbnails; confidence-weighted centroid of salient object bounding boxes, normalized 0–1 (Vision bottom-left origin flipped to top-left); NULL when no salient objects found — decisions #59, #64
8. **Pair scoring** — PairScorer, dual topK (composite top-150 + thematic top-10); two-phase: intra-folder first (blocking), cross-folder in background (cancellable) — decision #34

### Three Scoring Axes (PairScorer.swift)
- **Aesthetic (weight 0.40)** — Three-way max: HSL histogram intersection (harmony), LAB palette contrast (contrast), or accent color echo (accent_echo). Echo score = `hueScore × √(satA × satB)` where hueScore ramps ≤10°→1.0, ≤30°→linear, >30°→0. Winning pathway sets `aestheticSubmode`. See decision #56.
- **Geometric (weight 0.20)** — three-component formula: `structural×0.65 + directional×0.10 + breath×0.25`. Structural = (edge orientation cosine × edgeMult + grid cosine × varMult) / 2; directional = `directionalComplementScore()` using per-image `weightCentroidX/Y` (Vision attention saliency centroid from 512px thumbnails, stored in images table — decision #64); breath = `abs(normVarA − normVarB)`. When directional > structural, sets `geometricSubmode = "directional_complement"` and emits "Spatial tension — compositions in conversation." rationale. Edge peakedness exception for breath pairs remains inside edgeMult (decision #53). **Directional weight is 0.10 pending post-re-index validation** — will be raised to 0.35 once saliency centroids are confirmed non-trivially distributed. See decisions #59, #60, #64.
- **Thematic (weight 0.40, boosted to 0.60 when ≥0.20)** — weighted Dice coefficient on ConceptClusters matched from qwen captions; CLIP cosine fallback when no captions

### ConceptClusters
29 semantic clusters with three tiers:
- **Tier 1.0 (emotional/dramatic):** grief_sorrow, vulnerability_exposure, isolation_solitude, ritual_ceremony, tension_conflict, tenderness_care, devotion_belief, power_dominance, sensory_overwhelm, transformation_change, uncanny_ordinary, economic_precarity, solitude_in_crowd, domestic_intimacy
- **Tier 0.75 (contextual):** skilled_performance, sound_music, labor_effort, stillness_rest, waiting_anticipation, movement_energy, bodily_gesture, looking_watching, confinement_freedom, youth_age, joy_celebration, humor_absurdity
- **Tier 0.2 (ambient):** urban_street, nature_landscape, community_gathering, animal_presence

Five clusters use two-signal gating (require ≥1 keyword from each of two vocabulary groups): `humor_absurdity`, `uncanny_ordinary`, `solitude_in_crowd`, `domestic_intimacy`, `animal_presence`.

## Pairing Theory — Design Intent and Known Gaps

Full theory in PAIRING_THEORY.md. This section is the operational summary for implementation work.

### Three Pairing Modes
- **Mode 1 — Semantic arc:** Two images occupy complementary positions in the same human experience arc. Neither image alone names it; together they make it visible. Third meaning is an idea that can be articulated. *Primary carrier: thematic axis.*
- **Mode 2 — Slant rhyme:** Two images share one specific formal property (a color, a shape, a quality of light) while diverging on everything else. Third meaning is a perception felt before it's named. *Primary carrier: aesthetic (accent echo) and geometric axes.*
- **Mode 3 — Ambient existential register:** Shared quality of attention to the fragile and ordinary (Soth's towels). Out of scope currently.

### Third Meaning Test
A pair passes if it creates a meaning that exists in neither image alone. It fails if the best description of the pair just restates what each image independently contains. Two dogs = fail ("there are two dogs"). Musician + ears-woman = pass (sound as a force in the city — given by one, hungered for by another).

### Per-Axis Design Intent vs. Current State

**Thematic** — *should measure:* complementary positions in the same human experience arc. *Currently measures:* weighted Dice on cluster vocabulary — rewards shared clusters, not relational position. *Architectural ceiling reached:* can't distinguish source from receiver of the same phenomenon. Musician and ears-woman both fire `sound_music` + `sensory_overwhelm` via the word "ear" → Dice > ambient floor → axis bonus guard fires → pair below thematic topK cutoff. Caption redesign (#50) is the correct next lever. Do not add more clusters expecting this to improve.

**Aesthetic** — *should measure:* harmony (same visual world), complement (productive tonal contrast), or echo (one specific formal property rhyming across dissimilar images). *Currently measures:* three-way max of HSL histogram intersection (harmony), LAB palette contrast (complement), and accent hue echo (#56). *Missing:* light quality (deferred, hardest to compute reliably); tonal weight complementarity for breath pairs (#55, adds ~0.12 max composite lift when implemented).

**Geometric** — *should measure:* structural rhyme, directional complement (figures spatially facing each other / strong lines leading from one image to the next), or breath (dense image paired with spare/open image). *Currently measures:* three-component formula `structural×0.65 + directional×0.10 + breath×0.25` — structural via edge/grid cosine similarity, directional via Vision attention saliency centroid opposition (`weightCentroidX/Y`, decision #64), breath via tonal weight differential. *Directional weight is 0.10 pending validation:* edge-energy centroid (#59) proven ineffective; replaced with Vision saliency in #64. Saliency centroid quality unverified on real library — validate stdev and spot-check asymmetric images before raising weight to 0.35. *Missing:* uniform area ratio for genuine sparseness detection; gaze direction; light quality.

### Known Scoring Failures
- **Musician + ears-woman:** Both captions share `sound_music` + `sensory_overwhelm` vocabulary → Dice > ambient floor → axis bonus guard fires. Pair scores via Dice but ranks below thematic topK cutoff. Only caption redesign (#50) fixes this.
- **Breath pairs:** Geometric differential ~0.07 composite max is below surfacing threshold. Aesthetic tonal weight complementarity (#55) needed to close the gap.
- **Mode 2 beyond color echo:** Light quality echo and gestural/energetic echo are unmeasured anywhere in the system.

## Known Gotchas

**GRDB returns INTEGER columns as Int64, not Int** — `as? Int` silently returns nil on GRDB Row even on 64-bit macOS. Use the `intCol()` helper or explicit coercion: `(row["col"] as? Int) ?? (row["col"] as? Int64).map(Int.init) ?? 0`. Affects COUNT(*) results too.

**captureDate stored as INTEGER in SQLite** — GRDB's `as? Double` returns nil for Int64 column values. Explicit coercion required in `fetchRepresentativePairs` and `fetchPairs`: `(row["captureDateA"] as? Double) ?? (row["captureDateA"] as? Int64).map { Double($0) }`. Without this, temporal penalty never fires (all dates arrive as nil → penalty=1.0). See decision #26.

**Titlebar (NSTitlebarBackgroundView)** — the frosted-glass effect comes from a private `NSTitlebarBackgroundView` at subview index 0 of `NSTitlebarView`, NOT from an NSVisualEffectView. The fix is `SolidTitlebarCover` (a plain CALayer-backed NSView) inserted at subview index 1 in `CoupletTheme.swift → installSolidTitlebar`. Re-applies from `didBecomeKeyNotification` and `didBecomeMainNotification`. Read decision #30 in full before touching any titlebar rendering — prior approaches (targeting VEVs, setting layer.backgroundColor on NSThemeFrame) do not work.

**Tools bar (filter controls in titlebar)** — three approaches that do NOT work: (1) SwiftUI `.toolbar { ToolbarItem }` — macOS 15 applies per-item liquid glass capsules to NSToolbarItem containers that cannot be suppressed from inside; (2) `NSTitlebarAccessoryViewController` with `.bottom` — creates a visually separate second row with dead space between it and the traffic-light band; (3) `.windowToolbarStyle(.unified(showsTitle: true))` on the scene — causes the window title to reappear during state transitions. **What works:** empty `NSToolbar` (no items) with `window.toolbarStyle = .unified` expands `NSTitlebarView` to ~50px without producing NSToolbarItem containers; a `PassthroughHostingView<AnyView>` is inserted directly into `NSTitlebarView` at `leadingAnchor + 192` and updated each render cycle via `WindowConfigurator.updateNSView`. See decision #36 for full rationale and known limitations.

**weightedDice ambient floor** — `weightedDice()` in ConceptClusters requires ≥1 cluster in the shared intersection with weight ≥ 0.75; pairs sharing only ambient-tier clusters (urban_street/nature_landscape/community_gathering/animal_presence, all weight 0.2) return `kAmbientFloor = 0.1`. Any new ambient cluster must stay at weight ≤ 0.24 or the gate logic breaks. See decision #29.

**Meaningful asymmetry gate requires weight ≥ 0.75 unique clusters per side** — `PairScorer.swift` filters `onlyA` and `onlyB` to clusters with weight ≥ 0.75 before checking asymmetry. A pair where one image uniquely has `urban_street` (weight 0.2) and the other has nothing unique at the meaningful tier fails the gate and returns ambient floor, even if both images have rich meaningful clusters they share. Changed in #49 from the original `!onlyA.isEmpty && !onlyB.isEmpty` which allowed ambient-only asymmetry to pass. Axis pairs are exempt from this gate — they fire via different clusters on each side by structural definition. See decision #49.

**Axis bonus only fires at ambient floor** — `ConceptClusters.axisPairs` defines 9 cluster-opposition relationships that reward complementary pairs (source ↔ receiver of the same phenomenon). The bonus fires ONLY when `clusterScore ≤ 0.10` (ambient floor) — the guard `if saturated || clusterScore > 0.10 { axisBonus = 0 }` prevents +0.35 additive inflation on pairs that already score above ambient floor via Dice. A pair like musician + ears-cupping woman scores via Dice rather than the axis bonus if both captions happen to share `sound_music` or `sensory_overwhelm` vocabulary — the axis bonus won't additionally reward them. See decision #48.

**Temporal penalty must be replayed in convertToPair** — `EngineController.convertToPair` must replay the temporal penalty using `captureDateA/B` (already fetched by the query). Never recompute `displayComposite` from raw component scores without the penalty — sequential pairs inflate to the top otherwise. See decision #26.

**Orphan pair sweep runs before per-run DELETE** — `IndexingEngine.reindex()` sweeps pairs where either image `isActive=0` before the scoped per-run DELETE+INSERT. Preserve this ordering if touching `reindex()`. See decision #19.

**Two-phase scoring scope** — Phase 1 (blocking) scores batch × batch only; Phase 2 (background) scores batch × all-other-active. DELETE scoping is separate for each phase. `crossFolderTask` is cancelled before any new `index()` call. See decision #34.

**Double-onChange race in PairsGridView** — `LibraryViewModel.selectFolder` and `selectCollection` each set *both* `selectedFolderID` and `selectedCollectionID` in the same synchronous pass. If PairsGridView has separate `onChange(of: selectedFolderID)` and `onChange(of: selectedCollectionID)` handlers, both fire within milliseconds with different settled-state snapshots, launching two competing `loadPairs` calls. Fix: merge both handlers to call a single `reloadPairs()` helper that reads the *settled* `currentFolderID` / `currentCollectionID` published values (not the argument to `onChange`). Any future state mutations that touch both properties will hit the same race if separate observers are used. See decision #39.

**QueryService.fetchRepresentativePairs and fetchImagePairCounts are nonisolated** — both methods are `nonisolated` synchronous functions. Calling them directly from `@MainActor` context (e.g. inside `EngineController`) runs them synchronously on the main thread and blocks the UI for the duration of the SQL query. Always call them from a `Task.detached` block. The existing call site in `EngineController.fetchRepresentativePairs` already does this correctly — any new call sites must follow the same pattern. See decision #40.

**PairHelpers.swift functions must stay nonisolated** — `adjustedGeometricFree`, `convertToPairFree`, `pairSortComparator`, `applyCap2Free`, `applyPass2Free` are free functions in `PairHelpers.swift` marked `nonisolated` to prevent Swift 6.3 from inferring `@MainActor` on them. The inference chain is: `DisplayPair.colorA/colorB` use `NSColor` (which is `@MainActor` in the macOS 14+ SDK) → Swift infers `@MainActor` on the `DisplayPair.init` → infers it on any function that constructs a `DisplayPair`. The `nonisolated` keyword on the helpers and `nonisolated init` on `DisplayPair` together break this chain. Do not remove these annotations. See decision #41.

**streamPage0Pairs populates representativePairsCache on completion** — `EngineController.streamPage0Pairs` runs DB fetching and cap-2 in a `Task.detached`, yields accepted batches through `AsyncStream<[DisplayPair]>`, then updates `representativePairsCache` via `await MainActor.run` (with generation check) after the last batch. `PairsGridViewModel.loadPairs` consumes the stream and appends batches directly to `allPairs`. `loadMorePairs` still slices from the cache as before. Do not skip the `MainActor.run` cache update at the end of the inner detached task or `loadMorePairs` will return empty results. See decision #41.

## Open Backlog Items
| # | Title | Notes |
|---|-------|-------|
| 7 | Settings that require re-index | dHash threshold + CLIP similarity ceiling affect data written to DB; UI should distinguish these from cheap runtime settings. See decision #7. |
| 8 | Double CLIP build on launch | Race in `engineBuildTask?.cancel()` on some launches. No crashes recently — monitor. See decision #8. |
| 11 | FileAccessCoordinator centralization | Centralise security-scoped bookmark management; detect invalid bookmarks; clean up stale entries on `removeFolder`; handle offline volumes. See decision #11. |
| 14 | Continue geometric scorer tuning | Step distinctiveness multiplier exponent down from 0.4; add multiplier-strength slider; evaluate normalization anchors. See decision #14. |
| 16 | Center-cell discount | Slider + Apply button for peripheral composition cell weighting. Requires re-score (not full re-index). See decision #16. |
| 21 | Caption UI in lightbox info rail | Collapsed-by-default captions with "show more" toggle; strip redundant qwen openers (optional). See decision #21. |
| 23 | Revisit dot badge on pair grid tiles | Recalibrate threshold + improve visual legibility after topK and scoring changes settle. See decision #23. |
| 35 | "Find Pairs For…" — explore or retire | Button removed (no implementation); evaluate vs. existing anchor/filmstrip flow before building. See decision #35. |
| 43 | Layout recursion warning | Console: "-layoutSubtreeIfNeeded on a view which is already being laid out" — once per launch, likely PassthroughHostingView insertion timing. See decision #43. |
| 46 | Complementary role scoring — two sides of the same phenomenon | Implemented via axis pairs (#47, #48, #49). Post-implementation diagnostic: canonical test pair (musician+ears) still absent from DB — both images share `sound_music` and `sensory_overwhelm` vocabulary, so Dice > ambient floor and axis bonus guard fires. See decisions #47, #48, #49. |
| 47 | animal_presence demoted to ambient tier (0.75 → 0.2) | Done. Dog+dog pairs reduced but not eliminated — they still score via shared 0.75-tier behavior clusters. See decision #47. |
| 48 | Complementary axis pair bonus | Done. 9 axis pairs defined in `ConceptClusters.axisPairs`. Axis bonus fires only when `clusterScore ≤ 0.10`. See decision #48. |
| 49 | Meaningful asymmetry gate — weight ≥ 0.75 unique clusters per side | Done. Replaced `!onlyA.isEmpty && !onlyB.isEmpty` with meaningful-tier filter in `PairScorer.swift`. See decision #49. |
| 50 | Caption prompt redesign — emotional register over scene description | Keyword cluster system at architectural ceiling after #45, #47, #48, #49. qwen2.5vl-caption captions describe what is visible, not what is felt. Recommended first step: redesign qwen prompt to request emotional register and human condition rather than scene inventory. Define 3–5 failing test pairs before committing to a full re-caption. See decision #46 outcome note and backlog #50 in DECISIONS.md. |
| 55 | Breath pairs — aesthetic axis tonal weight complementarity | Geometric axis (#53) contributes `abs(normVarA − normVarB)` differential (weight 0.4/2.4) but max composite lift is ~0.07 — not enough to surface breath pairs reliably. Next step: add tonal weight complementarity as Component 3 of the aesthetic axis (weight 0.30 within aesthetic, ~0.12 max composite lift). Prerequisite: visually confirm `20250426-_R016343.jpg` and `20210313-L1001045.jpg` as genuine open/spare breath-pair candidates. See decision #55 and PAIRING_THEORY.md §Aesthetic axis redesign. |
| 56 | Accent color echo — pair scoring + info panel | Done. `accentEchoScore = hueScore × √(satA × satB)`, hue ramp ≤10°→1.0, ≤30°→linear, >30°→0. Three-way max in `aestheticScore()` with `harmony` and `contrast`. Lightbox info rail shows "Color echo" label with two hue swatches when `aestheticSubmode == "accent_echo"`. Canonical test pair (`_R017085` + `R0024458`, both accentHue≈7.5°) confirmed in pairs table post re-index. See decision #56. |
| 59 | Directional complement scoring — geometric axis | Superseded by #64. Edge-energy centroid proven ineffective (stdev=0.046, 96.1% of library in centX [0.40, 0.60]). Scoring infrastructure (columns, `directionalComplementScore()`, Phase 3.7) retained; computation replaced with Vision saliency in #64. Structural weight partially restored in #60. See decision #59. |
| 60 | Restore geometric structural weight | Done. `structural×0.65 + directional×0.10 + breath×0.25`. Weight will be re-calibrated once saliency centroids are validated. See decision #60. |
| 64 | Vision saliency centroid — replace edge-energy centroid | Done. `VNGenerateAttentionBasedSaliencyImageRequest` on cached 512px thumbnails. v11 migration nulls stale edge-energy values; Phase 3.7 re-populates with attention saliency on next re-index. **Pending validation:** re-index and confirm stdev > 0.10 and DSCF3336 centX < 0.40. Once confirmed, raise directional weight from 0.10 → 0.35. See decision #64. |
| 61 | Directional complement — dominant orientation opposition | Use the existing 32-bin `edgeOrientation` histogram (stored per image in `featureVectors`, not read at score time). Extract dominant bin angle per image; score opposition as angular distance mapped so 180° → 1.0. No new data or re-index. Would detect opposing diagonals (DSCF3269-positive). |
| 62 | Directional complement — regional orientation histogram | Per-cell dominant edge direction from an 8×8 grid. Would capture "subject on left facing right" as rightward edges in left cells. Requires new extraction phase + DB schema. Long-term. |
| 63 | Gaze / body direction detection | Vision `VNDetectFaceRectanglesRequest` or `VNDetectHumanBodyPoseRequest`. Directly detects "figure facing into frame" directional complement. Long-term; requires new Phase 3.x and DB columns. |
| 57 | Accent echo — desaturated reds under shadow | Under low-light or shadow, photographic reds maintain hue but lose saturation. `√(satA × satB)` penalises these even when the pair is a genuine echo. Would require reasoning about hue purity independent of luminance — not solvable at pixel-statistics level without scene context. Backlog until a test case justifies the complexity. |
| 58 | Accent echo — ambient hue exclusion (foliage green, sky blue) | Distinguishing billboard green from foliage green, painted blue from sky blue, requires scene context (caption vocabulary, CLIP region features) not available at score time. `√(satA × satB)` partially compensates (dull ambient greens have low saturation), but vivid sky or foliage could still inflate scores. Cannot be solved at pixel-statistics level without knowing what a color "belongs to." Backlog. |

## Commit Convention
Use `#ID` prefix matching the decisions log:
```
fix(#26): replay temporal penalty in convertToPair
feat(#21): add collapsed caption display to info rail
chore: initial commit
```
