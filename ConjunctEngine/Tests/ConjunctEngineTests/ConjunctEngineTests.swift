import XCTest
import CoreGraphics
@testable import ConjunctEngine

// ── FileScannerTests ──────────────────────────────────────────────────────────

final class FileScannerTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testScansJPEGFiles() async throws {
        let files = ["a.jpg", "b.jpeg", "c.JPG"]
        for name in files {
            FileManager.default.createFile(
                atPath: tempDir.appendingPathComponent(name).path,
                contents: Data([0xFF, 0xD8, 0xFF])
            )
        }
        let scanner = FileScanner()
        let results = try await scanner.scan(directory: tempDir)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.fileFormat == "JPEG" })
    }

    func testIgnoresUnsupportedFormats() async throws {
        let files = ["photo.jpg", "document.pdf", "video.mov", "raw.cr2"]
        for name in files {
            FileManager.default.createFile(
                atPath: tempDir.appendingPathComponent(name).path,
                contents: Data([0x00])
            )
        }
        let scanner = FileScanner()
        let results = try await scanner.scan(directory: tempDir)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.filename, "photo.jpg")
    }

    func testRespectsExclusionPatterns() async throws {
        let exportDir = tempDir.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: exportDir.appendingPathComponent("web.jpg").path,
            contents: Data([0xFF, 0xD8, 0xFF])
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("keep.jpg").path,
            contents: Data([0xFF, 0xD8, 0xFF])
        )
        let scanner = FileScanner(exclusionPatterns: ["exports"])
        let results = try await scanner.scan(directory: tempDir)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.filename, "keep.jpg")
    }

    func testContentHashStableForUnchangedFile() async throws {
        let fileURL = tempDir.appendingPathComponent("test.jpg")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data([0xFF, 0xD8, 0xFF]))
        let scanner = FileScanner()
        let first  = try await scanner.scan(directory: tempDir)
        let second = try await scanner.scan(directory: tempDir)
        XCTAssertEqual(first.first?.contentHash, second.first?.contentHash)
    }
}

// ── FilenameVariantsTests ─────────────────────────────────────────────────────

final class FilenameVariantsTests: XCTestCase {

    func testPrefixCopyOfDatePrefixedOriginal() {
        // The regression that motivated decision #94: the original itself starts
        // with digits, so stripping `^\d+-` from both sides never matched.
        XCTAssertTrue(FilenameVariants.areVariants("00-20250504-_R017085.jpg", "20250504-_R017085.jpg"))
        XCTAssertTrue(FilenameVariants.areVariants("20250507-_DSF0572.jpg", "63-20250507-_DSF0572.jpg"))
    }

    func testPrefixCopyOfPlainOriginal() {
        XCTAssertTrue(FilenameVariants.areVariants("63-foo.jpg", "foo.jpg"))
    }

    func testTwoPrefixedCopies() {
        XCTAssertTrue(FilenameVariants.areVariants("00-20241221-_DSF4186.jpg", "29-20241221-_DSF4186.jpg"))
    }

    func testTrailingSuffixVariant() {
        XCTAssertTrue(FilenameVariants.areVariants("20250315-_DSF9076.jpg", "20250315-_DSF9076-2.jpg"))
    }

    func testDifferentShotsAreNotVariants() {
        // Adjacent burst frames — distinct trailing frame numbers are part of the
        // camera base name, not an export suffix... except when one parses as a
        // "-N" suffix; the captureDate gate in detectDuplicates covers that case.
        XCTAssertFalse(FilenameVariants.areVariants("20250515-_DSF2488.jpg", "20250515-_DSF2489.jpg"))
        XCTAssertFalse(FilenameVariants.areVariants("46-20250326-_DSF3715.jpg", "20250326-_DSF3713.jpg"))
    }

    func testIdenticalNamesAreNotVariants() {
        XCTAssertFalse(FilenameVariants.areVariants("foo.jpg", "foo.jpg"))
    }

    func testEmptyNamesAreNotVariants() {
        XCTAssertFalse(FilenameVariants.areVariants("", "foo.jpg"))
        XCTAssertFalse(FilenameVariants.areVariants("", ""))
    }
}

