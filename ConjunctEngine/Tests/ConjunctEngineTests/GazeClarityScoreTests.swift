import XCTest
@testable import ConjunctEngine

/// The gaze validity-pass score is geometry-derived (decision #109): the VLM verdict
/// is binary; among VALID pairs, the number ranks by how clearly this is a real,
/// well-aimed directed look (gaze strength + gutter coherence). NOT a quality score.
final class GazeClarityScoreTests: XCTestCase {

    func testRangeBounds() {
        // Minimum-clarity valid pair (gaze at threshold, subject at center) → floor 0.60.
        XCTAssertEqual(GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.22, coherence: 0.0), 0.60, accuracy: 0.001)
        // Maximum-clarity (strong gaze, subject hard at the gutter) → ceiling 0.95.
        XCTAssertEqual(GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.60, coherence: 0.45), 0.95, accuracy: 0.001)
        // Never exceeds the ceiling even past the anchors.
        XCTAssertLessThanOrEqual(GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.9, coherence: 0.9), 0.95)
    }

    func testMonotonicInGazeStrength() {
        let weak = GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.24, coherence: 0.2)
        let strong = GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.55, coherence: 0.2)
        XCTAssertGreaterThan(strong, weak, "a stronger lateral look should score higher")
    }

    func testMonotonicInCoherence() {
        let loose = GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.4, coherence: 0.05)
        let tight = GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.4, coherence: 0.40)
        XCTAssertGreaterThan(tight, loose, "a subject nearer the gutter should score higher")
    }

    func testRealRanking() {
        // The live spread: a strong looker (DSF0045 ~0.45 gaze) outranks a soft one
        // (L1007801 ~0.24 gaze) — matching the 0.85 vs 0.74 observed verdicts.
        let strong = GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.45, coherence: 0.3)
        let soft = GazeVisionBackgroundPass.clarityScore(lookerGazeAbs: 0.24, coherence: 0.3)
        XCTAssertGreaterThan(strong, soft)
    }
}
