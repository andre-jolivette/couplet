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
    case composite = "Composite"
    case thematic  = "Thematic"
    case geometric = "Geometric"
    case aesthetic = "Aesthetic"
    var id: String { rawValue }

    /// The DB column name used for SQL ORDER BY and window-function ranking.
    /// These are hardcoded strings, not user input, so no injection risk.
    var dbColumn: String {
        switch self {
        case .composite: return "compositeScore"
        case .thematic:  return "thematicScore"
        case .geometric: return "geometricScore"
        case .aesthetic: return "aestheticScore"
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
    let compositeScore: Float
    let aestheticScore: Float
    let geometricScore: Float
    let thematicScore: Float
    let rationale: String
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

    /// Human-readable explanation of why this is a thematic pair.
    /// Computed live from captions so it's always current, never stale.
    var thematicRationale: String {
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
            onlyA.first.map { "one image brings \($0.replacingOccurrences(of: "_", with: " "))" },
            onlyB.first.map { "the other brings \($0.replacingOccurrences(of: "_", with: " "))" }
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
        compositeScore: Float, aestheticScore: Float,
        geometricScore: Float, thematicScore: Float,
        rationale: String,
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
        self.compositeScore = compositeScore; self.aestheticScore = aestheticScore
        self.geometricScore = geometricScore; self.thematicScore = thematicScore
        self.rationale = rationale
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
}
