# Findings — Role-extraction candidate generation (supports backlog #95)

**Date:** 2026-06-15  **Status:** validated approach, not yet built
**Scripts:** `/tmp/caption-test/role_validate.py` (cheap-model run), `/tmp/caption-test/role_oracle.py` (good-extractor run). Both apply the *same* deterministic join code.

## The question
Backlog #95/#99 established that the four-pool topK **entry gate** is the binding constraint: genuine conceptual pairs never enter the `pairs` table, so no candidate-ordering (#100) or scorer (#85) change can reach them. The entry gate needs a new candidate generator. This doc records which mechanism works, measured against the 8 hand-curated golden pairs + 3 known-bad pairs.

## Three mechanisms tested on the same pairs
| mechanism | golden pairs reached | why |
|---|---|---|
| caption-embedding kNN (similarity) | **0 / 8** | golden partners rank 13–93 of 109 nearest neighbours; complementary pairs have *dissimilar* captions by construction. Re-confirms decision #51. |
| keyword-cluster axis-pairs (#48) | **0 / 8** | the sound↔sensory axis fires on violinist+ears but the bonus is suppressed because "block out a **sound**" makes the receiver also fire `sound_music`; the ironic pairs fire nothing. Keyword presence measures *aboutness*, not *role*. |
| **role extraction → join rules** | **7 / 8** (8th is the weakest pair) | encodes the relationship (source/receiver, claim/enactment, real/toy), which both aboutness methods structurally cannot. |

The root insight: similarity (embeddings) and keyword-clusters both measure **aboutness**; third-meaning pairs are about **role**. "violin" and "block out a sound" are both *about* sound — only role tells you one *produces* and one *blocks*.

## The approach
```
per image:  caption ──[LLM, ~990 one-time calls]──▶ RoleProfile (typed slots)
pairing:    RoleProfiles ──[deterministic + bounded semantic join]──▶ candidate set
scoring:    candidates ──[bigger judge, #85]──▶ kept pairs
```
Roles do **recall** (get the right pairs into the candidate set); the judge does **precision**. Per-*image* extraction (≈990 calls) is affordable; per-*pair* (≈489K) is not.

### RoleProfile schema (per image)
- `subjects`: salient nouns
- `phenomena`: `[{phenomenon ∈ (sound,gaze,motion,force,touch,speech,heat,smell), role ∈ source|receiver}]` — musician = sound/source; hands-over-ears = sound/receiver
- `claims`: statements the image **displays** as text/sign, **normalized to meaning** ("SEE SOMETHING SAY SOMETHING" → "report danger")
- `enacts` / `subverts`: concepts the **subject** embodies / contradicts (smiling = enacts "smile"; covered mouth = subverts "smile") — **not text-dependent**
- `objects`: `[{object, register ∈ real|toy|depicted|costume|sign, category}]` — real gun vs toy gun; live pigeon vs depicted peacock (category "bird")
- `directed_at`: nameable target of a gaze/action (#72)
- `stance`: `{attitude, target ∈ viewer|subject}` or null

### Join rules (recall-oriented; judge filters)
1. **Source ↔ Receiver** — A `(P,source)`, B `(P,receiver)` → complementary
2. **Claim ↔ Enact/Subvert** — concept in A.claims/enacts matches B.enacts/subverts → ironic (carries 4 of 8 golden; the only one nothing else can do)
3. **Same object, opposite register** — A `(O,real)`, B `(O,toy|depicted|costume)`, matched on `category` → contrastive
4. **Attention ↔ target** — x in A.directed_at ∈ B.subjects/objects → complementary (#72)
5. **Shared outward stance** — same attitude, both outward → tonal (fuzziest; build last)

## Validation result
| golden pair | cheap 3B | good extractor | join |
|---|---|---|---|
| violinist+ears | ✅ | ✅ | 1 source/receiver (sound) |
| gun+water-gun | ✅ | ✅ | 3 real/toy (gun) |
| smile+smiling-woman | ✅ | ✅ | 2 claim/enact (smile) |
| sunscreen+see-something | ❌ | ✅ | 2 claim/enact (watch) |
| see-something+gun | ❌ | ✅ | 2 claim/enact (danger) |
| smile+hoop | ❌ | ✅ | 2 claim/subvert (smile) |
| pigeons+peacock | ❌ | ✅ | 3 real/depicted (bird) |
| gun+punk | ❌ | ❌ | — deadpan gun, no shared stance (oracle ~0.55; arguably correct reject) |
| **3 bad pairs** | **0 join** | **0 join** | zero false positives |

**Good extractor: 7/8 golden, 0/3 bad, four of five join types firing.** The cheap 3B reaches only 3/8 — limited by extraction quality (skips claim normalization, fails to infer subversions, misses objects like the printed eyes), the same cheap-model ceiling seen in #99.

## Two refinements the validation surfaced
1. **Claim normalization is load-bearing.** see-something+gun missed on the 3B *only* because it left the sign text verbatim instead of normalizing to "report danger" (gun already had `enacts:["danger"]`). The extractor must normalize sign text to meaning — a comprehension task → the #85 model.
2. **Object joins need a `category` (hypernym) field.** pigeons+peacock connected only when both birds were tagged `category:"bird"` rather than exact noun `"pigeon"`/`"peacock"`.

## Implications for the build
- The gating factor is **model quality — now for extraction, not just judging.** One good model (#85's) serves double duty: per-image extraction *and* per-candidate judging. This simplifies the cost story.
- **Supersedes axis-pairs (#48)** — delete them. Keep keyword-clusters only for UI labels + the cheap same-theme similarity pool, with a path to converge both into one per-image LLM extraction once roles are proven.
- This is the v1 entry-gate mechanism. Drop the caption-embedding backfill (it only fed the dead kNN path).

## Honest limits
- n=8/3 is tiny. 0/3 bad is encouraging, not a scale guarantee. **Join 2 is the over-fire risk at scale** ("danger" matches many objects); the judge is the precision backstop and candidate-flood size must be measured (score-harness) before any live run.
- The "good extractor" is a frontier model reading captions, run through the *identical* deterministic join code — it establishes the ceiling, but the real number depends on whether the #85-class local model produces similar profiles. Confirm that first when wiring it up.
- Join matching here used token-overlap as a stand-in for the real bounded semantic step (short concept vs object/subject tags). That semantic step's precision/recall needs its own measurement at scale.
