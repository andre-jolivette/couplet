import Foundation
import Accelerate

public struct ScoringWeights: Sendable, Codable, Equatable {
    public var aesthetic: Float
    public var geometric: Float
    public var thematic: Float

    public static let `default` = ScoringWeights(aesthetic: 0.4, geometric: 0.2, thematic: 0.4)

    public init(aesthetic: Float, geometric: Float, thematic: Float) {
        self.aesthetic = aesthetic
        self.geometric = geometric
        self.thematic  = thematic
    }
}

public struct PairScore: Sendable {
    public let imageAID: Int64
    public let imageBID: Int64
    public let aestheticScore: Float
    public let aestheticSubmode: String
    public let geometricScore: Float
    /// Raw (pre-multiplier) edge cosine similarity. Stored per pair so display-time
    /// recomputation can apply the distinctiveness multiplier without a re-score.
    public let rawEdgeSim: Float
    /// Raw (pre-multiplier) composition grid cosine similarity.
    public let rawGridSim: Float
    /// max(edgePeakedness_A, edgePeakedness_B) — how strongly lined the more
    /// directional of the two images is. ~1.0 = flat/circular, 3–8+ = clear lines.
    public let maxEdgePeakedness: Float
    /// max(gridVariance_A, gridVariance_B) — tonal structure of the more
    /// compositionally distinct image. ~0 = flat, ~0.15+ = clear subject/bg split.
    public let maxGridVariance: Float
    /// √(normPeak_A × normPeak_B) — continuous edge distinctiveness multiplier.
    /// 1.0 = both images have strong directional lines; approaches 0 when both are flat.
    public let edgePeakednessMult: Float
    /// √(normVar_A × normVar_B) — continuous composition distinctiveness multiplier.
    /// 1.0 = both images have clear tonal structure; approaches 0 when both are uniform.
    public let gridVarianceMult: Float
    public let thematicScore: Float
    public let compositeScore: Float
    public let rationale: String
}

public enum PairScorer {

