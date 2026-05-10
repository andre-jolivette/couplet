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
        accentHueA: Double? = nil, accentSaturationA: Double? = nil,
        accentHueB: Double? = nil, accentSaturationB: Double? = nil,
        weights: ScoringWeights = .default
    ) -> PairScore {
        let (aID, bID, vA, vB): (Int64, Int64, FeatureVector, FeatureVector) =
            imageAID <= imageBID
                ? (imageAID, imageBID, vectorA, vectorB)
                : (imageBID, imageAID, vectorB, vectorA)

        // CLIP cosine — computed once, used for both thematic diversity multiplier
        // and composite ceiling penalties below.
        let clipSim = thematicScore(vA.clipEmbeddingFloats, vB.clipEmbeddingFloats)

        // Thematic: weighted Dice on ConceptClusters matched from qwen captions,
        // scaled by a visual diversity multiplier. When captions are absent, falls
        // back to CLIP image cosine.
        //
        // Visual diversity multiplier rationale:
        //   Cross-context resonance = images that look different but share a theme.
        //   Same-event pairs (protest+protest, festival+festival) look similar AND
        //   share many clusters → they dominate the thematic topK without this correction.
        //   The multiplier rewards low-CLIP pairs (cross-context) and penalises
        //   high-CLIP pairs (same-context) on the thematic axis, independently of
        //   the existing composite ceiling penalties.
        //
        //   CLIP < 0.30  → ×1.35  (visually distinct → cross-context bonus)
        //   CLIP 0.30–0.60 → ×1.00 (neutral — typical street pair)
        //   CLIP 0.60–0.88 → ×0.75 (visually similar → same-context penalty)
        //   CLIP > 0.88  → handled by composite ceiling below; no double-penalty here
        let diversityMult: Float
        if clipSim < 0.30      { diversityMult = 1.35 }
        else if clipSim < 0.60 { diversityMult = 1.00 }
        else if clipSim < 0.88 { diversityMult = 0.75 }
        else                   { diversityMult = 1.00 }  // ceiling handles composite

        let thematic: Float
        let hasCaptions = !captionA.isEmpty && !captionB.isEmpty
        if hasCaptions {
            let clustersA = ConceptClusters.matchedClusters(for: captionA)
            let clustersB = ConceptClusters.matchedClusters(for: captionB)
            let shared = clustersA.intersection(clustersB)
            let onlyA = clustersA.subtracting(clustersB)
            let onlyB = clustersB.subtracting(clustersA)

            // Require MEANINGFUL asymmetry: each image must have at least one
            // non-ambient cluster (weight ≥ 0.75) that the other doesn't share.
            // Ambient-only asymmetry (urban_street vs. community_gathering) is
            // trivially satisfied by any two different street photos and does not
            // signal genuine thematic difference. Dog+dog pairs pass the old gate
            // because they differ by ambient clusters while sharing all meaningful ones.
            let meaningfulOnlyA = onlyA.filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
            let meaningfulOnlyB = onlyB.filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
            let hasAsymmetry = !meaningfulOnlyA.isEmpty && !meaningfulOnlyB.isEmpty

            // Saturation gate: weight-based rather than raw count.
            let weightedSharedSum = shared.reduce(0.0 as Float) { $0 + (ConceptClusters.weights[$1] ?? 0.5) }
            let saturated = weightedSharedSum > 5.0

            let clusterScore: Float
            if saturated || !hasAsymmetry {
                clusterScore = 0
            } else {
                clusterScore = ConceptClusters.weightedDice(clustersA: clustersA, clustersB: clustersB)
            }

            // Complementary axis bonus: rescues pairs that have NO meaningful shared cluster
            // (Dice at ambient floor 0.10) but are on opposite ends of the same phenomenon.
            // Intentionally does NOT add to pairs that already score via Dice — those don't
            // need rescuing, and adding to them inflates scores past 1.0 when combined with
            // the diversity multiplier.
            let axisBonus: Float
            if saturated || clusterScore > 0.10 {
                axisBonus = 0
            } else {
                axisBonus = ConceptClusters.axisPairs.reduce(0.0) { best, axis in
                    let fires = (clustersA.contains(axis.a) && clustersB.contains(axis.b))
                             || (clustersA.contains(axis.b) && clustersB.contains(axis.a))
                    return fires ? max(best, axis.bonus) : best
                }
            }

            thematic = min(1.0, (clusterScore + axisBonus) * diversityMult)
        } else {
            thematic = thematicScore(vA.clipEmbeddingFloats, vB.clipEmbeddingFloats)
        }

        let (aesthetic, submode) = aestheticScore(vA, vB,
                                                   accentHueA: accentHueA, accentSaturationA: accentSaturationA,
                                                   accentHueB: accentHueB, accentSaturationB: accentSaturationB)
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

        // CLIP similarity ceiling: very high CLIP cosine = visually near-identical.
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
            let meaningfulShared = shared.filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
            if let theme = meaningfulShared.first {
                let readable = theme.replacingOccurrences(of: "_", with: " ")
                rationaleText = "Thematic resonance — both images share a sense of \(readable)."
            } else if let axis = ConceptClusters.axisPairs.first(where: { axis in
                (cA.contains(axis.a) && cB.contains(axis.b)) || (cA.contains(axis.b) && cB.contains(axis.a))
            }) {
                let aName = axis.a.replacingOccurrences(of: "_", with: " ")
                let bName = axis.b.replacingOccurrences(of: "_", with: " ")
                rationaleText = "Complementary resonance — \(aName) meets \(bName)."
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

    static func aestheticScore(
        _ vA: FeatureVector, _ vB: FeatureVector,
        accentHueA: Double? = nil, accentSaturationA: Double? = nil,
        accentHueB: Double? = nil, accentSaturationB: Double? = nil
    ) -> (Float, String) {
        let harmony  = histogramIntersection(vA.hslHistogramFloats, vB.hslHistogramFloats)
        let contrast = paletteContrastScore(vA.dominantPaletteFloats, vB.dominantPaletteFloats)
        let echo     = accentEchoScore(accentHueA: accentHueA, accentSaturationA: accentSaturationA,
                                       accentHueB: accentHueB, accentSaturationB: accentSaturationB)
        if echo > harmony && echo > contrast { return (echo, "accent_echo") }
        return harmony >= contrast ? (harmony, "harmony") : (contrast, "contrast")
    }

    // Accent color echo: rewards pairs sharing a specific accent hue
    // (Mode 2 slant rhyme, PAIRING_THEORY.md §Component 2).
    //
    // Score: hueScore × √(satA × satB)
    //   • hueScore ramp: ≤10° → 1.0, ≤30° → linear 1.0→0.0, >30° → 0.0
    //   • Geometric mean saturation scales the score — pairs where both images
    //     carry vivid accents score higher than pairs where one accent is dull.
    //   • No hard saturation gate or hue-range exclusions: ambient color detection
    //     (foliage green vs billboard green, sky blue vs painted blue) requires
    //     scene context that isn't available at score time — backlog item.
    static func accentEchoScore(
        accentHueA: Double?, accentSaturationA: Double?,
        accentHueB: Double?, accentSaturationB: Double?
    ) -> Float {
        guard let hA = accentHueA.map(Float.init),
              let hB = accentHueB.map(Float.init),
              let sA = accentSaturationA.map(Float.init),
              let sB = accentSaturationB.map(Float.init) else { return 0 }

        // Circular hue distance
        let diff = abs(hA - hB)
        let angularDist = min(diff, 360 - diff)

        // Hue score ramp: tight window rewards close matches, penalises near-misses
        let hueScore: Float
        if angularDist <= 10      { hueScore = 1.0 }
        else if angularDist <= 30 { hueScore = (30 - angularDist) / 20 }
        else                      { return 0 }

        // Score: hue match × geometric mean saturation
        return hueScore * sqrt(sA * sB)
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
        // Breath-pair exception: when one image is geometrically rich and the other is
        // intentionally open/sparse (|normPeakA - normPeakB| > 0.5), the product form
        // suppresses the pair to near-zero. Give partial credit based on the richer image
        // instead. Does not fire when both images are similarly dense or similarly flat.
        var edgeMult   = pow(normPeakA * normPeakB, kDistinctivenessExponent)
        let kBreathThreshold: Float = 0.5
        let kBreathFactor:    Float = 0.6
        if abs(normPeakA - normPeakB) > kBreathThreshold {
            let richCredit = pow(max(normPeakA, normPeakB), kDistinctivenessExponent) * kBreathFactor
            edgeMult = max(edgeMult, richCredit)
        }
        let varMult    = pow(normVarA  * normVarB,  kDistinctivenessExponent)

        // Tonal weight differential: rewards compositional density asymmetry.
        // Peaks when one image is grid-complex (dense layered scene) and the other is
        // grid-uniform (plain wall, open sky). Similarity-based rawGridSim cannot surface
        // these breath pairs — they need a complementarity signal instead.
        // Weight 0.4 adds a third term; denominator adjusts accordingly.
        let kBreathWeight: Float = 0.4
        let breathScore = abs(normVarA - normVarB)

        return (
            score:              (rawEdge * edgeMult + rawGrid * varMult + breathScore * kBreathWeight) / (2 + kBreathWeight),
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
        case aesthetic where submode == "accent_echo":
            return "Colour echo — both images share a specific accent hue while diverging in overall palette."
        case aesthetic where submode == "harmony":
            return "Tonal harmony — images share a similar colour register and mood."
        case aesthetic:
            return "Colour contrast — images form a complementary colour relationship."
        default:
            return "Compositional echo — images share similar structural lines or visual weight."
        }
    }
}