// ── BurstNearDuplicateGuardTests ──────────────────────────────────────────────
// Selection-side burst guard for the four-pool topK (decision #84). These are
// genuinely different frames that caption alike — distinct from dHash duplicates
// (#94) — so they must be filtered out of pool selection by captureDate gap.
final class BurstNearDuplicateGuardTests: XCTestCase {
    private func isBurst(_ a: Double?, _ b: Double?,
                         _ fa: String = "a.jpg", _ fb: String = "b.jpg") -> Bool {
        IndexingEngine.isBurstNearDuplicate(
            captureDateA: a, captureDateB: b, filenameA: fa, filenameB: fb
        )
    }

    func testSameSecondFramesAreBurst() {
        XCTAssertTrue(isBurst(1_700_000_000, 1_700_000_000))
    }

    func testWithinGapIsBurst() {
        // Inclusive boundary at kBurstGapSeconds, and clearly inside it.
        XCTAssertTrue(isBurst(1_700_000_000, 1_700_000_000 + 30))
        XCTAssertTrue(isBurst(1_700_000_000, 1_700_000_000 + IndexingEngine.kBurstGapSeconds))
    }

    func testJustOutsideGapIsNotBurst() {
        XCTAssertFalse(isBurst(1_700_000_000, 1_700_000_000 + IndexingEngine.kBurstGapSeconds + 1))
    }

    func testMinutesApartIsNotBurst() {
        // 5min-1hr band — same event but a meaningful gap; must survive.
        XCTAssertFalse(isBurst(1_700_000_000, 1_700_000_000 + 3600))
    }

    func testNilCaptureDatesFallBackToFilenameOnly() {
        // No date signal → only filename-variant arm can fire.
        XCTAssertFalse(isBurst(nil, 1_700_000_000))
        XCTAssertFalse(isBurst(nil, nil))
        XCTAssertTrue(isBurst(nil, nil, "00-20250504-_R017085.jpg", "20250504-_R017085.jpg"))
    }

    func testFilenameVariantArmFiresIndependentOfDate() {
        // Export variant far apart in time is still caught (mirrors #94/judge guards).
        XCTAssertTrue(isBurst(1_700_000_000, 1_700_099_999,
                              "63-20250507-_DSF0572.jpg", "20250507-_DSF0572.jpg"))
    }
}

// ── PairScorerTests ───────────────────────────────────────────────────────────

final class PairScorerTests: XCTestCase {

    func testCanonicalOrdering() {
        let vA = makeFeatureVector(imageID: 99)
        let vB = makeFeatureVector(imageID: 12)
        let score = PairScorer.score(imageAID: 99, vectorA: vA, imageBID: 12, vectorB: vB)
        XCTAssertEqual(score.imageAID, 12)
        XCTAssertEqual(score.imageBID, 99)
    }

    // Identical images max the thematic axis (CLIP cosine ≈ 1.0), but the composite
    // is deliberately suppressed: the redundancy penalty (×0.45 when high thematic
    // comes from CLIP with no captions) and the CLIP-similarity ceiling (×0.40 above
    // 0.88) drive near-duplicates down so they don't dominate the grid. So thematic
    // is high while composite is heavily discounted relative to it.
    func testIdenticalImagesScoreHighThematicLowComposite() {
        let v = makeFeatureVector(imageID: 1)
        let score = PairScorer.score(imageAID: 1, vectorA: v, imageBID: 2, vectorB: v)
        XCTAssertGreaterThan(score.thematicScore, 0.95)
        XCTAssertLessThan(score.compositeScore, 0.3,
            "Near-duplicate composite is suppressed by the redundancy + CLIP-ceiling penalties")
        XCTAssertLessThan(score.compositeScore, score.thematicScore)
    }

    func testOrthogonalEmbeddingsScoreMidpoint() {
        var embA = [Float](repeating: 0, count: 512)
        var embB = [Float](repeating: 0, count: 512)
        embA[0] = 1.0
        embB[1] = 1.0
        let vA = makeFeatureVector(imageID: 1, embedding: embA)
        let vB = makeFeatureVector(imageID: 2, embedding: embB)
        let score = PairScorer.score(imageAID: 1, vectorA: vA, imageBID: 2, vectorB: vB)
        XCTAssertEqual(score.thematicScore, 0.5, accuracy: 0.01)
    }

