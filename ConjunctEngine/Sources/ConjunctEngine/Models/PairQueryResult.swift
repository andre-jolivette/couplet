import Foundation

public struct PairQueryResult: Sendable {
    public let pairID: Int64
    public let imageAID: Int64
    public let imageBID: Int64
    public let filenameA: String
    public let filenameB: String
    public let thumbnailPathA: String?
    public let thumbnailPathB: String?
    public let imagePathA: String
    public let imagePathB: String
    public let folderPathA: String
    public let folderPathB: String
    public let captureDateA: Date?
    public let captureDateB: Date?
    public let cameraModelA: String?
    public let cameraModelB: String?
    public let colorProfileA: String
    public let colorProfileB: String
    public let captionA: String
    public let captionB: String
    public let folderNameA: String
    public let folderNameB: String
    public let aestheticScore: Double
    public let aestheticSubmode: String
    public let geometricScore: Double
    /// Nil for pairs scored before v5_geometricStats migration. Display-time
    /// recomputation falls back to stored geometricScore when any of these are nil.
    public let rawEdgeSim: Double?
    public let rawGridSim: Double?
    public let maxEdgePeakedness: Double?
    public let maxGridVariance: Double?
    /// Nil for pairs scored before v6_distinctivenessMultipliers migration.
    public let edgePeakednessMult: Double?
    public let gridVarianceMult: Double?
    /// Nil for pairs scored before v8_selected_for migration; falls back to post-hoc labeling.
    public let selectedFor: String?
    public let thematicScore: Double
    public let compositeScore: Double
    public let rationale: String
    public let userDecision: String?
}

public struct FolderQueryResult: Sendable {
    public let id: Int64
    public let displayName: String
    public let path: String
    public let driveType: String
    public let imageCount: Int
    public let pairCount: Int
    public let lastIndexedAt: Date?
}

public struct CollectionQueryResult: Sendable {
    public let id: Int
    public let name: String
    public let pairCount: Int
}
