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
    private let roleExtractionEngine: any RoleExtractionEngine
    /// Concurrency cap for CLIP feature extraction (Phase 3). CLIP is ANE-bound, so a
    /// modest cap avoids contention; left conservative deliberately. See decision #101.
    private let maxConcurrency: Int
    /// Concurrency cap for purely CPU/IO-bound backfill phases (thumbnails, accent, dHash).
    /// Derived from the machine's core count so the work scales on more powerful Macs
    /// rather than being pinned to a flat cap. See decision #101.
    private let cpuConcurrency: Int
    /// Concurrency cap for the Vision phase (saliency/gaze). Vision leans on the Neural
    /// Engine/GPU, so returns diminish past a handful of concurrent handlers — capped at 6.
    private let visionConcurrency: Int
    /// Holds the running cross-folder (phase 2) scoring task so it can be
    /// cancelled when a new index is triggered before phase 2 finishes.
    private var crossFolderTask: Task<Void, Never>?

    public init(
        db: DatabaseManager,
        clipEngine: any CLIPInferenceEngine,
        captioningEngine: any CaptioningEngine = MockCaptioningEngine(),
        roleExtractionEngine: any RoleExtractionEngine = MockRoleExtractionEngine(),
        maxConcurrency: Int = min(ProcessInfo.processInfo.processorCount, 4)
    ) {
        self.db = db
        self.clipEngine = clipEngine
        self.captioningEngine = captioningEngine
        self.roleExtractionEngine = roleExtractionEngine
        self.maxConcurrency = maxConcurrency
        let cores = ProcessInfo.processInfo.processorCount
        self.cpuConcurrency = max(1, cores)
        self.visionConcurrency = max(1, min(cores, 6))
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
                                topK: topK,
                                continuation: continuation
                            )
                        } catch {
                            // CancellationError or DB error — signal done either way
                        }
                        // Cross-folder scoring done — revert the UI label to the generic
                        // background state while Phase 8.5 role generation runs.
                        continuation.yield(IndexingProgress(
                            phase: .backgroundScoring, itemsComplete: 0, itemsTotal: 0
                        ))
                        // Phase 8.5: role-join entry-gate candidates (decision #102).
                        // Must run after all normal pairs (intra + cross) exist so dedup is
                        // accurate AND so the cross-folder scoped DELETE can't wipe freshly
                        // inserted role rows — hence its placement here. It depends only on
                        // persisted roleProfiles + the final pairs table, and is idempotent,
                        // so a newer index that cancels this task simply re-runs it; if THIS
                        // task is superseded we skip (the newer index will generate them).
                        if Task.isCancelled {
                            print("RoleCandidates: skipped — index superseded; newer index will regenerate")
                        } else {
                            do { try await self.generateRoleCandidates(weights: weights) }
                            catch is CancellationError { /* superseded mid-run; newer index handles it */ }
                            catch { print("RoleCandidates: \(error.localizedDescription)") }
                        }
                        // Gaze (directed-attention) candidates (#109) — same placement
                        // rationale as role candidates: needs the final pairs table for
                        // dedup, idempotent, re-runs if superseded.
                        if Task.isCancelled {
                            print("GazeCandidates: skipped — index superseded; newer index will regenerate")
                        } else {
                            do { try await self.generateGazeCandidates(weights: weights) }
                            catch is CancellationError { /* superseded mid-run; newer index handles it */ }
                            catch { print("GazeCandidates: \(error.localizedDescription)") }
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

        var thumbnailsDone = 0
        try await mapConcurrent(
            imageIDs,
            concurrency: cpuConcurrency,
            work: { pair in
                let (imageID, url) = pair
                return (imageID, Self.writeThumbnailFile(imageID: imageID, sourceURL: url, dir: thumbDir))
            },
            consume: { result in
                let (imageID, freshFilename) = result
                if let freshFilename {
                    try db.write { db in
                        try db.execute(
                            sql: "UPDATE images SET thumbnailPath = ? WHERE id = ?",
                            arguments: [freshFilename, imageID]
                        )
                    }
                }
                thumbnailsDone += 1
                continuation.yield(IndexingProgress(
                    phase: .thumbnails, itemsComplete: thumbnailsDone, itemsTotal: total
                ))
            }
        )

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
                        // Null roleProfile alongside the caption write: a changed caption
                        // invalidates the role profile extracted from the old text, so it
                        // must be re-extracted in Phase 3.55 (decision #102, mirrors the
                        // documented "roleProfile mirrors caption semantics" contract).
                        try db.execute(
                            sql: "UPDATE images SET caption = ?, roleProfile = NULL WHERE id = ?",
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

        // ── Phase 3.55: Role extraction (decision #102) ───────────────────
        // Extract a structured RoleProfile from each caption, feeding the role-join
        // entry-gate candidate generator (RoleJoins). Text-only — reads the caption
        // the captioning phase produced, so no image decoding. Sequential like
        // captioning (one local LLM call at a time). Skipped entirely when every
        // captioned image already has a profile, so normal re-indexes aren't slowed.
        let roleTargets: [(Int64, String)] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, caption FROM images
                WHERE isActive = 1
                  AND caption IS NOT NULL AND caption != ''
                  AND roleProfile IS NULL
            """)
            return rows.compactMap { row -> (Int64, String)? in
                guard let id = row["id"] as? Int64,
                      let caption = row["caption"] as? String else { return nil }
                return (id, caption)
            }
        }
        if !roleTargets.isEmpty {
            continuation.yield(IndexingProgress(
                phase: .roleExtraction, itemsComplete: 0, itemsTotal: roleTargets.count
            ))
            let roleEncoder = JSONEncoder()
            var rolesExtracted = 0
            for (imageID, caption) in roleTargets {
                try Task.checkCancellation()
                do {
                    let profile = try await roleExtractionEngine.extract(caption: caption)
                    // Skip empty profiles (mirrors captioning's `if !text.isEmpty`): a
                    // no-op/Mock engine returns an empty RoleProfile, and writing it as
                    // non-null `{}` JSON would poison the `roleProfile IS NULL` sentinel
                    // and permanently block real re-extraction. Leave NULL → retried.
                    guard !profile.isEmpty else { continue }
                    let jsonText = String(decoding: try roleEncoder.encode(profile), as: UTF8.self)
                    try db.write { db in
                        try db.execute(
                            sql: "UPDATE images SET roleProfile = ? WHERE id = ?",
                            arguments: [jsonText, imageID]
                        )
                    }
                    rolesExtracted += 1
                } catch {
                    print("ROLE: skipped image \(imageID) — \(error.localizedDescription)")
                }
                continuation.yield(IndexingProgress(
                    phase: .roleExtraction, itemsComplete: rolesExtracted, itemsTotal: roleTargets.count
                ))
            }
        }

        // ── Phase 3.6: Accent color extraction ───────────────────────────
        // Backfills accentHue / accentSaturation for all active images that lack it.
        // Uses the cached 512px thumbnail when available (same pattern as Phase 3.5).
        // Images where extraction returns nil (B&W, neutral-heavy) remain NULL and
        // will be re-attempted on the next re-index — same trade-off as caption backfill.
        continuation.yield(IndexingProgress(
            phase: .accentExtraction, itemsComplete: 0, itemsTotal: 0
        ))

        let accentThumbDir = thumbnailDirectory()
        let accentRows: [(Int64, URL)] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, thumbnailPath FROM images
                WHERE isActive = 1 AND accentHue IS NULL
            """)
            return rows.compactMap { row -> (Int64, URL)? in
                guard let id   = row["id"]   as? Int64,
                      let path = row["path"] as? String else { return nil }
                if let thumbName = row["thumbnailPath"] as? String {
                    let thumbURL = accentThumbDir.appendingPathComponent(thumbName)
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

        var accentDone = 0
        let accentTotal = accentRows.count
        try await mapConcurrent(
            accentRows,
            concurrency: cpuConcurrency,
            work: { pair -> (Int64, Float, Float)? in
                let (imageID, url) = pair
                guard let cgImage = Self.loadCGImage(url: url),
                      let accent  = try? ColourAnalyser.extractAccentColor(image: cgImage)
                else { return nil }
                return (imageID, accent.hue, accent.saturation)
            },
            consume: { result in
                if let (imageID, hue, saturation) = result {
                    try db.write { db in
                        try db.execute(
                            sql: "UPDATE images SET accentHue = ?, accentSaturation = ? WHERE id = ?",
                            arguments: [hue, saturation, imageID]
                        )
                    }
                }
                accentDone += 1
                continuation.yield(IndexingProgress(
                    phase: .accentExtraction, itemsComplete: accentDone, itemsTotal: accentTotal
                ))
            }
        )
        // ── Phase 3.7: Saliency centroid extraction ───────────────────────
        // Backfills weightCentroidX / weightCentroidY using Vision attention saliency.
        // Runs on cached 512px thumbnails — no re-decode from originals required.
        continuation.yield(IndexingProgress(
            phase: .centroidExtraction, itemsComplete: 0, itemsTotal: 0
        ))

        let saliencyIDs: [Int64] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id FROM images
                WHERE isActive = 1 AND (weightCentroidX IS NULL OR gazeDirectionX IS NULL)
            """)
            return rows.compactMap { $0["id"] as? Int64 }
        }

        var saliencyDone = 0
        let saliencyTotal = saliencyIDs.count
        try await mapConcurrent(
            saliencyIDs,
            concurrency: visionConcurrency,
            work: { imageID -> (Int64, ImageSpatialFeatures?) in
                let url = thumbDir.appendingPathComponent("\(imageID).jpg")
                return (imageID, try? SaliencyAnalyser.analyse(thumbnailURL: url))
            },
            consume: { result in
                let (imageID, features) = result
                try db.write { db in
                    try db.execute(
                        sql: """
                            UPDATE images
                            SET weightCentroidX = ?, weightCentroidY = ?, gazeDirectionX = ?
                            WHERE id = ?
                        """,
                        arguments: [
                            features?.centroid?.x, features?.centroid?.y,
                            features?.gazeDirectionX,
                            imageID
                        ]
                    )
                }
                saliencyDone += 1
                continuation.yield(IndexingProgress(
                    phase: .centroidExtraction, itemsComplete: saliencyDone, itemsTotal: saliencyTotal
                ))
            }
        )

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
        typealias ImageMeta = (captureDate: Double?, filename: String, caption: String,
                               accentHue: Double?, accentSaturation: Double?,
                               weightCentroidX: Double?, weightCentroidY: Double?,
                               gazeDirectionX: Double?, colorProfile: String)
        let imageMeta: [Int64: ImageMeta] = try db.read { db in
            guard !batchIDs.isEmpty else { return [:] }
            let ids = batchIDs.map { "\($0)" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, captureDate, filename, caption, accentHue, accentSaturation, weightCentroidX, weightCentroidY, gazeDirectionX, colorProfile FROM images WHERE id IN (\(ids))"
            )
            var result = [Int64: ImageMeta]()
            for row in rows {
                let id = row["id"] as! Int64
                result[id] = (
                    captureDate: (row["captureDate"] as? Double)
                        ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as? String ?? "",
                    caption: row["caption"] as? String ?? "",
                    accentHue: row["accentHue"] as? Double,
                    accentSaturation: row["accentSaturation"] as? Double,
                    weightCentroidX: row["weightCentroidX"] as? Double,
                    weightCentroidY: row["weightCentroidY"] as? Double,
                    gazeDirectionX: row["gazeDirectionX"] as? Double,
                    colorProfile: row["colorProfile"] as? String ?? "color"
                )
            }
            return result
        }

        // Score every (i, j>i) pair. PairScorer.score is a pure static function, so each
        // row is independent and safe to compute concurrently; results are merged and
        // written serially on the actor in `consume`. Final four-pool topK selection is
        // order-independent, so parallel completion order does not change which pairs are
        // stored. See decision #101.
        var allScores: [PairScore] = []
        allScores.reserveCapacity(batchVectors.count * (batchVectors.count - 1) / 2)

        var scored = 0
        try await mapConcurrent(
            Array(batchVectors.indices),
            concurrency: cpuConcurrency,
            work: { i -> [PairScore] in
                let vA = batchVectors[i]
                let metaA = imageMeta[vA.imageID]
                var rowScores: [PairScore] = []
                for j in (i + 1)..<batchVectors.count {
                    let vB = batchVectors[j]
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
                        accentHueA: metaA?.accentHue, accentSaturationA: metaA?.accentSaturation,
                        accentHueB: metaB?.accentHue, accentSaturationB: metaB?.accentSaturation,
                        weightCentroidXA: metaA?.weightCentroidX.map(Float.init),
                        weightCentroidYA: metaA?.weightCentroidY.map(Float.init),
                        weightCentroidXB: metaB?.weightCentroidX.map(Float.init),
                        weightCentroidYB: metaB?.weightCentroidY.map(Float.init),
                        gazeDirectionXA: metaA?.gazeDirectionX.map(Float.init),
                        gazeDirectionXB: metaB?.gazeDirectionX.map(Float.init),
                        colorProfileA: metaA?.colorProfile ?? "color",
                        colorProfileB: metaB?.colorProfile ?? "color",
                        weights: weights
                    )
                    if s.compositeScore > 0 {
                        rowScores.append(s)
                    }
                }
                return rowScores
            },
            consume: { rowScores in
                allScores.append(contentsOf: rowScores)
                scored += 1
                continuation.yield(IndexingProgress(
                    phase: .scoring, itemsComplete: scored, itemsTotal: batchVectors.count
                ))
            }
        )

        let batchIDList = Array(batchIDs)
        // Drop burst near-duplicates before pool selection so they never enter any of the
        // four topK pools (the thematic/aesthetic/geometric pools select on raw axis score,
        // where the temporal penalty never applies). See decision #84.
        let scoresToInsert = allScores.filter { s in
            !Self.isBurstNearDuplicate(
                captureDateA: imageMeta[s.imageAID]?.captureDate,
                captureDateB: imageMeta[s.imageBID]?.captureDate,
                filenameA: imageMeta[s.imageAID]?.filename ?? "",
                filenameB: imageMeta[s.imageBID]?.filename ?? ""
            )
        }
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
            var compositeKeys = Set<String>()
            for (_, scores) in perImage {
                for s in Self.orderedByScore(scores, { $0.compositeScore }).prefix(topK) {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil {
                        toInsert[key] = s
                        compositeKeys.insert(key)
                    }
                }
            }

            let thematicK = max(30, topK / 3)
            for (_, scores) in perImage {
                let thematicCandidates = Self.orderedByScore(
                    scores.filter { $0.thematicScore >= 0.20 },
                    { $0.thematicScore }
                ).prefix(thematicK)
                for s in thematicCandidates {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil { toInsert[key] = s }
                }
            }

            // Geometric topK: top-5 per image by geometricScore, with one bonus slot
            // for the best non-structural pair if all top-5 are structural. Ensures
            // gaze_conversation and directional_complement pairs surface even when their
            // composite score is too low for the composite pool. See decision #68.
            let geometricK = 5
            var geometricKeys = Set<String>()
            for (_, scores) in perImage {
                let byGeo = Self.orderedByScore(scores, { $0.geometricScore })
                var slotsUsed = 0
                var hasNonStructural = false
                for s in byGeo {
                    if slotsUsed >= geometricK && hasNonStructural { break }
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    let isNonStructural = s.geometricSubmode != "structural"
                    if slotsUsed < geometricK {
                        if toInsert[key] == nil {
                            toInsert[key] = s
                            geometricKeys.insert(key)
                        }
                        slotsUsed += 1
                        if isNonStructural { hasNonStructural = true }
                    } else if !hasNonStructural && isNonStructural {
                        if toInsert[key] == nil {
                            toInsert[key] = s
                            geometricKeys.insert(key)
                        }
                        hasNonStructural = true
                    }
                }
            }

            // Aesthetic topK: top-5 per image by aestheticScore (minimum 0.55).
            // Escape hatch for strong aesthetic pairs — accent-echo and strong harmony/
            // contrast pairs — that are dragged below the composite topK ceiling by weak
            // thematic scores. Symmetric to the geometric escape hatch (#68).
            // See decision #75.
            let aestheticK = 5
            var aestheticKeys = Set<String>()
            for (_, scores) in perImage {
                let byAesthetic = Self.orderedByScore(
                    scores.filter { $0.aestheticScore >= 0.55 },
                    { $0.aestheticScore }
                )
                for s in byAesthetic.prefix(aestheticK) {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil {
                        toInsert[key] = s
                        aestheticKeys.insert(key)
                    }
                }
            }

            for (key, s) in toInsert {
                let selFor: String
                if compositeKeys.contains(key) { selFor = "composite" }
                else if geometricKeys.contains(key) { selFor = "geometric" }
                else if aestheticKeys.contains(key) { selFor = "aesthetic" }
                else { selFor = "thematic" }
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
                    selectedFor: selFor,
                    thematicScore: Double(s.thematicScore),
                    compositeScore: Double(s.compositeScore),
                    rationale: s.rationale,
                    geometricSubmode: s.geometricSubmode
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
        topK: Int,
        continuation: AsyncStream<IndexingProgress>.Continuation
    ) async throws {
        guard !batchIDs.isEmpty else { return }
        try Task.checkCancellation()

        let allVectors = try loadHeroVectors()
        let batchVectors = allVectors.filter {  batchIDs.contains($0.imageID) }
        let otherVectors = allVectors.filter { !batchIDs.contains($0.imageID) }

        // No other active images to score against (e.g. a single folder) — nothing to do.
        guard !batchVectors.isEmpty, !otherVectors.isEmpty else { return }

        // Genuine cross-folder work exists — surface it in the UI label.
        continuation.yield(IndexingProgress(
            phase: .scoringCrossFolder, itemsComplete: 0, itemsTotal: 0
        ))

        typealias ImageMeta = (captureDate: Double?, filename: String, caption: String,
                               accentHue: Double?, accentSaturation: Double?,
                               weightCentroidX: Double?, weightCentroidY: Double?,
                               gazeDirectionX: Double?, colorProfile: String)
        let imageMeta: [Int64: ImageMeta] = try db.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, captureDate, filename, caption, accentHue, accentSaturation, weightCentroidX, weightCentroidY, gazeDirectionX, colorProfile FROM images WHERE isActive = 1"
            )
            var result = [Int64: ImageMeta]()
            for row in rows {
                let id = row["id"] as! Int64
                result[id] = (
                    captureDate: (row["captureDate"] as? Double)
                        ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as? String ?? "",
                    caption: row["caption"] as? String ?? "",
                    accentHue: row["accentHue"] as? Double,
                    accentSaturation: row["accentSaturation"] as? Double,
                    weightCentroidX: row["weightCentroidX"] as? Double,
                    weightCentroidY: row["weightCentroidY"] as? Double,
                    gazeDirectionX: row["gazeDirectionX"] as? Double,
                    colorProfile: row["colorProfile"] as? String ?? "color"
                )
            }
            return result
        }

        // batch × all-other scoring. As in the intra-folder phase, PairScorer.score is
        // pure, so each batch row is computed concurrently and merged serially. See #101.
        var allScores: [PairScore] = []
        allScores.reserveCapacity(batchVectors.count * otherVectors.count)

        try await mapConcurrent(
            Array(batchVectors.indices),
            concurrency: cpuConcurrency,
            work: { i -> [PairScore] in
                let vA = batchVectors[i]
                let metaA = imageMeta[vA.imageID]
                var rowScores: [PairScore] = []
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
                        accentHueA: metaA?.accentHue, accentSaturationA: metaA?.accentSaturation,
                        accentHueB: metaB?.accentHue, accentSaturationB: metaB?.accentSaturation,
                        weightCentroidXA: metaA?.weightCentroidX.map(Float.init),
                        weightCentroidYA: metaA?.weightCentroidY.map(Float.init),
                        weightCentroidXB: metaB?.weightCentroidX.map(Float.init),
                        weightCentroidYB: metaB?.weightCentroidY.map(Float.init),
                        gazeDirectionXA: metaA?.gazeDirectionX.map(Float.init),
                        gazeDirectionXB: metaB?.gazeDirectionX.map(Float.init),
                        colorProfileA: metaA?.colorProfile ?? "color",
                        colorProfileB: metaB?.colorProfile ?? "color",
                        weights: weights
                    )
                    if s.compositeScore > 0 {
                        rowScores.append(s)
                    }
                }
                return rowScores
            },
            consume: { rowScores in
                allScores.append(contentsOf: rowScores)
            }
        )

        try Task.checkCancellation()

        let batchIDList = Array(batchIDs)
        // Drop burst near-duplicates before pool selection — see decision #84 and the
        // matching guard in runIntraFolderScoring.
        let scoresToInsert = allScores.filter { s in
            !Self.isBurstNearDuplicate(
                captureDateA: imageMeta[s.imageAID]?.captureDate,
                captureDateB: imageMeta[s.imageBID]?.captureDate,
                filenameA: imageMeta[s.imageAID]?.filename ?? "",
                filenameB: imageMeta[s.imageBID]?.filename ?? ""
            )
        }
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
            var compositeKeys = Set<String>()
            for (_, scores) in perImage {
                for s in Self.orderedByScore(scores, { $0.compositeScore }).prefix(topK) {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil {
                        toInsert[key] = s
                        compositeKeys.insert(key)
                    }
                }
            }

            let thematicK = max(30, topK / 3)
            for (_, scores) in perImage {
                let thematicCandidates = Self.orderedByScore(
                    scores.filter { $0.thematicScore >= 0.20 },
                    { $0.thematicScore }
                ).prefix(thematicK)
                for s in thematicCandidates {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil { toInsert[key] = s }
                }
            }

            // Geometric topK: top-5 per image by geometricScore, with one bonus slot
            // for the best non-structural pair if all top-5 are structural. See decision #68.
            let geometricK = 5
            var geometricKeys = Set<String>()
            for (_, scores) in perImage {
                let byGeo = Self.orderedByScore(scores, { $0.geometricScore })
                var slotsUsed = 0
                var hasNonStructural = false
                for s in byGeo {
                    if slotsUsed >= geometricK && hasNonStructural { break }
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    let isNonStructural = s.geometricSubmode != "structural"
                    if slotsUsed < geometricK {
                        if toInsert[key] == nil {
                            toInsert[key] = s
                            geometricKeys.insert(key)
                        }
                        slotsUsed += 1
                        if isNonStructural { hasNonStructural = true }
                    } else if !hasNonStructural && isNonStructural {
                        if toInsert[key] == nil {
                            toInsert[key] = s
                            geometricKeys.insert(key)
                        }
                        hasNonStructural = true
                    }
                }
            }

            // Aesthetic topK: top-5 per image by aestheticScore (minimum 0.55).
            // See decision #75.
            let aestheticK = 5
            var aestheticKeys = Set<String>()
            for (_, scores) in perImage {
                let byAesthetic = Self.orderedByScore(
                    scores.filter { $0.aestheticScore >= 0.55 },
                    { $0.aestheticScore }
                )
                for s in byAesthetic.prefix(aestheticK) {
                    let key = "\(s.imageAID)_\(s.imageBID)"
                    if toInsert[key] == nil {
                        toInsert[key] = s
                        aestheticKeys.insert(key)
                    }
                }
            }

            for (key, s) in toInsert {
                let selFor: String
                if compositeKeys.contains(key) { selFor = "composite" }
                else if geometricKeys.contains(key) { selFor = "geometric" }
                else if aestheticKeys.contains(key) { selFor = "aesthetic" }
                else { selFor = "thematic" }
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
                    selectedFor: selFor,
                    thematicScore: Double(s.thematicScore),
                    compositeScore: Double(s.compositeScore),
                    rationale: s.rationale,
                    geometricSubmode: s.geometricSubmode
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

        // Compute dHash for any images that don't have one yet. The "already hashed?"
        // check is hoisted into a single read so the hash computation (CGImageSource
        // decode + dHash) can run concurrently; DB writes stay serial in `consume`.
        let alreadyHashed: Set<Int64> = try db.read { db in
            try Int64.fetchSet(db, sql: "SELECT id FROM images WHERE dHash IS NOT NULL")
        }
        var hashedDone = 0
        try await mapConcurrent(
            imageIDs,
            concurrency: cpuConcurrency,
            work: { pair -> (Int64, String)? in
                let (imageID, url) = pair
                guard !alreadyHashed.contains(imageID) else { return nil }
                return (imageID, (try? PerceptualHasher.dHash(url: url)) ?? "")
            },
            consume: { result in
                if let (imageID, hash) = result {
                    try db.write { db in
                        try db.execute(
                            sql: "UPDATE images SET dHash = ? WHERE id = ?",
                            arguments: [hash, imageID]
                        )
                    }
                }
                hashedDone += 1
                continuation.yield(IndexingProgress(
                    phase: .duplicateDetection,
                    itemsComplete: hashedDone,
                    itemsTotal: imageIDs.count
                ))
            }
        )

        // Load all hashes and find groups using union-find.
        // Extract to plain Swift tuples immediately so Row values
        // never cross the actor boundary (Row is not Sendable in GRDB 6).
        typealias HashRow = (id: Int64, dHash: String, captureDate: Double?, filename: String)
        let hashRows: [HashRow] = try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, dHash, captureDate, filename FROM images WHERE isActive = 1 AND dHash IS NOT NULL AND dHash != ''"
            ).map { row in
                (
                    id: row["id"] as! Int64,
                    dHash: row["dHash"] as! String,
                    captureDate: (row["captureDate"] as? Double) ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as! String
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
                    continue
                }

                // Filename-variant rule — documented last resort (decision #94).
                // Crop/re-export copies of the same photo drift 7–20 Hamming bits,
                // and no pixel-level threshold separates them from genuine burst
                // frames (a real same-second burst pair in the reference library
                // measures Hamming 19 / CLIP 0.964 — *more* similar than a crop
                // copy at Hamming 20 / CLIP 0.934). So crops are matched by
                // export naming convention instead, gated on identical EXIF
                // captureDate: a re-export keeps its capture timestamp, while a
                // name collision from camera counter rollover does not.
                if let dA = hashRows[i].captureDate,
                   let dB = hashRows[j].captureDate,
                   dA == dB,
                   FilenameVariants.areVariants(hashRows[i].filename, hashRows[j].filename) {
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

            // Clear any previous duplicate group assignments. Old group rows are
            // deleted too — they are re-created from scratch every run, and
            // leaving them accumulates thousands of unreferenced rows.
            try db.execute(sql: "UPDATE images SET duplicateGroupID = NULL, isHero = 1")
            try db.execute(sql: "DELETE FROM duplicateGroups")

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

    // MARK: - Phase 8.5: Role-join candidate generation (decision #102)

    /// Generates entry-gate candidate pairs from per-image RoleProfiles and INSERTs
    /// them into `pairs` (selectedFor = "role", join hypothesis in `rationale`) for
    /// the validation judge to score. These are conceptual connections weak on every
    /// cheap axis that the four-pool topK never surfaces (backlog #95). Idempotent:
    /// skips pairs already in the table; re-runs each index (role rows are wiped by
    /// the per-run scoped DELETE and regenerated here). Validated config (Phase 0):
    /// joins 1/2/3, per-image-per-priority cap 4. Public so it can be re-run
    /// standalone (e.g. after a caption/profile change) without a full re-index.
    public func generateRoleCandidates(weights: ScoringWeights = .default) async throws {
        try Task.checkCancellation()   // bail fast if a newer index superseded us
        struct Profiled { let id: Int64; let profile: RoleProfile }
        let profiled: [Profiled] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, roleProfile FROM images
                WHERE isActive = 1 AND isHero = 1 AND roleProfile IS NOT NULL
            """)
            let dec = JSONDecoder()
            return rows.compactMap { row -> Profiled? in
                guard let id = row["id"] as? Int64,
                      let json = row["roleProfile"] as? String,
                      let data = json.data(using: .utf8),
                      let p = try? dec.decode(RoleProfile.self, from: data) else { return nil }
                return Profiled(id: id, profile: p)
            }
        }
        guard profiled.count > 1 else { return }

        // Corpus-derived non-discriminating concepts, then capped joins over all pairs.
        let generic = RoleJoins.genericConcepts(profiled.map(\.profile))
        let cap = 4
        var degree: [String: Int] = [:]
        struct Cand { let a: Int64; let b: Int64; let join: RoleJoins.Candidate }
        var cands: [Cand] = []
        for i in 0..<profiled.count {
            for j in (i + 1)..<profiled.count {
                guard let c = RoleJoins.join(profiled[i].profile, profiled[j].profile, generic: generic) else { continue }
                let ka = "\(profiled[i].id)#\(c.priority)", kb = "\(profiled[j].id)#\(c.priority)"
                if (degree[ka] ?? 0) < cap && (degree[kb] ?? 0) < cap {
                    cands.append(Cand(a: profiled[i].id, b: profiled[j].id, join: c))
                    degree[ka, default: 0] += 1; degree[kb, default: 0] += 1
                }
            }
        }
        guard !cands.isEmpty else { return }

        // Vectors + metadata for axis scoring (reuse PairScorer); existing-pair set for dedup.
        let vectors = try loadHeroVectors()
        let vByID = Dictionary(uniqueKeysWithValues: vectors.map { ($0.imageID, $0) })
        typealias ImageMeta = (captureDate: Double?, filename: String, caption: String,
                               accentHue: Double?, accentSaturation: Double?,
                               weightCentroidX: Double?, weightCentroidY: Double?,
                               gazeDirectionX: Double?, colorProfile: String)
        let heroIDs = vectors.map(\.imageID)
        let meta: [Int64: ImageMeta] = try db.read { db in
            guard !heroIDs.isEmpty else { return [:] }
            let ids = heroIDs.map { "\($0)" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT id, captureDate, filename, caption, accentHue, accentSaturation, weightCentroidX, weightCentroidY, gazeDirectionX, colorProfile FROM images WHERE id IN (\(ids))")
            var r = [Int64: ImageMeta]()
            for row in rows {
                let id = row["id"] as! Int64
                r[id] = (
                    captureDate: (row["captureDate"] as? Double) ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as? String ?? "",
                    caption: row["caption"] as? String ?? "",
                    accentHue: row["accentHue"] as? Double,
                    accentSaturation: row["accentSaturation"] as? Double,
                    weightCentroidX: row["weightCentroidX"] as? Double,
                    weightCentroidY: row["weightCentroidY"] as? Double,
                    gazeDirectionX: row["gazeDirectionX"] as? Double,
                    colorProfile: row["colorProfile"] as? String ?? "color"
                )
            }
            return r
        }
        // Canonical key → existing pairID. A join candidate that already has a pair
        // row (e.g. surfaced as composite/aesthetic) must still get the role
        // hypothesis + validate() treatment, so we UPDATE it rather than skip it.
        let existing: [String: Int64] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, imageAID, imageBID FROM pairs")
            var m = [String: Int64]()
            for row in rows {
                guard let id = row["id"] as? Int64,
                      let a = row["imageAID"] as? Int64, let b = row["imageBID"] as? Int64 else { continue }
                let (lo, hi) = a < b ? (a, b) : (b, a)
                m["\(lo)_\(hi)"] = id
            }
            return m
        }

        var inserted = 0, updated = 0
        try db.write { db in
            for c in cands {
                let (lo, hi) = c.a < c.b ? (c.a, c.b) : (c.b, c.a)
                let hypothesis = String(c.join.hypothesis.prefix(240))
                // Near-duplicate guard — mirror ThematicV2BackgroundPass.fetchCandidates
                // (decision #102/#84): burst frames (identical/near-identical captureDate)
                // and filename export variants fire joins on near-identical profiles. The
                // judge excludes them from scoring anyway, so a role candidate here would
                // only ever sit unjudged and surface on its inflated cluster thematicScore.
                // Skip them at the source.
                let mLo = meta[lo]; let mHi = meta[hi]
                if let da = mLo?.captureDate, let dbb = mHi?.captureDate, abs(da - dbb) <= 300 { continue }
                if FilenameVariants.areVariants(mLo?.filename ?? "", mHi?.filename ?? "") { continue }
                if let pairID = existing["\(lo)_\(hi)"] {
                    // Existing pair: attach the hypothesis and re-route to validate() by
                    // clearing any prior (cold) ThematicV2 verdict — but ONLY when the
                    // hypothesis is new or changed. RoleJoins is deterministic and profiles
                    // are stable, so an unchanged hypothesis must be a no-op; otherwise every
                    // re-index would re-null and re-judge the same surviving pairs forever,
                    // thrashing the judge budget (decision #102).
                    try db.execute(sql: """
                        UPDATE pairs SET roleHypothesis = ?,
                                         thematicV2Score = NULL,
                                         thematicV2RelationshipType = NULL,
                                         thematicV2Rationale = NULL
                        WHERE id = ? AND (roleHypothesis IS NULL OR roleHypothesis != ?)
                    """, arguments: [hypothesis, pairID, hypothesis])
                    if db.changesCount > 0 { updated += 1 }
                    continue
                }
                guard let vA = vByID[lo], let vB = vByID[hi] else { continue }
                let mA = mLo; let mB = mHi
                let s = PairScorer.score(
                    imageAID: lo, vectorA: vA, imageBID: hi, vectorB: vB,
                    captureDateA: mA?.captureDate, captureDateB: mB?.captureDate,
                    filenameA: mA?.filename ?? "", filenameB: mB?.filename ?? "",
                    captionA: mA?.caption ?? "", captionB: mB?.caption ?? "",
                    accentHueA: mA?.accentHue, accentSaturationA: mA?.accentSaturation,
                    accentHueB: mB?.accentHue, accentSaturationB: mB?.accentSaturation,
                    weightCentroidXA: mA?.weightCentroidX.map(Float.init), weightCentroidYA: mA?.weightCentroidY.map(Float.init),
                    weightCentroidXB: mB?.weightCentroidX.map(Float.init), weightCentroidYB: mB?.weightCentroidY.map(Float.init),
                    gazeDirectionXA: mA?.gazeDirectionX.map(Float.init), gazeDirectionXB: mB?.gazeDirectionX.map(Float.init),
                    colorProfileA: mA?.colorProfile ?? "color", colorProfileB: mB?.colorProfile ?? "color",
                    weights: weights
                )
                var rec = PairRecord(
                    imageAID: s.imageAID, imageBID: s.imageBID,
                    aestheticScore: Double(s.aestheticScore), aestheticSubmode: s.aestheticSubmode,
                    geometricScore: Double(s.geometricScore),
                    rawEdgeSim: Double(s.rawEdgeSim), rawGridSim: Double(s.rawGridSim),
                    maxEdgePeakedness: Double(s.maxEdgePeakedness), maxGridVariance: Double(s.maxGridVariance),
                    edgePeakednessMult: Double(s.edgePeakednessMult), gridVarianceMult: Double(s.gridVarianceMult),
                    selectedFor: "role",
                    thematicScore: Double(s.thematicScore), compositeScore: Double(s.compositeScore),
                    rationale: c.join.hypothesis,
                    geometricSubmode: s.geometricSubmode,
                    roleHypothesis: hypothesis
                )
                try rec.insert(db)
                inserted += 1
            }
        }
        print("RoleCandidates: \(inserted) new + \(updated) existing tagged of \(cands.count) joins (\(profiled.count) profiles)")
    }

    /// Geometric nomination of directed-attention "call and response" candidates
    /// (backlog #72, decision #109). Runs in the cross-folder task after scoring and
    /// `generateRoleCandidates`. Pairs a strong lateral looker (`|gazeDirectionX|`)
    /// with a target whose subject sits toward the gutter (`weightCentroidX`) so the
    /// look lands on it; orientation per the gaze convention (rightward-gazer = left).
    /// Inserts NEW pairs as `selectedFor='gaze'` with axis scores via PairScorer and
    /// `gazeJudgeScore` NULL (pending the vision judge — a later phase). The connection
    /// is visual, not textual, so these never go through the text ThematicV2 judge.
    ///
    /// Phase-1 scope: NEW pairs only — a nominated diptych that already exists as a
    /// pair (rare: gaze pairs are a fresh geometric relationship the four-pool topK
    /// doesn't select for) is skipped, not tagged. Existing-pair tagging can follow
    /// once the vision judge lands, mirroring the role pattern.
    public func generateGazeCandidates(weights: ScoringWeights = .default) async throws {
        try Task.checkCancellation()
        struct GazeMeta { let id: Int64; let gaze: Double?; let centroidX: Double?; let captureDate: Double? }
        let gazeRows: [GazeMeta] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, gazeDirectionX, weightCentroidX, captureDate FROM images
                WHERE isActive = 1 AND isHero = 1
            """)
            return rows.compactMap { row -> GazeMeta? in
                guard let id = row["id"] as? Int64 else { return nil }
                return GazeMeta(
                    id: id,
                    gaze: row["gazeDirectionX"] as? Double,
                    centroidX: row["weightCentroidX"] as? Double,
                    captureDate: (row["captureDate"] as? Double) ?? (row["captureDate"] as? Int64).map(Double.init))
            }
        }
        guard gazeRows.count > 1 else { return }

        let candidates = GazeNominator.nominate(gazeRows.map {
            GazeNominator.Image(id: $0.id, gaze: $0.gaze.map(Float.init),
                                centroidX: $0.centroidX.map(Float.init), captureDate: $0.captureDate)
        })
        guard !candidates.isEmpty else { return }

        // Vectors + metadata for axis scoring (reuse PairScorer); existing-pair set for dedup.
        let vectors = try loadHeroVectors()
        let vByID = Dictionary(uniqueKeysWithValues: vectors.map { ($0.imageID, $0) })
        typealias ImageMeta = (captureDate: Double?, filename: String, caption: String,
                               accentHue: Double?, accentSaturation: Double?,
                               weightCentroidX: Double?, weightCentroidY: Double?,
                               gazeDirectionX: Double?, colorProfile: String)
        let heroIDs = vectors.map(\.imageID)
        let meta: [Int64: ImageMeta] = try db.read { db in
            guard !heroIDs.isEmpty else { return [:] }
            let ids = heroIDs.map { "\($0)" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT id, captureDate, filename, caption, accentHue, accentSaturation, weightCentroidX, weightCentroidY, gazeDirectionX, colorProfile FROM images WHERE id IN (\(ids))")
            var r = [Int64: ImageMeta]()
            for row in rows {
                let id = row["id"] as! Int64
                r[id] = (
                    captureDate: (row["captureDate"] as? Double) ?? (row["captureDate"] as? Int64).map(Double.init),
                    filename: row["filename"] as? String ?? "",
                    caption: row["caption"] as? String ?? "",
                    accentHue: row["accentHue"] as? Double,
                    accentSaturation: row["accentSaturation"] as? Double,
                    weightCentroidX: row["weightCentroidX"] as? Double,
                    weightCentroidY: row["weightCentroidY"] as? Double,
                    gazeDirectionX: row["gazeDirectionX"] as? Double,
                    colorProfile: row["colorProfile"] as? String ?? "color"
                )
            }
            return r
        }
        let existing: Set<String> = try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT imageAID, imageBID FROM pairs")
            var s = Set<String>()
            for row in rows {
                guard let a = row["imageAID"] as? Int64, let b = row["imageBID"] as? Int64 else { continue }
                let (lo, hi) = a < b ? (a, b) : (b, a)
                s.insert("\(lo)_\(hi)")
            }
            return s
        }

        var inserted = 0
        try db.write { db in
            for c in candidates {
                let (lo, hi) = c.leftID < c.rightID ? (c.leftID, c.rightID) : (c.rightID, c.leftID)
                if existing.contains("\(lo)_\(hi)") { continue }            // Phase 1: new pairs only
                let mL = meta[c.leftID]; let mR = meta[c.rightID]
                if FilenameVariants.areVariants(mL?.filename ?? "", mR?.filename ?? "") { continue }
                guard let vL = vByID[c.leftID], let vR = vByID[c.rightID] else { continue }
                // Display orientation is fixed by the nominator (looker faces the gutter);
                // PairScorer is used only for the symmetric axis scores. leftID stays imageAID.
                let s = PairScorer.score(
                    imageAID: c.leftID, vectorA: vL, imageBID: c.rightID, vectorB: vR,
                    captureDateA: mL?.captureDate, captureDateB: mR?.captureDate,
                    filenameA: mL?.filename ?? "", filenameB: mR?.filename ?? "",
                    captionA: mL?.caption ?? "", captionB: mR?.caption ?? "",
                    accentHueA: mL?.accentHue, accentSaturationA: mL?.accentSaturation,
                    accentHueB: mR?.accentHue, accentSaturationB: mR?.accentSaturation,
                    weightCentroidXA: mL?.weightCentroidX.map(Float.init), weightCentroidYA: mL?.weightCentroidY.map(Float.init),
                    weightCentroidXB: mR?.weightCentroidX.map(Float.init), weightCentroidYB: mR?.weightCentroidY.map(Float.init),
                    gazeDirectionXA: mL?.gazeDirectionX.map(Float.init), gazeDirectionXB: mR?.gazeDirectionX.map(Float.init),
                    colorProfileA: mL?.colorProfile ?? "color", colorProfileB: mR?.colorProfile ?? "color",
                    weights: weights
                )
                var rec = PairRecord(
                    imageAID: c.leftID, imageBID: c.rightID,
                    aestheticScore: Double(s.aestheticScore), aestheticSubmode: s.aestheticSubmode,
                    geometricScore: Double(s.geometricScore),
                    rawEdgeSim: Double(s.rawEdgeSim), rawGridSim: Double(s.rawGridSim),
                    maxEdgePeakedness: Double(s.maxEdgePeakedness), maxGridVariance: Double(s.maxGridVariance),
                    edgePeakednessMult: Double(s.edgePeakednessMult), gridVarianceMult: Double(s.gridVarianceMult),
                    selectedFor: "gaze",
                    thematicScore: Double(s.thematicScore), compositeScore: Double(s.compositeScore),
                    rationale: "directed gaze: a figure looks toward the other image's subject — pending vision judge",
                    geometricSubmode: s.geometricSubmode,
                    roleHypothesis: nil
                )
                try rec.insert(db)
                inserted += 1
            }
        }
        print("GazeCandidates: \(inserted) new of \(candidates.count) nominated (\(gazeRows.count) heroes)")
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

    /// Runs `work` over `items` with at most `concurrency` tasks in flight, invoking
    /// `consume` on the engine actor for each result as it completes.
    ///
    /// `work` MUST be pure/`Sendable` — no actor state, no DB access — because it runs on
    /// the concurrent task pool. All DB writes belong in `consume`, which runs serially on
    /// the engine actor, preserving GRDB's single-writer requirement. This is the bounded
    /// producer-consumer pattern used by Phase 3 CLIP extraction, generalised. See #101.
    private func mapConcurrent<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        concurrency: Int,
        work: @escaping @Sendable (Item) async throws -> Result,
        consume: (Result) throws -> Void
    ) async throws {
        var iterator = items.makeIterator()
        try await withThrowingTaskGroup(of: Result.self) { group in
            func launchNext() {
                guard let item = iterator.next() else { return }
                group.addTask { try await work(item) }
            }
            for _ in 0..<max(1, concurrency) { launchNext() }
            while let result = try await group.next() {
                try Task.checkCancellation()
                try consume(result)
                launchNext()
            }
        }
    }

    /// Deterministic ordering for topK pool selection: primary `key` descending with a
    /// stable tiebreaker on pair identity. Because scoring is now parallel, `scoresToInsert`
    /// arrives in nondeterministic order; without a tiebreaker an unstable `sorted` + `prefix`
    /// would select different pairs among exact score ties run-to-run. This keeps the stored
    /// pair set fully reproducible regardless of completion order. See decision #101.
    private static func orderedByScore(
        _ scores: [PairScore],
        _ key: (PairScore) -> Float
    ) -> [PairScore] {
        scores.sorted { a, b in
            let sa = key(a), sb = key(b)
            if sa != sb { return sa > sb }
            if a.imageAID != b.imageAID { return a.imageAID < b.imageAID }
            return a.imageBID < b.imageBID
        }
    }

    /// Burst near-duplicate gap (seconds). Two images shot within this window are
    /// treated as same-session frames of one scene rather than a meaningful pair.
    /// Matches the gap used by the ThematicV2 judge (`fetchCandidates`) so a pair the
    /// judge would reject never enters the four-pool topK either. See decisions #84, #94.
    static let kBurstGapSeconds: Double = 300

    /// True when a candidate pair is a burst near-duplicate that must never enter the
    /// four-pool topK: either two same-session frames (identical/near-identical
    /// `captureDate`) or filename export variants. This is the SELECTION-side guard the
    /// four-pool topK previously lacked — burst frames caption alike, so they reach the
    /// thematic pool (which selects on raw `thematicScore`, where the temporal penalty
    /// never applies) and surface as pairs. Distinct from dHash duplicate detection
    /// (#94, true duplicates): these are genuinely different frames that merely caption
    /// alike, so they aren't grouped/deactivated — they must be filtered here. The
    /// `FilenameVariants` arm mirrors the existing judge/role-candidate guards; crop/
    /// re-export duplicates themselves are handled upstream by #94 grouping. See #84.
    static func isBurstNearDuplicate(
        captureDateA: Double?, captureDateB: Double?,
        filenameA: String, filenameB: String
    ) -> Bool {
        if let da = captureDateA, let db = captureDateB,
           abs(da - db) <= kBurstGapSeconds { return true }
        if FilenameVariants.areVariants(filenameA, filenameB) { return true }
        return false
    }

    /// Writes the 512px thumbnail file for an image. Returns the thumbnail's filename when
    /// freshly written (so the caller can persist `thumbnailPath`), or nil when the file
    /// already existed or generation failed — matching the original early-return behaviour.
    /// Static and pure (no actor state, no DB) so it is safe to call concurrently. See #101.
    private static func writeThumbnailFile(imageID: Int64, sourceURL: URL, dir: URL) -> String? {
        let dest = dir.appendingPathComponent("\(imageID).jpg")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return nil }

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
        else { return nil }

        CGImageDestinationAddImage(
            destDest, thumb,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destDest) else { return nil }
        return dest.lastPathComponent
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