    // A single-axis weight should route the composite to exactly that axis' score.
    // Uses distinct (orthogonal) embeddings so the pair is NOT a near-duplicate —
    // identical vectors trip the redundancy + CLIP-ceiling penalties (see
    // testIdenticalImagesScoreHighThematicLowComposite), which would mask the routing.
    // Orthogonal embeddings give CLIP cosine 0.5 (thematic 0.5), below every penalty
    // threshold, so composite == the single weighted axis with no discount.
    func testWeightsAffectComposite() {
        var embA = [Float](repeating: 0, count: 512)
        var embB = [Float](repeating: 0, count: 512)
        embA[0] = 1.0
        embB[1] = 1.0
        let vA = makeFeatureVector(imageID: 1, embedding: embA)
        let vB = makeFeatureVector(imageID: 2, embedding: embB)
        let allThematic  = ScoringWeights(aesthetic: 0.0, geometric: 0.0, thematic: 1.0)
        let allAesthetic = ScoringWeights(aesthetic: 1.0, geometric: 0.0, thematic: 0.0)
        let sT = PairScorer.score(imageAID: 1, vectorA: vA, imageBID: 2, vectorB: vB, weights: allThematic)
        let sA = PairScorer.score(imageAID: 1, vectorA: vA, imageBID: 2, vectorB: vB, weights: allAesthetic)
        XCTAssertEqual(sT.compositeScore, sT.thematicScore,  accuracy: 0.01)
        XCTAssertEqual(sA.compositeScore, sA.aestheticScore, accuracy: 0.01)
    }

    func testRationaleMaxLength() {
        let v = makeFeatureVector(imageID: 1)
        let score = PairScorer.score(imageAID: 1, vectorA: v, imageBID: 2, vectorB: v)
        XCTAssertLessThanOrEqual(score.rationale.count, 120)
    }

    private func makeFeatureVector(imageID: Int64, embedding: [Float]? = nil) -> FeatureVector {
        let raw: [Float]
        if let e = embedding {
            raw = e
        } else {
            raw = (0..<512).map { Float($0) * 0.001 + 0.3 }
        }
        let norm = sqrt(raw.map { $0 * $0 }.reduce(0, +))
        let normEmb = norm > 0 ? raw.map { $0 / norm } : raw
        return FeatureVector(
            imageID: imageID,
            clipEmbedding: normEmb,
            hslHistogram: [Float](repeating: 1.0 / 1152, count: 1152),
            dominantPalette: [Float](repeating: 50, count: 18),
            edgeOrientation: [Float](repeating: 1.0 / 32, count: 32),
            compositionGrid: [Float](repeating: 0.5, count: 32)
        )
    }
}

// ── ColourAnalyserTests ───────────────────────────────────────────────────────

final class ColourAnalyserTests: XCTestCase {

    func testHSLHistogramSumsToOne() throws {
        let image = makeRedImage(size: 64)
        let features = try ColourAnalyser.analyse(image: image)
        let sum = features.hslHistogram.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testHSLHistogramLength() throws {
        let image = makeRedImage(size: 64)
        let features = try ColourAnalyser.analyse(image: image)
        XCTAssertEqual(features.hslHistogram.count, 1152)
    }

    func testDominantPaletteLength() throws {
        let image = makeRedImage(size: 64)
        let features = try ColourAnalyser.analyse(image: image)
        XCTAssertEqual(features.dominantPalette.count, 18)
    }

    func testSameImageProducesIdenticalHistogram() throws {
        let image = makeRedImage(size: 64)
        let a = try ColourAnalyser.analyse(image: image)
        let b = try ColourAnalyser.analyse(image: image)
        XCTAssertEqual(a.hslHistogram, b.hslHistogram)
    }

    private func makeRedImage(size: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }
}

// ── GeometricAnalyserTests ────────────────────────────────────────────────────

final class GeometricAnalyserTests: XCTestCase {

    func testEdgeOrientationLength() throws {
        let image = makeGradientImage(size: 128)
        let features = try GeometricAnalyser.analyse(image: image)
        XCTAssertEqual(features.edgeOrientation.count, 32)
    }

    func testCompositionGridLength() throws {
        let image = makeGradientImage(size: 128)
        let features = try GeometricAnalyser.analyse(image: image)
        XCTAssertEqual(features.compositionGrid.count, 32)
    }

    func testSameImageProducesIdenticalGeometry() throws {
        let image = makeGradientImage(size: 128)
        let a = try GeometricAnalyser.analyse(image: image)
        let b = try GeometricAnalyser.analyse(image: image)
        XCTAssertEqual(a.edgeOrientation, b.edgeOrientation)
        XCTAssertEqual(a.compositionGrid, b.compositionGrid)
    }

