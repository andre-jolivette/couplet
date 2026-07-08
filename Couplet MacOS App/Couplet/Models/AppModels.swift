import Foundation
@preconcurrency import AppKit
import SwiftUI

// MARK: - Pairing Modality

public enum PairingModality: String, CaseIterable, Identifiable {
    case aesthetic = "Aesthetic"
    case geometric = "Geometric"
    case thematic  = "Thematic"

    public var id: String { rawValue }

    var color: NSColor {
        switch self {
        case .aesthetic: return NSColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 1)
        case .geometric: return NSColor(red: 0.20, green: 0.75, blue: 0.55, alpha: 1)
        case .thematic:  return NSColor(red: 0.85, green: 0.45, blue: 0.25, alpha: 1)
        }
    }
    var swiftColor: Color { Color(nsColor: color) }
}

// MARK: - Sort Order

enum PairSortOrder: String, CaseIterable, Identifiable {
    /// Peak-axis ranking: max(aesthetic, geometric×0.8, thematic) × temporalPenalty.
    /// Default sort. Rewards pairs exceptional on any single axis rather than
    /// averaging weakness across all three. See decision #66.
    case axis      = "Best"
    /// Weighted-average composite: aesthetic×w + geometric×w + thematic×w.
    /// Rewards pairs that score well across all axes simultaneously.
    case composite = "Balanced"
    case thematic  = "Thematic"
    case geometric = "Geometric"
    case aesthetic = "Aesthetic"
    var id: String { rawValue }

    /// SQL ORDER BY expression (may be a column name or a full expression).
    /// All are hardcoded strings — no injection risk.
    /// `.axis` / `.composite` proxy through the stored compositeScore OR a V2-aware
    /// recomputation — whichever is higher — so pairs with high thematicV2Score float
    /// up in the DB query before cap-2 runs. Cap-2 then re-sorts by axisScore in memory.
    /// NOTE: used verbatim in ORDER BY; do NOT prefix with a table alias in the SQL.
    var dbColumn: String {
        switch self {
        case .axis:
            // Proxy for axisScore = 0.6×peakScore + 0.4×displayComposite with V2 thematic.
            return "MAX(p.compositeScore, 0.6 * MAX(p.aestheticScore, p.geometricScore * 0.8, COALESCE(p.thematicV2Score, p.thematicScore)) + 0.4 * (p.aestheticScore * 0.4 + p.geometricScore * 0.2 + COALESCE(p.thematicV2Score, p.thematicScore) * 0.4))"
        case .composite:
            return "MAX(p.compositeScore, p.aestheticScore * 0.4 + p.geometricScore * 0.2 + COALESCE(p.thematicV2Score, p.thematicScore) * 0.4)"
        case .thematic:
            return "COALESCE(p.thematicV2Score, p.thematicScore)"
        case .geometric:
            return "p.geometricScore"
        case .aesthetic:
            return "p.aestheticScore"
        }
    }
}

// MARK: - User Decision

enum PairDecision {
    case none, liked, rejected, deleted
}

// MARK: - Display Pair

