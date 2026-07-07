-- #98: Caption gaze-direction hallucination — impact on ThematicV2 judged output
--
-- Run against the live DB:
--   sqlite3 ~/Library/Containers/com.toastingmachine.Couplet/Data/Library/"Application Support"/Conjunct/conjunct.db < diagnostics/98-gaze-hallucination-query.sql
--
-- "Flagged" = captions asserting a gaze target (`looking at/toward/down at/up at`,
-- `looks at`, `gazing/gazes at`) with no `camera` or `frame` mention — i.e. the caption
-- claims a specific in-frame target rather than honestly hedging (camera-directed or
-- explicitly off-frame). This is a re-derivation, not the original methodology behind
-- the "159" figure quoted in the CLAUDE.md backlog line — no derivation for that number
-- was preserved in this log. This phrase list yields 166 images against the DB snapshot
-- used for the 2026-07-07 diagnostic (close enough to be confident it's the same
-- population). See DECISIONS.md #98 for the full write-up.

CREATE TEMP TABLE flagged AS
SELECT id, caption FROM images
WHERE isActive = 1 AND (
  caption LIKE '%looking at%' OR caption LIKE '%looks at%' OR
  caption LIKE '%gazing at%' OR caption LIKE '%gazes at%' OR
  caption LIKE '%looking toward%' OR caption LIKE '%looking towards%' OR
  caption LIKE '%looking down at%' OR caption LIKE '%looking up at%'
)
AND caption NOT LIKE '%camera%'
AND caption NOT LIKE '%off-camera%'
AND caption NOT LIKE '%off camera%'
AND caption NOT LIKE '%off-frame%'
AND caption NOT LIKE '%off frame%'
AND caption NOT LIKE '%out of frame%'
AND caption NOT LIKE '%out of the frame%';

-- Scale: flagged count, candidate-pool entry, judged-pair entry
SELECT 'flagged_count' AS metric, COUNT(*) AS value FROM flagged
UNION ALL
SELECT 'flagged_in_any_pair', COUNT(DISTINCT f.id)
FROM flagged f JOIN pairs p ON p.imageAID = f.id OR p.imageBID = f.id
UNION ALL
SELECT 'flagged_in_judged_pair', COUNT(DISTINCT f.id)
FROM flagged f
JOIN pairs p ON (p.imageAID = f.id OR p.imageBID = f.id) AND p.thematicV2Score IS NOT NULL
UNION ALL
SELECT 'judged_pairs_involving_flagged', COUNT(DISTINCT p.id)
FROM pairs p JOIN flagged f ON p.imageAID = f.id OR p.imageBID = f.id
WHERE p.thematicV2Score IS NOT NULL;

-- Judged pairs (touching a flagged image) whose rationale references gaze/look/eye/
-- watch/attention/observe vocabulary — the set that needs manual classification into
-- "leans on it" / "present but incidental" / "not surfaced".
SELECT
  p.id AS pairID, p.imageAID, p.imageBID,
  p.thematicV2Score, p.thematicV2RelationshipType, p.compositeScore,
  p.roleHypothesis, p.selectedFor,
  p.thematicV2Rationale
FROM pairs p
LEFT JOIN flagged fa ON fa.id = p.imageAID
LEFT JOIN flagged fb ON fb.id = p.imageBID
WHERE p.thematicV2Score IS NOT NULL
AND (fa.id IS NOT NULL OR fb.id IS NOT NULL)
AND (
  p.thematicV2Rationale LIKE '%look%' OR
  p.thematicV2Rationale LIKE '%gaz%' OR
  p.thematicV2Rationale LIKE '%watch%' OR
  p.thematicV2Rationale LIKE '%stare%' OR
  p.thematicV2Rationale LIKE '%eye%' OR
  p.thematicV2Rationale LIKE '%glance%' OR
  p.thematicV2Rationale LIKE '%attention%' OR
  p.thematicV2Rationale LIKE '%observ%'
)
ORDER BY p.compositeScore DESC;
