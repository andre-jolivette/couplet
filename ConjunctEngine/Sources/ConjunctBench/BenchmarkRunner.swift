import Foundation
import CoreGraphics
import ImageIO
import GRDB
import ConjunctEngine

@main
struct BenchmarkRunner {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()

        guard let imageFolder = args.first, !imageFolder.hasPrefix("--") else {
            print("Usage: conjunct-bench <image-folder> [--model <path>] [--mock] [--top-k <N>]")
            exit(1)
        }

        let useMock   = args.contains("--mock")
        let modelPath = argValue(args, flag: "--model")
        let topK      = Int(argValue(args, flag: "--top-k") ?? "10") ?? 10
        let folderURL = URL(fileURLWithPath: imageFolder)

        let dbURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("conjunct-bench-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        guard let db = try? DatabaseManager(url: dbURL) else {
            print("Error: could not initialise database at \(dbURL.path)")
            exit(1)
        }

        let clipEngine: any CLIPInferenceEngine
        if useMock {
            print("⚡ Using MockCLIPEngine (simulated 30ms latency)")
            clipEngine = MockCLIPEngine(simulatedLatencyMs: 30)
        } else if let path = modelPath {
            let url = URL(fileURLWithPath: path)
            guard let engine = try? CLIPCoreMLEngine(modelURL: url) else {
                print("Error: could not load CLIP model at \(path)")
                print("Tip:  run `python Tools/convert_clip.py` to generate the model file.")
                exit(1)
            }
            print("🧠 Using CLIPCoreMLEngine: \(url.lastPathComponent)")
            clipEngine = engine
        } else {
            print("Error: provide --model <path> or --mock")
            exit(1)
        }

        let engine = IndexingEngine(db: db, clipEngine: clipEngine, maxConcurrency: 4)

        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  conjunct-bench")
        print("  Folder : \(folderURL.path)")
        print("  Top-K  : \(topK)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

        let overallStart = Date()
        var phaseTimings: [(String, TimeInterval)] = []
        var currentPhaseStart = Date()
        var currentPhase = ""

        let stream = await engine.index(
            folderURL: folderURL,
            duplicateSettings: DuplicateSettings(
                hammingThreshold: 8,
                allowIntraStackPairing: false,
                showReviewPrompt: false  // CLI: auto-proceed, just report
            ),
            topK: topK
        )

        for await progress in stream {
            let phaseName = progress.phase.rawValue

            if phaseName != currentPhase {
                if !currentPhase.isEmpty {
                    let elapsed = Date().timeIntervalSince(currentPhaseStart)
                    phaseTimings.append((currentPhase, elapsed))
                    print("\n  ✓ \(currentPhase.padding(toLength: 26, withPad: " ", startingAt: 0)) \(formatDuration(elapsed))")
                }
                currentPhase = phaseName
                currentPhaseStart = Date()
                print("  → \(phaseName)…", terminator: "")
                fflush(stdout)
            }

            if (progress.phase == .extraction || progress.phase == .scoring)
                && progress.itemsComplete % 10 == 0
                && progress.itemsComplete > 0 {
                print(".", terminator: "")
                fflush(stdout)
            }

            if progress.phase == .complete || progress.phase == .failed {
                let elapsed = Date().timeIntervalSince(currentPhaseStart)
                if progress.phase == .complete {
                    phaseTimings.append((currentPhase, elapsed))
                    print("\n  ✓ \(currentPhase.padding(toLength: 26, withPad: " ", startingAt: 0)) \(formatDuration(elapsed))")
                } else {
                    print("\n  ✗ FAILED: \(progress.errorMessage ?? "unknown error")")
                }
                break
            }
        }

        let totalElapsed = Date().timeIntervalSince(overallStart)

        guard
            let imageCount = try? db.read({ db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM images") ?? 0
            }),
            let pairCount = try? db.read({ db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pairs") ?? 0
            }),
            let topPairs = try? db.read({ db -> [(Double, String, String, String)] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT p.compositeScore, p.rationale,
                               a.filename AS nameA, b.filename AS nameB
                        FROM pairs p
                        JOIN images a ON a.id = p.imageAID
                        JOIN images b ON b.id = p.imageBID
                        ORDER BY p.compositeScore DESC
                        LIMIT 5
                    """
                )
                return rows.map {
                    ($0["compositeScore"] as! Double,
                     $0["rationale"] as! String,
                     $0["nameA"] as! String,
                     $0["nameB"] as! String)
                }
            })
        else {
            print("\nCould not read results from database.")
            exit(1)
        }

        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  RESULTS")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Images indexed : \(imageCount)")
        print("  Pairs scored   : \(pairCount)")
        print("  Total time     : \(formatDuration(totalElapsed))")

        if imageCount > 0 {
            let extractionTime = phaseTimings.first(where: { $0.0 == "Extracting features" })?.1 ?? 0
            let throughput = extractionTime > 0 ? Double(imageCount) / extractionTime : 0
            print("  Throughput     : \(String(format: "%.1f", throughput)) images/sec (extraction)")
        }

        if !topPairs.isEmpty {
            print("\n  TOP 5 PAIRS")
            for (score, rationale, nameA, nameB) in topPairs {
                print("  [\(String(format: "%.3f", score))]  \(nameA)  ↔  \(nameB)")
                print("         \(rationale)")
            }
        }

        // Report duplicate groups
        if let dupCount = try? db.read({ db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM duplicateGroups") ?? 0
        }), dupCount > 0,
           let dupRows = try? db.read({ db -> [(String)] in
               let rows = try Row.fetchAll(
                   db,
                   sql: """
                       SELECT GROUP_CONCAT(i.filename, ', ') AS members
                       FROM images i
                       JOIN duplicateGroups g ON g.id = i.duplicateGroupID
                       GROUP BY i.duplicateGroupID
                       LIMIT 5
                   """
               )
               return rows.map { $0["members"] as! String }
           }) {
            print("\n  DUPLICATE STACKS FOUND: \(dupCount)")
            print("  (hero images only used for pairing — non-heroes excluded)")
            for members in dupRows {
                print("  ⚠ \(members)")
            }
        }

        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    }

    static func argValue(_ args: ArraySlice<String>, flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), args.index(after: idx) < args.endIndex else {
            return nil
        }
        return args[args.index(after: idx)]
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        if t < 60 { return String(format: "%.1fs", t) }
        let m = Int(t / 60), s = Int(t.truncatingRemainder(dividingBy: 60))
        return "\(m)m \(s)s"
    }
}
