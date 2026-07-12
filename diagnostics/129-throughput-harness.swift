import Foundation
import ConjunctEngine

// #129 throughput harness (bench-swap). Judges a representative sample and
// reports per-stage call counts + wall time, to decide where the per-pair
// cost lives (extraction vs probes vs grounding vs retrieval) and thus whether
// Lever B (cut grounding calls) or Lever C (cheaper probe model) has leverage.
//
//   conjunct-bench <sample.json>

struct JudgeCase: Decodable {
    let group: String; let a: Int; let b: Int
    let hypothesis: String?; let captionA: String; let captionB: String
}

@main
struct BenchmarkRunner {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let path = args.first,
              let data = FileManager.default.contents(atPath: path),
              let cases = try? JSONDecoder().decode([JudgeCase].self, from: data) else {
            print("Usage: conjunct-bench <sample.json>"); exit(1)
        }
        guard await ThematicScorerV2.isAvailable() else {
            print("Error: Ollama unreachable"); exit(1)
        }
        let scorer = ThematicScorerV2()
        await scorer.resetPerf()

        var confirms = 0, rejects = 0, fails = 0
        let t0 = Date()
        print("pair\tpath\tsecs\tverdict")
        for c in cases {
            let s = Date()
            let r: ThematicV2Result?
            do {
                if let h = c.hypothesis {
                    r = try await scorer.validate(captionA: c.captionA, captionB: c.captionB, hypothesis: h)
                } else {
                    r = try await scorer.score(captionA: c.captionA, captionB: c.captionB)
                }
            } catch { print("\(c.a)/\(c.b)\tERROR \(error.localizedDescription)"); continue }
            let secs = Date().timeIntervalSince(s)
            let path = c.hypothesis == nil ? "cold" : "validate"
            if let r { if r.score > 0 { confirms += 1 } else { rejects += 1 }
                print("\(c.a)/\(c.b)\t\(path)\t\(String(format: "%.1f", secs))\t\(String(format: "%.2f", r.score)) \(r.relationshipType)") }
            else { fails += 1; print("\(c.a)/\(c.b)\t\(path)\t\(String(format: "%.1f", secs))\tPARSE_FAIL") }
        }
        let total = Date().timeIntervalSince(t0)

        print("\n=== per-stage (calls + wall ms across all pairs) ===")
        print(await scorer.perfReport())
        let n = cases.count
        print("\n=== summary ===")
        print("pairs=\(n)  confirms=\(confirms) rejects=\(rejects) parse_fails=\(fails)")
        print("total wall=\(String(format: "%.0f", total))s  avg=\(String(format: "%.1f", total / Double(n)))s/pair")
    }
}
