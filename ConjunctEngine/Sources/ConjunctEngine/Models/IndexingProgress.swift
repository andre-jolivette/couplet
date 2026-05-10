import Foundation

public struct IndexingProgress: Sendable {

    public enum Phase: String, Sendable, Equatable {
        case scanning              = "Scanning files"
        case duplicateDetection    = "Detecting duplicates"
        case thumbnails            = "Generating thumbnails"
        case extraction            = "Extracting features"
        case captioning            = "Captioning images"
        case accentExtraction      = "Extracting accent colors"
        case scoring               = "Scoring pairs"
        case complete              = "Complete"
        case failed                = "Failed"
        /// Cross-folder scoring running silently in background after phase 1 completes.
        case backgroundScoring     = "Background scoring"
        /// Phase 2 finished (or was cancelled) — All-view can refresh.
        case backgroundScoringComplete = "Background scoring complete"
    }

    public var phase: Phase
    public var itemsComplete: Int
    public var itemsTotal: Int
    public var eta: TimeInterval?
    public var errorMessage: String?
    /// Populated when phase transitions to .thumbnails after duplicate detection.
    /// The UI uses this to decide whether to show the duplicate review prompt.
    public var duplicateGroups: [DuplicateGroupSummary]?

    public var fractionComplete: Double {
        guard itemsTotal > 0 else { return 0 }
        return Double(itemsComplete) / Double(itemsTotal)
    }

    /// Public init — Swift's synthesized memberwise init is internal,
    /// so external modules (the app) need an explicit public init.
    public init(
        phase: Phase,
        itemsComplete: Int,
        itemsTotal: Int,
        eta: TimeInterval? = nil,
        errorMessage: String? = nil,
        duplicateGroups: [DuplicateGroupSummary]? = nil
    ) {
        self.phase = phase
        self.itemsComplete = itemsComplete
        self.itemsTotal = itemsTotal
        self.eta = eta
        self.errorMessage = errorMessage
        self.duplicateGroups = duplicateGroups
    }

    public static func initial() -> IndexingProgress {
        IndexingProgress(phase: .scanning, itemsComplete: 0, itemsTotal: 0)
    }
}
