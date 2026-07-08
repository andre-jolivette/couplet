import Foundation
import ConjunctEngine

// #96 passes 1–3 — per-cluster relationshipType distribution + rationale mining
//                   + cluster blind-spot analysis (2c strict, 2d specificity-corrected)
//                   + all-pairs axis-bonus-suppression scoring-guard check
//                   + pass 3: caption-first vocabulary discovery (unigram/bigram/
//                   trigram leftover mining + enrichment checks + a keyword-
//                   reachability bug audit, independent of pairing/judging).
//
// Read-only: reuses ConceptClusters.matchedClusters/weights/axisPairs/all directly
// (no reimplementation of the matcher). The one local COPY of tokenize/stem below is
// only for keyword ATTRIBUTION / phrase-building and is self-validated against the
// real matchedClusters.
//
// Not wired into the ConjunctEngine build. To run: create a throwaway SPM executable
// target depending on ConjunctEngine by local path (same headless-driver pattern as
// ConjunctBench / #117's bench117), drop this file in as its main.swift,
// `swift build -c release`, then run:
//     ClusterDiag <judged_pairs.json> <corpus_captions.json>
// Both JSON inputs come from 96-cluster-relationship-distribution-query.sql run against
// a COPY of the production DB. (Pass 2d's step-(e) axis-suppression pass is O(n^2) over
// corpus images — ~528k pairs, a few seconds in a release build.)
//
// argv[1] = judged_pairs.json (every judged pair, both captions + rationale)
// argv[2] = corpus_captions.json (all active-captioned images — corpus firing)
// See DECISIONS.md #96 (passes 1–3) for the full write-up.

struct JudgedPair: Decodable {
    let pairID: Int
    let imageAID: Int
    let imageBID: Int
    let score: Double?
    let relType: String?
    let rationale: String?
    let roleHyp: String?
    let captionA: String?
    let captionB: String?
    let filenameA: String
    let filenameB: String
}

struct CorpusImage: Decodable {
    let id: Int
    let isHero: Int
    let filename: String
    let caption: String?
}

let args = CommandLine.arguments
guard args.count > 2 else {
    print("Usage: ClusterDiag <judged_pairs.json> <corpus_captions.json>")
    exit(1)
}

