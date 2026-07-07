import XCTest
@testable import ConjunctEngine

/// Validates the deterministic join rules reproduce the Phase-0 result on
/// hand-authored fixtures of the 8 golden + bad pairs (decision #102).
final class RoleJoinsTests: XCTestCase {

    // MARK: fixtures (the load-bearing slots of each validated profile)

    func phen(_ ph: String, _ role: String) -> RoleProfile.Phenomenon { .init(phenomenon: ph, role: role) }
    func obj(_ o: String, _ r: String, _ c: String) -> RoleProfile.ObjectRole { .init(object: o, register: r, category: c) }

    lazy var violinist = RoleProfile(subjects: ["man"], phenomena: [phen("sound","source")])
    lazy var ears      = RoleProfile(subjects: ["woman"], phenomena: [phen("sound","receiver")], subverts: ["sound"])
    lazy var gun       = RoleProfile(subjects: ["man"], enacts: ["danger","threat"], objects: [obj("gun","real","weapon")])
    lazy var waterGun  = RoleProfile(subjects: ["girl"], enacts: ["play"], objects: [obj("gun","toy","weapon")])
    lazy var seeSign   = RoleProfile(subjects: ["woman","bus"], claims: ["danger"])
    lazy var smileSign = RoleProfile(subjects: ["woman"], claims: ["smile"])
    lazy var smilingW  = RoleProfile(subjects: ["woman"], enacts: ["smile"])
    lazy var hoop      = RoleProfile(subjects: ["man"], enacts: ["playful"], subverts: ["smile"])
    lazy var pigeons   = RoleProfile(subjects: ["pigeons"], objects: [obj("pigeon","real","bird")])
    lazy var peacock   = RoleProfile(subjects: ["peacock"], objects: [obj("peacock","depicted","bird")])
    // bad pair — no shared role/object/claim
    lazy var badA = RoleProfile(subjects: ["horse"], enacts: ["determination"], objects: [obj("lasso","real","tool")])
    lazy var badB = RoleProfile(subjects: ["tents"], enacts: ["waiting"], objects: [obj("bridge","real","structure")])
    // megaphone speaker — speech source (folds to sound via normalizePhenomenon)
    lazy var megaphone = RoleProfile(subjects: ["man"], phenomena: [phen("speech","source")], enacts: ["address"])
    // passive sound receiver with NO subverts (does not strain) — must NOT fire join 1
    lazy var earsPassive = RoleProfile(subjects: ["woman"], phenomena: [phen("sound","receiver")])
    // danger sign + a neutrally-described real weapon (no enact "danger") — join 4 only
    lazy var dangerSign = RoleProfile(subjects: ["bus"], claims: ["danger"])
    lazy var gunNeutral = RoleProfile(subjects: ["man"], enacts: ["stillness"], objects: [obj("handgun","real","weapon")])

    func testSourceReceiverFiresJoin1() {
        let j = RoleJoins.join(violinist, ears)
        XCTAssertEqual(j?.priority, 1)
        XCTAssertEqual(j?.relationshipType, "complementary")
    }

    func testRealVsToyObjectFiresJoin3() {
        let j = RoleJoins.join(gun, waterGun)
        XCTAssertEqual(j?.priority, 3)
        XCTAssertEqual(j?.relationshipType, "contrastive")
    }

    func testCategoryHypernymMatchesBird() {
        // pigeon vs peacock only connect via shared category "bird"
        let j = RoleJoins.join(pigeons, peacock)
        XCTAssertEqual(j?.priority, 3)
    }

    func testClaimEnactFiresJoin2EvenWhenConceptIsGeneric() {
        // "smile" is frequent (gated), but claims are privileged → still fires.
        let j = RoleJoins.join(smileSign, smilingW)
        XCTAssertEqual(j?.priority, 2)
        XCTAssertEqual(j?.relationshipType, "ironic")
    }

    func testClaimSubvertFiresJoin2() {
        let j = RoleJoins.join(smileSign, hoop)
        XCTAssertEqual(j?.priority, 2)
    }

    func testClaimDangerMatchesEnactDanger() {
        let j = RoleJoins.join(seeSign, gun)
        XCTAssertEqual(j?.priority, 2)
    }

    func testBadPairDoesNotJoin() {
        XCTAssertNil(RoleJoins.join(badA, badB))
    }

