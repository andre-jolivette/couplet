import Foundation

/// Deterministic, pure join rules over per-image `RoleProfile`s (decision #102).
/// These pair profiles into candidate connections that the four-pool topK never
/// surfaces — the entry-gate mechanism for backlog #95. Recall-oriented by design;
/// the LLM validation judge (`ThematicScorerV2.validate`) is the precision backstop.
///
/// Joins kept: 1 (source/receiver), 2 (claim/enact-subvert), 3 (object real-vs-alt
/// with category whitelist), 4 (claim↔present-object). Joins 5 (stance) deferred.
///
/// Cap redesign (decision #113): each join now reports a `specificity` (corpus rarity
/// of the matched key) so `generateRoleCandidates` can admit candidates *globally
/// best-first* under a per-join-type cap, instead of the old first-come-by-id cap that
/// arbitrarily dropped meaningful pairs and silently evicted working ones on any rule
/// change. Join 1 additionally (a) treats speech/music as `sound` (`normalizePhenomenon`,
/// G16) and (b) fires only when the RECEIVER actively strains/blocks (non-empty
/// `subverts`) — this sparsifies the otherwise near-complete `sound` graph so the cap
/// keeps genuine pairs. See KNOWN_GOOD_PAIRS.md (join-side findings).
public enum RoleJoins {

    /// A proposed connection between two images, fed to the validation judge.
    public struct Candidate: Sendable, Equatable {
        /// 1 = source/receiver, 2 = claim/enact, 3 = object real-vs-alt, 4 = claim↔object. Lower wins.
        public let priority: Int
        /// Suggested type (judge re-derives): complementary / ironic / tonal / contrastive.
        public let relationshipType: String
        /// Human-readable basis, stored in `pairs.rationale` and given to the judge.
        public let hypothesis: String
        /// Corpus rarity of the matched key (IDF-style): higher = more discriminating →
        /// admitted first under the per-type cap. 0 when no `CorpusFreq` was supplied.
        public let specificity: Double
        public init(priority: Int, relationshipType: String, hypothesis: String, specificity: Double = 0) {
            self.priority = priority; self.relationshipType = relationshipType
            self.hypothesis = hypothesis; self.specificity = specificity
        }
    }

    /// Corpus document-frequencies used to score a match's specificity (cap redesign,
    /// decision #113). Built once over all profiles; `spec` is IDF-style so a rarer
    /// matched key (e.g. phenomenon "touch", claim "escape") outranks a common one
    /// ("sound", "smile") when the per-type cap forces a choice.
    public struct CorpusFreq: Sendable {
        public let phenomenon: [String: Int]
        public let concept: [String: Int]
        public let objectNoun: [String: Int]
        public let category: [String: Int]
        public let total: Int

        public init(phenomenon: [String: Int], concept: [String: Int],
                    objectNoun: [String: Int], category: [String: Int], total: Int) {
            self.phenomenon = phenomenon; self.concept = concept
            self.objectNoun = objectNoun; self.category = category; self.total = total
        }

        func spec(_ table: [String: Int], _ key: String) -> Double {
            Foundation.log(Double(total + 1) / Double((table[key] ?? 0) + 1))
        }

        /// One-pass build over every profile (matches the harness; phenomena are
        /// taxonomy-normalised so speech/music fold into the `sound` frequency).
        public static func build(_ profiles: [RoleProfile]) -> CorpusFreq {
            var phen = [String: Int](), concept = [String: Int]()
            var noun = [String: Int](), cat = [String: Int]()
            for p in profiles {
                var ph = Set<String>()
                for x in p.phenomena { ph.insert(normalizePhenomenon(x.phenomenon)) }
                for x in ph { phen[x, default: 0] += 1 }
                var cs = Set<String>()
                for c in p.claims + p.enacts + p.subverts { cs.formUnion(tokens(c)) }
                for x in cs { concept[x, default: 0] += 1 }
                for o in p.objects {
                    if !o.object.isEmpty { noun[o.object.lowercased(), default: 0] += 1 }
                    if !o.category.isEmpty { cat[o.category.lowercased(), default: 0] += 1 }
                }
            }
            return CorpusFreq(phenomenon: phen, concept: concept,
                              objectNoun: noun, category: cat, total: profiles.count)
        }
    }

