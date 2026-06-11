# Couplet — Claude Code Reference

## On Genre and Assumptions

**Do not use genre labels as design constraints.** The developer's personal library happens to contain a particular style of photography, but Couplet is designed for any single-photographer library. Genre vocabulary ("street photography," "documentary") is likely to pull reasoning in the wrong direction: it suggests a narrower set of subjects, aesthetics, and pairing expectations than the tool actually supports, and it may lead to calibration decisions that are only correct for one kind of library. When assessing scoring, surfacing, or design questions, reason from what is actually in the data and what the pairing theory says — not from assumptions about what "street photographers" typically shoot or value. See decision #79.

## Project Overview
Couplet is a macOS app for photographers. It discovers meaningful image pairs in a photo library — not duplicates or sequential shots, but conceptually resonant connections the photographer might not have noticed.

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

**pairs table — ThematicV2 columns (v15 migration):**
- `thematicV2Score REAL` — derived score (confidence when connected, 0 when not). NULL = not yet scored.
- `thematicV2RelationshipType TEXT` — one of complementary / contrastive / echo / ironic / tonal / none.
- `thematicV2Rationale TEXT` — one-sentence LLM rationale (max 200 chars). NULL when thematicV2Score is NULL.

## Architecture

### Indexing Pipeline (8 phases)
1. **Scan** — FileScanner reads EXIF captureDate, colorProfile from CGImageSource
2. **Duplicate detection** — dHash perceptual hashing, Hamming threshold=6
3. **Thumbnails** — 512px via CGImageSourceCreateThumbnailAtIndex (prevents IOSurface exhaustion)
4. **CLIP extraction** — CLIPCoreMLEngine, 224px input, cosine similarity embeddings
5. **Captioning** — OllamaCaptioningEngine → `qwen2.5vl-caption` via localhost:11434; captions ALL uncaptioned active images each run
6. **Accent color extraction** — backfills `accentHue` / `accentSaturation` for all active images WHERE accentHue IS NULL; uses 256px downsample, 24 hue bins (15°), prominence = area × mean saturation, 5–40% pixel fraction window, saturation floor 0.25; NULL for B&W/neutral images — decision #54
7. **Saliency centroid + gaze extraction** — backfills `weightCentroidX`, `weightCentroidY`, and `gazeDirectionX` for all active images WHERE weightCentroidX IS NULL OR gazeDirectionX IS NULL; three Vision requests in one pass: `VNDetectHumanRectanglesRequest` (primary centroid: area-weighted human bounding boxes, confidence ≥ 0.3), `VNGenerateAttentionBasedSaliencyImageRequest` (centroid fallback for non-human subjects), `VNDetectFaceLandmarksRequest` (gaze: pupil offset within eye contour → [-1=left, +1=right], no fallback — returns nil when pupils not detected); runs on cached 512px thumbnails — decisions #59, #64, #65, #69
8. **Pair scoring** — PairScorer, four-pool topK (composite top-150 + thematic top-50 + geometric top-5 + aesthetic top-5); two-phase: intra-folder first (blocking), cross-folder in background (cancellable) — decisions #34, #68, #75, #76
9. **ThematicV2 background pass** — `ThematicV2BackgroundPass` (actor, ConjunctEngine) runs after each page-0 grid load, scores candidate pairs (aesthetic or geometric > 0.3, both captioned, `thematicV2Score IS NULL`, LIMIT 500) sequentially via `ThematicScorerV2` using llama3.2 on Ollama. Writes `thematicV2Score / thematicV2RelationshipType / thematicV2Rationale` to DB. Triggered from `EngineController.startThematicV2Pass()` after `streamPage0Pairs` completes; cancelled when a new index starts. **Near-duplicate guard:** candidates with identical `captureDate` (burst shots) are excluded by SQL; candidates sharing a normalized base filename (numeric-prefix variants like `63-foo.jpg` / `foo.jpg`) are excluded in Swift after the fetch. See decisions #82, #83.

