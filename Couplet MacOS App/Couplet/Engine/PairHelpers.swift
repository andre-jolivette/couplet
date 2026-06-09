import Foundation
import ConjunctEngine

// MARK: - Pure pair-processing helpers (actor-free)
//
// These functions receive all @MainActor-isolated dependencies as explicit
// parameters so they can be called from inside Task.detached closures without
// capturing EngineController (which is @MainActor-isolated).
//
// The `nonisolated` keyword is required to override Swift's inference: the
// Swift 6 compiler infers @MainActor on any free function in a file that uses
// @MainActor-associated types (e.g. DisplayPair via NSColor). All helpers here
// are pure value-type computations with no actor dependencies.

nonisolated func adjustedGeometricFree(
    _ result: PairQueryResult,
    peakFloor: Float,
    varFloor: Float
) -> Float {
    guard let rawEdge = result.rawEdgeSim,
          let rawGrid = result.rawGridSim else {
        return Float(result.geometricScore)
    }
    let edgeMult = result.edgePeakednessMult.map { Float($0) } ?? 1.0
    let varMult  = result.gridVarianceMult.map   { Float($0) } ?? 1.0
    var edgeSim  = Float(rawEdge) * edgeMult
    var gridSim  = Float(rawGrid) * varMult
    if let maxPeak = result.maxEdgePeakedness, Float(maxPeak) < peakFloor { edgeSim *= 0.40 }
    if let maxVar  = result.maxGridVariance,   Float(maxVar)  < varFloor  { gridSim *= 0.50 }
    return (edgeSim + gridSim) / 2
}

nonisolated func convertToPairFree(
    _ r: PairQueryResult,
    adjustedGeometricScore: Float,
    weights: ScoringWeights,
    pairCounts: [Int: Int],
    thumbnailBase: URL
) -> DisplayPair {
    let geoScore = adjustedGeometricScore
    let modality: PairingModality
    if r.selectedFor == "thematic" {
        modality = .thematic
    } else if r.selectedFor == "aesthetic" {
        modality = .aesthetic
    } else if r.thematicScore >= 0.25 && r.thematicScore > Double(geoScore) {
        modality = .thematic
    } else if Double(geoScore) >= r.aestheticScore {
        modality = .geometric
    } else {
        modality = .aesthetic
    }

    let decision: PairDecision
    switch r.userDecision {
    case "liked":    decision = .liked
    case "rejected": decision = .rejected
    case "deleted":  decision = .deleted
    default:         decision = .none
    }

    // Replay temporal penalty so display sort matches scorer intent.
    // captureDate stored as INTEGER in SQLite; coercion handled in QueryService.
    let temporalPenalty: Float = {
        guard let a = r.captureDateA, let b = r.captureDateB else { return 1.0 }
        let gap = abs(a.timeIntervalSince(b))
        if gap <= 30  { return 0.40 }
        if gap <= 60  { return 0.55 }
        if gap <= 300 { return 0.85 }
        return 1.0
    }()
    let displayComposite = (Float(r.aestheticScore) * weights.aesthetic
                          + geoScore               * weights.geometric
                          + Float(r.thematicScore) * weights.thematic)
                          * temporalPenalty

    // Peak-axis score: rewards pairs exceptional on any single axis.
    // The × 0.8 geometric scalar accounts for geometric's lower composite weight (0.20
    // vs 0.40 for aesthetic/thematic) so all three axes compete on equal footing.
    // temporalPenalty reused — never recomputed separately (decision #26).
    //
    // Blended with displayComposite (0.6/0.4) so multi-axis pairs rank above
    // single-axis pairs while both beat mediocre-everywhere. Pure max() was too
    // aggressive — a single strong axis with nothing else dominated the top.
    // See decision #78.
    let peakScore = max(
        Float(r.aestheticScore),
        geoScore * 0.8,
        Float(r.thematicScore)
    ) * temporalPenalty
    let axisScore = 0.6 * peakScore + 0.4 * displayComposite

    func thumbURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return thumbnailBase.appendingPathComponent(path)
    }

    return DisplayPair(
        id: Int(r.pairID), imageAID: Int(r.imageAID), imageBID: Int(r.imageBID),
        filenameA: r.filenameA, filenameB: r.filenameB,
        folderA: r.folderNameA, folderB: r.folderNameB,
        captureDateA: r.captureDateA, captureDateB: r.captureDateB,
        cameraModelA: r.cameraModelA, cameraModelB: r.cameraModelB,
        colorProfileA: r.colorProfileA, colorProfileB: r.colorProfileB,
        captionA: r.captionA, captionB: r.captionB,
        modality: modality, aestheticSubmode: r.aestheticSubmode,
        geometricSubmode: r.geometricSubmode,
        accentHueA: r.accentHueA, accentSaturationA: r.accentSaturationA,
        accentHueB: r.accentHueB, accentSaturationB: r.accentSaturationB,
        compositeScore: displayComposite, axisScore: axisScore,
        aestheticScore: Float(r.aestheticScore),
        geometricScore: geoScore, thematicScore: Float(r.thematicScore),
        rationale: r.rationale,
        pairCountA: pairCounts[Int(r.imageAID), default: 0],
        pairCountB: pairCounts[Int(r.imageBID), default: 0],
        thumbnailURLA: thumbURL(r.thumbnailPathA),
        thumbnailURLB: thumbURL(r.thumbnailPathB),
        pathA: r.imagePathA, pathB: r.imagePathB,
        folderPathA: r.folderPathA, folderPathB: r.folderPathB,
        decision: decision
    )
}