    // MARK: Tokenisation (mirrors the validated harness)

    static let stop: Set<String> = [
        "a","an","the","of","to","and","or","in","on","at","with","her","his",
        "their","for","is","are","this","that","you","see"
    ]

    static let categoryWhitelist: Set<String> = [
        "weapon","bird","animal","vehicle","instrument","food","tool","sign"
    ]

    /// Claim concept → object category, for join 4 (a sign warns of / names a thing that
    /// is physically present in the other frame: "danger"/"shoot" ↔ a real weapon).
    static let claimToCategory: [String: String] = [
        "danger": "weapon", "threat": "weapon", "shoot": "weapon",
        "weapon": "weapon", "gun": "weapon"
    ]

    /// Small curated claim → embodiment/subversion concept bridge for join 2 (decision
    /// #116). Raw token matching (`rawMatch`) misses pairs that are semantically linked
    /// but lexically disjoint — a claim "miss" against enacted `['hold hands',
    /// 'tenderness']` (G14). This is intentionally NOT a general synonym/thesaurus
    /// system: it is sized exactly to concept pairs evidenced in KNOWN_GOOD_PAIRS.md,
    /// one-directional (claim key → embodiment concept, never the reverse), so it
    /// cannot silently widen beyond an audited list. Matched on the WHOLE claim/
    /// embodiment string (exact, case-insensitive) rather than `tokens()` overlap —
    /// harness testing found token-level matching false-fires on a claim that merely
    /// *contains* the bridge word as one part of a longer phrase (a "Miss Rodeo" sash
    /// claim spuriously bridged to an unrelated "tenderness" embodiment via the shared
    /// "miss" token). A prior attempt at a broader smile↔speak bridge (for G8) was
    /// found, offline, to flood the "smile" claim's cap-8 window without even getting
    /// G8 admitted (598 still loses the cap-8 race) — omitted; do not re-add it
    /// without re-running that eviction/flood check against KNOWN_GOOD_PAIRS.md.
    static let claimEmbodimentBridge: [String: Set<String>] = [
        // "hold hands" added in #125: extraction's `tenderness` affect emission for the
        // G14 mannequins proved hypersensitive to unrelated prompt additions (any sign-
        // register clause dropped it), while the literal `hold hands` enact survives
        // every prompt variant — anchor the bridge on the robust emission.
        "miss": ["tenderness", "hold hands"],
    ]

