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

    let empty: Set<String> = []

    func testSourceReceiverFiresJoin1() {
        let j = RoleJoins.join(violinist, ears, generic: empty)
        XCTAssertEqual(j?.priority, 1)
        XCTAssertEqual(j?.relationshipType, "complementary")
    }

    func testRealVsToyObjectFiresJoin3() {
        let j = RoleJoins.join(gun, waterGun, generic: empty)
        XCTAssertEqual(j?.priority, 3)
        XCTAssertEqual(j?.relationshipType, "contrastive")
    }

    func testCategoryHypernymMatchesBird() {
        // pigeon vs peacock only connect via shared category "bird"
        let j = RoleJoins.join(pigeons, peacock, generic: empty)
        XCTAssertEqual(j?.priority, 3)
    }

    func testClaimEnactFiresJoin2EvenWhenConceptIsGeneric() {
        // "smile" is frequent (gated), but claims are privileged → still fires.
        let j = RoleJoins.join(smileSign, smilingW, generic: ["smile"])
        XCTAssertEqual(j?.priority, 2)
        XCTAssertEqual(j?.relationshipType, "ironic")
    }

    func testClaimSubvertFiresJoin2() {
        let j = RoleJoins.join(smileSign, hoop, generic: ["smile"])
        XCTAssertEqual(j?.priority, 2)
    }

    func testClaimDangerMatchesEnactDanger() {
        let j = RoleJoins.join(seeSign, gun, generic: empty)
        XCTAssertEqual(j?.priority, 2)
    }

    func testBadPairDoesNotJoin() {
        XCTAssertNil(RoleJoins.join(badA, badB, generic: empty))
    }

    func testGazePhenomenonExcludedFromJoin1() {
        let gazerA = RoleProfile(phenomena: [phen("gaze","source")])
        let gazerB = RoleProfile(phenomena: [phen("gaze","receiver")])
        XCTAssertNil(RoleJoins.join(gazerA, gazerB, generic: empty))
    }

    func testEnactEnactGatedByGenericConcept() {
        let a = RoleProfile(enacts: ["celebration"])
        let b = RoleProfile(enacts: ["celebration"])
        XCTAssertEqual(RoleJoins.join(a, b, generic: empty)?.priority, 2)      // discriminating → fires
        XCTAssertNil(RoleJoins.join(a, b, generic: ["celebration"]))           // gated → no fire
    }

    func testGenericConceptsThreshold() {
        // "common" in all 10 profiles (>10%) → generic; "rare" in 1 → not.
        var profiles = [RoleProfile](repeating: RoleProfile(enacts: ["common"]), count: 9)
        profiles.append(RoleProfile(enacts: ["common","rare"]))
        let g = RoleJoins.genericConcepts(profiles, threshold: 0.10)
        XCTAssertTrue(g.contains("common"))
        XCTAssertFalse(g.contains("rare"))
    }

    func testPriorityOrderingSourceReceiverBeatsObject() {
        // A pair that satisfies both join 1 and join 3 should report join 1.
        let a = RoleProfile(phenomena: [phen("sound","source")], objects: [obj("gun","real","weapon")])
        let b = RoleProfile(phenomena: [phen("sound","receiver")], objects: [obj("gun","toy","weapon")])
        XCTAssertEqual(RoleJoins.join(a, b, generic: empty)?.priority, 1)
    }
}
