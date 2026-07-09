import Foundation
import ConjunctEngine

// #124 judge-rubric harness (bench-swap; real BenchmarkRunner.swift restored after).
// Reads a cases.json exported from a production-DB copy and replays each pair through
// the REAL ThematicScorerV2.score()/validate() so prompt edits can be iterated in
// ~2 min instead of the full 45-min background pass.
//
// Usage: conjunct-bench <cases.json> [--group target|golden|regress_ok|regress_rej] [--runs N]

struct JudgeCase: Decodable {
    let group: String
    let a: Int
    let b: Int
    let baselineScore: Double?
    let baselineType: String?
    let hypothesis: String?
    let captionA: String
    let captionB: String
}

@main
struct BenchmarkRunner {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let casesPath = args.first, !casesPath.hasPrefix("--") else {
            print("Usage: conjunct-bench <cases.json> [--group <name>] [--runs N]")
            exit(1)
        }
        let groupFilter = argValue(args, flag: "--group")
        let runs = Int(argValue(args, flag: "--runs") ?? "1") ?? 1

        guard let data = FileManager.default.contents(atPath: casesPath),
              let allCases = try? JSONDecoder().decode([JudgeCase].self, from: data) else {
            print("Error: could not read/decode \(casesPath)")
            exit(1)
        }
        let cases = groupFilter.map { g in allCases.filter { $0.group == g } } ?? allCases

        guard await ThematicScorerV2.isAvailable() else {
            print("Error: Ollama unreachable or qwen2.5:14b-instruct missing")
            exit(1)
        }
        let scorer = ThematicScorerV2()

        print("pair\tgroup\tpath\tbase\trun_score\ttype\trationale")
        for c in cases {
            for run in 0..<runs {
                let result: ThematicV2Result?
                do {
                    if let hyp = c.hypothesis {
                        result = try await scorer.validate(captionA: c.captionA, captionB: c.captionB, hypothesis: hyp)
                    } else {
                        result = try await scorer.score(captionA: c.captionA, captionB: c.captionB)
                    }
                } catch {
                    print("\(c.a)/\(c.b)\t\(c.group)\tERROR: \(error.localizedDescription)")
                    continue
                }
                let path = c.hypothesis == nil ? "cold" : "validate"
                let base = c.baselineScore.map { String(format: "%.2f", $0) } ?? "—"
                if let r = result {
                    let runLabel = runs > 1 ? " r\(run)" : ""
                    print("\(c.a)/\(c.b)\(runLabel)\t\(c.group)\t\(path)\t\(base)\t\(String(format: "%.2f", r.score))\t\(r.relationshipType)\t\(r.rationale)")
                } else {
                    print("\(c.a)/\(c.b)\t\(c.group)\t\(path)\t\(base)\tPARSE_FAIL")
                }
            }
        }
    }

    static func argValue(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