struct DisplayPair: Identifiable, Hashable {
    let id: Int
    let imageAID: Int
    let imageBID: Int
    let filenameA: String
    let filenameB: String
    let folderA: String
    let folderB: String
    let captureDateA: Date?
    let captureDateB: Date?
    let cameraModelA: String?
    let cameraModelB: String?
    let colorProfileA: String
    let colorProfileB: String
    let captionA: String
    let captionB: String
    let modality: PairingModality
    let aestheticSubmode: String
    let geometricSubmode: String?
    let accentHueA: Double?
    let accentSaturationA: Double?
    let accentHueB: Double?
    let accentSaturationB: Double?
    /// Weighted-average display composite: (A×wA + G×wG + T×wT) × temporalPenalty.
    /// Used for the "Balanced" sort and the minimum-confidence filter.
    let compositeScore: Float
    /// Peak-axis score: max(aesthetic, geometric×0.8, thematic) × temporalPenalty.
    /// Used for the "Best" (default) sort. Rewards specialization — a pair exceptional
    /// on any single axis ranks above a pair mediocre on all three. See decision #66.
    let axisScore: Float
    let aestheticScore: Float
    let geometricScore: Float
    let thematicScore: Float
    let rationale: String
    /// Human-readable explanation of why this is a thematic pair, derived from captions.
    /// Computed once in `init` (not a computed property) so it doesn't get recomputed —
    /// and its cluster tie-break potentially re-resolved differently — on every SwiftUI
    /// re-render (e.g. hover-driven chrome show/hide in the lightbox). See decision #118.
    let thematicRationale: String
    /// One-sentence LLM explanation of the thematic connection. Nil when not yet scored by ThematicScorerV2.
    let thematicV2Rationale: String?
    /// Relationship type from ThematicScorerV2: complementary/contrastive/echo/ironic/tonal/none.
    let thematicV2RelationshipType: String?
    /// Gaze vision-judge (#109) verdict: geometry-derived clarity when the directed look
    /// is confirmed valid, 0 when rejected, nil when unjudged / not a gaze pair.
    let gazeJudgeScore: Float?
    /// One-sentence vision-judge rationale (what the look is aimed at). Shown in the
    /// lightbox info rail for `selectedFor='gaze'` pairs. Nil when unjudged.
    let gazeJudgeRationale: String?
    /// Total number of pairs for each image in the current folder context.
    /// Used for the dot badge in the grid (threshold: 100) and count labels in the lightbox.
    let pairCountA: Int
    let pairCountB: Int
    /// Full URL to the 512px thumbnail on disk. Nil until thumbnails are generated.
    let thumbnailURLA: URL?
    let thumbnailURLB: URL?
    /// Full on-disk path to the source image file. Used for mid-res generation in the lightbox.
    let pathA: String
    let pathB: String
    /// Path of the indexed folder containing each image. Used to resolve security-scoped bookmarks.
    let folderPathA: String
    let folderPathB: String
    var decision: PairDecision      = .none

    /// True when both images were captured within 10 seconds of each other.
    /// These are typically sequential shots from a burst or rapid-fire session.
    var isSequential: Bool {
        guard let a = captureDateA, let b = captureDateB else { return false }
        return abs(a.timeIntervalSince(b)) <= 10
    }

    enum ColorTone: String, CaseIterable {
        case bothColor = "Color"
        case bothBW    = "B&W"
        case mixed     = "Mixed"
    }
    var colorTone: ColorTone {
        let aIsBW = colorProfileA == "bw"
        let bIsBW = colorProfileB == "bw"
        if aIsBW && bIsBW { return .bothBW }
        if !aIsBW && !bIsBW { return .bothColor }
        return .mixed
    }

    /// Builds the human-readable thematic rationale from captions. Pure function of
    /// its inputs — called once from `init` and cached in `thematicRationale`.
    /// nonisolated: called from the nonisolated init (see decision #41/#118 — Swift
    /// infers @MainActor here otherwise, same inference chain as colorA/colorB).
    private nonisolated static func buildThematicRationale(
        modality: PairingModality, captionA: String, captionB: String, rationale: String
    ) -> String {
        guard modality == .thematic else { return rationale }
        let cA = captionA.isEmpty ? Set<String>() : ConjunctConceptClusters.matchedClusters(for: captionA)
        let cB = captionB.isEmpty ? Set<String>() : ConjunctConceptClusters.matchedClusters(for: captionB)
        guard !cA.isEmpty || !cB.isEmpty else { return rationale }
        let shared = cA.intersection(cB)
        let onlyA = cA.subtracting(cB)
        let onlyB = cB.subtracting(cA)
        guard !shared.isEmpty else { return rationale }
        let sharedReadable = shared
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .sorted().joined(separator: ", ")
        let contrastParts = [
            ConjunctConceptClusters.representativeCluster(in: onlyA).map { "one image brings \($0.replacingOccurrences(of: "_", with: " "))" },
            ConjunctConceptClusters.representativeCluster(in: onlyB).map { "the other brings \($0.replacingOccurrences(of: "_", with: " "))" }
        ].compactMap { $0 }
        let contrast = contrastParts.isEmpty ? "" : " — " + contrastParts.joined(separator: ", ")
        return "Both images share a sense of \(sharedReadable)\(contrast)."
    }