nonisolated func pairSortComparator(for order: PairSortOrder) -> (DisplayPair, DisplayPair) -> Bool {
    switch order {
    case .axis:      return { $0.axisScore      > $1.axisScore      }
    case .composite: return { $0.compositeScore > $1.compositeScore }
    case .thematic:  return { $0.thematicScore  > $1.thematicScore  }
    case .geometric: return { $0.geometricScore > $1.geometricScore }
    case .aesthetic: return { $0.aestheticScore > $1.aestheticScore }
    }
}

/// Two-pass greedy cap-2 deduplication. Input must be sorted by score descending.
/// Pass 1: both images unseen → accept, mark both seen.
/// Pass 2: at least one image still unseen after pass 1 → accept (each image
///         may appear in at most one pass-2 pair).
nonisolated func applyCap2Free(_ pairs: [DisplayPair]) -> [DisplayPair] {
    var seenImages = Set<Int>()
    var pass1: [DisplayPair] = []
    for pair in pairs {
        guard !seenImages.contains(pair.imageAID),
              !seenImages.contains(pair.imageBID) else { continue }
        pass1.append(pair)
        seenImages.insert(pair.imageAID)
        seenImages.insert(pair.imageBID)
    }
    var pass2Seen = Set<Int>()
    var pass2: [DisplayPair] = []
    for pair in pairs {
        let aUnseen = !seenImages.contains(pair.imageAID)
        let bUnseen = !seenImages.contains(pair.imageBID)
        guard aUnseen || bUnseen else { continue }
        guard !pass2Seen.contains(pair.imageAID),
              !pass2Seen.contains(pair.imageBID) else { continue }
        pass2.append(pair)
        pass2Seen.insert(pair.imageAID)
        pass2Seen.insert(pair.imageBID)
    }
    return pass1 + pass2
}

/// Pass-2 half of cap-2 for the streaming path, where pass-1 already ran
/// incrementally across chunks. `seenImages` is the accumulated set from pass-1.
nonisolated func applyPass2Free(_ pairs: [DisplayPair], seenImages: Set<Int>) -> [DisplayPair] {
    var pass2Seen = Set<Int>()
    var result: [DisplayPair] = []
    for pair in pairs {
        let aUnseen = !seenImages.contains(pair.imageAID)
        let bUnseen = !seenImages.contains(pair.imageBID)
        guard aUnseen || bUnseen else { continue }
        guard !pass2Seen.contains(pair.imageAID),
              !pass2Seen.contains(pair.imageBID) else { continue }
        result.append(pair)
        pass2Seen.insert(pair.imageAID)
        pass2Seen.insert(pair.imageBID)
    }
    return result
}
