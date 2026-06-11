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
    /// Which geometric sub-mode determined the score: "structural", "directional_complement",
    /// "gaze_conversation", or "opposing_diagonals". Stored per pair for topK variety selection.
    public let geometricSubmode: String
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
        weightCentroidXA: Float? = nil, weightCentroidYA: Float? = nil,
        weightCentroidXB: Float? = nil, weightCentroidYB: Float? = nil,
        gazeDirectionXA: Float? = nil, gazeDirectionXB: Float? = nil,
        colorProfileA: String = "color", colorProfileB: String = "color",
        weights: ScoringWeights = .default
    ) -> PairScore {
        // Canonicalize so aID < bID. Also reorder gaze and centroid params to match,
        // so geometricScore() always receives gazeXA for aID and gazeXB for bID.
        // Without this reorder, gaze values correspond to the caller's (arbitrary)
        // imageAID/imageBID ordering, not the canonical ordering — making gazeFlipped
        // logic below unreliable. See decision #71.
        let swap = imageAID > imageBID
        let (aID, bID, vA, vB): (Int64, Int64, FeatureVector, FeatureVector) =
            !swap
                ? (imageAID, imageBID, vectorA, vectorB)
                : (imageBID, imageAID, vectorB, vectorA)
        let (gazeA, gazeB) = !swap
            ? (gazeDirectionXA, gazeDirectionXB)
            : (gazeDirectionXB, gazeDirectionXA)
        let (cxA, cyA, cxB, cyB) = !swap
            ? (weightCentroidXA, weightCentroidYA, weightCentroidXB, weightCentroidYB)
            : (weightCentroidXB, weightCentroidYB, weightCentroidXA, weightCentroidYA)

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
                                                   accentHueB: accentHueB, accentSaturationB: accentSaturationB,
                                                   colorProfileA: colorProfileA, colorProfileB: colorProfileB)
        let geo = geometricScore(vA, vB,
                                 centXA: cxA, centYA: cyA,
                                 centXB: cxB, centYB: cyB,
                                 gazeXA: gazeA, gazeXB: gazeB)
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

        // Thematic boost: reweight toward thematic ONLY when thematic is the dominant
        // axis. Firing at thematic >= 0.20 unconditionally penalises strong two-axis
        // pairs (e.g. aesthetic=0.74 + geometric=0.71 + thematic=0.37) by giving 0.60
        // weight to the weakest component and dragging composite below mediocre-everywhere
        // pairs. The boost now requires thematic to beat or match both other axes
        // (geometric scaled to 0.8 to account for the lower composite weight). This
        // preserves the intent — genuine thematic pairs rank highly — without treating
        // two-axis pairs as if they were thematic. See decision #75.
        if hasCaptions && thematic >= 0.20 && thematic >= max(aesthetic, geometric * 0.8) {
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

        // Filename-base duplicate check — strips both leading numeric prefix ("63-name.jpg"
        // → "name.jpg") and trailing numeric suffix ("name-2.jpg" → "name.jpg").
        // Leading prefix pattern: e.g. exports/crops named "63-20250507-_DSF0572.jpg"
        // alongside the original "20250507-_DSF0572.jpg". dHash won't catch crops because
        // the composition changes enough that Hamming distance > 6.
        let sharesBaseName: Bool = {
            guard !filenameA.isEmpty, !filenameB.isEmpty else { return false }
            func base(_ s: String) -> String {
                var r = s
                r = r.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
                r = r.replacingOccurrences(of: #"-\d+(\.\w+)$"#, with: "$1", options: .regularExpression)
                return r.lowercased()
            }
            return base(filenameA) == base(filenameB)
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
                                      geometric: geometric, thematic: thematic,
                                      geometricSubmode: geo.geometricSubmode)
        }

        // For gaze_conversation pairs: ensure the rightward-gazing image is imageA
        // (displayed on the left) so the visual effect reads correctly across the diptych.
        // gazeFlipped means the reversed direction scored higher — swap the canonical
        // ID ordering so the rightward-gazer becomes imageAID. See decision #71.
        let finalAID = geo.gazeFlipped && geo.geometricSubmode == "gaze_conversation" ? bID : aID
        let finalBID = geo.gazeFlipped && geo.geometricSubmode == "gaze_conversation" ? aID : bID

        return PairScore(
            imageAID: finalAID, imageBID: finalBID,
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
            rationale: rationaleText,
            geometricSubmode: geo.geometricSubmode
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
        aesthetic: Float, submode: String, geometric: Float, thematic: Float,
        geometricSubmode: String = ""
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
                             geometric: geometric, thematic: thematic,
                             geometricSubmode: geometricSubmode)
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
        accentHueB: Double? = nil, accentSaturationB: Double? = nil,
        colorProfileA: String = "color", colorProfileB: String = "color"
    ) -> (Float, String) {
        let harmony  = histogramIntersection(vA.hslHistogramFloats, vB.hslHistogramFloats)
        let contrast = paletteContrastScore(vA.dominantPaletteFloats, vB.dominantPaletteFloats)
        let echo     = accentEchoScore(accentHueA: accentHueA, accentSaturationA: accentSaturationA,
                                       accentHueB: accentHueB, accentSaturationB: accentSaturationB)

        // B&W pairs: discount harmony and contrast — both metrics have less discriminative
        // power for monochrome images. Harmony measures lightness-only similarity (8 bins vs
        // 1,152 for colour), so even moderately different B&W images score high; contrast
        // measures L-channel distance only. The ×0.65 discount brings B&W scores into a
        // comparable range to colour scores rather than suppressing them entirely — a genuinely
        // tonal-resonant B&W pair (both high-key, both moody) should still score ~0.55–0.70.
        // Echo is unaffected (accentHue is nil for B&W images). See decision #77.
        let bothBW = colorProfileA == "bw" && colorProfileB == "bw"
        let adjHarmony  = bothBW ? harmony  * 0.65 : harmony
        let adjContrast = bothBW ? contrast * 0.65 : contrast

        if echo > adjHarmony && echo > adjContrast { return (echo, "accent_echo") }
        return adjHarmony >= adjContrast ? (adjHarmony, "harmony") : (adjContrast, "contrast")
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
        // Normalization: /100 (was /80). At /80, extreme colour-palette pairs reached 0.94+
        // and monopolised the grid. /100 calibrates the ceiling so average LAB distance ~100
        // scores 1.0 — a tighter bound on "maximum meaningful contrast." See decision #77.
        return count > 0 ? min(total / Float(count) / 100, 1) : 0
    }

    // MARK: - Geometric scoring

    // Gate: at least one image must have meaningful visual weight concentration
    // (normVar ≥ floor) for the directional complement score to fire.
    // Prevents rewarding pairs where both images are equally featureless.
    private static let kGridVarianceFloor: Float = 0.1

    // Directional complement: rewards pairs where visual weight sits on opposite
    // sides of the frame (left-heavy + right-heavy, or top + bottom).
    // Score = (hDist × 0.70 + vDist × 0.30) × √(concA × concB)
    //   • Horizontal opposition is the primary spatial conversation mode (0.70).
    //   • Concentration weighting: pairs where both images are strongly weighted
    //     score higher than one weighted + one diffuse.
    static func directionalComplementScore(
        centXA: Float, centYA: Float,
        centXB: Float, centYB: Float,
        normVarA: Float, normVarB: Float
    ) -> Float {
        guard max(normVarA, normVarB) >= kGridVarianceFloor else { return 0 }

        let hDist = abs(centXA - centXB)
        let vDist = abs(centYA - centYB)

        let rawScore = hDist * 0.70 + vDist * 0.30

        let concA = min(normVarA, 1.0)
        let concB = min(normVarB, 1.0)
        return rawScore * sqrt(concA * concB)
    }

    // Normalization anchors for the distinctiveness multiplier.
    // Calibrated against library debug output: edgePeakedness p90≈4.0, gridVariance p90≈0.20.
    // An image at or above the anchor scores 1.0; below it scales proportionally toward 0.
    private static let kEdgePeakedNorm: Float  = 4.0
    private static let kGridVarianceNorm: Float = 0.20

    /// Scores how much two images create a gaze conversation across the diptych.
    /// Maximum (1.0) when A looks hard right (+1) and B looks hard left (-1) — facing each other.
    /// Zero when both look the same direction or away from each other.
    static func gazeConversationScore(gazeA: Float, gazeB: Float) -> Float {
        // Raw pupil-offset gaze values cluster near 0 — p90 of abs(gazeDirectionX) ≈ 0.30.
        // Normalize by dividing by 0.30 so the real distribution fills [-1, +1] before scoring.
        // Without this, even a clearly lateral gaze (±0.24) contributes only half its true signal.
        // See decision #70.
        let kGazeScale: Float = 1.0 / 0.30
        let nA = min(max(gazeA * kGazeScale, -1), 1)
        let nB = min(max(gazeB * kGazeScale, -1), 1)
        // (nA - nB) / 2 maps:
        //   +1, -1 → 1.0  (facing each other, full score)
        //   +1,  0 → 0.5  (one looks toward the other)
        //   +1, +1 → 0.0  (parallel gaze, no conversation)
        //   -1, +1 → 0.0  (looking away from each other — negative clamped to zero)
        return max(0, (nA - nB) / 2)
    }

    /// Scores how strongly two images have opposing dominant line directions.
    /// Maximum (1.0) when dominant orientations are perpendicular (90° apart).
    /// Zero when both images share the same dominant line direction.
    ///
    /// Uses the stored 32-bin directional edge histogram (full 360°, atan2 gradient
    /// direction). Folded to undirected [0, 180°) by taking bin % 16 — bins 0 and 16
    /// represent the same undirected line direction.
    ///
    /// Score = sin(dist × π/16) × √(normPeakA × normPeakB)
    /// where dist ∈ [0, 8] bins = [0°, 90°] angular opposition between dominant directions.
    /// Diagonalness gate: both images must have a dominant direction in the ~22.5°–67.5°
    /// diagonal zone (|sin(undirBin × π/8)| ≥ 0.50). Filters bins 0–1 and 7–9 (near
    /// horizontal or vertical) — those are not compositional diagonals. Full credit for
    /// anything in the genuine diagonal range; no continuous penalty within the passing zone.
    /// Returns 0 when either image is below kMinPeakedness or fails the diagonalness gate.
    /// See decisions #73, #74.
    static func orientationOppositionScore(
        vA: FeatureVector, vB: FeatureVector,
        normPeakA: Float, normPeakB: Float
    ) -> Float {
        // Gate: both images need a reasonably clear dominant line direction.
        // normPeak = edgePeakedness / 4.0; kMinPeakedness = 0.25 → raw peakedness ≥ 1.0
        let kMinPeakedness: Float = 0.25
        guard normPeakA >= kMinPeakedness, normPeakB >= kMinPeakedness else { return 0 }

        let hA = vA.edgeOrientationFloats
        let hB = vB.edgeOrientationFloats
        guard hA.count >= 32, hB.count >= 32 else { return 0 }

        // Dominant directed bin [0, 32)
        let domA = hA.indices.max(by: { hA[$0] < hA[$1] }) ?? 0
        let domB = hB.indices.max(by: { hB[$0] < hB[$1] }) ?? 0

        // Fold to undirected [0, 16) — bins 180° apart = same line direction
        let undirA = domA % 16
        let undirB = domB % 16

        // Diagonalness gate: |sin(undirBin × π/8)| — 1.0 at 45°, 0.0 at 0° and 90°.
        // Threshold 0.50 passes bins 2–6 and 10–14 (22.5°–67.5° and its mirror).
        // Filters bins 0, 1, 7, 8, 9, 15 (within ~22.5° of horizontal or vertical).
        let kMinDiagonal: Float = 0.50
        let diagA = abs(sin(Float(undirA) * .pi / 8))
        let diagB = abs(sin(Float(undirB) * .pi / 8))
        guard diagA >= kMinDiagonal, diagB >= kMinDiagonal else { return 0 }

        // Undirected angular distance in [0, 8] bins = [0°, 90°]
        let diff = abs(undirA - undirB)
        let dist = min(diff, 16 - diff)   // wraps around the 16-bin circle; max = 8

        // sin ramp: 0 bins → 0.0, 4 bins (45°) → 0.71, 8 bins (90°) → 1.0
        let scoreBase = sin(Float(dist) * .pi / 16)

        // Scale by geometric mean of peakedness so weak-lined images earn less credit.
        return scoreBase * sqrt(normPeakA * normPeakB)
    }

    static func geometricScore(
        _ vA: FeatureVector, _ vB: FeatureVector,
        centXA: Float? = nil, centYA: Float? = nil,
        centXB: Float? = nil, centYB: Float? = nil,
        gazeXA: Float? = nil, gazeXB: Float? = nil
    ) -> (score: Float, rawEdgeSim: Float, rawGridSim: Float,
          maxEdgePeakedness: Float, maxGridVariance: Float,
          edgePeakednessMult: Float, gridVarianceMult: Float,
          geometricSubmode: String, gazeFlipped: Bool) {

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

        // Three-component geometric formula (decision #59, weights adjusted #60, #64, #65, #67):
        //   structural  (0.50) — edge orientation + grid cosine similarity; rhyme mode
        //   directional (0.25) — max(centroidScore, gazeScore); conversation-pairs mode.
        //                        centroidScore from Vision human-detection centroid opposition.
        //                        gazeScore from VNDetectFaceLandmarksRequest pupil direction.
        //                        orientationScore from dominant edge-line opposition (decision #73).
        //                        max() lets whichever signal is stronger drive the pair.
        //                        See decisions #64, #65, #73.
        //   breath      (0.25) — tonal weight differential; dense+spare pairs mode
        let structural = (rawEdge * edgeMult + rawGrid * varMult) / 2.0

        let centroidScore: Float
        if let cxA = centXA, let cyA = centYA, let cxB = centXB, let cyB = centYB {
            centroidScore = directionalComplementScore(
                centXA: cxA, centYA: cyA, centXB: cxB, centYB: cyB,
                normVarA: normVarA, normVarB: normVarB
            )
        } else {
            centroidScore = 0
        }

        // Symmetrize gaze: score both directions and take the max so the pair
        // is found regardless of which image happens to be gazeXA vs gazeXB.
        // gazeFlipped = true means the reversed order (B looks right, A looks left)
        // was stronger — caller uses this to swap imageAID/imageBID so the
        // rightward-gazer becomes imageA (left display). See decision #71.
        let gazeScore: Float
        let gazeFlipped: Bool
        if let gA = gazeXA, let gB = gazeXB {
            let fwd = gazeConversationScore(gazeA: gA, gazeB: gB)
            let rev = gazeConversationScore(gazeA: gB, gazeB: gA)
            if rev > fwd {
                gazeScore = rev; gazeFlipped = true
            } else {
                gazeScore = fwd; gazeFlipped = false
            }
        } else {
            gazeScore = 0; gazeFlipped = false
        }

        let orientationScore = orientationOppositionScore(
            vA: vA, vB: vB,
            normPeakA: normPeakA, normPeakB: normPeakB
        )

        let directional = max(centroidScore, gazeScore, orientationScore)

        let breath = abs(normVarA - normVarB)
        let score = structural * 0.50 + directional * 0.25 + breath * 0.25
        let geometricSubmode: String
        if directional > structural {
            if gazeScore >= centroidScore && gazeScore >= orientationScore {
                geometricSubmode = "gaze_conversation"
            } else if orientationScore >= centroidScore && orientationScore >= gazeScore {
                geometricSubmode = "opposing_diagonals"
            } else {
                geometricSubmode = "directional_complement"
            }
        } else {
            geometricSubmode = "structural"
        }

        return (
            score:              score,
            rawEdgeSim:         rawEdge,
            rawGridSim:         rawGrid,
            maxEdgePeakedness:  max(peakA, peakB),
            maxGridVariance:    max(varA, varB),
            edgePeakednessMult: edgeMult,
            gridVarianceMult:   varMult,
            geometricSubmode:   geometricSubmode,
            gazeFlipped:        gazeFlipped
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
        geometric: Float, thematic: Float,
        geometricSubmode: String = ""
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
        case geometric where geometricSubmode == "gaze_conversation":
            return "Eyes in conversation — each image completes the other's look."
        case geometric where geometricSubmode == "opposing_diagonals":
            return "Diagonal tension — lines cut across each other through the diptych."
        case geometric where geometricSubmode == "directional_complement":
            return "Spatial tension — compositions in conversation."
        default:
            return "Compositional echo — images share similar structural lines or visual weight."
        }
    }
}
