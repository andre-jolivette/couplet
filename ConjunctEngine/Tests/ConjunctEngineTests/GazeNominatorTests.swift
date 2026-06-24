import XCTest
@testable import ConjunctEngine

/// Validates the pure geometric nomination of directed-attention candidates
/// (backlog #72, decision #109). Orientation, the gutter-coherence filter, the
/// gaze threshold, the burst guard, and the degree caps.
final class GazeNominatorTests: XCTestCase {

    // Lookers default to faceCount 1 / humanCount 1 (single clear subject); targets
    // default to high dominance — so each test overrides only the field it exercises.
    func img(_ id: Int64, gaze: Float?, cx: Float?, cd: Double? = nil,
             faces: Int? = 1, humans: Int? = 1, dom: Float? = 1.0) -> GazeNominator.Image {
        .init(id: id, gaze: gaze, centroidX: cx, captureDate: cd,
              faceCount: faces, humanCount: humans, subjectDominance: dom)
    }

    func testRightwardLookerGoesLeftAndPointsIntoTarget() {
        // Looker(1) looks right (+0.30) → left (imageAID); target(2) subject on its
        // left edge (cx 0.2, gutter side) → right (imageBID). The look lands on it.
        let c = GazeNominator.nominate([img(1, gaze: 0.30, cx: 0.5),
                                        img(2, gaze: nil, cx: 0.2)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].leftID, 1)
        XCTAssertEqual(c[0].rightID, 2)
        XCTAssertEqual(c[0].lookerID, 1)
    }

    func testLeftwardLookerGoesRight() {
        // Looker(1) looks left (−0.30) → right (imageBID); target(2) subject on its
        // right edge (cx 0.8, gutter side when target is on the left) → left (imageAID).
        let c = GazeNominator.nominate([img(1, gaze: -0.30, cx: 0.5),
                                        img(2, gaze: nil, cx: 0.8)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].leftID, 2)
        XCTAssertEqual(c[0].rightID, 1)
        XCTAssertEqual(c[0].lookerID, 1)
    }

    func testWeakGazeIsNotALooker() {
        // |gaze| below threshold → no nomination even with a perfect target.
        let c = GazeNominator.nominate([img(1, gaze: 0.10, cx: 0.5),
                                        img(2, gaze: nil, cx: 0.1)],
                                       threshold: 0.20)
        XCTAssertTrue(c.isEmpty)
    }

    func testCoherenceFilterRejectsFarEdgeTarget() {
        // Looker looks right; target subject is jammed against ITS right (far) edge
        // (cx 0.9) → the gaze would overshoot it. coherence = 0.5 − 0.9 < 0 → rejected.
        let c = GazeNominator.nominate([img(1, gaze: 0.30, cx: 0.5),
                                        img(2, gaze: nil, cx: 0.9)])
        XCTAssertTrue(c.isEmpty)
    }

    func testNoTargetWithoutSalientSubject() {
        // Target has no centroid (no detected subject) → nothing to look at.
        let c = GazeNominator.nominate([img(1, gaze: 0.30, cx: 0.5),
                                        img(2, gaze: nil, cx: nil)])
        XCTAssertTrue(c.isEmpty)
    }

    func testBurstFramesExcluded() {
        // Looker and target within the burst gap (same session) → not a pair.
        let c = GazeNominator.nominate([img(1, gaze: 0.30, cx: 0.5, cd: 1000),
                                        img(2, gaze: nil, cx: 0.2, cd: 1100)],
                                       burstGapSeconds: 300)
        XCTAssertTrue(c.isEmpty)
    }

    func testNoSelfPair() {
        // A single looker that is also its own best target must not pair with itself.
        let c = GazeNominator.nominate([img(1, gaze: 0.30, cx: 0.1)])
        XCTAssertTrue(c.isEmpty)
    }

    func testPerTargetCapSpreadsLoad() {
        // Five lookers all look right; one ideal target. With capPerTarget=3 the
        // target accepts at most 3 of them — preventing one subject absorbing every looker.
        var imgs = [img(100, gaze: nil, cx: 0.1)]   // the lone target
        for id: Int64 in 1...5 { imgs.append(img(id, gaze: 0.30, cx: 0.6)) }
        let c = GazeNominator.nominate(imgs, capPerTarget: 3)
        XCTAssertEqual(c.count, 3)
        XCTAssertTrue(c.allSatisfy { $0.rightID == 100 })
    }

    func testStrongestLookerPicksFirst() {
        // Two lookers (strong 0.30, weaker 0.21) compete for a single target capped at 1.
        // The stronger looker wins the pick (processed first). threshold 0.20 so both qualify.
        let c = GazeNominator.nominate([img(1, gaze: 0.21, cx: 0.5),
                                        img(2, gaze: 0.30, cx: 0.5),
                                        img(100, gaze: nil, cx: 0.1)],
                                       threshold: 0.20, capPerTarget: 1)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].lookerID, 2)
    }

    func testMultiFaceLookerExcluded() {
        // A strong gaze but two faces → ambiguous looker (which face? gaze may land
        // on the other person in-frame). Excluded.
        let c = GazeNominator.nominate([img(1, gaze: 0.40, cx: 0.5, faces: 2),
                                        img(2, gaze: nil, cx: 0.2)])
        XCTAssertTrue(c.isEmpty)
    }

    func testCrowdLookerExcludedByHumanCount() {
        // The decisive case: a crowd where Vision detects only ONE face but many
        // humans (faceCount=1 passes, but humanCount=7 must exclude it).
        let c = GazeNominator.nominate([img(1, gaze: 0.50, cx: 0.5, faces: 1, humans: 7),
                                        img(2, gaze: nil, cx: 0.2)])
        XCTAssertTrue(c.isEmpty)
    }

    func testTightFaceCropLookerAllowed() {
        // A tight portrait: one face, zero full humans detected → still a valid looker.
        let c = GazeNominator.nominate([img(1, gaze: 0.50, cx: 0.5, faces: 1, humans: 0),
                                        img(2, gaze: nil, cx: 0.2)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].lookerID, 1)
    }

    func testLowDominanceTargetExcluded() {
        // Target's attention is scattered (dominance below the gate) → no single thing
        // for the look to land on. Excluded.
        let c = GazeNominator.nominate([img(1, gaze: 0.40, cx: 0.5),
                                        img(2, gaze: nil, cx: 0.2, dom: 0.10)],
                                       dominanceMin: 0.35)
        XCTAssertTrue(c.isEmpty)
    }

    func testDeterministicAcrossInputOrder() {
        let a = [img(1, gaze: 0.40, cx: 0.5), img(2, gaze: nil, cx: 0.2),
                 img(3, gaze: -0.35, cx: 0.5), img(4, gaze: nil, cx: 0.7)]
        XCTAssertEqual(GazeNominator.nominate(a), GazeNominator.nominate(a.reversed()))
    }
}