    /// Directional bridge check for join 2 only: does the WHOLE `claim` string
    /// (exact, case-insensitive) map via the curated table above to the WHOLE
    /// `embodiment` (enact/subvert) string? Deliberately not token-level — see the
    /// table's doc comment.
    static func bridgeMatch(_ claim: String, _ embodiment: String) -> Bool {
        guard let bridged = claimEmbodimentBridge[claim.lowercased()] else { return false }
        return bridged.contains(embodiment.lowercased())
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Speech and music are kinds of sound: a speaker/megaphone/instrument is also a
    /// `sound` source, so it can complete a `sound` receiver (decision #113, G16).
    static func normalizePhenomenon(_ ph: String) -> String {
        (ph == "speech" || ph == "music") ? "sound" : ph
    }

    /// Concepts that appear in >`threshold` fraction of profiles (in claims/enacts/
    /// subverts) are non-discriminating. Retained for the future tonal join (disabled).
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

    /// Returns the highest-priority connection between `a` and `b`, or nil. When `freq`
    /// is supplied the returned `Candidate.specificity` is set so the caller can rank
    /// candidates for admission; without it specificity is 0 (fine for unit fixtures).
    public static func join(_ a: RoleProfile, _ b: RoleProfile, freq: CorpusFreq? = nil) -> Candidate? {
        func rawMatch(_ x: String, _ y: String) -> Bool { !tokens(x).isDisjoint(with: tokens(y)) }

        // ── Join 1: source ↔ receiver of the same phenomenon ──
        // Gaze excluded; speech/music folded into sound; the RECEIVER must actively
        // strain/block (non-empty subverts) to sparsify the dense sound graph (#113).
        let pb = Set(b.phenomena.map { [normalizePhenomenon($0.phenomenon), $0.role] })
        let aStrains = !a.subverts.isEmpty, bStrains = !b.subverts.isEmpty
        for p in a.phenomena {
            let ph = normalizePhenomenon(p.phenomenon)
            if ph == "gaze" { continue }
            let asSource = p.role == "source" && pb.contains([ph, "receiver"]) && bStrains
            let asReceiver = p.role == "receiver" && pb.contains([ph, "source"]) && aStrains
            if asSource || asReceiver {
                let s = freq.map { $0.spec($0.phenomenon, ph) } ?? 0
                return Candidate(priority: 1, relationshipType: "complementary",
                    hypothesis: "complementary: one image is the SOURCE of \(ph) — it is produced there — while the other shows \(ph) being RECEIVED or physically blocked",
                    specificity: s)
            }
        }

        // ── Join 2: claim ↔ enact/subvert (claims NOT frequency-gated) ──
        func claimSpec(_ claim: String) -> Double {
            freq.map { f in tokens(claim).map { f.spec(f.concept, $0) }.max() ?? 0 } ?? 0
        }
        for ca in a.claims {
            for cb in b.enacts + b.subverts where rawMatch(ca, cb) || bridgeMatch(ca, cb) {
                return Candidate(priority: 2, relationshipType: "ironic",
                    hypothesis: "ironic: a sign or text announces or demands ‘\(ca)’, while the other image's subject literally embodies or contradicts that very idea",
                    specificity: claimSpec(ca))
            }
        }
        for ca in b.claims {
            for cb in a.enacts + a.subverts where rawMatch(ca, cb) || bridgeMatch(ca, cb) {
                return Candidate(priority: 2, relationshipType: "ironic",
                    hypothesis: "ironic: a sign or text announces or demands ‘\(ca)’, while the other image's subject literally embodies or contradicts that very idea",
                    specificity: claimSpec(ca))
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
                    let s = freq.map { f -> Double in
                        nounMatch ? f.spec(f.objectNoun, oa.object.lowercased())
                                  : f.spec(f.category, oa.category.lowercased())
                    } ?? 0
                    return Candidate(priority: 3, relationshipType: "contrastive",
                        hypothesis: "contrastive: the same kind of thing — a \(oa.object) — appears REAL in one image and as a \(altReg) version in the other, one earnest and one play or representation",
                        specificity: s)
                }
            }
        }

        // ── Join 4: claim ↔ a present object the claim warns of / names ──
        // A sign about danger paired with the real thing it warns about (decision #113).
        // Lower precedence than the register-contrast join 3.
        if let c = claimObjectJoin(a, b, freq: freq) ?? claimObjectJoin(b, a, freq: freq) {
            return c
        }

        return nil
    }

    /// One-directional claim↔object match: a claim in `x` that names (by category map or
    /// shared noun token) an object physically present in `y`.
    private static func claimObjectJoin(_ x: RoleProfile, _ y: RoleProfile, freq: CorpusFreq?) -> Candidate? {
        for ca in x.claims {
            let ct = tokens(ca)
            let wantCats = Set(ct.compactMap { claimToCategory[$0] })
            for o in y.objects {
                let cat = o.category.lowercased(), noun = o.object.lowercased()
                let catHit = !cat.isEmpty && wantCats.contains(cat)
                let nounHit = !noun.isEmpty && !ct.isDisjoint(with: tokens(noun))
                if catHit || nounHit {
                    let s = freq.map { f -> Double in
                        !cat.isEmpty ? f.spec(f.category, cat) : f.spec(f.objectNoun, noun)
                    } ?? 0
                    return Candidate(priority: 4, relationshipType: "ironic",
                        hypothesis: "ironic: a sign or text warns of or names ‘\(ca)’, while the other image shows the real \(o.object) — the very thing the warning is about",
                        specificity: s)
                }
            }
        }
        return nil
    }
}