### Three Scoring Axes (PairScorer.swift)
- **Aesthetic (weight 0.40)** — Three-way max: HSL histogram intersection (harmony), LAB palette contrast (contrast), or accent color echo (accent_echo). Echo score = `hueScore × √(satA × satB)` where hueScore ramps ≤10°→1.0, ≤30°→linear, >30°→0. Winning pathway sets `aestheticSubmode`. B&W pairs: harmony and contrast are multiplied by 0.65 — the 8-bin lightness-only comparison is less discriminative than the full 1,152-bin colour histogram, so scores are discounted rather than suppressed; a genuinely tonal-resonant B&W pair (both high-key, both moody) should score ~0.55–0.70; echo unaffected since `accentHue` is nil for B&W. Contrast normalization: `/100` (was `/80`) — avg LAB distance 100 = score 1.0. `colorProfile` must be fetched in `imageMeta` and passed to `PairScorer.score()` for suppression to fire. See decisions #56, #77.
- **Geometric (weight 0.20)** — three-component formula: `structural×0.50 + directional×0.25 + breath×0.25`. Structural = (edge orientation cosine × edgeMult + grid cosine × varMult) / 2; directional = `max(centroidScore, gazeScore)` — centroidScore from `directionalComplementScore()` using per-image `weightCentroidX/Y` (Vision human-detection centroid, decision #64); gazeScore from `gazeConversationScore()` using per-image `gazeDirectionX` (VNDetectFaceLandmarksRequest pupil offset, normalized by dividing by 0.30 to fill [-1,+1] before scoring, decision #70); gaze scored symmetrically — both directions tried, max taken — so pairs aren't missed due to arbitrary DB ID ordering (decision #71); rightward-gazer is always stored as imageAID (left display) for correct diptych orientation; orientationScore from `orientationOppositionScore()` using stored 32-bin edge histogram — dominant bin folded to undirected [0,16), scored as `sin(dist×π/16) × √(normPeakA×normPeakB)` with a hard diagonalness gate: both images must have dominant direction in the 22.5°–67.5° zone (`|sin(undirBin×π/8)| ≥ 0.50`); bins within ~22.5° of horizontal or vertical return 0 (decisions #73, #74); `directional = max(centroidScore, gazeScore, orientationScore)`; breath = `abs(normVarA − normVarB)`. When directional > structural: `geometricSubmode` = `"gaze_conversation"` / `"opposing_diagonals"` / `"directional_complement"` based on which directional signal won. Rationale strings per submode. `geometricSubmode` stored per pair in DB (v13 migration). See decisions #59, #60, #64, #65, #67, #70, #71, #73, #74.
- **Thematic (weight 0.40, boosted to 0.60 when dominant)** — weighted Dice coefficient on ConceptClusters matched from qwen captions; CLIP cosine fallback when no captions. Boost fires when `thematic >= 0.20 && thematic >= max(aesthetic, geometric × 0.8)` — i.e., thematic must be the dominant axis. Before #75, the boost fired at `thematic >= 0.20` unconditionally, penalising strong two-axis pairs. See decision #75. **ThematicV2 override:** at display time, `effectiveThematic = thematicV2Score ?? thematicScore` — the LLM pair-level score replaces the cluster score when available. See decision #82.

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

**Geometric** — *should measure:* structural rhyme, directional complement (figures spatially facing each other / strong lines leading from one image to the next), or breath (dense image paired with spare/open image). *Currently measures:* three-component formula `structural×0.50 + directional×0.25 + breath×0.25` — structural via edge/grid cosine similarity, directional via `max(centroidScore, gazeScore)` where centroidScore uses Vision human-detection centroid opposition (`weightCentroidX/Y`, decision #64) and gazeScore uses face landmark pupil direction (`gazeDirectionX`, decision #65), breath via tonal weight differential. Geometric topK pool (top-5 per image with submode variety bonus) gives gaze_conversation and directional_complement pairs an escape hatch from composite dominance (#68). *Missing:* uniform area ratio for genuine sparseness detection; light quality.

### Known Scoring Failures
- **Musician + ears-woman:** Both captions share `sound_music` + `sensory_overwhelm` vocabulary → Dice > ambient floor → axis bonus guard fires. Pair scores via Dice but ranks below thematic topK cutoff. Only caption redesign (#50) fixes this.
- **Breath pairs:** Geometric differential ~0.07 composite max is below surfacing threshold. Aesthetic tonal weight complementarity (#55) needed to close the gap.
- **Mode 2 beyond color echo:** Light quality echo and gestural/energetic echo are unmeasured anywhere in the system.

## Known Gotchas

**B&W aesthetic discount requires colorProfile in imageMeta** — `PairScorer.aestheticScore()` discounts harmony and contrast scores (×0.65) for B&W pairs via `colorProfileA/B` params. These are fetched from the `images` table into the `imageMeta` tuple in both `runIntraFolderScoring` and `runCrossFolderScoring`. If either SQL SELECT or `imageMeta` typealias is modified, keep `colorProfile` in the query. Without it, B&W pairs will revert to inflated aesthetic scores. See decision #77.

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

## Workflow

When completing any feature or fix, follow these steps in order before considering the task done:

1. **Branch** — work on a branch named `[type]/[decision-id]-[short-description]` (e.g. `feat/54-accent-color`, `fix/26-temporal-penalty`). Create it at the start, not the end.
2. **Code complete** — implement and verify the change works.
3. **Docs** — update `CLAUDE.md` and `DECISIONS.md` to reflect the change. Check both files deliberately: not just the obvious section, but anything touched by the change (Known Gotchas, Open Backlog, Architecture overview).
4. **Commit** — use `#ID` prefix convention. Doc updates go in the same commit or a follow-up commit on the same branch. Do not leave doc updates uncommitted.
5. **Merge check** — confirm all commits are on the branch and nothing is dangling or uncommitted.
6. **PR ready** — confirm the branch is pushed. State the suggested PR title and a one-paragraph description summarising what changed and why.
7. **Branch cleanup** — after the PR is merged, delete the remote branch.

Do not report the task as complete until all 7 steps are done.

## Open Backlog Items
| # | Title | Notes |
|---|-------|-------|
| 7 | Settings that require re-index | dHash threshold + CLIP similarity ceiling affect data written to DB; UI should distinguish these from cheap runtime settings. See decision #7. |
| 8 | Double CLIP build on launch | Race in `engineBuildTask?.cancel()` on some launches. No crashes recently — monitor. See decision #8. |
| 11 | FileAccessCoordinator centralization | Centralise security-scoped bookmark management; detect invalid bookmarks; clean up stale entries on `removeFolder`; handle offline volumes. See decision #11. |
| 14 | Continue geometric scorer tuning | Step distinctiveness multiplier exponent down from 0.4; add multiplier-strength slider; evaluate normalization anchors. See decision #14. |
| 16 | Center-cell discount | Slider + Apply button for peripheral composition cell weighting. Requires re-score (not full re-index). See decision #16. |
| 23 | Revisit dot badge on pair grid tiles | Recalibrate threshold + improve visual legibility after topK and scoring changes settle. See decision #23. |
| 35 | "Find Pairs For…" — explore or retire | Button removed (no implementation); evaluate vs. existing anchor/filmstrip flow before building. See decision #35. |
| 43 | Layout recursion warning | Console: "-layoutSubtreeIfNeeded on a view which is already being laid out" — once per launch, likely PassthroughHostingView insertion timing. See decision #43. |
| 46 | Complementary role scoring — two sides of the same phenomenon | Implemented via axis pairs (#47, #48, #49). Post-implementation diagnostic: canonical test pair (musician+ears) still absent from DB — both images share `sound_music` and `sensory_overwhelm` vocabulary, so Dice > ambient floor and axis bonus guard fires. See decisions #47, #48, #49. |
| 47 | animal_presence demoted to ambient tier (0.75 → 0.2) | Done. Dog+dog pairs reduced but not eliminated — they still score via shared 0.75-tier behavior clusters. See decision #47. |
| 48 | Complementary axis pair bonus | Done. 9 axis pairs defined in `ConceptClusters.axisPairs`. Axis bonus fires only when `clusterScore ≤ 0.10`. See decision #48. |
| 49 | Meaningful asymmetry gate — weight ≥ 0.75 unique clusters per side | Done. Replaced `!onlyA.isEmpty && !onlyB.isEmpty` with meaningful-tier filter in `PairScorer.swift`. See decision #49. |
| 50 | Caption prompt redesign — emotional register over scene description | **In progress.** Revised prompt committed to `CaptioningEngine.swift` (2026-06-10). Two additions: direction-of-action language + explicit transmission/exchange paragraph. Validated on 3 pilot images (violinist, woman on steps, punk singer) — directionality language fires correctly, no false positives on inward-turning subjects. Three pilot captions written to DB. Next step: full library re-caption (null all captions, trigger Phase 5 on next re-index). See decision #50 in DECISIONS.md. |
| 55 | Breath pairs — aesthetic axis tonal weight complementarity | Geometric axis (#53) contributes `abs(normVarA − normVarB)` differential (weight 0.4/2.4) but max composite lift is ~0.07 — not enough to surface breath pairs reliably. Next step: add tonal weight complementarity as Component 3 of the aesthetic axis (weight 0.30 within aesthetic, ~0.12 max composite lift). Prerequisite: visually confirm `20250426-_R016343.jpg` and `20210313-L1001045.jpg` as genuine open/spare breath-pair candidates. See decision #55 and PAIRING_THEORY.md §Aesthetic axis redesign. |
| 56 | Accent color echo — pair scoring + info panel | Done. `accentEchoScore = hueScore × √(satA × satB)`, hue ramp ≤10°→1.0, ≤30°→linear, >30°→0. Three-way max in `aestheticScore()` with `harmony` and `contrast`. Lightbox info rail shows "Color echo" label with two hue swatches when `aestheticSubmode == "accent_echo"`. Canonical test pair (`_R017085` + `R0024458`, both accentHue≈7.5°) confirmed in pairs table post re-index. See decision #56. |
| 59 | Directional complement scoring — geometric axis | Superseded by #64. Edge-energy centroid proven ineffective (stdev=0.046, 96.1% of library in centX [0.40, 0.60]). Scoring infrastructure (columns, `directionalComplementScore()`, Phase 3.7) retained; computation replaced with Vision saliency in #64. Structural weight partially restored in #60. See decision #59. |
| 60 | Restore geometric structural weight | Done. Superseded by #67 (current weights: `structural×0.50 + directional×0.25 + breath×0.25`). See decision #60. |
| 64 | Vision saliency centroid — replace edge-energy centroid | Done. Validated 2026-05-17: stdev_x = 0.141 (> 0.10 threshold ✅). Coverage 99.8%. See decision #64. |
| 61 | Directional complement — dominant orientation opposition | Use the existing 32-bin `edgeOrientation` histogram (stored per image in `featureVectors`, not read at score time). Extract dominant bin angle per image; score opposition as angular distance mapped so 180° → 1.0. No new data or re-index. Would detect opposing diagonals (DSCF3269-positive). |
| 62 | Directional complement — regional orientation histogram | Per-cell dominant edge direction from an 8×8 grid. Would capture "subject on left facing right" as rightward edges in left cells. Requires new extraction phase + DB schema. Long-term. |
| 63 | Gaze / body direction detection | Done — implemented as `gazeDirectionX` via `VNDetectFaceLandmarksRequest` in Phase 3.7. Pupil-only (head-yaw fallback removed in #69). See decision #65. |
| 65 | Gaze direction scoring | Done. Coverage will be lower after #69 fallback removal (~15–20% pupil-only vs 47% with fallback). Signal quality significantly improved — false positives from tilted/recumbent faces eliminated. See decisions #65, #69. |
| 69 | Drop head-yaw gaze fallback — pupil-only detection | Done. v14 migration nulls existing gaze readings; re-extracted pupil-only on next re-index. See decision #69. |
| 70 | Gaze score normalization — rescale pupil signal to fill [-1, +1] | Done. `kGazeScale = 1.0 / 0.30` applied in `gazeConversationScore()`. No re-index needed; takes effect on next re-score. See decision #70. |
| 71 | Symmetric gaze scoring + canonical display order | Done. `geometricScore()` now takes max(forward, reversed) gaze directions so pairs aren't missed due to ID ordering. Rightward-gazer is always stored as imageAID (left display). See decision #71. |
| 73 | Dominant orientation opposition — opposing_diagonals submode | Done. `orientationOppositionScore()` uses stored 32-bin edge histogram: find dominant bin per image, fold to undirected [0,16), score perpendicularity as `sin(dist×π/16) × √(normPeakA × normPeakB)`. Wired into `directional = max(centroidScore, gazeScore, orientationScore)`. New submode `"opposing_diagonals"`. No re-index. See decision #73. Calibration fix in #74. |
| 74 | Opposing diagonals — diagonalness gate + submode display | Done. Hard gate in `orientationOppositionScore()`: both images must have dominant direction in 22.5°–67.5° zone (`|sin(undirBin×π/8)| ≥ 0.50`). Filters near-horizontal/vertical; `_DSF2811` filtered, DSCF3269/_DSF1497 retain full scores. Pool: 75 pairs (down from 2,487). Lightbox info rail now shows submode-specific label: "Diagonal tension" / "Eyes in conversation" / "Spatial tension" / "Compositional structure". `geometricSubmode` threaded through `DisplayPair`. No re-index. See decision #74. |
| 67 | Directional weight rebalance after centroid + gaze validation | Done. `structural×0.50 + directional×0.25 + breath×0.25`. Conservative given gaze stdev 0.208 < 0.30. See decision #67. |
| 68 | Geometric topK pool — per-submode surfacing escape hatch | Done. Top-5 per image by geometricScore with submode variety bonus. `selectedFor = "geometric"`. `geometricSubmode` stored in DB (v13 migration). Requires re-score. See decision #68. |
| 66 | Composite scoring rethink — per-axis surfacing | Done. Three-phase fix: #75 (thematic boost fix + aesthetic topK pool) ensured one-axis-exceptional pairs enter the DB; #76 (axisScore "Best" sort) changed default ranking; #77+#78 calibrated aesthetic scoring and blended axisScore to prevent single-axis monopolization. Default sort: "Best" (`axisScore = 0.6×peakScore + 0.4×displayComposite` where `peakScore = max(aesthetic, geometric×0.8, thematic) × temporalPenalty`). See decisions #75, #76, #77, #78. |
| 75 | Thematic boost fix + aesthetic topK escape hatch (prerequisite for #66) | Done. (1) Thematic boost condition tightened: only fires when thematic is the dominant axis (`thematic >= max(aesthetic, geometric×0.8)`). (2) Aesthetic topK pool added (top-5 per image, ≥0.55 floor, `selectedFor = "aesthetic"`), symmetric to geometric pool (#68). (3) Modality detection in PairHelpers.swift updated. Requires re-score. See decision #75. |
| 76 | axisScore display field + "Best" default sort | Done. `axisScore` field added to `DisplayPair`. Default sort changed from "Composite" to "Best". "Composite" renamed "Balanced". Formula updated in #78 to blend with composite. No DB changes. See decisions #76, #78. |
| 77 | B&W aesthetic discount + contrast ceiling recalibration | Done. B&W pairs: harmony and contrast multiplied by 0.65 (was 0.35, revised after over-suppression). `paletteContrastScore()` divisor changed from `/80` to `/100`. Requires re-score. See decision #77. |
| 78 | axisScore blend formula | Done. `axisScore = 0.6×peakScore + 0.4×displayComposite`. No re-score. See decision #78. |
| 80 | B&W aesthetic tuning — lighter and lower-contrast pairs | High-contrast B&W pairs surface well after #77 calibration. Lower-contrast and high-key B&W pairs (e.g. softer, more luminous work) are under-represented — the lightness histogram has fewer images to compare against in a typical library and the 8-bin resolution may not distinguish tonal styles within the low-contrast range. Revisit when the library includes more varied B&W work or if specific failing pairs can be identified. The geometric axis can also produce false-positive B&W pairs via structural edge similarity (e.g. tree silhouette + scooter chaos both scoring high on edge orientation) — noted 2026-06-09. |
| 81 | Caption correction for known-failing thematic pairs | Two pairs fail due to caption quality, not scoring architecture. Smile text (`96-20250823-_DSF6565.jpg`) + basketball hoop man (`20-20240909-_DSF9023.jpg`): hoop caption must make mouth-covering explicit. Gun/costume (`73-20250606-_R019980.jpg`) + punk singer (`04-20160709-IMG_8931.jpg`): punk caption must surface directed provocation, not just performance energy. Approach: manually correct captions for `20-20240909-_DSF9023.jpg` and `04-20160709-IMG_8931.jpg`, write to DB, re-score to validate. Feeds back into #50. |
| 72 | Directed-attention / looking-toward pairs | **Observation (2026-05-23):** The gaze scoring system only rewards face-to-face opposition (A looks right, B looks left). An equally valid — often more subtle — pairing is where a figure in one image is looking toward something that is the subject of the paired image: a person looking at hands + a close-up of hands; a child looking at a door + a threshold image. Validated example: L1007802 (woman looking right) + L1001626 (hands with wedding ring) — the look is directed AT the subject of the companion image, reinforced by color echo. Current system scores this as structural because L1001626 has no detected gaze. **Why it's hard:** requires understanding what a gaze is directed toward, not just which direction the pupils point. Requires either (a) caption-based inference ("woman looking at hands" → pair with hand images) or (b) CLIP region features to detect semantic continuity between gaze direction and companion content. Not solvable at pixel/gaze level alone. Backlog until caption redesign (#50) provides richer relational context. |
| 57 | Accent echo — desaturated reds under shadow | Under low-light or shadow, photographic reds maintain hue but lose saturation. `√(satA × satB)` penalises these even when the pair is a genuine echo. Would require reasoning about hue purity independent of luminance — not solvable at pixel-statistics level without scene context. Backlog until a test case justifies the complexity. |
| 58 | Accent echo — ambient hue exclusion (foliage green, sky blue) | Distinguishing billboard green from foliage green, painted blue from sky blue, requires scene context (caption vocabulary, CLIP region features) not available at score time. `√(satA × satB)` partially compensates (dull ambient greens have low saturation), but vivid sky or foliage could still inflate scores. Cannot be solved at pixel-statistics level without knowing what a color "belongs to." Backlog. |
| 84 | ThematicV2BackgroundPass near-duplicate guard — validate against other libraries | The current guard has two mechanisms: (1) SQL `captureDate` exact-match filters burst shots — robust across naming schemes; (2) `normalizedBaseName()` strips leading numeric prefixes (`63-foo.jpg` / `foo.jpg`) — specific to this library's export workflow and will silently miss variants in libraries with different naming conventions (`foo_edit.jpg`, `foo-crop.jpg`, `foo (1).jpg`, etc.). When testing against a second library, check the thematic-sorted grid for near-duplicate pairs surfacing near the top. If found, evaluate whether a `thematicScore > 0.90` floor (identical captions = near-identical images) or a small captureDate window (`ABS(a.captureDate - b.captureDate) <= 3`) would catch them without filtering genuine high-thematic pairs. See decision #83. |

## Commit Convention
Use `#ID` prefix matching the decisions log:
```
fix(#26): replay temporal penalty in convertToPair
feat(#21): add collapsed caption display to info rail
chore: initial commit
```