    public static func score(
        imageAID: Int64, vectorA: FeatureVector,
        imageBID: Int64, vectorB: FeatureVector,
        captureDateA: Double? = nil, captureDateB: Double? = nil,
        filenameA: String = "", filenameB: String = "",
        captionA: String = "", captionB: String = "",
        captionEmbeddingA: [Float]? = nil, captionEmbeddingB: [Float]? = nil,
        weights: ScoringWeights = .default
    ) -> PairScore {
        let (aID, bID, vA, vB): (Int64, Int64, FeatureVector, FeatureVector) =
            imageAID <= imageBID
                ? (imageAID, imageBID, vectorA, vectorB)
                : (imageBID, imageAID, vectorB, vectorA)

        // Thematic: caption embedding cosine (primary) + weighted Dice (secondary).
        //
        // When caption embeddings are available, the blend is:
        //   thematic = 0.65 × normEmbeddingSim + 0.35 × clusterScore
        // where normEmbeddingSim = max(0, (cosine - 0.50) / 0.50) — a floor
        // subtraction that removes the ~0.55 baseline all caption pairs share in
        // the nomic-embed-text embedding space. Calibrated against 7 real caption
        // pairs: grief-grief=0.732, protest-ritual=0.658, urban-urban=0.660,
        // grief-joy=0.568, grief-urban=0.551. After flooring at 0.50:
        //   grief-grief: norm=0.464 → 0.302 (passes boost)
        //   protest-ritual: norm=0.316 → 0.205 (passes boost — key zero-cluster case)
        //   grief-joy: norm=0.136 → 0.088 (does not pass boost)
        //   grief-urban: norm=0.102 → 0.066 (does not pass boost)
        // See decision #44 in DECISIONS.md for full calibration rationale.
        //
        // When embeddings are absent but captions are present, falls back to
        // cluster-only weighted Dice. When captions are absent, falls back to
        // CLIP image embedding cosine similarity.
        let thematic: Float
        let hasCaptions = !captionA.isEmpty && !captionB.isEmpty
        if hasCaptions {
            let clustersA = ConceptClusters.matchedClusters(for: captionA)
            let clustersB = ConceptClusters.matchedClusters(for: captionB)
            let shared = clustersA.intersection(clustersB)
            let onlyA = clustersA.subtracting(clustersB)
            let onlyB = clustersB.subtracting(clustersA)

            // Require asymmetry: each image must have at least one cluster
            // the other doesn't. Pure overlap = redundancy, not resonance.
            let hasAsymmetry = !onlyA.isEmpty && !onlyB.isEmpty

            // Saturation gate: weight-based rather than raw count.
            // With 29 clusters, genuine cross-context resonant pairs routinely
            // share 4–6 clusters across different emotional registers (bodily
            // gesture + isolation + tension + waiting). Raw count > 3 zeroed
            // these out. Weight-based threshold of > 5.0 distinguishes emotional
            // depth of overlap from count:
            //   • 4× tier-0.75 shared = 3.0  → not saturated (genuine resonance)
            //   • 5× tier-1.0 shared  = 5.0  → borderline (approaching same-event)
            //   • 8× mixed same-event = 8.0+ → saturated (two wedding shots)
            let weightedSharedSum = shared.reduce(0.0 as Float) { $0 + (ConceptClusters.weights[$1] ?? 0.5) }
            let saturated = weightedSharedSum > 5.0

            let clusterScore: Float
            if saturated || !hasAsymmetry {
                clusterScore = 0
            } else {
                // Weighted Dice via ConceptClusters — emotionally specific clusters
                // (weight 1.0) contribute more than ambient setting clusters (weight 0.2).
                // Meaningful-tier gate, asymmetry gate, and saturation gate all applied
                // above or inside weightedDice; formula lives in one place.
                clusterScore = ConceptClusters.weightedDice(clustersA: clustersA, clustersB: clustersB)
            }

            thematic = clusterScore
        } else {
            thematic = thematicScore(vA.clipEmbeddingFloats, vB.clipEmbeddingFloats)
        }

        let (aesthetic, submode) = aestheticScore(vA, vB)
        let geo = geometricScore(vA, vB)
        let geometric = geo.score

        var composite =
              weights.aesthetic * aesthetic
            + weights.geometric * geometric
            + weights.thematic  * thematic

        // Redundancy penalty: high thematic from CLIP embedding (no captions)
        // still means visually/semantically near-identical — penalise.
        if !hasCaptions && thematic > 0.80 {
            composite *= 0.45
        }

        // When captions produce a meaningful thematic score, boost thematic weight
        // so these pairs can compete with high-aesthetic/geometric pairs.
        if hasCaptions && thematic >= 0.20 {
            composite = 0.25 * aesthetic + 0.15 * geometric + 0.60 * thematic
        }

        // CLIP similarity ceiling: even without captions, very high CLIP
        // cosine similarity means visually/semantically near-identical images.
        let clipSim = thematicScore(vA.clipEmbeddingFloats, vB.clipEmbeddingFloats)
        if clipSim > 0.88 {
            composite *= 0.40
        } else if clipSim > 0.75 && thematic < 0.20 {
            // Secondary CLIP tier: same-subject discount (dogs/dogs, cars/cars).
            // Thematic guard avoids penalising visually-similar pairs that are genuinely
            // resonant (e.g. two protest photos sharing bodily_gesture + tension_conflict).
            composite *= 0.65
        }

        // Sequential penalty
        let isSequential: Bool = {
            guard let a = captureDateA, let b = captureDateB else { return false }
            return abs(a - b) <= 30
        }()

        // Soft temporal falloff for shots minutes apart (same scene, different moment)
        let temporalPenalty: Float = {
            guard let a = captureDateA, let b = captureDateB else { return 1.0 }
            let gap = abs(a - b)
            if gap <= 30   { return 0.40 }
            if gap <= 60   { return 0.55 }
            if gap <= 300  { return 0.85 }
            return 1.0
        }()

        // Filename-base duplicate check
        let sharesBaseName: Bool = {
            guard !filenameA.isEmpty, !filenameB.isEmpty else { return false }
            let baseA = filenameA.replacingOccurrences(of: #"-\d+(\.\w+)$"#,
                with: "$1", options: .regularExpression)
            let baseB = filenameB.replacingOccurrences(of: #"-\d+(\.\w+)$"#,
                with: "$1", options: .regularExpression)
            return baseA.lowercased() == baseB.lowercased()
        }()

        if sharesBaseName    { composite = 0 }
        else if isSequential { composite *= 0.40 }
        else                 { composite *= temporalPenalty }

        let rationaleText: String
        if isSequential {
            rationaleText = "Sequential shots — captured within seconds of each other."
        } else if hasCaptions && thematic >= 0.20 {
            let cA = ConceptClusters.matchedClusters(for: captionA)
            let cB = ConceptClusters.matchedClusters(for: captionB)
            let shared = cA.intersection(cB)
            if let theme = shared.first {
                let readable = theme.replacingOccurrences(of: "_", with: " ")
                rationaleText = "Thematic resonance — both images share a sense of \(readable)."
            } else {
                rationaleText = "Conceptual contrast — subjects from different worlds, connected by emotional register."
            }
        } else {
            rationaleText = rationale(aesthetic: aesthetic, submode: submode,
                                      geometric: geometric, thematic: thematic)
        }

        return PairScore(
            imageAID: aID, imageBID: bID,
            aestheticScore: aesthetic, aestheticSubmode: submode,
            geometricScore: geometric,
            rawEdgeSim: geo.rawEdgeSim,
            rawGridSim: geo.rawGridSim,
            maxEdgePeakedness: geo.maxEdgePeakedness,
            maxGridVariance: geo.maxGridVariance,
            edgePeakednessMult: geo.edgePeakednessMult,
            gridVarianceMult: geo.gridVarianceMult,
            thematicScore: thematic,
            compositeScore: composite,
            rationale: rationaleText
        )
    }