    private func makeGradientImage(size: Int) -> CGImage {
        var raw = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let v = UInt8(255 * x / size)
                let i = (y * size + x) * 4
                raw[i] = v; raw[i+1] = v; raw[i+2] = v; raw[i+3] = 255
            }
        }
        let ctx = CGContext(
            data: &raw, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return ctx.makeImage()!
    }
}

// ── MockCLIPEngineTests ───────────────────────────────────────────────────────

final class MockCLIPEngineTests: XCTestCase {

    func testEmbeddingLength() async throws {
        let engine = MockCLIPEngine(simulatedLatencyMs: 0)
        let image = CGImage.solidColour(width: 224, height: 224, red: 0.5, green: 0.5, blue: 0.5)
        let output = try await engine.embed(image: image)
        XCTAssertEqual(output.embedding.count, 512)
    }

    func testEmbeddingIsUnitNormed() async throws {
        let engine = MockCLIPEngine(simulatedLatencyMs: 0)
        let image = CGImage.solidColour(width: 224, height: 224, red: 0.2, green: 0.6, blue: 0.9)
        let output = try await engine.embed(image: image)
        let norm = sqrt(output.embedding.map { $0 * $0 }.reduce(0, +))
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testDeterminism() async throws {
        let engine = MockCLIPEngine(simulatedLatencyMs: 0)
        let image = CGImage.solidColour(width: 224, height: 224, red: 0.5, green: 0.5, blue: 0.5)
        let a = try await engine.embed(image: image)
        let b = try await engine.embed(image: image)
        XCTAssertEqual(a.embedding, b.embedding)
    }
}

// ── ConceptClustersTests ──────────────────────────────────────────────────────

final class ConceptClustersTests: XCTestCase {

    // Every cluster in `all` must have a weight entry — no silent fallback to 0.5.
    func testAllClustersHaveWeights() {
        for cluster in ConceptClusters.all {
            XCTAssertNotNil(
                ConceptClusters.weights[cluster.name],
                "Missing weight for cluster: \(cluster.name)"
            )
        }
        XCTAssertEqual(
            ConceptClusters.weights.count,
            ConceptClusters.all.count,
            "weights dict count does not match all-clusters count"
        )
    }

    // Spot-check one cluster from each tier to catch accidental value changes.
    func testTierAssignments() {
        // Tier 1.0 — emotional / high-specificity
        XCTAssertEqual(ConceptClusters.weights["grief_sorrow"],           1.0)
        XCTAssertEqual(ConceptClusters.weights["vulnerability_exposure"], 1.0)
        XCTAssertEqual(ConceptClusters.weights["sensory_overwhelm"],      1.0)
        XCTAssertEqual(ConceptClusters.weights["power_dominance"],        1.0)
        XCTAssertEqual(ConceptClusters.weights["tenderness_care"],        1.0)
        // Tier 0.75 — meaningful but moderate-frequency
        XCTAssertEqual(ConceptClusters.weights["skilled_performance"],    0.75)
        XCTAssertEqual(ConceptClusters.weights["bodily_gesture"],         0.75)
        XCTAssertEqual(ConceptClusters.weights["sound_music"],            0.75)
        XCTAssertEqual(ConceptClusters.weights["joy_celebration"],        0.75)
        // Tier 0.2 — ambient setting / context (demoted from 0.5; see decision #47)
        XCTAssertEqual(ConceptClusters.weights["urban_street"],           0.2)
        XCTAssertEqual(ConceptClusters.weights["nature_landscape"],       0.2)
        XCTAssertEqual(ConceptClusters.weights["community_gathering"],    0.2)
    }

    // Verify that the test captions fire exactly the clusters we expect
    // before relying on them in the scoring test below.
    func testClusterMembershipForScoringTestCaptions() {
        XCTAssertEqual(
            ConceptClusters.matchedClusters(for: "the crowd stood in grief"),
            ["community_gathering", "grief_sorrow"]
        )
        XCTAssertEqual(
            ConceptClusters.matchedClusters(for: "grief on the street corner"),
            ["grief_sorrow", "urban_street"]
        )
        XCTAssertEqual(
            ConceptClusters.matchedClusters(for: "a busy street with a crowd"),
            ["urban_street", "community_gathering"]
        )
        XCTAssertEqual(
            ConceptClusters.matchedClusters(for: "the street under clear sky"),
            ["urban_street", "nature_landscape"]
        )
    }

