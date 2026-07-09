import Foundation
import ConjunctEngine

// #120 — exhaustive per-keyword collision audit.
//
// For EVERY (cluster, keyword) across all 30 clusters, against the full corpus:
//   firings            — captions whose stemmed token set contains the keyword
//   % of cluster       — firings / cluster's total corpus firings (real matcher)
//   sole-trigger count — captions where removing this keyword would un-fire the
//                        cluster (single-signal: only cluster keyword present;
//                        requiredGroups: sole satisfier of its group while the
//                        other groups are satisfied) — the predicted removal delta
//   raw-form inventory — every distinct raw caption word stemming to the keyword
//   near-miss stems    — corpus stems adjacent to the keyword that do NOT match
//                        (the #96 raise/obscure reachability class)
//   enrichment         — non-`none` thematicV2 rate among judged non-role pairs
//                        where the cluster is meaningfully shared AND this keyword
//                        is a shared trigger, vs the pool base rate
//
// Read-only; reuses real ConceptClusters.matchedClusters/weights/all. Local copy
// of tokenize/stem is ONLY for attribution and is self-validated (must be 0
// mismatches vs the real matcher before any output is trusted).
//
// Usage: ClusterDiag <judged_pairs.json> <corpus_captions.json> <output_dir>

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
guard args.count > 3 else {
    print("Usage: ClusterDiag <judged_pairs.json> <corpus_captions.json> <output_dir>")
    exit(1)
}

