import XCTest
@testable import ConjunctEngine

/// #127 — evidence verification + computed verdict.
final class JudgeEvidenceTests: XCTestCase {

    // MARK: Quote matching

    func testExactSubstringMatches() {
        XCTAssertTrue(JudgeEvidence.quoteMatches(
            "holding a megaphone to his mouth",
            in: "A man is holding a megaphone to his mouth, addressing the crowd."))
    }

    func testNormalizationHandlesCurlyQuotesAndCase() {
        XCTAssertTrue(JudgeEvidence.quoteMatches(
            "Don't miss us too much",
            in: "The text \u{201C}Don\u{2019}t miss us too much\u{201D} is printed on the glass."))
    }

    func testCompressedQuoteMatchesWithinOneSentence() {
        // The G14 probe case: subject + verb quoted across an appositive.
        let caption = "Two mannequins, one dressed in a dark outfit with a green bag, the other in a blue and white checkered dress, hold hands. The scene is static."
        XCTAssertTrue(JudgeEvidence.quoteMatches("Two mannequins hold hands", in: caption))
    }

    func testCrossSentenceStitchingRejected() {
        // Words present but in different sentences must not assemble a claim.
        let caption = "A woman stands near the bus. A man is smiling at the camera."
        XCTAssertFalse(JudgeEvidence.quoteMatches("A woman is smiling", in: caption))
    }

    func testFabricatedWordsRejected() {
        // 547/707 class: no span supports the claim.
        let caption = "A woman and a man stand side by side, both draped in American flags."
        XCTAssertFalse(JudgeEvidence.quoteMatches("embodying racism through their attire", in: caption))
    }

    func testEmptyQuoteRejected() {
        XCTAssertFalse(JudgeEvidence.quoteMatches("", in: "Anything at all."))
    }

    func testShortSubsequenceRejected() {
        // Under 3 tokens, only contiguous substring is accepted.
        XCTAssertFalse(JudgeEvidence.quoteMatches("woman bus", in: "A woman stands near the bus."))
    }

    // MARK: Sign-text register detection

    func testSignTextDetectedInsideQuotes() {
        let caption = "A bus has the words \"DO SOMETHING\" displayed on its front."
        XCTAssertTrue(JudgeEvidence.isSignText("DO SOMETHING", in: caption))
    }

    func testWorldSpanNotInsideQuotes() {
        let caption = "A bus has the words \"DO SOMETHING\" displayed on its front."
        XCTAssertFalse(JudgeEvidence.isSignText("displayed on its front", in: caption))
    }

    func testSignTextWithCurlyQuotesAndApostrophe() {
        let caption = "The text \u{201C}Don\u{2019}t miss us too much\u{201D} is printed on the glass behind her."
        XCTAssertTrue(JudgeEvidence.isSignText("Don't miss us too much", in: caption))
    }

    // MARK: Verdict formula

    private func finding(_ kind: FindingKind, qA: String, qB: String,
                         eA: Bool = true, eB: Bool = true, note: String = "") -> JudgeFinding {
        JudgeFinding(kind: kind, quoteA: qA, quoteB: qB, explicitA: eA, explicitB: eB, note: note)
    }