    // Core behavioural proof: a pair sharing a tier-1.0 cluster (grief_sorrow)
    // should score higher than one sharing only an ambient-tier cluster
    // (urban_street, w=0.2), even when both pairs have the same cluster-set sizes.
    //
    // Without weighting, both would score identically (Dice = 2×1/(2+2) = 0.5).
    //
    // With weighting (ambient clusters at 0.2, see decision #47):
    //   Pair A — shared grief_sorrow(w=1.0), unshared community_gathering(0.2)
    //            and urban_street(0.2): 2×1.0 / (1.2+1.2) = 0.833
    //   Pair B — shared cluster is urban_street only (ambient, w=0.2). The
    //            meaningful-tier gate in weightedDice requires a shared cluster of
    //            weight ≥ 0.75; with none, it returns kAmbientFloor = 0.1.
    func testEmotionalPairOutscoresAmbientPair() {
        // Pair A: shared cluster is grief_sorrow (weight 1.0)
        let scoreA = ConceptClusters.thematicScore(
            captionA: "the crowd stood in grief",   // → {community_gathering, grief_sorrow}
            captionB: "grief on the street corner"  // → {grief_sorrow, urban_street}
        )
        // Pair B: shared cluster is urban_street (weight 0.5)
        let scoreB = ConceptClusters.thematicScore(
            captionA: "a busy street with a crowd", // → {urban_street, community_gathering}
            captionB: "the street under clear sky"  // → {urban_street, nature_landscape}
        )

        XCTAssertGreaterThan(scoreA, scoreB,
            "Pair sharing grief_sorrow (w=1.0) should outscore pair sharing ambient urban_street (w=0.2)")
        XCTAssertEqual(Double(scoreA), 2.0/2.4, accuracy: 0.001,
            "Weighted Dice: 2×1.0 / (1.2+1.2) = 0.833")
        XCTAssertEqual(Double(scoreB), 0.1, accuracy: 0.001,
            "Ambient-only shared cluster → meaningful-tier gate fails → kAmbientFloor = 0.1")
    }
}

// ── DatabaseTests ─────────────────────────────────────────────────────────────

final class DatabaseTests: XCTestCase {

    func testSchemaCreation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try DatabaseManager(url: url)
        let tables = try db.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        let expected = ["collectionPairs", "collections", "featureVectors",
                        "folders", "images", "pairs", "userDecisions"]
        for table in expected {
            XCTAssertTrue(tables.contains(table), "Missing table: \(table)")
        }
    }

    // PairRecord no longer reorders IDs: PairScorer.score() owns canonical ordering,
    // and gaze_conversation pairs intentionally store the rightward-gazer as imageAID
    // regardless of numeric order (decision #71). PairRecord must persist exactly what
    // the scorer hands it — inserting (20, 10) stores (20, 10), not (10, 20).
    func testPairStoresIDsAsGiven() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try DatabaseManager(url: url)

        try db.write { db in
            try db.execute(
                sql: "INSERT INTO folders (id, path, isActive) VALUES (1, '/test', 1)"
            )
            try db.execute(
                sql: "INSERT INTO images (id, path, contentHash, filename, folderID, fileFormat, isActive, indexedAt) VALUES (10, '/test/a.jpg', 'h1', 'a.jpg', 1, 'JPEG', 1, 0)"
            )
            try db.execute(
                sql: "INSERT INTO images (id, path, contentHash, filename, folderID, fileFormat, isActive, indexedAt) VALUES (20, '/test/b.jpg', 'h2', 'b.jpg', 1, 'JPEG', 1, 0)"
            )
        }

        try db.write { db in
            var pair = PairRecord(
                imageAID: 20, imageBID: 10,
                aestheticScore: 0.8, aestheticSubmode: "harmony",
                geometricScore: 0.5, thematicScore: 0.7,
                compositeScore: 0.72, rationale: "Test pair"
            )
            try pair.insert(db)
        }

        let stored = try db.read { db in
            try PairRecord.fetchOne(db, sql: "SELECT * FROM pairs LIMIT 1")
        }
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored!.imageAID, 20)
        XCTAssertEqual(stored!.imageBID, 10)
    }
}
