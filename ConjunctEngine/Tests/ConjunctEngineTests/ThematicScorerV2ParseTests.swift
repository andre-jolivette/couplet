import XCTest
@testable import ConjunctEngine

/// #129 — extraction parsing is lenient to the now-optional `note` field.
final class ThematicScorerV2ParseTests: XCTestCase {

    func testFindingWithoutNoteParses() {
        // Note is omitted for scoring findings (#129); parser defaults to "".
        let raw = """
        {"findings":[{"kind":"source_receiver","quoteA":"plays a trumpet",\
        "quoteB":"covers her ears","explicitA":true,"explicitB":true}]}
        """
        let findings = ThematicScorerV2.parseFindings(from: raw)
        XCTAssertEqual(findings?.count, 1)
        XCTAssertEqual(findings?.first?.kind, .sourceReceiver)
        XCTAssertEqual(findings?.first?.note, "")
    }

    func testSharedCategoryNoteStillParses() {
        // Shared_category keeps its note (feeds the inherent-idea probe).
        let raw = """
        {"findings":[{"kind":"shared_category","quoteA":"a protest","quoteB":"a march",\
        "explicitA":true,"explicitB":true,"note":"both protests"}]}
        """
        let findings = ThematicScorerV2.parseFindings(from: raw)
        XCTAssertEqual(findings?.first?.note, "both protests")
    }

    func testUnknownKindSkippedNotFailed() {
        let raw = """
        {"findings":[{"kind":"nonsense","quoteA":"x","quoteB":"y","explicitA":true,"explicitB":true},\
        {"kind":"gesture_echo","quoteA":"raised fist","quoteB":"raised fist","explicitA":true,"explicitB":true}]}
        """
        let findings = ThematicScorerV2.parseFindings(from: raw)
        XCTAssertEqual(findings?.count, 1)
        XCTAssertEqual(findings?.first?.kind, .gestureEcho)
    }

    func testMissingRequiredFieldSkipsFinding() {
        // A finding missing quoteB is skipped, not fatal.
        let raw = """
        {"findings":[{"kind":"source_receiver","quoteA":"only A","explicitA":true,"explicitB":false}]}
        """
        let findings = ThematicScorerV2.parseFindings(from: raw)
        XCTAssertEqual(findings?.count, 0)
    }
}
