import Foundation

/// User preferences for duplicate detection and pairing behaviour.
/// Stored in preferences.json alongside ScoringWeights.
public struct DuplicateSettings: Sendable, Codable, Equatable {

    /// Hamming distance threshold for duplicate detection.
    /// 0 = exact hash match only. 8 = default (same shot, different processing).
    /// Max meaningful value is ~12; beyond that unrelated images start matching.
    public var hammingThreshold: Int

    /// When true, images within a duplicate stack can be paired with each other.
    /// When false (default), only the hero image is eligible for pairing with
    /// non-duplicate images; stack members are excluded from the pairing engine.
    public var allowIntraStackPairing: Bool

    /// When true, duplicate detection runs and the user is prompted to review
    /// groups before indexing continues. When false, duplicates are silently
    /// merged into stacks using the default hero selection (earliest capture date).
    public var showReviewPrompt: Bool

    public static let `default` = DuplicateSettings(
        hammingThreshold: 8,
        allowIntraStackPairing: false,
        showReviewPrompt: true
    )

    public init(
        hammingThreshold: Int = 8,
        allowIntraStackPairing: Bool = false,
        showReviewPrompt: Bool = true
    ) {
        self.hammingThreshold = hammingThreshold
        self.allowIntraStackPairing = allowIntraStackPairing
        self.showReviewPrompt = showReviewPrompt
    }
}
