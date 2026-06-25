import Foundation
import GRDB

/// Read-only query service for the app layer.
/// Returns plain Swift structs — no GRDB types exposed to callers.
public actor QueryService {

    private let db: DatabaseManager

    public init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Folders

    public func fetchFolders() throws -> [FolderQueryResult] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.id, f.displayName, f.path, f.driveType,
                           f.lastIndexedAt,
                           COUNT(i.id) as imageCount,
                           (
                               SELECT COUNT(*)
                               FROM pairs p
                               JOIN images ia ON ia.id = p.imageAID
                               JOIN images ib ON ib.id = p.imageBID
                               WHERE ia.folderID = f.id AND ib.folderID = f.id
                                 AND ia.isActive = 1 AND ib.isActive = 1
                           ) as pairCount
                    FROM folders f
                    LEFT JOIN images i ON i.folderID = f.id AND i.isActive = 1
                    WHERE f.isActive = 1
                    GROUP BY f.id
                    ORDER BY f.id
                """
            )
            return rows.map { row in
                let ts = row["lastIndexedAt"] as? Double
                // GRDB returns SQLite INTEGER columns as Int64; `as? Int` silently returns nil
                // even on 64-bit platforms. Coerce via Int64 as the canonical fallback.
                func intCol(_ name: String) -> Int {
                    (row[name] as? Int) ?? (row[name] as? Int64).map(Int.init) ?? 0
                }
                return FolderQueryResult(
                    id: row["id"] as! Int64,
                    displayName: (row["displayName"] as? String) ?? "Untitled",
                    path: row["path"] as! String,
                    driveType: (row["driveType"] as? String) ?? "internal",
                    imageCount: intCol("imageCount"),
                    pairCount: intCol("pairCount"),
                    lastIndexedAt: ts.map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }

    // MARK: - Pairs

    /// Fetches one representative pair per image — the top-1 pair for each image regardless
    /// of whether it sits on the A or B side — deduplicated by DISTINCT. Returns all
    /// candidates (no SQL LIMIT); pagination is handled in the caller via in-memory slicing.
    ///
    /// **Why `all_sides` instead of separate `top_a`/`top_b` CTEs:**
    /// The old two-CTE design let hub images dominate: image 1471 (837 pairs) appeared as
    /// imageBID in 44 of the top-150 sorted candidates, causing the Swift cap-2 to reject
    /// all but 2, leaving only ~44 pairs in the grid. The `all_sides` UNION ALL ranks
    /// every image's best pair from either side with a single window function, so
    /// `DISTINCT pairID` on rn=1 yields at most ~1,028 candidates (one per image, many
    /// shared). Cap-2 then trims hub appearances to ≤2 across the full set.
    ///
    /// - Parameters:
    ///   - folderID: If set, restricts to intra-folder pairs (both images in this folder).
    ///   - collectionID: If set, restricts to pairs in this collection.
    ///   - sortColumn: DB column to rank/sort by. Must be a valid pairs column name
    ///     (validated by the call site via PairSortOrder enum — not user input).
    public nonisolated func fetchRepresentativePairs(
        folderID: Int64? = nil,
        collectionID: Int64? = nil,
        sortColumn: String,
        directedGazeOnly: Bool = false,
        additionalCondition: String? = nil
    ) throws -> [PairQueryResult] {
        var results: [PairQueryResult] = []
        try streamRepresentativePairs(
            folderID: folderID, collectionID: collectionID,
            sortColumn: sortColumn, directedGazeOnly: directedGazeOnly,
            additionalCondition: additionalCondition, chunkSize: Int.max
        ) { results.append(contentsOf: $0) }
        return results
    }

    /// Streams pairs in chunks using a GRDB cursor inside a single read transaction.
    /// Rows arrive as SQLite produces them via the compositeScore index scan, so the
    /// first chunk is available within milliseconds rather than after the full result
    /// set is collected. `process` is called synchronously for each chunk; throw
    /// `CancellationError` to stop early.
    public nonisolated func streamRepresentativePairs(
        folderID: Int64? = nil,
        collectionID: Int64? = nil,
        sortColumn: String,
        directedGazeOnly: Bool = false,
        additionalCondition: String? = nil,
        chunkSize: Int = 20,
        process: ([PairQueryResult]) throws -> Void
    ) throws {
        var conditions: [String] = [
            "a.isActive = 1",
            "b.isActive = 1",
        ]
        var args: [DatabaseValueConvertible] = []

        if let fid = folderID {
            conditions.append("a.folderID = ? AND b.folderID = ?")
            args.append(contentsOf: [fid, fid])
        }
        if let cid = collectionID {
            if cid == -1 {
                conditions.append("EXISTS (SELECT 1 FROM userDecisions ud WHERE ud.pairID = p.id AND ud.decision = 'liked')")
            } else {
                conditions.append("EXISTS (SELECT 1 FROM collectionPairs cp WHERE cp.pairID = p.id AND cp.collectionID = ?)")
                args.append(cid)
            }
        }

        // Directed-gaze review (#109): just the confirmed gaze pairs, ordered by the
        // caller's sortColumn (the app passes p.gazeJudgeScore). No cap-2 downstream
        // (fetchRepresentativePairs collects all) so the full set is reviewable.
        if directedGazeOnly {
            conditions.append("p.selectedFor = 'gaze' AND p.gazeJudgeScore > 0")
        }

        // Submode filter: caller-supplied SQL condition (not user input — always a
        // hardcoded column = literal string from the app's submode routing table).
        if let cond = additionalCondition {
            conditions.append(cond)
        }
        let where_ = "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT
                p.id        AS pairID,
                p.imageAID, p.imageBID,
                p.aestheticScore, p.aestheticSubmode,
                p.geometricScore,
                p.rawEdgeSim, p.rawGridSim,
                p.maxEdgePeakedness, p.maxGridVariance,
                p.edgePeakednessMult, p.gridVarianceMult,
                p.selectedFor,
                p.thematicScore,
                p.compositeScore, p.rationale,
                p.geometricSubmode,
                p.thematicV2Score,
                p.thematicV2RelationshipType,
                p.thematicV2Rationale,
                p.roleHypothesis,
                p.gazeJudgeScore,
                p.gazeJudgeRationale,
                a.filename       AS filenameA,
                a.thumbnailPath  AS thumbA,
                a.path           AS imagePathA,
                a.captureDate    AS captureDateA,
                a.cameraModel    AS cameraModelA,
                b.filename       AS filenameB,
                b.thumbnailPath  AS thumbB,
                b.path           AS imagePathB,
                b.captureDate    AS captureDateB,
                b.cameraModel    AS cameraModelB,
                a.colorProfile   AS colorProfileA,
                b.colorProfile   AS colorProfileB,
                COALESCE(a.caption, '') AS captionA,
                COALESCE(b.caption, '') AS captionB,
                a.accentHue        AS accentHueA,
                a.accentSaturation AS accentSaturationA,
                b.accentHue        AS accentHueB,
                b.accentSaturation AS accentSaturationB,
                fa.displayName   AS folderNameA,
                fa.path          AS folderPathA,
                fb.displayName   AS folderNameB,
                fb.path          AS folderPathB,
                (
                    SELECT decision FROM userDecisions
                    WHERE pairID = p.id
                    ORDER BY decidedAt DESC LIMIT 1
                ) AS userDecision
            FROM pairs p
            JOIN images  a  ON a.id  = p.imageAID
            JOIN images  b  ON b.id  = p.imageBID
            JOIN folders fa ON fa.id = a.folderID
            JOIN folders fb ON fb.id = b.folderID
            \(where_)
            ORDER BY \(sortColumn) DESC
        """

        try db.read { db in
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(args))
            var chunk: [PairQueryResult] = []
            chunk.reserveCapacity(min(chunkSize, 64))
            while let row = try cursor.next() {
                let tsA = (row["captureDateA"] as? Double) ?? (row["captureDateA"] as? Int64).map { Double($0) }
                let tsB = (row["captureDateB"] as? Double) ?? (row["captureDateB"] as? Int64).map { Double($0) }
                chunk.append(PairQueryResult(
                    pairID: row["pairID"] as! Int64,
                    imageAID: row["imageAID"] as! Int64,
                    imageBID: row["imageBID"] as! Int64,
                    filenameA: row["filenameA"] as! String,
                    filenameB: row["filenameB"] as! String,
                    thumbnailPathA: row["thumbA"] as? String,
                    thumbnailPathB: row["thumbB"] as? String,
                    imagePathA: (row["imagePathA"] as? String) ?? "",
                    imagePathB: (row["imagePathB"] as? String) ?? "",
                    folderPathA: (row["folderPathA"] as? String) ?? "",
                    folderPathB: (row["folderPathB"] as? String) ?? "",
                    captureDateA: tsA.map { Date(timeIntervalSince1970: $0) },
                    captureDateB: tsB.map { Date(timeIntervalSince1970: $0) },
                    cameraModelA: row["cameraModelA"] as? String,
                    cameraModelB: row["cameraModelB"] as? String,
                    colorProfileA: (row["colorProfileA"] as? String) ?? "color",
                    colorProfileB: (row["colorProfileB"] as? String) ?? "color",
                    captionA: (row["captionA"] as? String) ?? "",
                    captionB: (row["captionB"] as? String) ?? "",
                    folderNameA: (row["folderNameA"] as? String) ?? "",
                    folderNameB: (row["folderNameB"] as? String) ?? "",
                    aestheticScore: row["aestheticScore"] as! Double,
                    aestheticSubmode: row["aestheticSubmode"] as! String,
                    geometricScore: row["geometricScore"] as! Double,
                    rawEdgeSim: row["rawEdgeSim"] as? Double,
                    rawGridSim: row["rawGridSim"] as? Double,
                    maxEdgePeakedness: row["maxEdgePeakedness"] as? Double,
                    maxGridVariance: row["maxGridVariance"] as? Double,
                    edgePeakednessMult: row["edgePeakednessMult"] as? Double,
                    gridVarianceMult: row["gridVarianceMult"] as? Double,
                    selectedFor: row["selectedFor"] as? String,
                    thematicScore: row["thematicScore"] as! Double,
                    compositeScore: row["compositeScore"] as! Double,
                    rationale: row["rationale"] as! String,
                    userDecision: row["userDecision"] as? String,
                    accentHueA: row["accentHueA"] as? Double,
                    accentSaturationA: row["accentSaturationA"] as? Double,
                    accentHueB: row["accentHueB"] as? Double,
                    accentSaturationB: row["accentSaturationB"] as? Double,
                    geometricSubmode: row["geometricSubmode"] as? String,
                    thematicV2Score: row["thematicV2Score"] as? Double,
                    thematicV2RelationshipType: row["thematicV2RelationshipType"] as? String,
                    thematicV2Rationale: row["thematicV2Rationale"] as? String,
                    roleHypothesis: row["roleHypothesis"] as? String,
                    gazeJudgeScore: row["gazeJudgeScore"] as? Double,
                    gazeJudgeRationale: row["gazeJudgeRationale"] as? String
                ))
                if chunk.count == chunkSize {
                    try process(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try process(chunk) }
        }
    }

    /// Returns total pair count per image (both as A and B side) for the given context.
    /// Used to populate the dot badge threshold and lightbox count badges.
    public nonisolated func fetchImagePairCounts(
        folderID: Int64? = nil,
        collectionID: Int64? = nil
    ) throws -> [Int64: Int] {

        var conditions: [String] = [
            "a.isActive = 1",
            "b.isActive = 1",
        ]
        var args: [DatabaseValueConvertible] = []

        if let fid = folderID {
            conditions.append("a.folderID = ? AND b.folderID = ?")
            args.append(contentsOf: [fid, fid])
        }
        if let cid = collectionID {
            if cid == -1 {
                conditions.append("EXISTS (SELECT 1 FROM userDecisions ud WHERE ud.pairID = p.id AND ud.decision = 'liked')")
            } else {
                conditions.append("EXISTS (SELECT 1 FROM collectionPairs cp WHERE cp.pairID = p.id AND cp.collectionID = ?)")
                args.append(cid)
            }
        }

        let where_ = "WHERE " + conditions.joined(separator: " AND ")

        // Count each image's appearances on both the A and B sides of pairs.
        // Uses existing idx_pairs_imageAID_score and idx_pairs_imageBID_score indices.
        let sql = """
            SELECT img, SUM(c) AS total
            FROM (
                SELECT p.imageAID AS img, COUNT(*) AS c
                FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                \(where_)
                GROUP BY p.imageAID
                UNION ALL
                SELECT p.imageBID AS img, COUNT(*) AS c
                FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                \(where_)
                GROUP BY p.imageBID
            )
            GROUP BY img
        """

        // Duplicate args: WHERE conditions appear in both the A-side and B-side subqueries.
        let doubledArgs = args + args

        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(doubledArgs))
            var result = [Int64: Int]()
            for row in rows {
                if let img = row["img"] as? Int64, let total = row["total"] as? Int64 {
                    result[img] = Int(total)
                }
            }
            return result
        }
    }

    /// Fetches all scored pairs with joined image and folder metadata.
    /// - Parameters:
    ///   - folderID: If set, returns only intra-folder pairs (both images in this folder).
    ///   - collectionID: If set, returns only pairs in this collection.
    ///   - anchorImageID: If set, returns only pairs containing this image.
    public func fetchPairs(
        folderID: Int64? = nil,
        collectionID: Int64? = nil,
        anchorImageID: Int64? = nil,
        limit: Int = 500
    ) throws -> [PairQueryResult] {

        var conditions: [String] = [
            "a.isActive = 1",
            "b.isActive = 1",
        ]
        var args: [DatabaseValueConvertible] = []

        if let fid = folderID {
            conditions.append("a.folderID = ? AND b.folderID = ?")
            args.append(contentsOf: [fid, fid])
        }
        if let cid = collectionID {
            if cid == -1 {
                conditions.append("EXISTS (SELECT 1 FROM userDecisions ud WHERE ud.pairID = p.id AND ud.decision = 'liked')")
            } else {
                conditions.append("EXISTS (SELECT 1 FROM collectionPairs cp WHERE cp.pairID = p.id AND cp.collectionID = ?)")
                args.append(cid)
            }
        }
        if let aid = anchorImageID {
            conditions.append("(p.imageAID = ? OR p.imageBID = ?)")
            args.append(contentsOf: [aid, aid])
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT
                p.id        AS pairID,
                p.imageAID, p.imageBID,
                p.aestheticScore, p.aestheticSubmode,
                p.geometricScore,
                p.rawEdgeSim, p.rawGridSim,
                p.maxEdgePeakedness, p.maxGridVariance,
                p.edgePeakednessMult, p.gridVarianceMult,
                p.selectedFor,
                p.thematicScore,
                p.compositeScore, p.rationale,
                p.geometricSubmode,
                p.thematicV2Score,
                p.thematicV2RelationshipType,
                p.thematicV2Rationale,
                p.roleHypothesis,
                p.gazeJudgeScore,
                p.gazeJudgeRationale,
                a.filename       AS filenameA,
                a.thumbnailPath  AS thumbA,
                a.path           AS imagePathA,
                a.captureDate    AS captureDateA,
                a.cameraModel    AS cameraModelA,
                b.filename       AS filenameB,
                b.thumbnailPath  AS thumbB,
                b.path           AS imagePathB,
                b.captureDate    AS captureDateB,
                b.cameraModel    AS cameraModelB,
                a.colorProfile   AS colorProfileA,
                b.colorProfile   AS colorProfileB,
                COALESCE(a.caption, '') AS captionA,
                COALESCE(b.caption, '') AS captionB,
                a.accentHue        AS accentHueA,
                a.accentSaturation AS accentSaturationA,
                b.accentHue        AS accentHueB,
                b.accentSaturation AS accentSaturationB,
                fa.displayName   AS folderNameA,
                fa.path          AS folderPathA,
                fb.displayName   AS folderNameB,
                fb.path          AS folderPathB,
                (
                    SELECT decision FROM userDecisions
                    WHERE pairID = p.id
                    ORDER BY decidedAt DESC LIMIT 1
                ) AS userDecision
            FROM pairs p
            JOIN images  a  ON a.id  = p.imageAID
            JOIN images  b  ON b.id  = p.imageBID
            JOIN folders fa ON fa.id = a.folderID
            JOIN folders fb ON fb.id = b.folderID
            \(where_)
            ORDER BY MAX(p.compositeScore, 0.6 * MAX(p.aestheticScore, p.geometricScore * 0.8, CASE WHEN p.roleHypothesis IS NOT NULL AND p.thematicV2Score = 0 THEN p.thematicScore ELSE COALESCE(p.thematicV2Score, p.thematicScore) END) + 0.4 * (p.aestheticScore * 0.4 + p.geometricScore * 0.2 + (CASE WHEN p.roleHypothesis IS NOT NULL AND p.thematicV2Score = 0 THEN p.thematicScore ELSE COALESCE(p.thematicV2Score, p.thematicScore) END) * 0.4)) DESC
            LIMIT \(limit)
        """

        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                // captureDate is stored as INTEGER in SQLite; GRDB's `as? Double`
                // silently returns nil for int64 values. Coerce explicitly.
                let tsA = (row["captureDateA"] as? Double) ?? (row["captureDateA"] as? Int64).map { Double($0) }
                let tsB = (row["captureDateB"] as? Double) ?? (row["captureDateB"] as? Int64).map { Double($0) }
                return PairQueryResult(
                    pairID: row["pairID"] as! Int64,
                    imageAID: row["imageAID"] as! Int64,
                    imageBID: row["imageBID"] as! Int64,
                    filenameA: row["filenameA"] as! String,
                    filenameB: row["filenameB"] as! String,
                    thumbnailPathA: row["thumbA"] as? String,
                    thumbnailPathB: row["thumbB"] as? String,
                    imagePathA: (row["imagePathA"] as? String) ?? "",
                    imagePathB: (row["imagePathB"] as? String) ?? "",
                    folderPathA: (row["folderPathA"] as? String) ?? "",
                    folderPathB: (row["folderPathB"] as? String) ?? "",
                    captureDateA: tsA.map { Date(timeIntervalSince1970: $0) },
                    captureDateB: tsB.map { Date(timeIntervalSince1970: $0) },
                    cameraModelA: row["cameraModelA"] as? String,
                    cameraModelB: row["cameraModelB"] as? String,
                    colorProfileA: (row["colorProfileA"] as? String) ?? "color",
                    colorProfileB: (row["colorProfileB"] as? String) ?? "color",
                    captionA: (row["captionA"] as? String) ?? "",
                    captionB: (row["captionB"] as? String) ?? "",
                    folderNameA: (row["folderNameA"] as? String) ?? "",
                    folderNameB: (row["folderNameB"] as? String) ?? "",
                    aestheticScore: row["aestheticScore"] as! Double,
                    aestheticSubmode: row["aestheticSubmode"] as! String,
                    geometricScore: row["geometricScore"] as! Double,
                    rawEdgeSim: row["rawEdgeSim"] as? Double,
                    rawGridSim: row["rawGridSim"] as? Double,
                    maxEdgePeakedness: row["maxEdgePeakedness"] as? Double,
                    maxGridVariance: row["maxGridVariance"] as? Double,
                    edgePeakednessMult: row["edgePeakednessMult"] as? Double,
                    gridVarianceMult: row["gridVarianceMult"] as? Double,
                    selectedFor: row["selectedFor"] as? String,
                    thematicScore: row["thematicScore"] as! Double,
                    compositeScore: row["compositeScore"] as! Double,
                    rationale: row["rationale"] as! String,
                    userDecision: row["userDecision"] as? String,
                    accentHueA: row["accentHueA"] as? Double,
                    accentSaturationA: row["accentSaturationA"] as? Double,
                    accentHueB: row["accentHueB"] as? Double,
                    accentSaturationB: row["accentSaturationB"] as? Double,
                    geometricSubmode: row["geometricSubmode"] as? String,
                    thematicV2Score: row["thematicV2Score"] as? Double,
                    thematicV2RelationshipType: row["thematicV2RelationshipType"] as? String,
                    thematicV2Rationale: row["thematicV2Rationale"] as? String,
                    roleHypothesis: row["roleHypothesis"] as? String,
                    gazeJudgeScore: row["gazeJudgeScore"] as? Double,
                    gazeJudgeRationale: row["gazeJudgeRationale"] as? String
                )
            }
        }
    }

    // MARK: - Image paths

    /// Returns the on-disk paths for both images in a pair, or nil if either is missing.
    public func fetchImagePaths(imageAID: Int64, imageBID: Int64) throws -> (pathA: String, pathB: String)? {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, path FROM images WHERE id IN (?, ?)",
                arguments: [imageAID, imageBID]
            )
            var pathMap: [Int64: String] = [:]
            for row in rows {
                if let id = row["id"] as? Int64, let path = row["path"] as? String {
                    pathMap[id] = path
                }
            }
            guard let pathA = pathMap[imageAID], let pathB = pathMap[imageBID] else { return nil }
            return (pathA: pathA, pathB: pathB)
        }
    }

    // MARK: - Folder management

    public func removeFolder(id: Int64) throws {
        try db.write { db in
            // Mark images inactive rather than deleting — preserves pair history
            try db.execute(
                sql: "UPDATE images SET isActive = 0 WHERE folderID = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "UPDATE folders SET isActive = 0 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Decision write

    public func saveDecision(pairID: Int64, decision: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO userDecisions (pairID, decision, decidedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(pairID) DO UPDATE SET
                        decision  = excluded.decision,
                        decidedAt = excluded.decidedAt
                """,
                arguments: [pairID, decision, Date().timeIntervalSince1970]
            )
        }
    }

    public func deletePairRecord(pairID: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM pairs WHERE id = ?",
                arguments: [pairID]
            )
        }
    }

    // MARK: - Collection reads

    public func fetchCollections() throws -> [CollectionQueryResult] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id, c.name, COUNT(cp.pairID) as pairCount
                    FROM collections c
                    LEFT JOIN collectionPairs cp ON cp.collectionID = c.id
                    GROUP BY c.id
                    ORDER BY c.sortOrder, c.id
                """
            )
            return rows.map { row in
                func intCol(_ name: String) -> Int {
                    (row[name] as? Int) ?? (row[name] as? Int64).map(Int.init) ?? 0
                }
                return CollectionQueryResult(
                    id: intCol("id"),
                    name: (row["name"] as? String) ?? "",
                    pairCount: intCol("pairCount")
                )
            }
        }
    }

    public nonisolated func fetchLikedPairsCount() throws -> Int {
        try db.read { db in
            let sql = """
                SELECT COUNT(*) FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                WHERE a.isActive = 1 AND b.isActive = 1
                AND EXISTS (
                    SELECT 1 FROM userDecisions ud
                    WHERE ud.pairID = p.id AND ud.decision = 'liked'
                )
            """
            return (try Int.fetchOne(db, sql: sql)) ?? 0
        }
    }

    // MARK: - Collection writes

    public func createCollection(name: String) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO collections (name, createdAt, sortOrder) VALUES (?, ?, 0)",
                arguments: [name, Int64(Date().timeIntervalSince1970)]
            )
            return db.lastInsertedRowID
        }
    }

    public func deleteCollection(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id])
        }
    }

    public func renameCollection(id: Int64, to name: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE collections SET name = ? WHERE id = ?",
                arguments: [name, id]
            )
        }
    }

    // MARK: - Collection pair membership

    public func addPairToCollection(pairID: Int64, collectionID: Int64) throws -> Bool {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO collectionPairs (collectionID, pairID, addedAt)
                    VALUES (?, ?, ?)
                """,
                arguments: [collectionID, pairID, Int64(Date().timeIntervalSince1970)]
            )
            return db.changesCount > 0
        }
    }

    public func removePairFromCollection(pairID: Int64, collectionID: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM collectionPairs WHERE collectionID = ? AND pairID = ?",
                arguments: [collectionID, pairID]
            )
        }
    }
}