let pairs = try! JSONDecoder().decode([JudgedPair].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let corpus = try! JSONDecoder().decode([CorpusImage].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    .sorted { $0.id < $1.id }   // deterministic iteration everywhere
let outDir = URL(fileURLWithPath: args[3])
try! FileManager.default.createDirectory(at: outDir.appendingPathComponent("samples"), withIntermediateDirectories: true)

// ── Local COPY of ConceptClusters.tokenize/stem (internal in the engine) purely
//    for keyword ATTRIBUTION. Self-validated against the real matcher below. ──
func localStem(_ word: String) -> String {
    var w = word
    let suffixes = ["ation","tion","ance","ence","ness","ment","able","ible","ing","ity","ies","ed","er","al","ly","ful","es","s"]
    for suffix in suffixes where w.hasSuffix(suffix) && w.count > suffix.count + 3 {
        w = String(w.dropLast(suffix.count)); break
    }
    return w
}
let localStop: Set<String> = ["the","a","an","is","are","in","on","at","and","or","of","to","with","by","for","their","his","her","they","he","she","it","this","that","there","has","have","from","what","who","which","when","where","while","been","being","was","were","will","would","could","should","may","might","both","each","such","some","more"]
func localRawWords(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count > 2 && !localStop.contains($0) }
}
func localTokens(_ text: String) -> Set<String> {
    Set(localRawWords(text).map { localStem($0) })
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

// ── Self-validation ──
var mismatches = 0
for img in corpus {
    guard let cap = img.caption else { continue }
    if localMatched(cap) != ConceptClusters.matchedClusters(for: cap) { mismatches += 1 }
}
print("Self-validation: \(mismatches) mismatch(es) over \(corpus.count) captions")
guard mismatches == 0 else {
    print("ABORT: local matcher diverges from ConceptClusters.matchedClusters — attribution untrustworthy")
    exit(2)
}

// ── Precompute per-caption token data ──
struct CapData {
    let id: Int
    let filename: String
    let caption: String
    let tokens: Set<String>
    let stemToRaw: [String: Set<String>]   // stem → raw words in this caption
    let fired: Set<String>                  // real matcher result
}
var caps: [CapData] = []
for img in corpus {
    guard let cap = img.caption, !cap.isEmpty else { continue }
    let raws = localRawWords(cap)
    var s2r: [String: Set<String>] = [:]
    for r in raws { s2r[localStem(r), default: []].insert(r) }
    caps.append(CapData(id: img.id, filename: img.filename, caption: cap,
                        tokens: Set(s2r.keys), stemToRaw: s2r,
                        fired: ConceptClusters.matchedClusters(for: cap)))
}

// Global raw-form inventory: stem → (raw word → corpus caption count)
var globalRawForms: [String: [String: Int]] = [:]
// Global stem frequency: stem → # captions containing it
var stemFreq: [String: Int] = [:]
for c in caps {
    for (stem, raws) in c.stemToRaw {
        stemFreq[stem, default: 0] += 1
        for r in raws { globalRawForms[stem, default: [:]][r, default: 0] += 1 }
    }
}

// ── Cluster totals (all 30) ──
var clusterTotal: [String: Int] = [:]
for c in caps { for cl in c.fired { clusterTotal[cl, default: 0] += 1 } }

var totalsOut = "cluster,weight,corpus_firings,pct_of_corpus\n"
for cl in ConceptClusters.all.sorted(by: { (ConceptClusters.weights[$0.name] ?? 0, $1.name) > (ConceptClusters.weights[$1.name] ?? 0, $0.name) }) {
    let n = clusterTotal[cl.name] ?? 0
    totalsOut += "\(cl.name),\(ConceptClusters.weights[cl.name] ?? 0),\(n),\(String(format: "%.1f%%", 100.0*Double(n)/Double(caps.count)))\n"
}
try! totalsOut.write(to: outDir.appendingPathComponent("cluster_totals.csv"), atomically: true, encoding: .utf8)
print("\nCluster totals written. Sanity (expected: devotion_belief 373, tenderness_care 662, confinement_freedom 550, bodily_gesture 968, stillness_rest 590):")
for cl in ["devotion_belief","tenderness_care","confinement_freedom","bodily_gesture","stillness_rest"] {
    print("  \(cl): \(clusterTotal[cl] ?? 0)")
}

// ── Judged-pair prep for enrichment ──
struct JP { let relType: String; let isRole: Bool; let mShared: Set<String>; let tokA: Set<String>; let tokB: Set<String> }
var judged: [JP] = []
for p in pairs {
    guard let a = p.captionA, let b = p.captionB, !a.isEmpty, !b.isEmpty else { continue }
    let cA = ConceptClusters.matchedClusters(for: a)
    let cB = ConceptClusters.matchedClusters(for: b)
    let mShared = cA.intersection(cB).filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
    judged.append(JP(relType: p.relType ?? "none", isRole: p.roleHyp != nil,
                     mShared: mShared, tokA: localTokens(a), tokB: localTokens(b)))
}
let nonRoleJudged = judged.filter { !$0.isRole }
let nonRoleBase = Double(nonRoleJudged.filter { $0.relType != "none" }.count) / Double(max(nonRoleJudged.count, 1))
print(String(format: "\nJudged: %d (non-role %d), non-role non-none base rate %.1f%%", judged.count, nonRoleJudged.count, nonRoleBase*100))

// ── Per (cluster, keyword) audit ──
func groupIndex(of keyword: String, in cluster: ConceptClusters.Cluster) -> Int? {
    guard let groups = cluster.requiredGroups else { return nil }
    return groups.firstIndex(where: { $0.contains(keyword) })
}

var auditCSV = "cluster,weight,group,keyword,firings,pct_of_cluster,sole_trigger,enrich_nonnone_pct,enrich_n,raw_forms,near_miss_stems\n"
var reviewLines: [String: [String]] = [:]   // cluster → sample-file sections
var aboveThresholdCount = 0

for cluster in ConceptClusters.all.sorted(by: { $0.name < $1.name }) {
    let total = clusterTotal[cluster.name] ?? 0
    let weight = ConceptClusters.weights[cluster.name] ?? 0

    // keywords to audit: for requiredGroups clusters iterate group-by-group
    let keywordList: [(String, Int?)]
    if let groups = cluster.requiredGroups {
        keywordList = groups.enumerated().flatMap { gi, g in g.sorted().map { ($0, gi as Int?) } }
    } else {
        keywordList = cluster.keywords.sorted().map { ($0, nil) }
    }

    for (kw, gi) in keywordList {
        // firings: captions whose token set contains kw
        let hits = caps.filter { $0.tokens.contains(kw) }
        let firings = hits.count

        // sole-trigger: removal delta
        var sole = 0
        for c in caps where c.fired.contains(cluster.name) && c.tokens.contains(kw) {
            if let groups = cluster.requiredGroups, let gi = gi {
                // sole satisfier of its group (other groups unaffected by removal)
                let others = groups[gi].subtracting([kw])
                if c.tokens.isDisjoint(with: others) { sole += 1 }
            } else {
                let others = cluster.keywords.subtracting([kw])
                if c.tokens.isDisjoint(with: others) { sole += 1 }
            }
        }

        // raw forms
        let rawForms = (globalRawForms[kw] ?? [:]).sorted { $0.value > $1.value }
            .map { "\($0.key):\($0.value)" }.joined(separator: " ")

        // near-miss stems: adjacent corpus stems that do NOT match this keyword
        // (and aren't other keywords of the same cluster)
        var nearMisses: [String] = []
        if kw.count >= 4 {
            for (stem, n) in stemFreq where stem != kw && n >= 2 {
                let related = stem.hasPrefix(kw) || kw.hasPrefix(stem)
                if related && abs(stem.count - kw.count) <= 4 && !cluster.keywords.contains(stem) {
                    nearMisses.append("\(stem):\(n)")
                }
            }
        }
        nearMisses.sort { (Int($0.split(separator: ":")[1]) ?? 0) > (Int($1.split(separator: ":")[1]) ?? 0) }
        let nearMissStr = nearMisses.prefix(6).joined(separator: " ")

        // enrichment: non-role judged pairs where cluster meaningfully shared AND kw in both sides
        let relevant = nonRoleJudged.filter { $0.mShared.contains(cluster.name) && $0.tokA.contains(kw) && $0.tokB.contains(kw) }
        let enrichN = relevant.count
        let enrichPct = enrichN > 0 ? 100.0 * Double(relevant.filter { $0.relType != "none" }.count) / Double(enrichN) : -1

        let pct = total > 0 ? 100.0 * Double(firings) / Double(total) : 0
        auditCSV += "\(cluster.name),\(weight),\(gi.map(String.init) ?? ""),\(kw),\(firings),\(String(format: "%.1f", pct)),\(sole),\(enrichPct >= 0 ? String(format: "%.0f", enrichPct) : ""),\(enrichN),\(rawForms.replacingOccurrences(of: ",", with: ";")),\(nearMissStr.replacingOccurrences(of: ",", with: ";"))\n"

        // sample dump for above-threshold keywords
        let above = firings >= 10 || pct >= 5.0 || sole >= 10
        if above && firings > 0 {
            aboveThresholdCount += 1
            var section = "\n## `\(kw)`\(gi.map { " (group \($0))" } ?? "")  — firings \(firings) (\(String(format: "%.0f", pct))% of cluster), sole-trigger \(sole)\n"
            section += "raw forms: \(rawForms)\n\n"
            // deterministic spread: evenly strided sample of up to 15 hit captions
            let stride = max(1, hits.count / 15)
            var shown = 0
            var i = 0
            while shown < 15 && i < hits.count {
                let c = hits[i]
                // pull the sentence(s) containing a matching raw word
                let raws = c.stemToRaw[kw] ?? []
                let sentences = c.caption.components(separatedBy: ". ")
                let matching = sentences.filter { s in
                    let lower = s.lowercased()
                    return raws.contains { lower.contains($0) }
                }
                let snippet = (matching.first ?? String(c.caption.prefix(160))).trimmingCharacters(in: .whitespacesAndNewlines)
                section += "- [\(c.id) \(c.filename)] «\(snippet)» (word: \(raws.sorted().joined(separator: ",")))\n"
                shown += 1
                i += stride
            }
            reviewLines[cluster.name, default: []].append(section)
        }
    }
}

try! auditCSV.write(to: outDir.appendingPathComponent("keyword_audit.csv"), atomically: true, encoding: .utf8)
for (cluster, sections) in reviewLines {
    let header = "# \(cluster) — weight \(ConceptClusters.weights[cluster] ?? 0), corpus firings \(clusterTotal[cluster] ?? 0)\n"
    try! (header + sections.joined()).write(to: outDir.appendingPathComponent("samples/\(cluster).md"), atomically: true, encoding: .utf8)
}
print("\nAudit table written (\(aboveThresholdCount) keywords above review threshold). Sample files: \(reviewLines.count) clusters.")

// ── Golden-pair baseline (G4=245↔246, G6=874↔80, G7=259↔80, G16=50↔572) ──
var golden = "golden-pair matchedClusters baseline\n"
for id in [245, 246, 874, 80, 259, 50, 572] {
    if let c = caps.first(where: { $0.id == id }) {
        golden += "\(id) [\(c.filename)]: \(c.fired.sorted().joined(separator: ", "))\n"
    } else {
        golden += "\(id): NOT FOUND in corpus\n"
    }
}
try! golden.write(to: outDir.appendingPathComponent("golden_baseline.txt"), atomically: true, encoding: .utf8)
print("Golden baseline written.\nDone.")
