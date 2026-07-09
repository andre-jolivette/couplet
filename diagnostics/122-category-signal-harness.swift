import Foundation
import ConjunctEngine

// #122 — category-overlap signal diagnostic.
//
// For every hero image: compute matchedClusters, the meaningful (>=0.75) cluster
// set, and the deterministic representativeCluster. Then for named test pairs and
// golden pairs, print the shared meaningful clusters, the shared representative,
// and corpus frequency of each shared cluster (a category-specificity proxy).
//
// Read-only. Reuses the real ConceptClusters matcher. Usage:
//   CategoryDiag <captions.json>
// captions.json = [{ "id": Int, "caption": String }, ...]

struct CorpusImage: Decodable { let id: Int; let caption: String }

let args = CommandLine.arguments
guard args.count > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let corpus = try? JSONDecoder().decode([CorpusImage].self, from: data) else {
    FileHandle.standardError.write("usage: CategoryDiag <captions.json>\n".data(using: .utf8)!)
    exit(1)
}

// Compute per-image cluster sets.
var clustersByID: [Int: Set<String>] = [:]
var meaningfulByID: [Int: Set<String>] = [:]
var repByID: [Int: String] = [:]
var corpusClusterFreq: [String: Int] = [:]     // # images firing each cluster
var corpusMeaningfulFreq: [String: Int] = [:]   // # images firing each meaningful cluster

for img in corpus {
    let cs = ConceptClusters.matchedClusters(for: img.caption)
    clustersByID[img.id] = cs
    let meaningful = cs.filter { (ConceptClusters.weights[$0] ?? 0) >= 0.75 }
    meaningfulByID[img.id] = meaningful
    if let rep = ConceptClusters.representativeCluster(in: meaningful) { repByID[img.id] = rep }
    for c in cs { corpusClusterFreq[c, default: 0] += 1 }
    for c in meaningful { corpusMeaningfulFreq[c, default: 0] += 1 }
}

let total = corpus.count
func pct(_ n: Int) -> String { String(format: "%.1f%%", 100.0 * Double(n) / Double(total)) }

func report(_ label: String, _ a: Int, _ b: Int) {
    let ca = clustersByID[a] ?? [], cb = clustersByID[b] ?? []
    let ma = meaningfulByID[a] ?? [], mb = meaningfulByID[b] ?? []
    let sharedAll = ca.intersection(cb).sorted()
    let sharedMeaningful = ma.intersection(mb).sorted()
    let repA = repByID[a] ?? "-", repB = repByID[b] ?? "-"
    let sharedRep = (repA == repB && repA != "-") ? repA : "—"
    print("\n=== \(label)  (A=\(a) B=\(b)) ===")
    print("  repA=\(repA)  repB=\(repB)  sharedRep=\(sharedRep)")
    print("  meaningful A: \(ma.sorted())")
    print("  meaningful B: \(mb.sorted())")
    print("  shared meaningful: \(sharedMeaningful.map { "\($0)[\(corpusMeaningfulFreq[$0] ?? 0), \(pct(corpusMeaningfulFreq[$0] ?? 0))]" })")
    print("  shared all:        \(sharedAll.map { "\($0)[\(corpusClusterFreq[$0] ?? 0)]" })")
}

print("### corpus size: \(total) hero images")
print("\n### Meaningful-cluster corpus frequency (category-density proxy):")
for (c, n) in corpusMeaningfulFreq.sorted(by: { $0.value > $1.value }) {
    print(String(format: "  %-24@ %5d  %@", c as NSString, n, pct(n)))
}

print("\n\n########## NAMED #122 PAIRS (bad — should be discounted) ##########")
report("P1 protest 105/220 (cross-event 82d)", 105, 220)
report("P2 protest 486/804 (cross-event 73d)", 486, 804)
report("P3 protest 339/670 (cross-event 40d)", 339, 670)
report("P4 protest 363/695 (cross-event 1796d)", 363, 695)
report("P5 pets   238/811 (cross-event 265d)", 238, 811)
report("P6 protest 18/126  (cross-event 32d)", 18, 126)
report("P7 skate  729/1009 (SAME-EVENT 0.01d)", 729, 1009)
report("P8 skate  278/643  (SAME-EVENT 0.04d)", 278, 643)

print("\n\n########## GOLDEN PAIRS (good — must NOT be discounted) ##########")
report("G4 pigeons/peacock 245/246 (V2 0.95)", 245, 246)
report("G6 smile 874/80 (V2 0.95)", 874, 80)
report("G7 smile 259/80 (V2 0.95)", 259, 80)
report("G16 megaphone/ears 50/572 (V2 0.95)", 50, 572)
report("G1 rose/flowers 176/494", 176, 494)
report("G5 musician/ears 822/572", 822, 572)
report("G8 smile/hoop 259/598", 259, 598)
report("G9 cage/escape 367/153", 367, 153)
report("G10 see/eyes 474/513", 474, 513)
report("G13 flags 371/293", 371, 293)
report("G14 miss/mannequins 645/587", 645, 587)
report("G15 pride 61/564", 61, 564)
