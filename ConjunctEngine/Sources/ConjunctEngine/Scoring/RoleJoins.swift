import Foundation

/// Deterministic, pure join rules over per-image `RoleProfile`s (decision #102).
/// These pair profiles into candidate connections that the four-pool topK never
/// surfaces — the entry-gate mechanism for backlog #95. Recall-oriented by design;
/// the LLM validation judge (`ThematicScorerV2.validate`) is the precision backstop.
///
/// Configuration is the validated Phase-0 outcome (golden recall 6/8, 0/3 bad,
/// 2,914 candidates at cap 4): keep joins 1 (source/receiver), 2 (claim/enact),
/// 3 (object real-vs-alt with category whitelist); drop joins 4 (attention→target)
/// and 5 (stance) for v1 — they carried no golden recall and most of the flood.
public enum RoleJoins {

    /// A proposed connection between two images, fed to the validation judge.
    public struct Candidate: Sendable, Equatable {
        /// 1 = source/receiver, 2 = claim/enact, 3 = object real-vs-alt. Lower wins.
        public let priority: Int
        /// Suggested type (judge re-derives): complementary / ironic / tonal / contrastive.
        public let relationshipType: String
        /// Human-readable basis, stored in `pairs.rationale` and given to the judge.
        public let hypothesis: String
    }

    // MARK: Tokenisation (mirrors the validated harness)

    static let stop: Set<String> = [
        "a","an","the","of","to","and","or","in","on","at","with","her","his",
        "their","for","is","are","this","that","you","see"
    ]

    static let categoryWhitelist: Set<String> = [
        "weapon","bird","animal","vehicle","instrument","food","tool","sign"
    ]

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Concepts that appear in >`threshold` fraction of profiles (in claims/enacts/
    /// subverts) are non-discriminating — they cause join-2 flood. Used to gate
    /// enact↔enact matches (claims are exempt: a sign is an intentional signal).
    public static func genericConcepts(_ profiles: [RoleProfile], threshold: Double = 0.10) -> Set<String> {
        guard !profiles.isEmpty else { return [] }
        var docfreq: [String: Int] = [:]
        for p in profiles {
            var seen = Set<String>()
            for c in p.claims + p.enacts + p.subverts { seen.formUnion(tokens(c)) }
            for w in seen { docfreq[w, default: 0] += 1 }
        }
        let cutoff = threshold * Double(profiles.count)
        return Set(docfreq.filter { Double($0.value) > cutoff }.keys)
    }

    // MARK: Join

    /// Returns the highest-priority connection between `a` and `b`, or nil.
    /// `generic` (the corpus rarity-gate set, see `genericConcepts`) is reserved for the
    /// enact↔enact tonal join, disabled in v1 — kept in the signature for that future.
    public static func join(_ a: RoleProfile, _ b: RoleProfile, generic: Set<String> = []) -> Candidate? {
        _ = generic
        func rawMatch(_ x: String, _ y: String) -> Bool { !tokens(x).isDisjoint(with: tokens(y)) }

        // ── Join 1: source ↔ receiver of the same phenomenon (gaze excluded) ──
        let pb = Set(b.phenomena.map { [$0.phenomenon, $0.role] })
        func bHas(_ ph: String, _ role: String) -> Bool { pb.contains([ph, role]) }
        for p in a.phenomena where p.phenomenon != "gaze" {
            if (p.role == "source" && bHas(p.phenomenon, "receiver"))
                || (p.role == "receiver" && bHas(p.phenomenon, "source")) {
                return Candidate(priority: 1, relationshipType: "complementary",
                    hypothesis: "complementary: one image is the SOURCE of \(p.phenomenon) — it is produced there — while the other shows \(p.phenomenon) being RECEIVED or physically blocked")
            }
        }

        // ── Join 2: claim ↔ enact/subvert (claims NOT frequency-gated) ──
        // Only the claim-based path is kept. The enact↔enact ("tonal") path carried
        // zero golden recall, produced most of the join-2 flood, and yielded judge
        // false-positives on shared abstract moods — and ambient-tonal pairing
        // (Mode 3) is out of scope. See decision #102 / PAIRING_THEORY.
        for ca in a.claims {
            for cb in b.enacts + b.subverts where rawMatch(ca, cb) {
                return Candidate(priority: 2, relationshipType: "ironic",
                    hypothesis: "ironic: a sign or text announces or demands ‘\(ca)’, while the other image's subject literally embodies or contradicts that very idea")
            }
        }
        for ca in b.claims {
            for cb in a.enacts + a.subverts where rawMatch(ca, cb) {
                return Candidate(priority: 2, relationshipType: "ironic",
                    hypothesis: "ironic: a sign or text announces or demands ‘\(ca)’, while the other image's subject literally embodies or contradicts that very idea")
            }
        }

        // ── Join 3: same object, opposite register (noun match or whitelisted category) ──
        let alt: Set<String> = ["toy","depicted","costume"]
        for oa in a.objects {
            for ob in b.objects {
                let nounMatch = !oa.object.isEmpty && oa.object.lowercased() == ob.object.lowercased()
                let catMatch = !oa.category.isEmpty
                    && oa.category.lowercased() == ob.category.lowercased()
                    && categoryWhitelist.contains(oa.category.lowercased())
                let regs = Set([oa.register.lowercased(), ob.register.lowercased()])
                if (nounMatch || catMatch) && oa.register.lowercased() != ob.register.lowercased()
                    && !regs.isDisjoint(with: alt) && regs.contains("real") {
                    let altReg = alt.intersection(regs).first ?? "depicted"
                    return Candidate(priority: 3, relationshipType: "contrastive",
                        hypothesis: "contrastive: the same kind of thing — a \(oa.object) — appears REAL in one image and as a \(altReg) version in the other, one earnest and one play or representation")
                }
            }
        }

        return nil
    }
}
