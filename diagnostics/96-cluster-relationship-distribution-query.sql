-- #96 passes 1–2: per-cluster relationshipType distribution + rationale mining
--
-- Exports the two JSON inputs the harness (96-cluster-relationship-distribution-harness.swift)
-- reads: judged_pairs.json (every judged pair, both captions + rationale) and
-- corpus_captions.json (all active-captioned images, for Part A's corpus-level firing).
-- Run against a COPY of the DB, never the live one:
--
--   sqlite3 <db-copy> <<SQL
--   .mode json
--   .output judged_pairs.json
--   <query 1 below>
--   .output corpus_captions.json
--   <query 2 below>
--   SQL
--
-- Then: ClusterDiag judged_pairs.json corpus_captions.json
-- See DECISIONS.md #96 (passes 1–2) for the full write-up.

-- Query 1 — judged_pairs.json
SELECT p.id AS pairID, p.imageAID, p.imageBID,
       p.thematicV2Score AS score,
       p.thematicV2RelationshipType AS relType,
       p.thematicV2Rationale AS rationale,
       p.roleHypothesis AS roleHyp,
       a.caption AS captionA, b.caption AS captionB,
       a.filename AS filenameA, b.filename AS filenameB
FROM pairs p
JOIN images a ON a.id = p.imageAID
JOIN images b ON b.id = p.imageBID
WHERE p.thematicV2Score IS NOT NULL;

-- Query 2 — corpus_captions.json (Part A: full-corpus image-level firing)
SELECT id, isHero, filename, caption
FROM images
WHERE isActive = 1 AND caption IS NOT NULL AND caption != '';