    // Fallback stub colour when thumbnail is not yet available.
    // Explicitly @MainActor to prevent Swift from inferring the whole struct
    // (and its init) as @MainActor due to NSColor's actor annotation in the SDK.
    @MainActor var colorA: NSColor { SampleData.stubColor(for: imageAID) }
    @MainActor var colorB: NSColor { SampleData.stubColor(for: imageBID) }

    // Explicit init so EngineController can set all fields including thumbnail URLs.
    // nonisolated prevents Swift from inferring @MainActor on the init due to the
    // @MainActor computed properties (colorA/colorB) that use NSColor.
    nonisolated init(
        id: Int, imageAID: Int, imageBID: Int,
        filenameA: String, filenameB: String,
        folderA: String, folderB: String,
        captureDateA: Date?, captureDateB: Date?,
        cameraModelA: String? = nil, cameraModelB: String? = nil,
        colorProfileA: String = "color", colorProfileB: String = "color",
        captionA: String = "", captionB: String = "",
        modality: PairingModality, aestheticSubmode: String,
        geometricSubmode: String? = nil,
        accentHueA: Double? = nil, accentSaturationA: Double? = nil,
        accentHueB: Double? = nil, accentSaturationB: Double? = nil,
        compositeScore: Float, axisScore: Float = 0,
        aestheticScore: Float,
        geometricScore: Float, thematicScore: Float,
        rationale: String,
        thematicV2Rationale: String? = nil,
        thematicV2RelationshipType: String? = nil,
        gazeJudgeScore: Float? = nil, gazeJudgeRationale: String? = nil,
        pairCountA: Int = 0, pairCountB: Int = 0,
        thumbnailURLA: URL? = nil, thumbnailURLB: URL? = nil,
        pathA: String = "", pathB: String = "",
        folderPathA: String = "", folderPathB: String = "",
        decision: PairDecision = .none
    ) {
        self.id = id; self.imageAID = imageAID; self.imageBID = imageBID
        self.filenameA = filenameA; self.filenameB = filenameB
        self.folderA = folderA; self.folderB = folderB
        self.captureDateA = captureDateA; self.captureDateB = captureDateB
        self.cameraModelA = cameraModelA; self.cameraModelB = cameraModelB
        self.colorProfileA = colorProfileA; self.colorProfileB = colorProfileB
        self.captionA = captionA; self.captionB = captionB
        self.modality = modality; self.aestheticSubmode = aestheticSubmode
        self.geometricSubmode = geometricSubmode
        self.accentHueA = accentHueA; self.accentSaturationA = accentSaturationA
        self.accentHueB = accentHueB; self.accentSaturationB = accentSaturationB
        self.compositeScore = compositeScore; self.axisScore = axisScore
        self.aestheticScore = aestheticScore
        self.geometricScore = geometricScore; self.thematicScore = thematicScore
        self.rationale = rationale
        self.thematicRationale = Self.buildThematicRationale(
            modality: modality, captionA: captionA, captionB: captionB, rationale: rationale
        )
        self.thematicV2Rationale = thematicV2Rationale
        self.thematicV2RelationshipType = thematicV2RelationshipType
        self.gazeJudgeScore = gazeJudgeScore; self.gazeJudgeRationale = gazeJudgeRationale
        self.pairCountA = pairCountA; self.pairCountB = pairCountB
        self.thumbnailURLA = thumbnailURLA; self.thumbnailURLB = thumbnailURLB
        self.pathA = pathA; self.pathB = pathB
        self.folderPathA = folderPathA; self.folderPathB = folderPathB
        self.decision = decision
    }

    static func == (lhs: DisplayPair, rhs: DisplayPair) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Folder Item

struct FolderItem: Identifiable, Hashable {
    let id: Int
    let displayName: String
    let path: String
    let driveType: DriveType
    let imageCount: Int
    let pairCount: Int
    var isIndexing: Bool = false
    var indexingFraction: Double? = nil   // 0–1 while indexing, nil if unknown

    enum DriveType { case `internal`, external, nas }

    var systemImage: String {
        switch driveType {
        case .internal: return "internaldrive"
        case .external: return "externaldrive"
        case .nas:      return "server.rack"
        }
    }

    static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Collection Item

struct CollectionItem: Identifiable, Hashable {
    let id: Int
    var name: String
    var pairCount: Int
    var isPermanent: Bool = false
}
