import Foundation

// #122 — Event-proximity thematic discount.
//
// Photos shot in the same session ("same event") caption alike, and the ThematicV2
// judge over-scores them as taxonomic — e.g. two skate tricks minutes apart rated
// 0.89 "complementary parts of the same event". This demotes (never rejects) the
// *thematic* axis of a pair shot close together in time that ALSO shares a
// meaningful (>=0.75-weight) cluster — the "same category" proxy.
//
// Deliberately distinct from the burst-scale, whole-composite `temporalPenalty`
// (PairScorer.swift), which cliffs to 1.0 at 300s: this is event-scale,
// thematic-only, and category-gated. Pairs shot >6h apart, or without a shared
// meaningful cluster, are unaffected — so genuine cross-subject same-session pairs
// (a quiet detail shot at a loud event, backlog #123) keep their thematic score.
//
// The temporal guard runs first and short-circuits before any caption parsing, so
// the (relatively costly) cluster match only fires for the small in-window
// population. The nearest KNOWN_GOOD_PAIRS golden pair is 21 days apart — far
// outside the 6h window — so this cannot touch a golden pair.
//
// Lives in ConjunctEngine (pure, unit-tested) and is called from BOTH app display
// sites — PairHelpers.convertToPairFree and EngineController.convertToPair — so the
// two never diverge. See decision #122.

/// Multiplier in [0.70, 1.0] applied to a pair's effective thematic score.
/// Returns 1.0 (no discount) when either capture date is missing, when the pair
/// falls outside the (300s, 6h] same-event window, or when the two captions share
/// no meaningful (>=0.75-weight) cluster.
public func eventProximityThematicFactor(
    captureDateA: Date?, captureDateB: Date?,
    captionA: String?, captionB: String?
) -> Float {
    guard let a = captureDateA, let b = captureDateB else { return 1.0 }
    let gap = abs(a.timeIntervalSince(b))
    // Below 300s is the burst guard's territory (already handled); above 6h is a
    // different day/event and out of scope for the proximity discount.
    guard gap > 300, gap <= 6 * 3600 else { return 1.0 }
    guard let capA = captionA, let capB = captionB,
          ConceptClusters.sharesMeaningfulCluster(capA, capB) else { return 1.0 }
    if gap <= 1800      { return 0.70 }   // 300s – 30min: continuous session
    else if gap <= 7200 { return 0.80 }   // 30min – 2h
    else                { return 0.90 }   // 2h – 6h
}

extension ConceptClusters {
    /// True when both captions fire at least one common cluster of weight >= 0.75 —
    /// the "same category" proxy that gates the #122 event-proximity discount.
    /// Ambient-tier clusters (weight 0.2, e.g. urban_street) are excluded so
    /// incidental overlap (both merely "urban") does not count as a shared category.
    public static func sharesMeaningfulCluster(_ captionA: String, _ captionB: String) -> Bool {
        let ma = matchedClusters(for: captionA).filter { (weights[$0] ?? 0) >= 0.75 }
        guard !ma.isEmpty else { return false }
        let mb = matchedClusters(for: captionB).filter { (weights[$0] ?? 0) >= 0.75 }
        return !ma.isDisjoint(with: mb)
    }
}