    func testGazePhenomenonExcludedFromJoin1() {
        let gazerA = RoleProfile(phenomena: [phen("gaze","source")])
        let gazerB = RoleProfile(phenomena: [phen("gaze","receiver")])
        XCTAssertNil(RoleJoins.join(gazerA, gazerB))
    }

    func testEnactEnactDoesNotJoinInV1() {
        // The enact↔enact (tonal) path is disabled in v1 (no golden recall, judge
        // false-positives, Mode-3 out of scope). Two images sharing only an enact
        // must not join. See decision #102.
        let a = RoleProfile(enacts: ["celebration"])
        let b = RoleProfile(enacts: ["celebration"])
        XCTAssertNil(RoleJoins.join(a, b))
    }

    func testGenericConceptsThreshold() {
        // Rarity-gate infrastructure retained for the future tonal join.
        var profiles = [RoleProfile](repeating: RoleProfile(enacts: ["common"]), count: 9)
        profiles.append(RoleProfile(enacts: ["common","rare"]))
        let g = RoleJoins.genericConcepts(profiles, threshold: 0.10)
        XCTAssertTrue(g.contains("common"))
        XCTAssertFalse(g.contains("rare"))
    }

    func testPriorityOrderingSourceReceiverBeatsObject() {
        // A pair that satisfies both join 1 and join 3 should report join 1.
        // Receiver strains (subverts non-empty) so join 1 is eligible under #113.
        let a = RoleProfile(phenomena: [phen("sound","source")], objects: [obj("gun","real","weapon")])
        let b = RoleProfile(phenomena: [phen("sound","receiver")], subverts: ["sound"], objects: [obj("gun","toy","weapon")])
        XCTAssertEqual(RoleJoins.join(a, b)?.priority, 1)
    }

    // MARK: cap-redesign additions (decision #113)

    func testSpeechSourceCompletesSoundReceiverViaTaxonomy() {
        // A megaphone speaker (speech:source) should complete a straining sound:receiver
        // because speech is a kind of sound (normalizePhenomenon). G16.
        XCTAssertEqual(RoleJoins.join(megaphone, ears)?.priority, 1)
    }

    func testJoin1RequiresStrainingReceiver() {
        // A passive receiver (no subverts) must NOT fire join 1 — this sparsifies the
        // dense sound graph so the cap keeps genuine pairs.
        XCTAssertNil(RoleJoins.join(violinist, earsPassive))
    }

    func testClaimObjectFiresJoin4() {
        // "danger" sign + a real weapon (no shared object, no enact "danger") → join 4.
        let j = RoleJoins.join(dangerSign, gunNeutral)
        XCTAssertEqual(j?.priority, 4)
        XCTAssertEqual(j?.relationshipType, "ironic")
    }

    func testJoin2StillBeatsJoin4WhenEnactMatches() {
        // The classic gun with enact "danger" matches the claim via join 2 (precedes 4).
        XCTAssertEqual(RoleJoins.join(seeSign, gun)?.priority, 2)
    }

    func testSpecificityIsSetWhenFreqProvided() {
        // A rarer phenomenon outranks a common one by specificity.
        let common = RoleJoins.CorpusFreq(phenomenon: ["sound": 90], concept: [:], objectNoun: [:], category: [:], total: 100)
        let s = RoleJoins.join(violinist, ears, freq: common)?.specificity ?? 0
        XCTAssertGreaterThan(s, 0)
    }

    // MARK: join-2 synonym bridge (decision #116)

    lazy var missSign     = RoleProfile(subjects: ["woman"], claims: ["miss"])
    lazy var handHolding  = RoleProfile(subjects: ["mannequin","mannequin"], enacts: ["hold hands", "tenderness"])
    lazy var missRodeo    = RoleProfile(subjects: ["woman"], claims: ["Miss Rodeo"])

    func testBridgeConnectsMissClaimToTendernessEmbodiment() {
        // G14: raw token match alone can't bridge "miss" to "hold hands"/"tenderness".
        let j = RoleJoins.join(missSign, handHolding)
        XCTAssertEqual(j?.priority, 2)
        XCTAssertEqual(j?.relationshipType, "ironic")
    }

    func testBridgeDoesNotFireOnSubstringWithinLongerClaim() {
        // "Miss Rodeo" is a pageant-sash title, not the longing claim "miss" — the
        // bridge must match on the whole claim string, not a token contained in it.
        XCTAssertNil(RoleJoins.join(missRodeo, handHolding))
    }
}