let pairs = try! JSONDecoder().decode([JudgedPair].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let corpus = try! JSONDecoder().decode([CorpusImage].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

func meaningful(_ c: String) -> Bool { (ConceptClusters.weights[c] ?? 0) >= 0.75 }

// ── Local COPY of ConceptClusters.tokenize/stem (internal in the engine, so not
//    importable) purely for keyword ATTRIBUTION — which keyword triggered a fire.
//    NOT used for the finding's matching (that uses the real matchedClusters).
//    Self-validated below: localMatched == real matchedClusters on all captions. ──
func localStem(_ word: String) -> String {
    var w = word
    let suffixes = ["ation","tion","ance","ence","ness","ment","able","ible","ing","ity","ies","ed","er","al","ly","ful","es","s"]
    for suffix in suffixes where w.hasSuffix(suffix) && w.count > suffix.count + 3 {
        w = String(w.dropLast(suffix.count)); break
    }
    return w
}
let localStop: Set<String> = ["the","a","an","is","are","in","on","at","and","or","of","to","with","by","for","their","his","her","they","he","she","it","this","that","there","has","have","from","what","who","which","when","where","while","been","being","was","were","will","would","could","should","may","might","both","each","such","some","more"]
func localTokens(_ text: String) -> Set<String> {
    Set(text.lowercased().components(separatedBy: .alphanumerics.inverted)
        .filter { $0.count > 2 && !localStop.contains($0) }
        .map { localStem($0) })
}
func localMatched(_ caption: String) -> Set<String> {
    let ws = localTokens(caption)
    var out = Set<String>()
    for cl in ConceptClusters.all {
        if let groups = cl.requiredGroups {
            if groups.allSatisfy({ !ws.isDisjoint(with: $0) }) { out.insert(cl.name) }
        } else if !ws.isDisjoint(with: cl.keywords) { out.insert(cl.name) }
    }
    return out
}
func sharedTriggerKeywords(_ cluster: String, _ capA: String, _ capB: String) -> [String] {
    guard let cl = ConceptClusters.all.first(where: { $0.name == cluster }) else { return [] }
    let tA = localTokens(capA), tB = localTokens(capB)
    // keywords present in BOTH captions (the shared trigger, since meaningfulShared = intersection)
    return cl.keywords.filter { tA.contains($0) && tB.contains($0) }.sorted()
}

// ── PART A: full-corpus image-level firing for the four #15 two-signal clusters ──
let fifteenClusters = ["uncanny_ordinary", "economic_precarity", "solitude_in_crowd", "domestic_intimacy"]
// also report a couple of reference clusters for scale
let refClusters = ["sound_music", "ritual_ceremony", "transformation_change", "tenderness_care", "bodily_gesture"]

// Self-validation: local matcher must reproduce the real one exactly.
var mismatches = 0
for img in corpus {
    guard let cap = img.caption else { continue }
    if localMatched(cap) != ConceptClusters.matchedClusters(for: cap) { mismatches += 1 }
}
print("Local-matcher self-validation vs ConceptClusters.matchedClusters: \(mismatches) mismatch(es) over \(corpus.count) captions")

print("=== PART A: full-corpus image-level cluster firing ===")
print("Corpus images (active, captioned): \(corpus.count)  [hero=\(corpus.filter{$0.isHero==1}.count)]")
var corpusFire: [String: Int] = [:]
var corpusFireHero: [String: Int] = [:]
for img in corpus {
    guard let cap = img.caption else { continue }
    let matched = ConceptClusters.matchedClusters(for: cap)
    for cl in fifteenClusters + refClusters where matched.contains(cl) {
        corpusFire[cl, default: 0] += 1
        if img.isHero == 1 { corpusFireHero[cl, default: 0] += 1 }
    }
}
print("cluster,corpus_images_firing,hero_images_firing,pct_of_corpus")
for cl in fifteenClusters + refClusters {
    let n = corpusFire[cl] ?? 0
    let h = corpusFireHero[cl] ?? 0
    print("\(cl),\(n),\(h),\(String(format: "%.1f%%", 100.0*Double(n)/Double(corpus.count)))")
}

// Corpus-wide per-keyword attribution: for single-signal clusters, which keyword
// triggers the match, across all firing images. Reveals over-broad vocabulary at source.
print("\n--- corpus-wide per-keyword trigger frequency (single-signal clusters) ---")
for cl in ["sound_music", "ritual_ceremony", "transformation_change"] {
    guard let cluster = ConceptClusters.all.first(where: { $0.name == cl }), cluster.requiredGroups == nil else { continue }
    var kw: [String: Int] = [:]
    for img in corpus {
        guard let cap = img.caption else { continue }
        let toks = localTokens(cap)
        let hit = cluster.keywords.filter { toks.contains($0) }
        for k in hit { kw[k, default: 0] += 1 }
    }
    let sorted = kw.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
    print("\(cl): \(sorted)")
}

// ── Build analyzed pairs (same definitions as pass 1) ──
struct Analyzed {
    let pair: JudgedPair
    let isRole: Bool
    let relType: String
    let firing: Set<String>       // meaningfulShared ∪ axis-participant
    let meaningfulShared: Set<String>
    let clustersA: Set<String>    // full matched set, image A
    let clustersB: Set<String>    // full matched set, image B
    let meaningfulOnlyA: Set<String>
    let meaningfulOnlyB: Set<String>
}
var analyzed: [Analyzed] = []
for p in pairs {
    guard let a = p.captionA, let b = p.captionB, !a.isEmpty, !b.isEmpty else { continue }
    let cA = ConceptClusters.matchedClusters(for: a)
    let cB = ConceptClusters.matchedClusters(for: b)
    let shared = cA.intersection(cB)
    let mShared = shared.filter(meaningful)
    let mOnlyA = cA.subtracting(cB).filter(meaningful)
    let mOnlyB = cB.subtracting(cA).filter(meaningful)
    var fire = Set(mShared)
    for axis in ConceptClusters.axisPairs {
        let fires = (cA.contains(axis.a) && cB.contains(axis.b)) || (cA.contains(axis.b) && cB.contains(axis.a))
        if fires { fire.insert(axis.a); fire.insert(axis.b) }
    }
    analyzed.append(Analyzed(pair: p, isRole: p.roleHyp != nil, relType: p.relType ?? "none",
                             firing: fire, meaningfulShared: mShared,
                             clustersA: cA, clustersB: cB,
                             meaningfulOnlyA: mOnlyA, meaningfulOnlyB: mOnlyB))
}
let nonRole = analyzed.filter { !$0.isRole }
print("\nNon-role analyzed: \(nonRole.count)  Role: \(analyzed.count - nonRole.count)")

// ── BUCKET 1: over-broad vocabulary (sound_music / ritual_ceremony / transformation_change, relType=none) ──
let bucket1Clusters = ["sound_music", "ritual_ceremony", "transformation_change"]
print("\n\n=== BUCKET 1: non-role + fired {sound_music|ritual_ceremony|transformation_change} meaningfully + relType=none ===")
var b1seen = Set<Int>()
var b1byCluster: [String: Int] = [:]
for cl in bucket1Clusters {
    let hits = nonRole.filter { $0.firing.contains(cl) && $0.relType == "none" }
    b1byCluster[cl] = hits.count
    for h in hits { b1seen.insert(h.pair.pairID) }
}
print("per-cluster none counts: \(b1byCluster)  | distinct pairs (dedup overlap): \(b1seen.count)")
// keyword attribution: for each bucket-1 cluster, which keyword is the shared trigger
print("\n--- shared-trigger keyword frequency across the none-pairs (what makes the cluster fire on BOTH captions) ---")
for cl in bucket1Clusters {
    var kw: [String: Int] = [:]
    let hits = nonRole.filter { $0.firing.contains(cl) && $0.relType == "none" }
    for h in hits {
        for k in sharedTriggerKeywords(cl, h.pair.captionA ?? "", h.pair.captionB ?? "") { kw[k, default: 0] += 1 }
    }
    let sorted = kw.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
    print("\(cl) (n=\(hits.count)): \(sorted)")
}
// sound_music firing mechanism split: shared-cluster (both captions) vs axis-pair (sound↔sensory)
do {
    let hits = nonRole.filter { $0.firing.contains("sound_music") && $0.relType == "none" }
    var viaShared = 0, viaAxisOnly = 0
    for h in hits {
        let cA = ConceptClusters.matchedClusters(for: h.pair.captionA ?? "")
        let cB = ConceptClusters.matchedClusters(for: h.pair.captionB ?? "")
        if cA.contains("sound_music") && cB.contains("sound_music") { viaShared += 1 }
        else { viaAxisOnly += 1 }
    }
    print("sound_music none-pairs (n=\(hits.count)): both-share sound_music=\(viaShared), only via sound↔sensory axis=\(viaAxisOnly)")
}

// dump all distinct pairs, tagged with which of the three fired
let b1pairs = nonRole.filter { $0.relType == "none" && !$0.firing.isDisjoint(with: Set(bucket1Clusters)) }
    .sorted { $0.pair.pairID < $1.pair.pairID }
for h in b1pairs {
    let which = bucket1Clusters.filter { h.firing.contains($0) }.joined(separator: "+")
    print("\n--- pair \(h.pair.pairID) [\(which)] score=\(h.pair.score ?? -1) fired=\(h.firing.sorted())")
    print("  A(\(h.pair.filenameA)): \(h.pair.captionA ?? "")")
    print("  B(\(h.pair.filenameB)): \(h.pair.captionB ?? "")")
    print("  RATIONALE: \(h.pair.rationale ?? "")")
}

// ── BUCKET 1 TAIL: weak-tail clusters, read the RARE non-none rationales ──
let tailClusters = ["tenderness_care", "stillness_rest", "confinement_freedom", "isolation_solitude", "sensory_overwhelm"]
print("\n\n=== BUCKET 1 TAIL: non-role non-none rationales for weak-tail clusters ===")
for cl in tailClusters {
    let nonNone = nonRole.filter { $0.firing.contains(cl) && $0.relType != "none" }
    let total = nonRole.filter { $0.firing.contains(cl) }.count
    print("\n### \(cl): \(nonNone.count) non-none of \(total) fired")
    for h in nonNone.sorted(by: { $0.pair.pairID < $1.pair.pairID }) {
        print("  [\(h.relType) \(h.pair.score ?? -1)] pair \(h.pair.pairID) fired=\(h.firing.sorted())")
        print("     A(\(h.pair.filenameA)): \((h.pair.captionA ?? "").prefix(200))")
        print("     B(\(h.pair.filenameB)): \((h.pair.captionB ?? "").prefix(200))")
        print("     RATIONALE: \(h.pair.rationale ?? "")")
    }
}

// ── BUCKET 2: recurring relational phrases (non-role, relational, score>=0.80) ──
let relationalTypes: Set<String> = ["complementary", "contrastive", "ironic", "tonal"]
let bucket2 = nonRole.filter { relationalTypes.contains($0.relType) && ($0.pair.score ?? 0) >= 0.80 }
    .sorted { ($0.pair.score ?? 0) > ($1.pair.score ?? 0) }
print("\n\n=== BUCKET 2: non-role relational (comp/contrast/ironic/tonal) score>=0.80 — n=\(bucket2.count) ===")
for h in bucket2 {
    print("\n--- pair \(h.pair.pairID) [\(h.relType) \(h.pair.score ?? -1)] fired=\(h.firing.sorted()) mShared=\(h.meaningfulShared.sorted())")
    print("  A(\(h.pair.filenameA)): \(h.pair.captionA ?? "")")
    print("  B(\(h.pair.filenameB)): \(h.pair.captionB ?? "")")
    print("  RATIONALE: \(h.pair.rationale ?? "")")
}

// ── Golden-pair inclusion check for bucket 2 threshold ──
print("\n\n=== GOLDEN PAIR bucket-2 threshold check (G4/G6/G7/G16 by filename) ===")
let golden: [(String, [String])] = [
    ("G4", ["10-20201030-L1000519", "87-20250706-R0024349"]),
    ("G6", ["07-20190120-_G130022", "42-20250326-_DSF3629"]),
    ("G7", ["96-20250823-_DSF6565", "42-20250326-_DSF3629"]),
    ("G16", ["20250315-_DSF9076", "20250405-_R014662"]),
]
for (name, fns) in golden {
    let matches = analyzed.filter { a in
        fns.allSatisfy { fn in a.pair.filenameA.contains(fn) || a.pair.filenameB.contains(fn) }
    }
    for m in matches {
        let inB2 = !m.isRole && relationalTypes.contains(m.relType) && (m.pair.score ?? 0) >= 0.80
        print("\(name): pair \(m.pair.pairID) [\(m.relType) \(m.pair.score ?? -1)] role=\(m.isRole) inBucket2=\(inB2)")
        print("   RATIONALE: \(m.pair.rationale ?? "")")
    }
    if matches.isEmpty { print("\(name): NOT FOUND in judged set") }
}


// ══════════════════════════════════════════════════════════════════════════
// PASS 2c — cluster BLIND SPOTS: judge found a real relationship but the
// cluster system's Dice/axis mechanism had nothing to contribute.
// blind-spot = relType != none AND meaningfulShared empty AND no axisPair fired
//            = relType != none AND firing.isEmpty   (firing = mShared ∪ axis-participant)
// Reuses the exact same `firing`/`relType` computations as passes 1–2 (no drift).
// ══════════════════════════════════════════════════════════════════════════
print("\n\n═══ PASS 2c: BLIND-SPOT pairs (relType != none AND firing empty) ═══")
let blind = analyzed.filter { relationalTypes.contains($0.relType) && $0.firing.isEmpty }
let blindRole = blind.filter { $0.isRole }
let blindNonRole = blind.filter { !$0.isRole }
print("n = \(blind.count)  |  role-hypothesis = \(blindRole.count)  non-role = \(blindNonRole.count)")
// relType split
var brt: [String: Int] = [:]; for b in blind { brt[b.relType, default: 0] += 1 }
print("relType split: \(brt)")
// sanity: how many non-none pairs total, and what fraction are blind
let nonNone = analyzed.filter { relationalTypes.contains($0.relType) }
print("of \(nonNone.count) non-none judged pairs, \(blind.count) (\(String(format: "%.1f%%", 100.0*Double(blind.count)/Double(nonNone.count)))) are cluster blind spots")

// ── Recurring-pattern aggregation: cross-side meaningful-cluster co-occurrence
//    among blind-spot pairs (both sides fired meaningful clusters but no shared/axis link).
//    This is option (a) territory: existing clusters that just aren't linked. ──
func ckey(_ a: String, _ b: String) -> String { a < b ? "\(a)×\(b)" : "\(b)×\(a)" }
var comboBoth: [String: (n: Int, rt: [String: Int])] = [:]   // both sides fired ≥1 meaningful cluster
var oneSideEmpty = 0                                          // at least one side fired NO meaningful cluster
for b in blind {
    if b.meaningfulOnlyA.isEmpty || b.meaningfulOnlyB.isEmpty { oneSideEmpty += 1 }
    for x in b.meaningfulOnlyA { for y in b.meaningfulOnlyB {
        let k = ckey(x, y)
        var e = comboBoth[k] ?? (0, [:]); e.n += 1; e.rt[b.relType, default: 0] += 1; comboBoth[k] = e
    }}
}
print("\nblind-spot pairs where ≥1 side fired NO meaningful cluster (pure extraction/caption signal): \(oneSideEmpty) of \(blind.count)")
print("\n--- recurring cross-side meaningful-cluster combos among blind-spot pairs (n>=3), NOT already an axisPair ---")
let knownAxis = Set(ConceptClusters.axisPairs.map { ckey($0.a, $0.b) })
for (k, e) in comboBoth.sorted(by: { $0.value.n > $1.value.n }) where e.n >= 3 {
    let tag = knownAxis.contains(k) ? " [ALREADY-AXIS]" : ""
    print("\(k): n=\(e.n) rt=\(e.rt)\(tag)")
}

// ── Also: per-single-meaningful-cluster frequency among blind-spot pairs
//    (which clusters show up at all on either side — catches option-b/c leads
//    where only one side fires a meaningful cluster). ──
var sideClusterFreq: [String: Int] = [:]
for b in blind { for c in b.meaningfulOnlyA.union(b.meaningfulOnlyB) { sideClusterFreq[c, default: 0] += 1 } }
print("\n--- meaningful clusters appearing on EITHER side of blind-spot pairs (freq) ---")
for (c, n) in sideClusterFreq.sorted(by: { $0.value > $1.value }) { print("\(c): \(n)") }

// ── Cross-ref against KNOWN_GOOD_PAIRS golden/lead pairs ──
print("\n--- KNOWN_GOOD_PAIRS cross-ref: are any golden pairs (G4/G6/G7/G16) blind spots? ---")
for (name, fns) in golden {
    for m in blind where fns.allSatisfy({ fn in m.pair.filenameA.contains(fn) || m.pair.filenameB.contains(fn) }) {
        print("\(name) IS a blind spot: pair \(m.pair.pairID) [\(m.relType)] role=\(m.isRole)")
    }
}

// ── Full dump for reading (rationale + BOTH captions), sorted role-first then relType ──
print("\n\n═══ BLIND-SPOT FULL DUMP (read for recurring concepts; verify against caption text) ═══")
for b in blind.sorted(by: { ($0.isRole ? 0 : 1, $0.relType, -($0.pair.score ?? 0)) < ($1.isRole ? 0 : 1, $1.relType, -($1.pair.score ?? 0)) }) {
    print("\n--- pair \(b.pair.pairID) [\(b.relType) \(b.pair.score ?? -1)] role=\(b.isRole) mOnlyA=\(b.meaningfulOnlyA.sorted()) mOnlyB=\(b.meaningfulOnlyB.sorted())")
    print("  HYP: \(b.pair.roleHyp ?? "(none)")")
    print("  A(\(b.pair.filenameA)): \(b.pair.captionA ?? "")")
    print("  B(\(b.pair.filenameB)): \(b.pair.captionB ?? "")")
    print("  RATIONALE: \(b.pair.rationale ?? "")")
}


// ══════════════════════════════════════════════════════════════════════════
// PASS 2c — BROADER LENS. The strict blind-spot filter (firing empty) is nearly
// empty because ubiquitous clusters create incidental meaningfulShared on almost
// every pair. Two complementary broader views:
//  (i)   corpus firing rate per cluster → identify the "incidental" ubiquitous ones.
//  (ii)  cross-side meaningful-cluster combos over ALL non-none pairs (role+nonrole),
//        looking for recurring (clusterA_onlyA × clusterB_onlyB) under a consistent
//        relType that is NOT an axisPair → option-(a) candidate axis pairs.
// ══════════════════════════════════════════════════════════════════════════
print("\n\n═══ PASS 2c BROADER (i): corpus firing rate, ALL clusters (identify incidental/ubiquitous) ═══")
var allFire: [String: Int] = [:]
for img in corpus { guard let cap = img.caption else { continue }
    for c in ConceptClusters.matchedClusters(for: cap) { allFire[c, default: 0] += 1 } }
for (c, n) in allFire.sorted(by: { $0.value > $1.value }) {
    print("\(c): \(n) (\(String(format: "%.0f%%", 100.0*Double(n)/Double(corpus.count))))")
}

print("\n\n═══ PASS 2c BROADER (ii): cross-side meaningful-cluster combos over ALL non-none pairs ═══")
func ckey2(_ a: String, _ b: String) -> String { a < b ? "\(a)×\(b)" : "\(b)×\(a)" }
let knownAxis2 = Set(ConceptClusters.axisPairs.map { ckey2($0.a, $0.b) })
// combos where clusterX is meaningful-onlyA and clusterY is meaningful-onlyB (both sides fired
// a DIFFERENT meaningful cluster the other lacks). Split role vs non-role.
func comboReport(_ items: [Analyzed], _ label: String) {
    var combo: [String: (n: Int, rt: [String: Int])] = [:]
    for it in items {
        for x in it.meaningfulOnlyA { for y in it.meaningfulOnlyB {
            let k = ckey2(x, y)
            var e = combo[k] ?? (0, [:]); e.n += 1; e.rt[it.relType, default: 0] += 1; combo[k] = e
        }}
    }
    print("\n--- \(label): recurring cross-side combos (n>=5), sorted by n ---")
    for (k, e) in combo.sorted(by: { $0.value.n > $1.value.n }) where e.n >= 5 {
        let tag = knownAxis2.contains(k) ? " [ALREADY-AXIS]" : ""
        // dominant relType share
        let dom = e.rt.max(by: { $0.value < $1.value })!
        let domShare = String(format: "%.0f%%", 100.0*Double(dom.value)/Double(e.n))
        print("\(k): n=\(e.n) dom=\(dom.key)(\(domShare)) rt=\(e.rt)\(tag)")
    }
}
let allNonNone = analyzed.filter { relationalTypes.contains($0.relType) }
comboReport(allNonNone.filter { $0.isRole },  "ROLE non-none (n=\(allNonNone.filter{$0.isRole}.count))")
comboReport(allNonNone.filter { !$0.isRole }, "NON-ROLE non-none (n=\(allNonNone.filter{ !$0.isRole }.count))")


// ── Targeted read of base-rate-ENRICHED combos (complementary lift over pool 7%) ──
func dumpCombo(_ x: String, _ y: String, _ rt: String, _ limit: Int) {
    print("\n\n═══ ENRICHED-COMBO READ: \(x) × \(y), relType=\(rt) ═══")
    let hits = analyzed.filter {
        $0.relType == rt &&
        (( $0.meaningfulOnlyA.contains(x) && $0.meaningfulOnlyB.contains(y)) ||
         ( $0.meaningfulOnlyA.contains(y) && $0.meaningfulOnlyB.contains(x)))
    }
    print("n=\(hits.count) (role=\(hits.filter{$0.isRole}.count) nonrole=\(hits.filter{ !$0.isRole}.count))")
    for h in hits.prefix(limit) {
        print("\n- pair \(h.pair.pairID) role=\(h.isRole) HYP: \(h.pair.roleHyp ?? "(none)")")
        print("  A(\(h.pair.filenameA)): \((h.pair.captionA ?? "").prefix(280))")
        print("  B(\(h.pair.filenameB)): \((h.pair.captionB ?? "").prefix(280))")
        print("  RATIONALE: \(h.pair.rationale ?? "")")
    }
}
dumpCombo("tenderness_care", "vulnerability_exposure", "complementary", 6)
dumpCombo("sensory_overwhelm", "skilled_performance", "complementary", 6)


// ══════════════════════════════════════════════════════════════════════════
// PASS 2d — specificity-corrected blind spots. Pass 2c's strict test treated
// ANY nonzero meaningfulShared as "cluster contributed something", but clusters
// firing on >half the corpus (bodily_gesture 94% etc.) convey ~no information
// about why two SPECIFIC images share them. 2d discounts near-ubiquitous clusters
// before rerunning 2c. Read-only. Reuses ConceptClusters directly.
// ══════════════════════════════════════════════════════════════════════════
func tier(_ c: String) -> String {
    switch ConceptClusters.weights[c] ?? 0 { case 1.0: return "1.0"; case 0.75: return "0.75"; default: return "0.2" }
}
func idfSpec(_ count: Int, _ total: Int) -> Double { Foundation.log(Double(total + 1) / Double(count + 1)) }

print("\n\n═══ PASS 2d (a): FULL 29-cluster corpus-frequency table (denom=\(corpus.count)) ═══")
print("cluster,tier,corpus_firing,pct,idf_spec")
var freqAll: [(String, Int)] = []
for cl in ConceptClusters.all {
    let n = allFire[cl.name] ?? 0
    freqAll.append((cl.name, n))
}
for (name, n) in freqAll.sorted(by: { $0.1 > $1.1 }) {
    print("\(name),\(tier(name)),\(n),\(String(format: "%.0f%%", 100.0*Double(n)/Double(corpus.count))),\(String(format: "%.2f", idfSpec(n, corpus.count)))")
}
// gap analysis among MEANINGFUL-tier clusters (weight >= 0.75) only
print("\n--- gap analysis, MEANINGFUL-tier clusters only (descending firing) ---")
let meaningfulSorted = freqAll.filter { (ConceptClusters.weights[$0.0] ?? 0) >= 0.75 }.sorted { $0.1 > $1.1 }
var prev = -1
for (name, n) in meaningfulSorted {
    let gap = prev < 0 ? 0 : prev - n
    print("\(name): \(n) (\(String(format: "%.0f%%", 100.0*Double(n)/Double(corpus.count))))  gap_from_prev=\(gap)")
    prev = n
}

// Ubiquitous set = meaningful clusters firing on > 50% of corpus (the 54->40 natural break)
let ubiquitous: Set<String> = Set(meaningfulSorted.filter { Double($0.1)/Double(corpus.count) > 0.50 }.map { $0.0 })
print("\n>>> UBIQUITOUS set (meaningful-tier, >50% corpus firing): \(ubiquitous.sorted())")

// ── (c) informative blind-spot recompute ──
// informativeFiring = firing (meaningfulShared ∪ axis-participant) minus ubiquitous
print("\n\n═══ PASS 2d (c): INFORMATIVE blind spots (relType != none AND informativeFiring empty) ═══")
func informative(_ a: Analyzed) -> Set<String> { a.firing.subtracting(ubiquitous) }
let iblind = analyzed.filter { relationalTypes.contains($0.relType) && informative($0).isEmpty }
print("n=\(iblind.count) (role=\(iblind.filter{$0.isRole}.count) nonrole=\(iblind.filter{ !$0.isRole}.count)) of \(analyzed.filter{relationalTypes.contains($0.relType)}.count) non-none")
var irt: [String: Int] = [:]; for b in iblind { irt[b.relType, default: 0] += 1 }
print("relType split: \(irt)")
// how many have EVERY meaningful-shared cluster ubiquitous (pure ubiquitous overlap)
var pureUbiqShared = 0
for b in iblind where !b.meaningfulShared.isEmpty && b.meaningfulShared.isSubset(of: ubiquitous) { pureUbiqShared += 1 }
print("of those, \(pureUbiqShared) had a non-empty meaningfulShared that was ENTIRELY ubiquitous (2c would have counted these as 'contributed')")

// KNOWN_GOOD cross-ref
print("\n--- KNOWN_GOOD_PAIRS cross-ref among informative blind spots ---")
for (name, fns) in golden {
    for m in iblind where fns.allSatisfy({ fn in m.pair.filenameA.contains(fn) || m.pair.filenameB.contains(fn) }) {
        print("\(name): pair \(m.pair.pairID) [\(m.relType)] role=\(m.isRole)")
    }
}

// ── (d) enriched cross-side combo scan restricted to INFORMATIVE clusters ──
print("\n\n═══ PASS 2d (d): enriched cross-side combos, INFORMATIVE clusters only ═══")
func infoOnlyA(_ a: Analyzed) -> Set<String> { a.meaningfulOnlyA.subtracting(ubiquitous) }
func infoOnlyB(_ a: Analyzed) -> Set<String> { a.meaningfulOnlyB.subtracting(ubiquitous) }
func comboReportInfo(_ items: [Analyzed], _ label: String) {
    let base = Double(items.count)
    var brt: [String: Int] = [:]; for it in items { brt[it.relType, default: 0] += 1 }
    print("\n--- \(label) (n=\(items.count)) base-rate: \(brt.mapValues { String(format: "%.0f%%", 100.0*Double($0)/base) }) ---")
    var combo: [String: (n: Int, rt: [String: Int])] = [:]
    for it in items {
        for x in infoOnlyA(it) { for y in infoOnlyB(it) {
            let k = x < y ? "\(x)×\(y)" : "\(y)×\(x)"
            var e = combo[k] ?? (0, [:]); e.n += 1; e.rt[it.relType, default: 0] += 1; combo[k] = e
        }}
    }
    let knownAxis = Set(ConceptClusters.axisPairs.map { $0.a < $0.b ? "\($0.a)×\($0.b)" : "\($0.b)×\($0.a)" })
    for (k, e) in combo.sorted(by: { $0.value.n > $1.value.n }) where e.n >= 3 {
        let dom = e.rt.max(by: { $0.value < $1.value })!
        let domShare = 100.0*Double(dom.value)/Double(e.n)
        let tag = knownAxis.contains(k) ? " [AXIS]" : ""
        print("\(k): n=\(e.n) dom=\(dom.key)(\(String(format: "%.0f%%", domShare))) rt=\(e.rt)\(tag)")
    }
}
let allNN = analyzed.filter { relationalTypes.contains($0.relType) }
comboReportInfo(allNN.filter { $0.isRole },  "ROLE non-none")
comboReportInfo(allNN.filter { !$0.isRole }, "NON-ROLE non-none")


// ── (e) AXIS-BONUS-SUPPRESSION check over ALL corpus pairs (structural, not judged-biased) ──
// Replicates PairScorer's guard: axis bonus fires only when NOT (saturated || clusterScore > 0.10).
// clusterScore = 0 if (saturated || !hasAsymmetry) else weightedDice.
// For axis-eligible pairs whose bonus IS suppressed, split: suppression driven purely by
// ubiquitous incidentally-shared clusters (meaningfulShared nonempty ⊆ ubiquitous) vs a
// genuine non-ubiquitous shared cluster.
print("\n\n═══ PASS 2d (e): axis-bonus suppression over ALL corpus pairs (scoring-guard finding) ═══")
// precompute cluster sets + weighted sums per corpus image
struct ImgC { let m: Set<String>; let wsum: Double }
var imgs: [ImgC] = []
for img in corpus { guard let cap = img.caption else { continue }
    let m = ConceptClusters.matchedClusters(for: cap)
    imgs.append(ImgC(m: m, wsum: m.reduce(0.0) { $0 + Double(ConceptClusters.weights[$1] ?? 0.5) }))
}
func wdice(_ a: Set<String>, _ b: Set<String>, _ wa: Double, _ wb: Double) -> Double {
    let sh = a.intersection(b)
    guard sh.contains(where: { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }) else { return 0.10 } // ambient floor
    let ws = sh.reduce(0.0) { $0 + Double(ConceptClusters.weights[$1] ?? 0.5) }
    let d = wa + wb
    return d > 0 ? 2*ws/d : 0
}
let axisList = ConceptClusters.axisPairs
var axisEligible = 0, bonusFires = 0, suppressed = 0, suppUbiqOnly = 0, suppGenuine = 0, suppSaturated = 0
for i in 0..<imgs.count {
    for j in (i+1)..<imgs.count {
        let cA = imgs[i].m, cB = imgs[j].m
        // axis structurally fires?
        var fires = false
        for ax in axisList where (cA.contains(ax.a) && cB.contains(ax.b)) || (cA.contains(ax.b) && cB.contains(ax.a)) { fires = true; break }
        guard fires else { continue }
        axisEligible += 1
        let mOnlyA = cA.subtracting(cB).filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
        let mOnlyB = cB.subtracting(cA).filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
        let hasAsym = !mOnlyA.isEmpty && !mOnlyB.isEmpty
        let sh = cA.intersection(cB)
        let wShared = sh.reduce(0.0) { $0 + Double(ConceptClusters.weights[$1] ?? 0.5) }
        let saturated = wShared > 5.0
        let clusterScore = (saturated || !hasAsym) ? 0.0 : wdice(cA, cB, imgs[i].wsum, imgs[j].wsum)
        let bonusSuppressed = saturated || clusterScore > 0.10
        if !bonusSuppressed { bonusFires += 1; continue }
        suppressed += 1
        if saturated { suppSaturated += 1; continue }
        // clusterScore > 0.10 means a meaningful shared cluster exists. Is it ONLY ubiquitous?
        let mShared = sh.filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
        if !mShared.isEmpty && mShared.isSubset(of: ubiquitous) { suppUbiqOnly += 1 } else { suppGenuine += 1 }
    }
}
print("axis-eligible corpus pairs: \(axisEligible)")
print("  bonus FIRES (not suppressed): \(bonusFires)")
print("  bonus SUPPRESSED: \(suppressed)")
print("    ├ by saturation (wShared>5.0): \(suppSaturated)")
print("    ├ by UBIQUITOUS-only shared cluster (would fire if ubiquitous discounted): \(suppUbiqOnly)")
print("    └ by genuine non-ubiquitous shared cluster: \(suppGenuine)")

// ── (f) qualitative caption read: why do the ubiquitous clusters over-fire? ──
print("\n\n═══ PASS 2d (f): qualitative caption sample per ubiquitous cluster (keyword attribution) ═══")
for cl in ubiquitous.sorted() {
    guard let cluster = ConceptClusters.all.first(where: { $0.name == cl }) else { continue }
    // corpus-wide keyword trigger frequency
    var kw: [String: Int] = [:]
    var sampleCaps: [(String, [String])] = []
    for img in corpus { guard let cap = img.caption else { continue }
        let toks = localTokens(cap)
        let hit = cluster.keywords.filter { toks.contains($0) }.sorted()
        if !hit.isEmpty {
            for k in hit { kw[k, default: 0] += 1 }
            if sampleCaps.count < 18 { sampleCaps.append((img.filename, hit)) }
        }
    }
    let kwSorted = kw.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
    print("\n### \(cl) [tier \(tier(cl))] — keyword trigger freq: \(kwSorted)")
    for (fn, hit) in sampleCaps.prefix(18) { print("   \(fn): via \(hit)") }
}


// ── (c-detail) roleHyp-template tally of the 92 informative blind spots + the non-role case ──
print("\n\n═══ PASS 2d (c-detail): informative blind-spot roleHyp templates ═══")
func hypTemplate(_ h: String?) -> String {
    guard let h = h else { return "(non-role)" }
    // collapse to the join template: text before the first ':' plus the phenomenon word if present
    let lower = h.lowercased()
    if lower.contains("source of sound") { return "join1 source↔receiver: SOUND" }
    if lower.contains("source of light") { return "join1 source↔receiver: LIGHT" }
    if lower.contains("source of motion") { return "join1 source↔receiver: MOTION" }
    if lower.contains("source of") { return "join1 source↔receiver: OTHER" }
    if lower.contains("real") && lower.contains("depict") { return "join3 real-vs-depicted object" }
    if lower.contains("claim") || lower.contains("sign") { return "join2/4 claim↔embodiment/object" }
    if lower.contains("enact") || lower.contains("subvert") { return "join2 claim↔enact/subvert" }
    return "other: " + String(h.prefix(60))
}
var tmpl: [String: Int] = [:]
for b in iblind { tmpl[hypTemplate(b.pair.roleHyp), default: 0] += 1 }
for (t, n) in tmpl.sorted(by: { $0.value > $1.value }) { print("  \(n)×  \(t)") }
print("\n--- the non-role informative blind spot(s), full ---")
for b in iblind where !b.isRole {
    print("pair \(b.pair.pairID) [\(b.relType) \(b.pair.score ?? -1)] mOnlyA=\(b.meaningfulOnlyA.sorted()) mOnlyB=\(b.meaningfulOnlyB.sorted())")
    print("  A(\(b.pair.filenameA)): \(b.pair.captionA ?? "")")
    print("  B(\(b.pair.filenameB)): \(b.pair.captionB ?? "")")
    print("  RATIONALE: \(b.pair.rationale ?? "")")
}


// ══════════════════════════════════════════════════════════════════════════
// PASS 3 — caption-first vocabulary discovery, independent of pairing/judging.
// Passes 1–2d all started from judged pairs and worked backward to clusters;
// every actionable finding was a removal or a role-pipeline lead. This pass
// inverts direction: mine captions directly for recurring vocabulary the 29
// clusters have zero representation for. Read-only.
// ══════════════════════════════════════════════════════════════════════════

// (1) Exclusion set: literal union of ALL 29 clusters' keyword lists, straight
// from ConceptClusters.all (not the pass-2 attributed subset).
let clusterVocab: Set<String> = Set(ConceptClusters.all.flatMap { $0.keywords })
print("\n\n═══ PASS 3 (1): exclusion set — \(clusterVocab.count) distinct keyword stems across 29 clusters ═══")

// (2) Tokenize every caption: unigrams (stemmed, corpus-wide per-image presence,
// exactly pass 2d's "corpus firing" method) using the ALREADY-VALIDATED tokenizer
// copy (0 mismatches vs matchedClusters, confirmed in pass 2).
var unigramCorpusFreqRAW: [String: Int] = [:]   // stem -> #images (BEFORE exclusion/stoplist)
for img in corpus {
    guard let cap = img.caption else { continue }
    for stem in localTokens(cap) { unigramCorpusFreqRAW[stem, default: 0] += 1 }
}
print("\n--- RAW top-80 unigram stems by corpus frequency (BEFORE cluster-vocab/stoplist exclusion; for calibrating the boilerplate stoplist) ---")
for (stem, n) in unigramCorpusFreqRAW.sorted(by: { $0.value > $1.value }).prefix(80) {
    let inCluster = clusterVocab.contains(stem) ? " [CLUSTER]" : ""
    print("\(stem): \(n)\(inCluster)")
}


// (4) Caption-boilerplate stoplist. Built by inspecting the raw top-80 unigram
// frequency table above and categorizing what's clearly prompt-v2 photographic/
// descriptive filler rather than thematic content, reasoning from the categories
// visible in that table:
//   - generic-subject nouns: woman, man, person, people, someone/something, one, another
//   - clothing/color/physical-appearance description: wear(ing), shirt, jean, pant,
//     hat, hair, white, black, blue, red, brown, dark
//   - photographic/descriptive meta-vocabulary (the prompt-v2 "physical facts first"
//     narration voice): appear, suggest, background, scene, overall, possib(ly),
//     visible, sett(ing), slight(ly), casu(al), direct(ed/ion — ambiguous but
//     overwhelmingly "facing/oriented" in this corpus, not "directing" as an action),
//     focus(ed), atmosphere, camera, mood, moment, expression, seem, engag(ed/ing —
//     spot-checked: near-universally "engaged in [activity]" scene-setting, not a
//     relational-engagement claim)
//   - generic spatial/positional words: right, left, side, top, down, forward,
//     toward, ground
//   - generic body-part mentions used for physical description, not behavior:
//     head, eyes, hair (hair listed above too)
// NOT included despite high frequency, because each has plausible thematic content
// and is examined on its own below: "light" (287 — ties to the KNOWN missing
// aesthetic-axis "light quality" signal, backlog #55/PAIRING_THEORY, kept as its
// own candidate rather than stoplisted).
let boilerplateStoplist: Set<String> = [
    "woman", "man", "person", "people", "someth", "one", "anoth", "individual",
    "wear", "shirt", "jean", "pant", "hat", "hair", "white", "black", "blue", "red", "brown", "dark",
    "green", "pink", "gray", "dres", "jacket", "sunglass", "cowboy",
    "appear", "suggest", "background", "scene", "overall", "possib", "visible", "sett", "slight",
    "casu", "direct", "focus", "atmosphere", "camera", "mood", "moment", "expression", "seem", "engag",
    "right", "left", "side", "top", "down", "forward", "toward", "ground", "front", "beside", "foreground",
    "around", "near", "off", "out", "over", "ahead", "position", "area", "facing",
    "head", "eyes", "legs", "feet", "arms", "body", "face",
    "stand", "sits", "seat", "captur", "photograph", "frame", "sense", "indicat", "seeming",
    "pattern", "text", "object", "includ", "firm", "everyday",
    // additional pure function/filler words the stemmer/tokenizer lets through
    // (numbers, generic verbs of presence, not stopped by localStop's 2-char floor)
    "like", "other", "show", "read", "twent", "30s", "large", "small", "long", "color", "walk", "rais",
    "them", "him", "its", "two", "not"
]
// Deliberately KEPT despite generic feel — flagged for explicit read below, not stoplisted
// on inspection alone: "light" (287, ties to backlog #55/PAIRING_THEORY light-quality gap),
// "phone" (101, possible digital-object/distraction concept), "convers"/"interac" (109/123,
// possible relational-concept gap — no existing cluster names conversation/interaction itself),
// "posture" (154, meta-descriptor — read below to decide if it's boilerplate or content),
// "outdoor"/"tree"/"building"/"metal"/"park" (setting nouns — read below re: ambient-tier gap).
print("\n\n═══ PASS 3 (4): boilerplate stoplist — \(boilerplateStoplist.count) terms excluded (see source comment for category rationale) ═══")

// (3) Subtract cluster vocab. (5) Rank leftover by corpus frequency, gap analysis.
let leftoverUnigrams = unigramCorpusFreqRAW.filter { !clusterVocab.contains($0.key) && !boilerplateStoplist.contains($0.key) }
print("\n═══ PASS 3 (3+5): LEFTOVER unigrams (not in any cluster, not boilerplate) — top 60 by corpus frequency ═══")
let leftoverSorted = leftoverUnigrams.sorted { $0.value > $1.value }
var prevN = -1
for (stem, n) in leftoverSorted.prefix(60) {
    let gap = prevN < 0 ? 0 : prevN - n
    print("\(stem): \(n) (\(String(format: "%.0f%%", 100.0*Double(n)/Double(corpus.count))))  gap=\(gap)")
    prevN = n
}


// ── BYPRODUCT CHECK: keyword-reachability audit ──
// "obscur" surfaced as a leftover unigram (86 corpus hits, NOT in clusterVocab) despite
// uncanny_ordinary literally listing "obscure" as a G2 keyword. Hypothesis: this is a
// stemmer/authoring mismatch (keyword written as a dictionary word, not the truncated
// stem form the tokenizer actually produces), not a rarity gap. Verify directly.
print("\n\n═══ PASS 3 byproduct: keyword-reachability audit (does each keyword ever match a real corpus stem?) ═══")
print("localStem(\"obscured\") = \(localStem("obscured"))   (cluster keyword is literally \"obscure\")")
var deadKeywords: [(cluster: String, keyword: String)] = []
for cl in ConceptClusters.all {
    for kw in cl.keywords where (unigramCorpusFreqRAW[kw] ?? 0) == 0 {
        deadKeywords.append((cl.name, kw))
    }
}
print("keywords with ZERO corpus stem support (never matches ANY caption in this 1,028-image corpus): \(deadKeywords.count) of \(clusterVocab.count) distinct keywords")
for d in deadKeywords.sorted(by: { $0.cluster < $1.cluster }) { print("  \(d.cluster): \"\(d.keyword)\"") }

// Confirm the "obscure" fix would be LIVE (not just theoretical): does any corpus caption
// have BOTH the stemmed token "obscur" AND satisfy uncanny_ordinary's G1 group?
let uncannyCluster = ConceptClusters.all.first { $0.name == "uncanny_ordinary" }!
let g1 = uncannyCluster.requiredGroups![0]
var obscurAndG1 = 0
var obscurExamples: [String] = []
for img in corpus {
    guard let cap = img.caption else { continue }
    let toks = localTokens(cap)
    if toks.contains("obscur") {
        let hasG1 = !toks.isDisjoint(with: g1)
        if hasG1 { obscurAndG1 += 1; if obscurExamples.count < 5 { obscurExamples.append("\(img.filename): \(cap)") } }
    }
}
print("\nimages with stemmed 'obscur' present: \(unigramCorpusFreqRAW["obscur"] ?? 0)")
print("of those, images that ALSO satisfy uncanny_ordinary's G1 (eerie/dreamlike register): \(obscurAndG1)")
for e in obscurExamples { print("  - \(e.prefix(220))") }


// ── Is the 364-dead-keyword figure mostly a SYSTEMATIC stemmer/authoring bug, or
//    mostly genuine content absence? For each dead keyword K, test whether a COMMON
//    inflection of K (K+"ed", K+"s", K+"ing", K+"d") stems to something that DOES
//    have corpus support — if so, K is very likely unreachable-by-design (the author
//    wrote a full/dictionary word where the tokenizer needed the truncated stem),
//    not a genuine absence. ──
print("\n\n═══ PASS 3 byproduct (cont.): dead-keyword root-cause split (bug vs. genuine absence) ═══")
var likelyBug: [(cluster: String, keyword: String, reachableForm: String, support: Int)] = []
var likelyAbsent: [(cluster: String, keyword: String)] = []
for (cl, kw) in deadKeywords {
    var found: (String, Int)? = nil
    for suffix in ["ed", "s", "ing", "d", "es"] {
        let inflected = kw + suffix
        let stemmed = localStem(inflected)
        if stemmed != kw, let n = unigramCorpusFreqRAW[stemmed], n > 0 {
            if found == nil || n > found!.1 { found = (stemmed, n) }
        }
    }
    if let f = found { likelyBug.append((cl, kw, f.0, f.1)) }
    else { likelyAbsent.append((cl, kw)) }
}
print("of 364 dead keywords: \(likelyBug.count) are LIKELY a stemmer/authoring mismatch (a common inflection DOES have corpus support under a different stem); \(likelyAbsent.count) show NO support under any tested inflection either (genuinely rare/absent content, or a rarer inflection pattern this check doesn't cover)")
print("\n--- LIKELY-BUG keywords, sorted by the reachable-form's corpus support (highest impact first) ---")
for b in likelyBug.sorted(by: { $0.support > $1.support }) {
    print("  \(b.cluster): keyword \"\(b.keyword)\" — caption stem \"\(b.reachableForm)\" has \(b.support) corpus hits but never matches \"\(b.keyword)\" literally")
}


// ── Verify likely-bug candidates aren't coincidental substring false-positives
// (e.g. "crow"+"d"="crowd" is a DIFFERENT word, not an inflection of "crow") ──
print("\n\n═══ PASS 3 byproduct verify: example captions for borderline bug candidates ═══")
for (label, stem) in [("star (from stare?)", "star"), ("fixed (from fix?)", "fixed"), ("runs (from run?)", "runs")] {
    print("\n--- \(label): stem '\(stem)' example captions ---")
    var shown = 0
    for img in corpus { guard let cap = img.caption else { continue }
        if localTokens(cap).contains(stem) && shown < 4 {
            print("  \(img.filename): \((cap as NSString).substring(to: min(200, cap.count)))")
            shown += 1
        }
    }
}


// ══════════════════════════════════════════════════════════════════════════
// PASS 3 (2 cont.): PHRASE-LEVEL (bigram/trigram) candidates.
// Thematic concepts are often phrase-level ("hands over ears", "looking down at").
// Build n-grams from lightly-cleaned (lowercased, punctuation-stripped) caption
// word sequences — NOT from the stemmed/stopword-filtered token set, since phrases
// need natural adjacency. A phrase counts as a NEW-vocabulary candidate only if
// NONE of its content words' stems are already in clusterVocab (fully uncovered).
// ══════════════════════════════════════════════════════════════════════════
func cleanWords(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
}
// phrase-boundary stopwords: pure function words that shouldn't anchor a phrase
let phraseFnWords: Set<String> = ["a","an","the","is","are","in","on","at","and","or","of","to",
    "with","by","for","her","his","their","they","he","she","it","this","that","there","has",
    "have","from","as","its","his","him","them"]
func phraseIsContentful(_ words: [String]) -> Bool {
    // at least one word must be a non-boilerplate, non-cluster, non-function content word
    words.contains { w in
        let s = localStem(w)
        return w.count > 2 && !phraseFnWords.contains(w) && !localStop.contains(s)
    }
}
func phraseFullyUncovered(_ words: [String]) -> Bool {
    // NONE of the phrase's content-word stems already in clusterVocab
    for w in words where w.count > 2 && !phraseFnWords.contains(w) {
        if clusterVocab.contains(localStem(w)) { return false }
    }
    return true
}
func phraseIsBoilerplate(_ words: [String]) -> Bool {
    // all content words are boilerplate-stoplisted -> not interesting
    let content = words.filter { $0.count > 2 && !phraseFnWords.contains($0) }
    guard !content.isEmpty else { return true }
    return content.allSatisfy { boilerplateStoplist.contains(localStem($0)) }
}

var bigramFreq: [String: Int] = [:]
var trigramFreq: [String: Int] = [:]
for img in corpus {
    guard let cap = img.caption else { continue }
    let words = cleanWords(cap)
    var seenBi = Set<String>(), seenTri = Set<String>()
    if words.count >= 2 {
        for i in 0..<(words.count - 1) {
            let bg = [words[i], words[i+1]]
            guard phraseIsContentful(bg), phraseFullyUncovered(bg), !phraseIsBoilerplate(bg) else { continue }
            seenBi.insert(bg.joined(separator: " "))
        }
    }
    if words.count >= 3 {
        for i in 0..<(words.count - 2) {
            let tg = [words[i], words[i+1], words[i+2]]
            guard phraseIsContentful(tg), phraseFullyUncovered(tg), !phraseIsBoilerplate(tg) else { continue }
            seenTri.insert(tg.joined(separator: " "))
        }
    }
    for b in seenBi { bigramFreq[b, default: 0] += 1 }
    for t in seenTri { trigramFreq[t, default: 0] += 1 }
}
print("\n\n═══ PASS 3 (2/3/5 phrase-level): top 40 UNCOVERED bigrams by corpus (image) frequency ═══")
for (b, n) in bigramFreq.sorted(by: { $0.value > $1.value }).prefix(40) {
    print("\"\(b)\": \(n) (\(String(format: "%.1f%%", 100.0*Double(n)/Double(corpus.count))))")
}
print("\n═══ top 25 UNCOVERED trigrams by corpus (image) frequency ═══")
for (t, n) in trigramFreq.sorted(by: { $0.value > $1.value }).prefix(25) {
    print("\"\(t)\": \(n) (\(String(format: "%.1f%%", 100.0*Double(n)/Double(corpus.count))))")
}


// ── ENRICHMENT CHECK: does a candidate term/phrase correlate with non-none judged
// outcomes above the relevant pool's base rate, when present on EITHER caption side? ──
func enrichmentCheck(_ label: String, _ predicate: @escaping (String) -> Bool) {
    let roleP = analyzed.filter { $0.isRole }
    let nonRoleP = analyzed.filter { !$0.isRole }
    func rate(_ pool: [Analyzed]) -> (hit: Int, nonNone: Int, base: Double) {
        let hits = pool.filter { predicate($0.pair.captionA ?? "") || predicate($0.pair.captionB ?? "") }
        let nn = hits.filter { $0.relType != "none" }.count
        let baseNN = pool.filter { $0.relType != "none" }.count
        return (hits.count, nn, pool.isEmpty ? 0 : 100.0*Double(baseNN)/Double(pool.count))
    }
    let r = rate(roleP), nr = rate(nonRoleP)
    print("\n--- enrichment: \(label) ---")
    print("  ROLE: n=\(r.hit) hit, \(r.nonNone) non-none (\(r.hit > 0 ? String(format: "%.0f%%", 100.0*Double(r.nonNone)/Double(r.hit)) : "n/a")) vs pool base \(String(format: "%.1f%%", r.base))")
    print("  NON-ROLE: n=\(nr.hit) hit, \(nr.nonNone) non-none (\(nr.hit > 0 ? String(format: "%.0f%%", 100.0*Double(nr.nonNone)/Double(nr.hit)) : "n/a")) vs pool base \(String(format: "%.1f%%", nr.base))")
}
print("\n\n═══ PASS 3 (6): enrichment checks for top candidates ═══")
enrichmentCheck("phone (unigram stem)") { cap in localTokens(cap).contains("phone") }
enrichmentCheck("convers/interac (either stem present)") { cap in
    let t = localTokens(cap); return t.contains("convers") || t.contains("interac")
}
enrichmentCheck("downward (unigram stem)") { cap in localTokens(cap).contains("downward") }
enrichmentCheck("light (unigram stem)") { cap in localTokens(cap).contains("light") }

// ── example captions for the surviving top candidates ──
print("\n\n═══ PASS 3: example captions ═══")
func showExamples(_ label: String, _ stem: String, _ limit: Int) {
    print("\n--- \(label) ---")
    var shown = 0
    for img in corpus { guard let cap = img.caption else { continue }
        if localTokens(cap).contains(stem) && shown < limit {
            print("  \(img.filename): \(cap.prefix(240))")
            shown += 1
        }
    }
}
showExamples("phone", "phone", 8)
showExamples("convers", "convers", 8)
showExamples("interac", "interac", 8)
showExamples("downward", "downward", 8)


print("\n\n═══ PASS 3 validation: KNOWN_GOOD_PAIRS-motivated candidates ═══")
enrichmentCheck("pattern/stripe (either stem present)") { cap in
    let t = localTokens(cap); return t.contains("pattern") || t.contains("stripe")
}
enrichmentCheck("tattoo (unigram stem)") { cap in localTokens(cap).contains("tattoo") }
showExamples("tattoo", "tattoo", 6)

showExamples("rais (collision check for raise fix)", "rais", 10)