    // MARK: - Caption-based thematic scoring

    /// Word overlap between two captions, ignoring short stop-words.
    /// Returns 0–1 where 1 = identical vocabulary, 0 = no shared words.
    /// A score of 0.3–0.6 suggests related-but-distinct scenes (good pairs).
    /// A score > 0.80 suggests redundancy (penalised in composite).
    static func captionWordOverlap(_ a: String, _ b: String) -> Float {
        let stopWords: Set<String> = ["the","a","an","is","are","in","on","at",
                                       "and","or","of","to","with","by","for",
                                       "their","his","her","they","he","she","it",
                                       "this","that","there","has","have","from"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 3 && !stopWords.contains($0) })
        }
        let wA = words(a), wB = words(b)
        guard !wA.isEmpty, !wB.isEmpty else { return 0 }
        let intersection = Float(wA.intersection(wB).count)
        let union = Float(wA.union(wB).count)
        return union > 0 ? intersection / union : 0
    }

    static func captionRationale(
        _ captionA: String, _ captionB: String,
        aesthetic: Float, submode: String, geometric: Float, thematic: Float
    ) -> String {
        let cA = ConceptClusters.matchedClusters(for: captionA)
        let cB = ConceptClusters.matchedClusters(for: captionB)
        let shared = cA.intersection(cB)

        if !shared.isEmpty {
            let theme = shared.first!.replacingOccurrences(of: "_", with: " ")
            return "Thematic resonance — both images share a sense of \(theme)."
        } else if thematic < 0.15 {
            return "Conceptual contrast — the subjects inhabit different worlds but share a visual or emotional register."
        } else {
            return rationale(aesthetic: aesthetic, submode: submode,
                             geometric: geometric, thematic: thematic)
        }
    }

    // MARK: - Original CLIP-based thematic score (fallback when no captions)

    static func thematicScore(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return (dot + 1) / 2
    }

    /// Raw cosine similarity between two caption embedding vectors, clamped to [0, 1].
    /// nomic-embed-text produces L2-normalised vectors so cosine = dot product,
    /// but we compute it defensively. Unlike CLIP image embeddings (which range [-1, 1]
    /// and need the (dot+1)/2 shift), text embeddings are always positive-valued.
    static func captionEmbeddingCosineSim(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 0 }
        return max(0, min(1, dot / denom))
    }

    static func aestheticScore(_ vA: FeatureVector, _ vB: FeatureVector) -> (Float, String) {
        let harmony  = histogramIntersection(vA.hslHistogramFloats, vB.hslHistogramFloats)
        let contrast = paletteContrastScore(vA.dominantPaletteFloats, vB.dominantPaletteFloats)
        return harmony >= contrast ? (harmony, "harmony") : (contrast, "contrast")
    }

    static func histogramIntersection(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        for i in 0..<a.count { result += min(a[i], b[i]) }
        return result
    }

    static func paletteContrastScore(_ palA: [Float], _ palB: [Float]) -> Float {
        guard palA.count == 18, palB.count == 18 else { return 0 }
        var total: Float = 0
        var count = 0
        for i in stride(from: 0, to: 18, by: 3) {
            for j in stride(from: 0, to: 18, by: 3) {
                let dL = palA[i]   - palB[j]
                let da = palA[i+1] - palB[j+1]
                let db = palA[i+2] - palB[j+2]
                total += sqrt(dL*dL + da*da + db*db)
                count += 1
            }
        }
        return count > 0 ? min(total / Float(count) / 80, 1) : 0
    }

    // MARK: - Geometric scoring

    // Normalization anchors for the distinctiveness multiplier.
    // Calibrated against library debug output: edgePeakedness p90≈4.0, gridVariance p90≈0.20.
    // An image at or above the anchor scores 1.0; below it scales proportionally toward 0.
    private static let kEdgePeakedNorm: Float  = 4.0
    private static let kGridVarianceNorm: Float = 0.20

    static func geometricScore(
        _ vA: FeatureVector, _ vB: FeatureVector
    ) -> (score: Float, rawEdgeSim: Float, rawGridSim: Float,
          maxEdgePeakedness: Float, maxGridVariance: Float,
          edgePeakednessMult: Float, gridVarianceMult: Float) {

        let rawEdge = cosineSimilarity01(vA.edgeOrientationFloats, vB.edgeOrientationFloats)
        let rawGrid = cosineSimilarity01(vA.compositionGridFloats, vB.compositionGridFloats)

        // Edge peakedness: max(hist) / mean(hist). Since the histogram is L1-normalised,
        // mean = 1/32 exactly, so max/mean = max * 32. ~1.0 = flat/circular, 3–8+ = clear lines.
        let peakA = (vA.edgeOrientationFloats.max() ?? 0) * 32
        let peakB = (vB.edgeOrientationFloats.max() ?? 0) * 32

        // Grid variance: stddev of the 16 brightness cells (first half of the 32-float grid).
        let varA = gridVariance(vA.compositionGridFloats)
        let varB = gridVariance(vB.compositionGridFloats)

        // Continuous distinctiveness multipliers: √(norm_A × norm_B).
        // Both images must be geometrically interesting for the pair to earn full credit.
        // A flat/circular image alongside a strongly-lined image yields ~√(0 × 1) = 0 — penalised.
        // Two strongly-lined images yield ~√(1 × 1) = 1 — full credit.
        let normPeakA  = min(peakA / kEdgePeakedNorm,  1.0)
        let normPeakB  = min(peakB / kEdgePeakedNorm,  1.0)
        let normVarA   = min(varA  / kGridVarianceNorm, 1.0)
        let normVarB   = min(varB  / kGridVarianceNorm, 1.0)
        // Distinctiveness exponent: 0.5 = sqrt (stronger), lower = gentler curve.
        // Increment in 0.1 steps toward 0.0 (disabled) to find the right balance.
        // Current: 0.4 — one step gentler than the sqrt default.
        let kDistinctivenessExponent: Float = 0.4
        let edgeMult   = pow(normPeakA * normPeakB, kDistinctivenessExponent)
        let varMult    = pow(normVarA  * normVarB,  kDistinctivenessExponent)

        return (
            score:              (rawEdge * edgeMult + rawGrid * varMult) / 2,
            rawEdgeSim:         rawEdge,
            rawGridSim:         rawGrid,
            maxEdgePeakedness:  max(peakA, peakB),
            maxGridVariance:    max(varA, varB),
            edgePeakednessMult: edgeMult,
            gridVarianceMult:   varMult
        )
    }

    private static func gridVariance(_ grid: [Float]) -> Float {
        guard grid.count >= 16 else { return 0 }
        let b = grid[0..<16]
        let mean = b.reduce(0, +) / 16
        let variance = b.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 16
        return variance.squareRoot()
    }

    static func cosineSimilarity01(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 0 }
        return max(0, min(1, (dot / denom + 1) / 2))
    }

    static func rationale(
        aesthetic: Float, submode: String,
        geometric: Float, thematic: Float
    ) -> String {
        let maxScore = max(aesthetic, geometric, thematic)
        switch maxScore {
        case thematic where thematic >= 0.75:
            return "Strong semantic similarity — images share closely related subject matter."
        case thematic:
            return "Thematic connection — images share a conceptual or contextual relationship."
        case aesthetic where submode == "harmony":
            return "Tonal harmony — images share a similar colour register and mood."
        case aesthetic:
            return "Colour contrast — images form a complementary colour relationship."
        default:
            return "Compositional echo — images share similar structural lines or visual weight."
        }
    }
}