    func testSourceReceiverBothExplicitScores095() {
        let capA = "A man is holding a megaphone to his mouth."
        let capB = "A woman stands with hands cupping her ears as if blocking out noise."
        let vf = JudgeEvidence.verify(
            finding(.sourceReceiver, qA: "holding a megaphone to his mouth",
                    qB: "hands cupping her ears as if blocking out noise"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.confidence, 0.95, accuracy: 0.001)
        XCTAssertEqual(v.relationshipType, "complementary")
        // Source-receiver confirms carry the same-phenomenon probe.
        XCTAssertEqual(v.probes.count, 1)
        if case .samePhenomenon = v.probes[0] {} else { XCTFail("expected samePhenomenon probe") }
    }

    func testImpliedSideCapsAt075() {
        let capA = "Two people are engaged in conversation on a bench."
        let capB = "A woman stands with hands cupping her ears."
        let vf = JudgeEvidence.verify(
            finding(.sourceReceiver, qA: "engaged in conversation",
                    qB: "hands cupping her ears", eA: false, eB: true),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.confidence, 0.75, accuracy: 0.001)
    }

    func testCategoryOnlyRejects() {
        let capA = "A crowd is engaged in a peaceful protest or demonstration."
        let capB = "The scene appears to be a protest or demonstration."
        let vf = JudgeEvidence.verify(
            finding(.sharedCategory, qA: "a peaceful protest or demonstration",
                    qB: "a protest or demonstration", note: "both protests"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertFalse(v.connected)
        XCTAssertEqual(v.relationshipType, "none")
        XCTAssertEqual(v.confidence, 0)
    }

    func testUnverifiedFindingDiscardedEvenWhenKindIsStrong() {
        // 186/390 class: source side has no supporting span.
        let capA = "A woman raises her fist, gripping a red flag."
        let capB = "A woman is holding a megaphone and speaking passionately."
        let vf = JudgeEvidence.verify(
            finding(.sourceReceiver, qA: "", qB: "holding a megaphone and speaking passionately"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertFalse(v.connected)
    }

    func testTextVsWorldWithQuotedSignAndExplicitEnactmentScores095() {
        let capA = "A sidewalk sign reads \"SMILE\" in bold letters."
        let capB = "A woman is smiling broadly as she walks."
        let vf = JudgeEvidence.verify(
            finding(.textVsWorld, qA: "SMILE", qB: "smiling broadly", eA: true, eB: true),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.confidence, 0.95, accuracy: 0.001)
        XCTAssertEqual(v.relationshipType, "ironic")
    }

    func testTextVsWorldWithoutQuotedSignIsDiscarded() {
        // No mechanically-verifiable text register in either caption — no
        // evidence any text exists (the grounding fallback recovers genuine
        // cases whose sign text IS quoted).
        let capA = "A sign near the door mentions smiling at strangers."
        let capB = "A woman is smiling broadly as she walks."
        let vf = JudgeEvidence.verify(
            finding(.textVsWorld, qA: "smiling at strangers", qB: "smiling broadly"),
            captionA: capA, captionB: capB)
        XCTAssertFalse(JudgeVerdict.compute(findings: [vf]).connected)
    }

    func testSceneSpanMentioningASignIsDiscarded() {
        // A sign "answered" by another sign is one register (339/670 class).
        let capA = "She holds a sign that reads \"MAKE YOUR CHOICE\" at the market."
        let capB = "A large pink heart-shaped sign stands by the road."
        let vf = JudgeEvidence.verify(
            finding(.textVsWorld, qA: "MAKE YOUR CHOICE",
                    qB: "A large pink heart-shaped sign stands by the road"),
            captionA: capA, captionB: capB)
        XCTAssertFalse(JudgeVerdict.compute(findings: [vf]).connected)
    }

    func testTextVsWorldProbesDependOnOverlapAndCategory() {
        let capA = "A protester holds a sign that reads \"SOLIDARITY\" at a demonstration."
        let capB = "A crowd marches together at a protest, arms linked."
        let tvw = JudgeEvidence.verify(
            finding(.textVsWorld, qA: "SOLIDARITY", qB: "arms linked"),
            captionA: capA, captionB: capB)
        let cat = JudgeEvidence.verify(
            finding(.sharedCategory, qA: "a demonstration", qB: "a protest", note: "both protests"),
            captionA: capA, captionB: capB)
        // No stem overlap + shared category → link probe AND inherent-idea probe.
        let with = JudgeVerdict.compute(findings: [tvw, cat])
        XCTAssertTrue(with.connected)
        XCTAssertEqual(with.probes.count, 2)
        if case .textWorldLink = with.probes[0] {} else { XCTFail("expected textWorldLink probe") }
        if case .inherentIdea(_, let category) = with.probes[1] {
            XCTAssertEqual(category, "both protests")
        } else { XCTFail("expected inherentIdea probe") }
        // Without a category finding, only the link probe remains.
        let without = JudgeVerdict.compute(findings: [tvw])
        XCTAssertEqual(without.probes.count, 1)
        if case .textWorldLink = without.probes[0] {} else { XCTFail("expected textWorldLink probe") }
    }

    // MARK: Structural rules (#127 v2)

    func testTwoSignTextsDiscarded() {
        // The join-3 false-premise class: sign text ↔ sign text is one register.
        let capA = "A protester raises a sign that reads \"I CAN'T BREATHE\" above the crowd."
        let capB = "A woman holds up a sign that reads \"HEAL.\" as others watch."
        let vf = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "I CAN'T BREATHE", qB: "HEAL."),
            captionA: capA, captionB: capB)
        XCTAssertTrue(vf.signTextA)
        XCTAssertTrue(vf.signTextB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertFalse(v.connected)
    }

    func testRealVsDepictedRequiresDepictionWordOnExactlyOneSide() {
        // Truck ↔ truck: both real, no register flip → discard.
        let capA = "A white pickup truck and a black livestock trailer are visible."
        let capB = "A white Ford F-150 truck is parked on the street."
        let both = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "A white pickup truck and a black livestock trailer are visible",
                    qB: "A white Ford F-150 truck is parked on the street"),
            captionA: capA, captionB: capB)
        XCTAssertFalse(JudgeVerdict.compute(findings: [both]).connected)

        // Pigeons ↔ peacock mural: depiction word on one side → 0.90 contrastive.
        let capC = "A group of pigeons scattered on the ground near a bench."
        let capD = "A large mural of a peacock's head on the wall behind her."
        let flip = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "pigeons scattered on the ground",
                    qB: "a large mural of a peacock's head", eA: false, eB: false),
            captionA: capC, captionB: capD)
        let v = JudgeVerdict.compute(findings: [flip])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.confidence, 0.90, accuracy: 0.001)
        XCTAssertEqual(v.relationshipType, "contrastive")
        // The same-kind probe gates the register flip (bus ↔ toy cars fails).
        XCTAssertEqual(v.probes.count, 1)
        if case .sameKindDepicted(let real, let depicted) = v.probes[0] {
            XCTAssertTrue(real.contains("pigeons"))
            XCTAssertTrue(depicted.contains("mural"))
        } else { XCTFail("expected sameKindDepicted probe") }
    }

    func testFacePaintIsNotADepiction() {
        // #128 96/631: "a face painted with a clown-like design" is a real face
        // with makeup, not a depicted flag. "painted" must not flip the register.
        let capA = "A woman with a face painted with a clown-like design is holding an American flag."
        let capB = "Behind the crowd, two flags are hanging: the American flag and the Texas state flag."
        let vf = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "a face painted with a clown-like design",
                    qB: "two flags are hanging: the American flag and the Texas state flag"),
            captionA: capA, captionB: capB)
        XCTAssertFalse(JudgeVerdict.compute(findings: [vf]).connected)
    }

    func testPaintingNounStillCountsAsDepiction() {
        // The noun form (a framed painting) is unaffected by dropping "painted".
        let capA = "A real dog lies on the rug by the fire."
        let capB = "A framed painting of a dog hangs above the mantel."
        let vf = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "A real dog lies on the rug",
                    qB: "A framed painting of a dog hangs above the mantel"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.relationshipType, "contrastive")
    }

    func testRationaleNotTruncatedForNormalQuotes() {
        // #128: the old 70/200 caps clipped real quotes mid-phrase. A realistic
        // real-vs-depicted rationale must now render its full template tail.
        let capA = "A woman with long blonde hair stands beside a group of pigeons scattered across the plaza stones."
        let capB = "Two women sit dwarfed beneath a large mural of a peacock's head painted on the brick wall behind them."
        let vf = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "a group of pigeons scattered across the plaza stones",
                    qB: "a large mural of a peacock's head", eA: false, eB: false),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.rationale.hasSuffix("depicted in the other."))
        XCTAssertFalse(v.rationale.contains("…"))
    }

    func testToyIsNotADepictionWord() {
        // 52/842 + 111/616 class: "toy"/"possibly a toy" hedges are not a
        // verified register flip.
        let capA = "A bus with a bicycle mounted on its front is parked on the street."
        let capB = "Toy cars are placed on the ground in front of her."
        let vf = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "A bus with a bicycle mounted on its front",
                    qB: "Toy cars are placed on the ground"),
            captionA: capA, captionB: capB)
        XCTAssertFalse(JudgeVerdict.compute(findings: [vf]).connected)
    }

    func testGenericActionOverlapIsNotDirectEmbodiment() {
        XCTAssertFalse(JudgeVerdict.stemOverlap("just walk in", "The girl is walking forward"))
        XCTAssertTrue(JudgeVerdict.stemOverlap("Smile", "smiling widely"))
    }

    func testInterpretiveSceneSpanCapsDirectness() {
        XCTAssertTrue(JudgeVerdict.isInterpretive("a sense of adventure and freedom"))
        XCTAssertFalse(JudgeVerdict.isInterpretive("smiling widely, showing her teeth"))
    }

    func testPeaceSignIsNotASignboard() {
        XCTAssertFalse(JudgeVerdict.mentionsSign("her fingers forming a peace sign"))
        XCTAssertFalse(JudgeVerdict.mentionsSign("a sign of exhaustion"))
        XCTAssertTrue(JudgeVerdict.mentionsSign("a large pink heart-shaped sign"))
        XCTAssertTrue(JudgeVerdict.mentionsSign("holding a poster above her head"))
    }

    func testSignMessageWithoutContentWordsDiscarded() {
        // "We are NOT." — a truncated sign cannot ground a link.
        let capA = "She holds a sign that reads \"We are NOT.\" while marching."
        let capB = "The crowd appears to be engaged in a peaceful protest or demonstration."
        let vf = JudgeEvidence.verify(
            finding(.textVsWorld, qA: "We are NOT.",
                    qB: "engaged in a peaceful protest or demonstration"),
            captionA: capA, captionB: capB)
        XCTAssertFalse(JudgeVerdict.compute(findings: [vf]).connected)
    }

    func testOneSignSideReKindsToTextVsWorld() {
        // The model mislabels sign+world as real_vs_depicted (G14's shape) —
        // structurally it is text-vs-world.
        let capA = "Two mannequins, one dressed in a dark outfit, hold hands. The scene is static."
        let capB = "The text \"Don't miss us too much\" is printed on the glass behind her."
        let vf = JudgeEvidence.verify(
            finding(.realVsDepicted, qA: "Two mannequins hold hands",
                    qB: "Don't miss us too much", eA: false, eB: true),
            captionA: capA, captionB: capB)
        XCTAssertTrue(vf.verifiedA)
        XCTAssertTrue(vf.verifiedB)
        XCTAssertTrue(vf.signTextB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.relationshipType, "ironic")
        XCTAssertEqual(v.confidence, 0.75, accuracy: 0.001) // slant — pending link probe
        if case .textWorldLink = v.probes.first {} else { XCTFail("expected textWorldLink probe") }
    }

    func testQuoteMarkStyleDifferenceStillMatches() {
        // The model re-quotes sign text with its own quote style.
        let caption = "The text \"Don't miss us too much\" is printed on the glass."
        XCTAssertTrue(JudgeEvidence.quoteMatches("'Don't miss us too much'", in: caption))
    }

    func testSingleQuotedSignRegionDetected() {
        let caption = "A protester raises a sign that reads 'I CAN'T BREATHE' above the crowd."
        XCTAssertTrue(JudgeEvidence.isSignText("I CAN'T BREATHE", in: caption))
        XCTAssertFalse(JudgeEvidence.isSignText("above the crowd", in: caption))
    }

    func testStemOverlapDetectsLexicalEmbodiment() {
        XCTAssertTrue(JudgeVerdict.stemOverlap("SMILE you're Beautiful", "She is smiling widely"))
        XCTAssertFalse(JudgeVerdict.stemOverlap("RACISM IS NOT PATRIOTISM", "Both are wearing baseball caps"))
    }

    func testDirectEmbodimentScores095AndStillCarriesLinkProbe() {
        let capA = "A sidewalk sign reads \"SMILE you're Beautiful\" in bold letters."
        let capB = "She is smiling widely, showing her teeth."
        let vf = JudgeEvidence.verify(
            finding(.textVsWorld, qA: "SMILE you're Beautiful", qB: "smiling widely, showing her teeth"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.confidence, 0.95, accuracy: 0.001)
        // The link probe always gates text-vs-world — direct overlap only sets
        // the confidence (a bare noun echoing an object is a word coincidence).
        XCTAssertEqual(v.probes.count, 1)
        if case .textWorldLink = v.probes[0] {} else { XCTFail("expected textWorldLink probe") }
    }

    func testProbeMessageIsTheQuotedRegionNotTheNarration() {
        // 52/842 class: the model's quote wraps the sign text in narration; the
        // probe message (and the content-word gate) must use the region only.
        let capA = "The bus has the words \"DO SOMETHING\" displayed on its front."
        let capB = "Toy cars are placed on the ground in front of her."
        let vf = JudgeEvidence.verify(
            finding(.textVsWorld,
                    qA: "The bus has the words \"DO SOMETHING\" displayed on its front.",
                    qB: "Toy cars are placed on the ground"),
            captionA: capA, captionB: capB)
        XCTAssertEqual(vf.signRegionA, "do something")
        // "DO SOMETHING" has no content words → the finding is discarded.
        XCTAssertFalse(JudgeVerdict.compute(findings: [vf]).connected)
    }

    func testPossessiveApostropheCannotOpenSignRegion() {
        let caption = "The mannequins' hands are clasped. A sign reads 'HOLD ON' nearby."
        XCTAssertEqual(JudgeEvidence.quotedRegions(of: caption), ["hold on"])
    }

    func testSameSubjectReversalCarriesProbe() {
        let capA = "To her right, a man in a black shirt and jeans is also wearing a face mask."
        let capB = "Behind her, a man in a black shirt and cap stands with his arms raised."
        let vf = JudgeEvidence.verify(
            finding(.sameSubjectReversal,
                    qA: "a man in a black shirt and jeans is also wearing a face mask",
                    qB: "a man in a black shirt and cap stands with his arms raised"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.connected)
        if case .sameSubjectOpposed = v.probes.first {} else { XCTFail("expected sameSubjectOpposed probe") }
    }

    func testBestFindingWinsAndCategoryIsIgnoredForScoring() {
        let capA = "A man plays a trumpet on the corner. The street is busy."
        let capB = "A woman covers her ears near the loud street. People walk by."
        let strong = JudgeEvidence.verify(
            finding(.sourceReceiver, qA: "plays a trumpet", qB: "covers her ears"),
            captionA: capA, captionB: capB)
        let cat = JudgeEvidence.verify(
            finding(.sharedCategory, qA: "The street is busy", qB: "People walk by", note: "street scenes"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [cat, strong])
        XCTAssertTrue(v.connected)
        XCTAssertEqual(v.relationshipType, "complementary")
        XCTAssertEqual(v.confidence, 0.95, accuracy: 0.001)
    }

    func testRationaleIsBuiltFromQuotesAndCapped() {
        let capA = "A man plays a trumpet on the corner."
        let capB = "A woman covers her ears near the loud street."
        let vf = JudgeEvidence.verify(
            finding(.sourceReceiver, qA: "plays a trumpet", qB: "covers her ears"),
            captionA: capA, captionB: capB)
        let v = JudgeVerdict.compute(findings: [vf])
        XCTAssertTrue(v.rationale.contains("plays a trumpet"))
        XCTAssertTrue(v.rationale.contains("covers her ears"))
        XCTAssertLessThanOrEqual(v.rationale.count, 200)
    }

    func testNoFindingsRejectsCleanly() {
        let v = JudgeVerdict.compute(findings: [])
        XCTAssertFalse(v.connected)
        XCTAssertEqual(v.relationshipType, "none")
    }
}
