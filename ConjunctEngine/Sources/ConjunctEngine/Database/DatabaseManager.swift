import Foundation
import GRDB

public final class DatabaseManager: Sendable {

    private let pool: DatabasePool

    public init(url: URL) throws {
        // FIX: was `var config` — changed to `let` since config is never mutated.
        // Uncomment the prepareDatabase line below and change back to `var` if you
        // want to enable SQL logging during development.
        let config = Configuration()
        pool = try DatabasePool(path: url.path, configuration: config)
        try applyMigrations()
    }

    // MARK: - Public access

    public func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) throws -> T {
        try pool.write(updates)
    }

    public func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) throws -> T {
        try pool.read(value)
    }

    // MARK: - Migrations

    private func applyMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in

            try db.create(table: "folders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("displayName", .text)
                t.column("bookmarkData", .blob)
                t.column("driveType", .text)
                t.column("exclusionPatterns", .text)
                t.column("lastIndexedAt", .integer)
                t.column("isActive", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "images") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("contentHash", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("folderID", .integer).references("folders")
                t.column("captureDate", .integer)
                t.column("cameraModel", .text)
                t.column("lensModel", .text)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.column("fileFormat", .text).notNull()
                t.column("thumbnailPath", .text)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("indexedAt", .integer).notNull()
            }

            try db.create(table: "featureVectors") { t in
                t.column("imageID", .integer)
                    .primaryKey()
                    .references("images", onDelete: .cascade)
                t.column("clipEmbedding", .blob).notNull()
                t.column("hslHistogram", .blob).notNull()
                t.column("dominantPalette", .blob).notNull()
                t.column("edgeOrientation", .blob).notNull()
                t.column("compositionGrid", .blob).notNull()
                t.column("extractedAt", .integer).notNull()
            }

            try db.create(table: "pairs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("imageAID", .integer).notNull().references("images")
                t.column("imageBID", .integer).notNull().references("images")
                t.column("aestheticScore", .double).notNull()
                t.column("aestheticSubmode", .text).notNull()
                t.column("geometricScore", .double).notNull()
                t.column("thematicScore", .double).notNull()
                t.column("compositeScore", .double).notNull()
                t.column("rationale", .text).notNull()
                t.column("scoredAt", .integer).notNull()
                t.uniqueKey(["imageAID", "imageBID"])
            }

            try db.create(table: "userDecisions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pairID", .integer)
                    .notNull()
                    .references("pairs", onDelete: .cascade)
                t.column("decision", .text).notNull()
                t.column("decidedAt", .integer).notNull()
            }

            try db.create(table: "collections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "collectionPairs") { t in
                t.column("collectionID", .integer)
                    .notNull()
                    .references("collections", onDelete: .cascade)
                t.column("pairID", .integer)
                    .notNull()
                    .references("pairs", onDelete: .cascade)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("addedAt", .integer).notNull()
                t.primaryKey(["collectionID", "pairID"])
            }

            try db.create(
                index: "idx_pairs_imageAID_score",
                on: "pairs", columns: ["imageAID", "compositeScore"]
            )
            try db.create(
                index: "idx_pairs_imageBID_score",
                on: "pairs", columns: ["imageBID", "compositeScore"]
            )
            try db.create(
                index: "idx_pairs_score",
                on: "pairs", columns: ["compositeScore"]
            )
            try db.create(
                index: "idx_images_folder_date",
                on: "images", columns: ["folderID", "captureDate"]
            )
            try db.create(
                index: "idx_userDecisions_pairID",
                on: "userDecisions", columns: ["pairID"]
            )
        }

        // ── v2: Duplicate detection ───────────────────────────────────────
        migrator.registerMigration("v2_duplicates") { db in

            // Groups of near-duplicate images identified by perceptual hash
            try db.create(table: "duplicateGroups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .integer).notNull()
                t.column("memberCount", .integer).notNull().defaults(to: 0)
            }

            // Add perceptual hash and duplicate tracking to images
            try db.alter(table: "images") { t in
                // 16-char hex string representing the 64-bit dHash
                t.add(column: "dHash", .text)
                // FK to duplicateGroups — null if image is not part of any group
                t.add(column: "duplicateGroupID", .integer)
                    .references("duplicateGroups")
                // True if this is the representative image for its duplicate group.
                // Non-duplicate images are always their own hero (effectively true).
                t.add(column: "isHero", .boolean).notNull().defaults(to: true)
            }

            try db.create(
                index: "idx_images_dHash",
                on: "images", columns: ["dHash"]
            )
            try db.create(
                index: "idx_images_duplicateGroup",
                on: "images", columns: ["duplicateGroupID"]
            )
        }

        // ── v3: Image captions ────────────────────────────────────────────
        migrator.registerMigration("v3_captions") { db in
            try db.alter(table: "images") { t in
                // Natural-language caption generated by a vision-language model.
                // Empty string = not yet captioned. NULL = captioning not run.
                t.add(column: "caption", .text)
            }
        }

        // ── v4: Color profile ─────────────────────────────────────────────
        migrator.registerMigration("v4_colorProfile") { db in
            try db.alter(table: "images") { t in
                // "color" or "bw" — detected from CGImagePropertyColorModel at scan time
                t.add(column: "colorProfile", .text).defaults(to: "color")
            }
        }

        // ── v5: Geometric sub-scores for display-time slider gating ───────
        // Stores the raw (pre-gate) edge and grid cosine similarities alongside
        // per-pair peakedness and variance stats. Display-time sliders in Settings
        // use these to recompute geometric score without a re-score or re-index.
        // NULL = pair predates this migration; falls back to stored geometricScore.
        migrator.registerMigration("v5_geometricStats") { db in
            try db.alter(table: "pairs") { t in
                t.add(column: "rawEdgeSim",        .double)
                t.add(column: "rawGridSim",        .double)
                t.add(column: "maxEdgePeakedness", .double)
                t.add(column: "maxGridVariance",   .double)
            }
        }

        // ── v6: Distinctiveness multipliers for display-time geometric scoring ───
        // Stores the per-pair √(norm_A × norm_B) multipliers so display-time logic
        // can apply them to rawEdgeSim / rawGridSim without holding feature vectors.
        // NULL = pair predates this migration; falls back to stored geometricScore.
        migrator.registerMigration("v6_distinctivenessMultipliers") { db in
            try db.alter(table: "pairs") { t in
                t.add(column: "edgePeakednessMult", .double)
                t.add(column: "gridVarianceMult",   .double)
            }
        }

        // ── v7: Clear moondream captions ──────────────────────────────────
        // All captions were generated by moondream 1.8B, which is being replaced
        // by qwen2.5vl:7b with a new prompt. The two models produce incompatible
        // vocabularies for cluster matching, so all captions must be regenerated.
        // Setting caption = NULL marks every image as uncaptioned so the next
        // indexing run recaptions the full library with qwen.
        migrator.registerMigration("v7_clear_moondream_captions") { db in
            try db.execute(sql: "UPDATE images SET caption = NULL")
        }

        // ── v8: selectedFor — records which topK path inserted the pair ───
        // 'thematic' = entered exclusively via thematic topK-10; 'composite' = entered
        // via composite topK-150 (possibly also thematic). NULL = pre-migration row;
        // app falls back to post-hoc score comparison for those rows.
        migrator.registerMigration("v8_selected_for") { db in
            try db.alter(table: "pairs") { t in
                t.add(column: "selectedFor", .text)
            }
        }

        // ── v9: Accent color per image ────────────────────────────────────
        // accentHue (0–360°) and accentSaturation (0–1) store the primary accent
        // color for each image — the hue cluster with highest mean saturation that
        // covers 5–40% of pixels (after excluding pixels below saturation 0.25).
        // NULL when no qualifying accent exists (B&W images, neutral-heavy images).
        // Used by the accent color echo component of the aesthetic scorer (follow-on).
        migrator.registerMigration("v9_accentColors") { db in
            try db.alter(table: "images") { t in
                t.add(column: "accentHue",        .real)
                t.add(column: "accentSaturation", .real)
            }
        }

        // ── v10: Edge-energy weight centroid per image ────────────────────
        // weightCentroidX (0–1, left=0, right=1) and weightCentroidY (0–1, top=0, bottom=1)
        // store the edge-energy-weighted visual centroid of each image's composition grid.
        // Used by the directional complement component of the geometric scorer.
        // NULL when not yet processed or when the image is near-featureless (total edge
        // energy < 1e-6). Same re-attempt semantics as accentHue. See decision #59.
        migrator.registerMigration("v10_weightCentroids") { db in
            try db.alter(table: "images") { t in
                t.add(column: "weightCentroidX", .real)
                t.add(column: "weightCentroidY", .real)
            }
        }

        try migrator.migrate(pool)
    }
}
