import Foundation
import GRDB

public struct PairRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var imageAID: Int64
    public var imageBID: Int64
    public var aestheticScore: Double
    public var aestheticSubmode: String
    public var geometricScore: Double
    /// Raw edge cosine similarity before gating. Nil for pairs scored before v5.
    public var rawEdgeSim: Double?
    /// Raw composition grid cosine similarity before gating. Nil for pairs scored before v5.
    public var rawGridSim: Double?
    /// max(edgePeakedness_A, edgePeakedness_B). Nil for pairs scored before v5.
    public var maxEdgePeakedness: Double?
    /// max(gridVariance_A, gridVariance_B). Nil for pairs scored before v5.
    public var maxGridVariance: Double?
    /// √(normPeak_A × normPeak_B). Nil for pairs scored before v6.
    public var edgePeakednessMult: Double?
    /// √(normVar_A × normVar_B). Nil for pairs scored before v6.
    public var gridVarianceMult: Double?
    /// Which topK path inserted this pair: 'composite', 'thematic', or 'geometric'. Nil for pre-v8 rows.
    public var selectedFor: String?
    public var thematicScore: Double
    public var compositeScore: Double
    public var rationale: String
    /// Geometric sub-mode that produced the score. Nil for pre-v13 rows.
    public var geometricSubmode: String?
    public var scoredAt: Date

    public static var databaseTableName = "pairs"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(
        imageAID rawA: Int64,
        imageBID rawB: Int64,
        aestheticScore: Double,
        aestheticSubmode: String,
        geometricScore: Double,
        rawEdgeSim: Double? = nil,
        rawGridSim: Double? = nil,
        maxEdgePeakedness: Double? = nil,
        maxGridVariance: Double? = nil,
        edgePeakednessMult: Double? = nil,
        gridVarianceMult: Double? = nil,
        selectedFor: String? = nil,
        thematicScore: Double,
        compositeScore: Double,
        rationale: String,
        geometricSubmode: String? = nil,
        scoredAt: Date = Date()
    ) {
        // PairScorer.score() owns canonical ordering — for most pairs this means
        // smaller ID first, but for gaze_conversation pairs the rightward-gazing
        // image is stored as imageAID (left display) regardless of numeric ID order.
        // Do NOT re-apply min/max here; trust what the scorer computed. See decision #71.
        self.imageAID = rawA
        self.imageBID = rawB
        self.aestheticScore = aestheticScore
        self.aestheticSubmode = aestheticSubmode
        self.geometricScore = geometricScore
        self.rawEdgeSim = rawEdgeSim
        self.rawGridSim = rawGridSim
        self.maxEdgePeakedness = maxEdgePeakedness
        self.maxGridVariance = maxGridVariance
        self.edgePeakednessMult = edgePeakednessMult
        self.gridVarianceMult = gridVarianceMult
        self.selectedFor = selectedFor
        self.thematicScore = thematicScore
        self.compositeScore = compositeScore
        // 240 (was 120): role-join hypotheses (#102) stored here as the judge's input
        // run ~130-150 chars; normal scoring rationales are short and unaffected.
        self.rationale = String(rationale.prefix(240))
        self.geometricSubmode = geometricSubmode
        self.scoredAt = scoredAt
    }
}

public extension PairRecord {
    func partnerID(for anchorID: Int64) -> Int64? {
        if imageAID == anchorID { return imageBID }
        if imageBID == anchorID { return imageAID }
        return nil
    }
}
