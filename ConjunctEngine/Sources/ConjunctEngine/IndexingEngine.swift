import Foundation
import CoreGraphics
import ImageIO
// FIX: GRDB must be explicitly imported. Row, Int64.fetchSet, etc. are GRDB types
// and are not available without this import, even though DatabaseManager uses GRDB internally.
import GRDB

/// Orchestrates the four-phase indexing pipeline.
/// Publishes progress via an AsyncStream the UI subscribes to.
public actor IndexingEngine {

    private let db: DatabaseManager
    private let clipEngine: any CLIPInferenceEngine
    private let captioningEngine: any CaptioningEngine
    private let maxConcurrency: Int
    /// Holds the running cross-folder (phase 2) scoring task so it can be
    /// cancelled when a new index is triggered before phase 2 finishes.
    private var crossFolderTask: Task<Void, Never>?

    public init(
        db: DatabaseManager,
        clipEngine: any CLIPInferenceEngine,
        captioningEngine: any CaptioningEngine = MockCaptioningEngine(),
        maxConcurrency: Int = min(ProcessInfo.processInfo.processorCount, 4)
    ) {
        self.db = db
        self.clipEngine = clipEngine
        self.captioningEngine = captioningEngine
        self.maxConcurrency = maxConcurrency
    }

    // MARK: - Public entry point

    public func index(
        folderURL: URL,
        exclusionPatterns: [String] = [],
        weights: ScoringWeights = .default,
        duplicateSettings: DuplicateSettings = .default,
        topK: Int = 50
    ) -> AsyncStream<IndexingProgress> {
        // Cancel any cross-folder scoring still running from a previous index call.
        crossFolderTask?.cancel()
        crossFolderTask = nil

        return AsyncStream { continuation in
            Task {
                do {
                    let batchIDs = try await self.runPipeline(
                        folderURL: folderURL,
                        exclusionPatterns: exclusionPatterns,
                        weights: weights,
                        duplicateSettings: duplicateSettings,
                        topK: topK,
                        continuation: continuation
                    )
                    // Phase 1 complete — folder is browsable. Launch phase 2 in background.
                    // The continuation stays open; phase 2 will close it when done.
                    self.crossFolderTask = Task(priority: .background) {
                        do {
                            try await self.runCrossFolderScoring(
                                batchIDs: batchIDs,
                                weights: weights,
                                topK: topK
                            )
                        } catch {
                            // CancellationError or DB error — signal done either way
                        }
                        continuation.yield(IndexingProgress(
                            phase: .backgroundScoringComplete,
                            itemsComplete: 0, itemsTotal: 0
                        ))
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(IndexingProgress(
                        phase: .failed,
                        itemsComplete: 0, itemsTotal: 0,
                        errorMessage: error.localizedDescription
                    ))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Pipeline phases

    /// Runs the main indexing pipeline and returns the set of image IDs in the scanned
    /// batch so the caller can launch cross-folder scoring (phase 2) independently.
    private func runPipeline(
        folderURL: URL,
        exclusionPatterns: [String],
        weights: ScoringWeights,
        duplicateSettings: DuplicateSettings,
        topK: Int,
        continuation: AsyncStream<IndexingProgress>.Continuation
    ) async throws -> Set<Int64> {

        // ── Phase 1: File scan ────────────────────────────────────────────
        continuation.yield(IndexingProgress(
            phase: .scanning, itemsComplete: 0, itemsTotal: 0
        ))

        let scanner = FileScanner(exclusionPatterns: exclusionPatterns)
        let scanned = try await scanner.scan(directory: folderURL) { count in
            continuation.yield(IndexingProgress(
                phase: .scanning, itemsComplete: count, itemsTotal: 0
            ))
        }
        try Task.checkCancellation()

        let folderID = try upsertFolder(path: folderURL.path)
        let imageIDs = try upsertImages(scanned: scanned, folderID: folderID)
        let total = imageIDs.count

        // Backfill colorProfile for ALL active images — not just those in the
        // current scan.  Images from previous scans may have the migration default
        // "color", and images scanned before pixel-detection was added need
        // re-detection too.  The current scan batch (imageIDs) already has correct
        // values from upsertImages, so we skip them to avoid redundant file reads.
        try refreshAllColorProfiles(excludingIDs: Set(imageIDs.map { $0.0 }))

        // ── Phase 1.5: Duplicate detection ───────────────────────────────
        continuation.yield(IndexingProgress(
            phase: .duplicateDetection, itemsComplete: 0, itemsTotal: total
        ))

        let duplicateGroups = try await detectDuplicates(
            imageIDs: imageIDs,
            settings: duplicateSettings,
            continuation: continuation
        )

        // Emit groups so the UI can show the review prompt before continuing.
        // In the benchmark CLI this is logged; in the app it triggers a sheet.
        var progressWithGroups = IndexingProgress(
            phase: .thumbnails, itemsComplete: 0, itemsTotal: total
        )
        progressWithGroups.duplicateGroups = duplicateGroups
        continuation.yield(progressWithGroups)

        let thumbDir = thumbnailDirectory()
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)

        for (idx, (imageID, url)) in imageIDs.enumerated() {
            try Task.checkCancellation()
            try generateThumbnail(imageID: imageID, sourceURL: url, dir: thumbDir)
            continuation.yield(IndexingProgress(
                phase: .thumbnails, itemsComplete: idx + 1, itemsTotal: total
            ))
        }

        // ── Phase 3: Feature extraction ───────────────────────────────────
        continuation.yield(IndexingProgress(
            phase: .extraction, itemsComplete: 0, itemsTotal: total
        ))
        try await clipEngine.warmUp()

        let needsExtraction = try imagesNeedingExtraction(ids: imageIDs.map(\.0))
        let extractionURLs: [(Int64, URL)] = needsExtraction.compactMap { id in
            imageIDs.first(where: { $0.0 == id })
        }

        var extracted = 0
        let extractStart = Date()

        try await withThrowingTaskGroup(of: (Int64, FeatureVector).self) { group in
            var inFlight = 0
            var pending = extractionURLs.makeIterator()

            func launchNext() {
                guard let (imageID, url) = pending.next() else { return }
                inFlight += 1
                group.addTask { [clipEngine] in
                    let fv = try await Self.extractFeatures(
                        imageID: imageID, url: url, clipEngine: clipEngine
                    )
                    return (imageID, fv)
                }
            }

            for _ in 0..<maxConcurrency { launchNext() }

            // FIX: renamed `imageID` to `_` since it is already stored in `fv.imageID`.
            for try await (_, fv) in group {
                try Task.checkCancellation()
                try db.write { try fv.upsert($0) }

                extracted += 1
                inFlight -= 1

                var eta: TimeInterval? = nil
                if extracted >= 10 {
                    let elapsed = Date().timeIntervalSince(extractStart)
                    let rate = Double(extracted) / elapsed
                    eta = rate > 0 ? Double(total - extracted) / rate : nil
                }

                continuation.yield(IndexingProgress(
                    phase: .extraction,
                    itemsComplete: extracted,
                    itemsTotal: total,
                    eta: eta
                ))
                launchNext()
            }
        }

        // ── Phase 3.5: Image captioning ───────────────────────────────────
        continuation.yield(IndexingProgress(
            phase: .captioning, itemsComplete: 0, itemsTotal: total
        ))

        // Caption ALL uncaptioned active images in DB — not just the current scan batch.
        // Images from previous scans would otherwise never get captioned on re-index.
        let captionThumbDir = thumbnailDirectory()
        let allUncaptionedIDs: [(Int64, URL)] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, thumbnailPath FROM images
                WHERE isActive = 1
                AND (caption IS NULL OR caption = '')
            """)
            return rows.compactMap { row -> (Int64, URL)? in
                guard let id = row["id"] as? Int64,
                      let path = row["path"] as? String else { return nil }
                // Prefer the cached 512px thumbnail — avoids re-decoding the full-res
                // original at caption time (typically 12MB → 54KB, ~80ms saved per image).
                // Falls back to security-scoped URL from current scan, then stored path.
                if let thumbName = row["thumbnailPath"] as? String {
                    let thumbURL = captionThumbDir.appendingPathComponent(thumbName)
                    if FileManager.default.fileExists(atPath: thumbURL.path) {
                        return (id, thumbURL)
                    }
                }
                if let match = imageIDs.first(where: { $0.0 == id }) {
                    return (id, match.1)
                }
                return (id, URL(fileURLWithPath: path))
            }
        }

        var captioned = 0
        let captionTotal = allUncaptionedIDs.count
        for (imageID, url) in allUncaptionedIDs {
            try Task.checkCancellation()
            do {
                let text = try await captioningEngine.caption(imageURL: url)
                if !text.isEmpty {
                    try db.write { db in
                        try db.execute(
                            sql: "UPDATE images SET caption = ? WHERE id = ?",
                            arguments: [text, imageID]
                        )
                    }
                    captioned += 1
                }
            } catch {
                print("CAPTION: skipped \(url.lastPathComponent) — \(error.localizedDescription)")
            }
            continuation.yield(IndexingProgress(
                phase: .captioning, itemsComplete: captioned, itemsTotal: captionTotal
            ))
        }
        // ── Phase 4: Intra-folder pair scoring ───────────────────────────
        // Scores only images in the current scan batch against each other.
        // Cross-folder scoring (batch × all other) runs as phase 2 in background
        // after this pipeline completes — see runCrossFolderScoring.
        let batchIDs = Set(imageIDs.map { $0.0 })

        continuation.yield(IndexingProgress(
            phase: .scoring, itemsComplete: 0, itemsTotal: total
        ))

        let allHeroVectors = duplicateSettings.allowIntraStackPairing
            ? try loadAllVectors()
            : try loadHeroVectors()
        let batchVectors = allHeroVectors.filter { batchIDs.contains($0.imageID) }

        // Build metadata only for batch images — sufficient for intra-folder scoring.
        typealias ImageMeta = (captureDate: Double?, filename: String, caption: String)
        let imageMeta: [Int64: ImageMeta] = try db.read { db in
            guard !batchIDs.isEmpty else { return [:] }
            let ids = batchIDs.map { "\($0)" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, captureDate, filename, caption FROM images WHERE id IN (\(ids))"
            )
            var result = [Int64: ImageMeta]()
            for row in rows {
                let id = row["id"] as! Int64
                result[id] = (
                    captureDate: (row["captureDate"] as? Double)
                        ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as? String ?? "",
                    caption: row["caption"] as? String ?? ""
                )
            }
            return result
        }

        var allScores: [PairScore] = []
        allScores.reserveCapacity(batchVectors.count * (batchVectors.count - 1) / 2)

        var scored = 0
        for (i, vA) in batchVectors.enumerated() {
            try Task.checkCancellation()

            for vB in batchVectors[(i+1)...] {
                let metaA = imageMeta[vA.imageID]
                let metaB = imageMeta[vB.imageID]
                let s = PairScorer.score(
                    imageAID: vA.imageID, vectorA: vA,
                    imageBID: vB.imageID, vectorB: vB,
                    captureDateA: metaA?.captureDate,
                    captureDateB: metaB?.captureDate,
                    filenameA: metaA?.filename ?? "",
                    filenameB: metaB?.filename ?? "",
                    captionA: metaA?.caption ?? "",
                    captionB: metaB?.caption ?? "",
                    weights: weights
                )
                if s.compositeScore > 0 {
                    allScores.append(s)
                }
            }

            scored += 1
            continuation.yield(IndexingProgress(
                phase: .scoring, itemsComplete: scored, itemsTotal: batchVectors.count
            ))
        }

        let batchIDList = Array(batchIDs)
        let scoresToInsert = allScores
        try db.write { db in
            // Orphan sweep: remove pairs for deactivated images (run once per index).
            try db.execute(sql: """
                DELETE FROM pairs
                WHERE imageAID NOT IN (SELECT id FROM images WHERE isActive = 1)
                   OR imageBID NOT IN (SELECT id FROM images WHERE isActive = 1)
            """)

            // Remove inactive image records that have no pairs.
            try db.execute(sql: """
                DELETE FROM images
                WHERE isActive = 0
                  AND id NOT IN (SELECT imageAID FROM pairs UNION SELECT imageBID FROM pairs)
            """)

            // Delete only intra-folder pairs for the batch (both images in batchIDs).
            // Cross-folder pairs (one image in batch, one outside) are preserved here
            // and replaced by phase 2 (runCrossFolderScoring).
            if !batchIDList.isEmpty {
                let ids = batchIDList.map { "\($0)" }.joined(separator: ",")
                try db.execute(sql: """
                    DELETE FROM pairs
                    WHERE imageAID IN (\(ids)) AND imageBID IN (\(ids))
                """)
            }

            var perImage = [Int64: [PairScore]]()
            for s in scoresToInsert {
                perImage[s.imageAID, default: []].append(s)
                perImage[s.imageBID, default: []].append(s)
            }

            var toInsert = [String: PairScore]()
            for (_, scores) in perImage {
                for s in scores.sorted(by: { $0.compositeScore > $1.compositeScore }).prefix(topK) {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil { toInsert[key] = s }
                }
            }

            let thematicK = max(10, topK / 5)
            for (_, scores) in perImage {
                let thematicCandidates = scores
                    .filter { $0.thematicScore >= 0.20 }
                    .sorted { $0.thematicScore > $1.thematicScore }
                    .prefix(thematicK)
                for s in thematicCandidates {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil { toInsert[key] = s }
                }
            }

            for s in toInsert.values {
                var record = PairRecord(
                    imageAID: s.imageAID, imageBID: s.imageBID,
                    aestheticScore: Double(s.aestheticScore),
                    aestheticSubmode: s.aestheticSubmode,
                    geometricScore: Double(s.geometricScore),
                    rawEdgeSim: Double(s.rawEdgeSim),
                    rawGridSim: Double(s.rawGridSim),
                    maxEdgePeakedness: Double(s.maxEdgePeakedness),
                    maxGridVariance: Double(s.maxGridVariance),
                    edgePeakednessMult: Double(s.edgePeakednessMult),
                    gridVarianceMult: Double(s.gridVarianceMult),
                    thematicScore: Double(s.thematicScore),
                    compositeScore: Double(s.compositeScore),
                    rationale: s.rationale
                )
                try record.insert(db)
            }
        }

        continuation.yield(IndexingProgress(
            phase: .complete, itemsComplete: total, itemsTotal: total
        ))
        return batchIDs
    }

    // MARK: - Phase 2: Cross-folder scoring

    /// Scores the batch against all other active images and updates the pairs table
    /// for cross-folder pairs only. Runs as a background task after phase 1 completes.
    /// Respects Task cancellation — safe to cancel at any point; partial state is
    /// cleaned up on the next run.
    private func runCrossFolderScoring(
        batchIDs: Set<Int64>,
        weights: ScoringWeights,
        topK: Int
    ) async throws {
        guard !batchIDs.isEmpty else { return }
        try Task.checkCancellation()

        let allVectors = try loadHeroVectors()
        let batchVectors = allVectors.filter {  batchIDs.contains($0.imageID) }
        let otherVectors = allVectors.filter { !batchIDs.contains($0.imageID) }

        guard !batchVectors.isEmpty, !otherVectors.isEmpty else { return }

        typealias ImageMeta = (captureDate: Double?, filename: String, caption: String)
        let imageMeta: [Int64: ImageMeta] = try db.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, captureDate, filename, caption FROM images WHERE isActive = 1"
            )
            var result = [Int64: ImageMeta]()
            for row in rows {
                let id = row["id"] as! Int64
                result[id] = (
                    captureDate: (row["captureDate"] as? Double)
                        ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as? String ?? "",
                    caption: row["caption"] as? String ?? ""
                )
            }
            return result
        }

        var allScores: [PairScore] = []
        allScores.reserveCapacity(batchVectors.count * otherVectors.count)

        for vA in batchVectors {
            try Task.checkCancellation()
            let metaA = imageMeta[vA.imageID]
            for vB in otherVectors {
                let metaB = imageMeta[vB.imageID]
                let s = PairScorer.score(
                    imageAID: vA.imageID, vectorA: vA,
                    imageBID: vB.imageID, vectorB: vB,
                    captureDateA: metaA?.captureDate,
                    captureDateB: metaB?.captureDate,
                    filenameA: metaA?.filename ?? "",
                    filenameB: metaB?.filename ?? "",
                    captionA: metaA?.caption ?? "",
                    captionB: metaB?.caption ?? "",
                    weights: weights
                )
                if s.compositeScore > 0 {
                    allScores.append(s)
                }
            }
        }

        try Task.checkCancellation()

        let batchIDList = Array(batchIDs)
        let scoresToInsert = allScores
        try db.write { db in
            // Delete existing cross-folder pairs for this batch (one image inside,
            // one outside). Intra-folder pairs (both inside) were handled by phase 1.
            if !batchIDList.isEmpty {
                let ids = batchIDList.map { "\($0)" }.joined(separator: ",")
                try db.execute(sql: """
                    DELETE FROM pairs
                    WHERE (imageAID IN (\(ids)) AND imageBID NOT IN (\(ids)))
                       OR (imageBID IN (\(ids)) AND imageAID NOT IN (\(ids)))
                """)
            }

            var perImage = [Int64: [PairScore]]()
            for s in scoresToInsert {
                perImage[s.imageAID, default: []].append(s)
                perImage[s.imageBID, default: []].append(s)
            }

            var toInsert = [String: PairScore]()
            for (_, scores) in perImage {
                for s in scores.sorted(by: { $0.compositeScore > $1.compositeScore }).prefix(topK) {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil { toInsert[key] = s }
                }
            }

            let thematicK = max(10, topK / 5)
            for (_, scores) in perImage {
                let thematicCandidates = scores
                    .filter { $0.thematicScore >= 0.20 }
                    .sorted { $0.thematicScore > $1.thematicScore }
                    .prefix(thematicK)
                for s in thematicCandidates {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil { toInsert[key] = s }
                }
            }

            for s in toInsert.values {
                var record = PairRecord(
                    imageAID: s.imageAID, imageBID: s.imageBID,
                    aestheticScore: Double(s.aestheticScore),
                    aestheticSubmode: s.aestheticSubmode,
                    geometricScore: Double(s.geometricScore),
                    rawEdgeSim: Double(s.rawEdgeSim),
                    rawGridSim: Double(s.rawGridSim),
                    maxEdgePeakedness: Double(s.maxEdgePeakedness),
                    maxGridVariance: Double(s.maxGridVariance),
                    edgePeakednessMult: Double(s.edgePeakednessMult),
                    gridVarianceMult: Double(s.gridVarianceMult),
                    thematicScore: Double(s.thematicScore),
                    compositeScore: Double(s.compositeScore),
                    rationale: s.rationale
                )
                try record.insert(db)
            }
        }
    }

    // MARK: - Color profile backfill

    /// Re-detects colorProfile for all active images not covered by the current
    /// scan.  This corrects the migration-default "color" value that was written
    /// for images indexed before v4_colorProfile was introduced, and picks up
    /// the improved pixel-level detection for any image that was missed before.
    private func refreshAllColorProfiles(excludingIDs: Set<Int64> = []) throws {
        typealias ImageRow = (id: Int64, path: String)
        let images: [ImageRow] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, path FROM images WHERE isActive = 1")
            return rows.compactMap { row -> ImageRow? in
                guard let id = row["id"] as? Int64,
                      let path = row["path"] as? String,
                      !excludingIDs.contains(id) else { return nil }
                return (id: id, path: path)
            }
        }
        guard !images.isEmpty else { return }

        let updates: [(profile: String, id: Int64)] = images.map { img in
            let profile = FileScanner.detectColorProfile(url: URL(fileURLWithPath: img.path))
            return (profile: profile, id: img.id)
        }

        try db.write { db in
            for u in updates {
                try db.execute(
                    sql: "UPDATE images SET colorProfile = ? WHERE id = ?",
                    arguments: [u.profile, u.id]
                )
            }
        }

        let bwCount = updates.filter { $0.profile == "bw" }.count
    }

    // MARK: - Static feature extraction

    private static func extractFeatures(
        imageID: Int64,
        url: URL,
        clipEngine: any CLIPInferenceEngine
    ) async throws -> FeatureVector {
        guard let cgImage = loadCGImage(url: url) else {
            throw ExtractionError.imageLoadFailed(url)
        }

        async let clipResult   = clipEngine.embed(image: cgImage)
        async let colourResult = Task.detached(priority: .userInitiated) {
            try ColourAnalyser.analyse(image: cgImage)
        }.value
        async let geoResult = Task.detached(priority: .userInitiated) {
            try GeometricAnalyser.analyse(image: cgImage)
        }.value

        let (clip, colour, geo) = try await (clipResult, colourResult, geoResult)

        return FeatureVector(
            imageID: imageID,
            clipEmbedding: clip.embedding,
            hslHistogram: colour.hslHistogram,
            dominantPalette: colour.dominantPalette,
            edgeOrientation: geo.edgeOrientation,
            compositionGrid: geo.compositionGrid
        )
    }

    /// Loads a CGImage at reduced resolution for feature extraction.
    /// 512px is sufficient for CLIP (224×224), colour histograms, and edge analysis.
    /// Using CGImageSourceCreateThumbnailAtIndex instead of CreateImageAtIndex
    /// decodes at the target size from the start, avoiding full-res IOSurface
    /// allocations (10–19MB each) that exhaust GPU memory during concurrent processing.
    private static func loadCGImage(url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return img
    }

    // MARK: - Database helpers

    /// Phase 1.5: compute dHash for all images, group near-duplicates, persist groups,
    /// mark heroes (earliest capture date wins), and return summaries for UI review.
    private func detectDuplicates(
        imageIDs: [(Int64, URL)],
        settings: DuplicateSettings,
        continuation: AsyncStream<IndexingProgress>.Continuation
    ) async throws -> [DuplicateGroupSummary] {

        // Compute dHash for any images that don't have one yet
        for (idx, (imageID, url)) in imageIDs.enumerated() {
            try Task.checkCancellation()

            let alreadyHashed: Bool = try db.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT dHash FROM images WHERE id = ? AND dHash IS NOT NULL",
                    arguments: [imageID]
                ) != nil
            }
            if !alreadyHashed {
                let hash = (try? PerceptualHasher.dHash(url: url)) ?? ""
                try db.write { db in
                    try db.execute(
                        sql: "UPDATE images SET dHash = ? WHERE id = ?",
                        arguments: [hash, imageID]
                    )
                }
            }

            continuation.yield(IndexingProgress(
                phase: .duplicateDetection,
                itemsComplete: idx + 1,
                itemsTotal: imageIDs.count
            ))
        }

        // Load all hashes and find groups using union-find.
        // Extract to plain Swift tuples immediately so Row values
        // never cross the actor boundary (Row is not Sendable in GRDB 6).
        typealias HashRow = (id: Int64, dHash: String, captureDate: Double?)
        let hashRows: [HashRow] = try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, dHash, captureDate FROM images WHERE isActive = 1 AND dHash IS NOT NULL AND dHash != ''"
            ).map { row in
                (
                    id: row["id"] as! Int64,
                    dHash: row["dHash"] as! String,
                    captureDate: (row["captureDate"] as? Double) ?? (row["captureDate"] as? Int64).map(Double.init)
                )
            }
        }

        // Union-Find grouping
        var parent = [Int64: Int64]()
        func find(_ x: Int64) -> Int64 {
            if parent[x] == nil { parent[x] = x }
            if parent[x]! == x { return x }
            parent[x] = find(parent[x]!)
            return parent[x]!
        }
        func union(_ a: Int64, _ b: Int64) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // O(n²) comparison — acceptable for ≤5,000 images
        for i in 0..<hashRows.count {
            for j in (i+1)..<hashRows.count {
                let idA = hashRows[i].id
                let idB = hashRows[j].id
                let hA  = hashRows[i].dHash
                let hB  = hashRows[j].dHash
                if PerceptualHasher.areDuplicates(hA, hB, threshold: settings.hammingThreshold) {
                    union(idA, idB)
                }
            }
        }

        // Collect groups with more than one member
        var groups = [Int64: [Int64]]()
        for row in hashRows {
            let id   = row.id
            let root = find(id)
            if groups[root] == nil { groups[root] = [] }
            groups[root]!.append(id)
        }
        let duplicateOnlyGroups = groups.filter { $0.value.count > 1 }

        guard !duplicateOnlyGroups.isEmpty else { return [] }

        // Persist groups and mark heroes (earliest captureDate wins; ties: lowest id).
        // Return summaries from db.write to avoid capturing a var across the actor boundary.
        let summaries: [DuplicateGroupSummary] = try db.write { db in
            var result: [DuplicateGroupSummary] = []

            // Clear any previous duplicate group assignments
            try db.execute(sql: "UPDATE images SET duplicateGroupID = NULL, isHero = 1")

            for (_, memberIDs) in duplicateOnlyGroups {
                var group = DuplicateGroup(memberCount: memberIDs.count)
                try group.insert(db)
                guard let groupID = group.id else { continue }

                // Extract member data as plain tuples (Row is not Sendable)
                typealias MemberRow = (id: Int64, filename: String, dHash: String, captureDate: Double?)
                let memberData: [MemberRow] = try Row.fetchAll(
                    db,
                    sql: "SELECT id, filename, dHash, captureDate FROM images WHERE id IN (\(memberIDs.map { "\($0)" }.joined(separator: ",")))"
                ).map { row in
                    (
                        id: row["id"] as! Int64,
                        filename: row["filename"] as! String,
                        dHash: row["dHash"] as! String,
                        captureDate: (row["captureDate"] as? Double) ?? (row["captureDate"] as? Int64).map(Double.init)
                    )
                }

                let heroID = memberData
                    .sorted {
                        let aDate = $0.captureDate ?? Double.infinity
                        let bDate = $1.captureDate ?? Double.infinity
                        if aDate != bDate { return aDate < bDate }
                        return $0.id < $1.id
                    }
                    .first?.id ?? memberIDs[0]

                for m in memberData {
                    try db.execute(
                        sql: "UPDATE images SET duplicateGroupID = ?, isHero = ? WHERE id = ?",
                        arguments: [groupID, m.id == heroID ? 1 : 0, m.id]
                    )
                }

                let members = memberData.map { m in
                    DuplicateMember(
                        imageID: m.id,
                        filename: m.filename,
                        dHash: m.dHash,
                        isHero: m.id == heroID
                    )
                }
                result.append(DuplicateGroupSummary(groupID: groupID, members: members))
            }
            return result
        }

        return summaries
    }

    private func loadAllVectors() throws -> [FeatureVector] {
        try db.read { db in
            try FeatureVector.fetchAll(db)
        }
    }

    /// Loads feature vectors for hero images only (one per duplicate stack).
    /// Non-hero duplicates are excluded from the pairing engine when
    /// allowIntraStackPairing is false.
    private func loadHeroVectors() throws -> [FeatureVector] {
        try db.read { db in
            // Join featureVectors with images to filter non-heroes
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT fv.*
                    FROM featureVectors fv
                    JOIN images i ON i.id = fv.imageID
                    WHERE i.isHero = 1 AND i.isActive = 1
                """
            )
            return try rows.map { row in
                try FeatureVector.init(row: row)
            }
        }
    }

    private func upsertFolder(path: String) throws -> Int64 {
        try db.write { db in
            if let existing = try Row.fetchOne(
                db, sql: "SELECT id FROM folders WHERE path = ?", arguments: [path]
            ) {
                let id = existing["id"] as! Int64
                // Re-activate if previously removed
                try db.execute(
                    sql: "UPDATE folders SET isActive = 1 WHERE id = ?",
                    arguments: [id]
                )
                return id
            }
            try db.execute(
                sql: "INSERT INTO folders (path, displayName, isActive) VALUES (?, ?, 1)",
                arguments: [path, URL(fileURLWithPath: path).lastPathComponent]
            )
            return db.lastInsertedRowID
        }
    }

    private func upsertImages(
        scanned: [ScannedFile],
        folderID: Int64
    ) throws -> [(Int64, URL)] {
        // Single transaction: upsert image row, then immediately update captureDate
        // using the concrete row ID. captureDate is written as a separate statement
        // within the same transaction using a concrete Double (never Optional<Double>)
        // to avoid GRDB optional-in-Any binding issues.
        try db.write { db in
            var result: [(Int64, URL)] = []
            for file in scanned {
                let path = file.url.path
                let rowID: Int64

                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT id, contentHash FROM images WHERE path = ?",
                    arguments: [path]
                ) {
                    rowID = existing["id"] as! Int64
                    if (existing["contentHash"] as? String) == file.contentHash {
                        try db.execute(
                            sql: "UPDATE images SET isActive = 1, folderID = ?, colorProfile = ? WHERE id = ?",
                            arguments: [folderID, file.colorProfile, rowID]
                        )
                    } else {
                        try db.execute(sql: "DELETE FROM featureVectors WHERE imageID = ?", arguments: [rowID])
                        try db.execute(
                            sql: "UPDATE images SET contentHash = ?, indexedAt = ?, isActive = 1, folderID = ?, colorProfile = ? WHERE id = ?",
                            arguments: [file.contentHash, Date().timeIntervalSince1970, folderID, file.colorProfile, rowID]
                        )
                    }
                } else if let sameFile = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM images WHERE filename = ? AND contentHash = ?",
                    arguments: [file.filename, file.contentHash]
                ) {
                    // Same file reachable from a new path (folder moved/re-added).
                    // Reactivate the existing record rather than creating a duplicate.
                    rowID = sameFile["id"] as! Int64
                    try db.execute(
                        sql: "UPDATE images SET path = ?, folderID = ?, isActive = 1, colorProfile = ? WHERE id = ?",
                        arguments: [path, folderID, file.colorProfile, rowID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO images (path, contentHash, filename, folderID, fileFormat, colorProfile, isActive, indexedAt)
                            VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                        """,
                        arguments: [path, file.contentHash, file.filename, folderID,
                                    file.fileFormat, file.colorProfile, Date().timeIntervalSince1970]
                    )
                    rowID = db.lastInsertedRowID
                }

                // Write captureDate as a separate statement with a concrete Double.
                // Doing this inside the same transaction and with a known rowID avoids
                // both path-mismatch and Optional<Double>-in-Any binding failures.
                if let date = file.captureDate {
                    let d: Double = date   // explicit concrete type — never optional
                    try db.execute(
                        sql: "UPDATE images SET captureDate = ? WHERE id = ?",
                        arguments: [d, rowID]
                    )
                }

                result.append((rowID, file.url))
            }
            return result
        }
    }

    private func imageIDsNeedingCaptions(ids: [Int64]) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { "\($0)" }.joined(separator: ",")
        return try db.read { db in
            let captioned = try Int64.fetchSet(
                db,
                sql: """
                    SELECT id FROM images
                    WHERE id IN (\(placeholders))
                    AND caption IS NOT NULL AND caption != ''
                """
            )
            return ids.filter { !captioned.contains($0) }
        }
    }

    private func imagesNeedingExtraction(ids: [Int64]) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { "\($0)" }.joined(separator: ",")
        return try db.read { db in
            let existing = try Int64.fetchSet(
                db,
                sql: "SELECT imageID FROM featureVectors WHERE imageID IN (\(placeholders))"
            )
            return ids.filter { !existing.contains($0) }
        }
    }

    private func generateThumbnail(imageID: Int64, sourceURL: URL, dir: URL) throws {
        let dest = dir.appendingPathComponent("\(imageID).jpg")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        guard
            let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            let thumb = CGImageSourceCreateThumbnailAtIndex(
                src, 0,
                [
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
            ),
            let destDest = CGImageDestinationCreateWithURL(
                dest as CFURL, "public.jpeg" as CFString, 1, nil
            )
        else { return }

        CGImageDestinationAddImage(
            destDest, thumb,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        CGImageDestinationFinalize(destDest)

        try db.write { db in
            try db.execute(
                sql: "UPDATE images SET thumbnailPath = ? WHERE id = ?",
                arguments: [dest.lastPathComponent, imageID]
            )
        }
    }

    private func thumbnailDirectory() -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conjunct/thumbnails")
    }

    // MARK: - Errors

    public enum ExtractionError: Error, LocalizedError {
        case imageLoadFailed(URL)

        public var errorDescription: String? {
            switch self {
            case .imageLoadFailed(let url):
                return "Failed to load image: \(url.lastPathComponent)"
            }
        }
    }
}
