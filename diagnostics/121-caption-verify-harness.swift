import Foundation
import ConjunctEngine

// #121 phase-2 verification harness — bench-swap of BenchmarkRunner.swift.
// Given the baseline and candidate caption TSVs produced by the phase-1 harness
// (diagnostics/121-caption-gender-harness.swift):
//   1. Cluster-firing diff (ConceptClusters.matchedClusters) for all cases.
//   2. Real RoleProfile extraction (qwen2.5:14b-instruct) from candidate captions
//      of the G4/G6/G7/G16 anchor images.
//   3. Pairwise RoleJoins.join on the four golden pairs.
//   4. ThematicScorerV2.validate() with candidate captions + stored DB hypotheses.
// Usage: swift run conjunct-bench <candidate-label>
// Run with label "baseline" to isolate environment drift from prompt-change effects.

@main
struct BenchmarkRunner {
    static let outDir = "/private/tmp/claude-501/-Users-andrejolivette-Documents-00-projects--couplet/59a9c022-84ea-41c5-9d11-99fa0f7995d9/scratchpad"

    static let anchorIDs = [245, 246, 874, 80, 259, 50, 572]

    // (name, idA, idB, stored hypothesis, stored score/type) — from the 2026-07-09 production DB copy.
    static let goldenPairs: [(String, Int, Int, String, String)] = [
        ("G4", 245, 246,
         "contrastive: the same kind of thing — a pigeons — appears REAL in one image and as a depicted version in the other, one earnest and one play or representation",
         "0.95 contrastive"),
        ("G6", 874, 80,
         "ironic: a sign or text announces or demands \u{2018}smile\u{2019}, while the other image's subject literally embodies or contradicts that very idea",
         "1.0 ironic"),
        ("G7", 259, 80,
         "ironic: a sign or text announces or demands \u{2018}smile\u{2019}, while the other image's subject literally embodies or contradicts that very idea",
         "1.0 ironic"),
        ("G16", 50, 572,
         "complementary: one image is the SOURCE of sound — it is produced there — while the other shows sound being RECEIVED or physically blocked",
         "1.0 complementary"),
    ]

    static func loadTSV(_ path: String) -> [Int: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [Int: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            if cols.count >= 5, let id = Int(cols[0]) { out[id] = String(cols[4]) }
        }
        return out
    }

    static func main() async {
        let label = CommandLine.arguments.dropFirst().first ?? "candidate-v5"
        let baseline = loadTSV("\(outDir)/121-captions-baseline.tsv")
        let candidate = loadTSV("\(outDir)/121-captions-\(label).tsv")
        guard !baseline.isEmpty, !candidate.isEmpty else {
            print("Missing TSVs"); exit(1)
        }

        // ── 1. Cluster-firing diff ──────────────────────────────────────────
        print("━━ 1. Cluster diff (baseline → \(label)) ━━")
        for id in baseline.keys.sorted() {
            guard let b = baseline[id], let c = candidate[id] else { continue }
            let cb = ConceptClusters.matchedClusters(for: b)
            let cc = ConceptClusters.matchedClusters(for: c)
            if cb != cc {
                let lost = cb.subtracting(cc).sorted().joined(separator: ",")
                let gained = cc.subtracting(cb).sorted().joined(separator: ",")
                print("  \(id): lost [\(lost)]  gained [\(gained)]")
            }
        }
        print("  (unlisted cases: identical cluster sets)\n")

        // ── 2. Role extraction on anchors ───────────────────────────────────
        print("━━ 2. RoleProfile extraction from \(label) captions ━━")
        let roleEngine = OllamaRoleExtractionEngine()
        var profiles: [Int: RoleProfile] = [:]
        let enc = JSONEncoder()
        for id in anchorIDs {
            guard let caption = candidate[id] else { continue }
            do {
                let p = try await roleEngine.extract(caption: caption)
                profiles[id] = p
                let json = (try? enc.encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
                print("  \(id): \(json)")
            } catch {
                print("  \(id): EXTRACTION ERROR \(error)")
            }
        }
        print("")

        // ── 3. Pairwise RoleJoins ───────────────────────────────────────────
        print("━━ 3. RoleJoins.join on golden pairs ━━")
        for (name, a, b, _, _) in goldenPairs {
            guard let pa = profiles[a], let pb = profiles[b] else {
                print("  \(name) (\(a),\(b)): missing profile"); continue
            }
            if let cand = RoleJoins.join(pa, pb) ?? RoleJoins.join(pb, pa) {
                print("  \(name) (\(a),\(b)): join\(cand.priority) [\(cand.relationshipType)] \(cand.hypothesis)")
            } else {
                print("  \(name) (\(a),\(b)): NO JOIN FIRED")
            }
        }
        print("")

        // ── 4. Judge validate() with candidate captions + stored hypotheses ─
        print("━━ 4. ThematicScorerV2.validate() — \(label) captions, stored hypotheses ━━")
        guard await ThematicScorerV2.isAvailable() else {
            print("  qwen2.5:14b-instruct not available"); exit(1)
        }
        let scorer = ThematicScorerV2()
        for (name, a, b, hyp, stored) in goldenPairs {
            guard let ca = candidate[a], let cb = candidate[b] else { continue }
            do {
                if let r = try await scorer.validate(captionA: ca, captionB: cb, hypothesis: hyp) {
                    let mark = r.connected ? "CONFIRMED" : "REJECTED"
                    print("  \(name): \(mark) \(String(format: "%.2f", r.score)) \(r.relationshipType) (stored: \(stored))")
                    print("        \(r.rationale)")
                } else {
                    print("  \(name): PARSE FAILURE (stored: \(stored))")
                }
            } catch {
                print("  \(name): ERROR \(error)")
            }
        }
    }
}
