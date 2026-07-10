import Foundation
import GRDB
import ConjunctEngine

// #125 sign-register harness — bench-swap of BenchmarkRunner.swift.
// Two subcommands:
//   extract <label> — run the REAL OllamaRoleExtractionEngine (whatever prompt is in
//     RoleExtractionEngine.swift) on the case set's captions from the production DB
//     copy; write profiles to <scratchpad>/125-profiles-<label>.json.
//   replay <label>  — load ALL hero profiles from the DB copy, overlay the label's
//     re-extracted profiles, and replicate generateRoleCandidates' #113 admission
//     exactly (CorpusFreq, global sort priority/specificity/id, per-image per-type
//     caps {1:8, 2:8, 3:5, 4:12}); report join-type counts, sign-hypothesis count,
//     and golden/anchor pair admission status vs the same replay on unmodified DB
//     profiles (label "db").
// Usage: swift run conjunct-bench extract baseline

@main
struct BenchmarkRunner {
    static let outDir = "/private/tmp/claude-501/-Users-andrejolivette-Documents-00-projects--couplet/59a9c022-84ea-41c5-9d11-99fa0f7995d9/scratchpad"
    static let dbPath = outDir + "/conjunct-125.db"

    struct Case { let id: Int64; let kind: String; let note: String }
    static let cases: [Case] = [
        // Sign-register defect targets — physical signs tagged depicted
        Case(id: 220, kind: "target", note: "#125 named: sign/communication depicted"),
        Case(id: 363, kind: "target", note: "#125 named: printed figure -> (police, depicted, person)"),
        Case(id: 670, kind: "target", note: "#125 named: sign/message depicted"),
        Case(id: 695, kind: "target", note: "#125 named: sign/text depicted"),
        Case(id: 33,  kind: "target", note: "sign/text"),
        Case(id: 37,  kind: "target", note: "sign/communication (megaphone sibling 9077)"),
        Case(id: 150, kind: "target", note: "sign/text"),
        Case(id: 187, kind: "target", note: "street sign/sign — real street sign"),
        Case(id: 193, kind: "target", note: "sign/artifact"),
        Case(id: 310, kind: "target", note: "building sign/text"),
        Case(id: 373, kind: "target", note: "sign/warning"),
        Case(id: 400, kind: "target", note: "sign/communication"),
        Case(id: 456, kind: "target", note: "signs and banners/communication"),
        Case(id: 545, kind: "target", note: "sign/text"),
        Case(id: 690, kind: "target", note: "banner/text"),
        Case(id: 752, kind: "target", note: "building entrance sign/text"),
        // Anchors — join-relevant content must be preserved
        Case(id: 245, kind: "anchor-G4",  note: "real pigeons must stay real"),
        Case(id: 246, kind: "anchor-G4",  note: "peacock MURAL must stay depicted"),
        Case(id: 367, kind: "anchor-G9",  note: "caged dog: subverts escape"),
        Case(id: 153, kind: "anchor-G9",  note: "escape sign: claims escape"),
        Case(id: 587, kind: "anchor-G14", note: "mannequins: enacts hold hands + tenderness"),
        Case(id: 645, kind: "anchor-G14", note: "wall text: claims miss"),
        Case(id: 61,  kind: "anchor-G15", note: "flag symbol object keeps #111 register"),
        Case(id: 564, kind: "anchor-G15", note: "cross + rainbow symbol objects keep registers"),
        Case(id: 50,  kind: "anchor-G16", note: "megaphone: speech/sound source"),
        Case(id: 572, kind: "anchor-G16", note: "ears-woman: receiver side"),
        Case(id: 874, kind: "anchor-G6",  note: "Smile poster: claims smile"),
        Case(id: 80,  kind: "anchor-G6G7", note: "smiling woman: enacts joy/smile"),
        Case(id: 259, kind: "anchor-G7",  note: "painted SMILE sidewalk: claims smile (also sign-class member)"),
    ]

    // (name, idA, idB, join type expected in the db replay)
    static let goldenPairs: [(String, Int64, Int64)] = [
        ("G4", 245, 246), ("G9", 153, 367), ("G14", 587, 645), ("G16", 50, 572),
        ("G6", 80, 874), ("G7", 80, 259),
    ]

    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        let mode = args.first ?? "extract"
        let label = args.dropFirst().first ?? "baseline"
        switch mode {
        case "extract": try await extract(label: label)
        case "extract-ids":
            // extract-ids <ids-file> <label> — re-extract an arbitrary id list
            let file = label
            let lbl = args.dropFirst(2).first ?? "signclass"
            let ids = try String(contentsOfFile: file, encoding: .utf8)
                .split(separator: "\n").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            try await extract(label: lbl, ids: ids)
        case "replay":  try replay(label: label)
        default: print("usage: conjunct-bench extract|extract-ids|replay <label>"); exit(1)
        }
    }

    // ── extract ─────────────────────────────────────────────────────────────
    static func extract(label: String, ids overrideIDs: [Int64]? = nil) async throws {
        let dbq = try DatabaseQueue(path: dbPath)
        let caseList: [Case] = overrideIDs.map { $0.map { Case(id: $0, kind: "ids-file", note: "") } } ?? cases
        let ids = caseList.map { "\($0.id)" }.joined(separator: ",")
        let captions: [Int64: String] = try await dbq.read { db in
            var m = [Int64: String]()
            for row in try Row.fetchAll(db, sql: "SELECT id, caption FROM images WHERE id IN (\(ids))") {
                m[row["id"] as! Int64] = row["caption"] as? String ?? ""
            }
            return m
        }
        let engine = OllamaRoleExtractionEngine()
        let enc = JSONEncoder()
        var out: [String: String] = [:]   // id -> profile JSON
        for c in caseList {
            guard let cap = captions[c.id], !cap.isEmpty else { print("‼️ \(c.id): no caption"); continue }
            do {
                let p = try await engine.extract(caption: cap)
                let json = String(data: try enc.encode(p), encoding: .utf8)!
                out["\(c.id)"] = json
                let deps = p.objects.filter { $0.register == "depicted" }.map { "\($0.object)/\($0.category)" }
                print("── \(c.id) [\(c.kind)] depicted: \(deps.isEmpty ? "-" : deps.joined(separator: ", "))")
                print("   claims: \(p.claims)  objects: \(p.objects.map { "(\($0.object),\($0.register))" }.joined(separator: " "))")
            } catch {
                print("‼️ \(c.id): \(error)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: "\(outDir)/125-profiles-\(label).json"))
        print("\nWrote 125-profiles-\(label).json (\(out.count) profiles)")
    }

    // ── replay ──────────────────────────────────────────────────────────────
    static func replay(label: String) throws {
        let dbq = try DatabaseQueue(path: dbPath)
        struct Profiled { let id: Int64; let profile: RoleProfile }
        let dec = JSONDecoder()
        var profiled: [Profiled] = try dbq.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, roleProfile FROM images
                WHERE isActive = 1 AND isHero = 1 AND roleProfile IS NOT NULL
            """).compactMap { row in
                guard let id = row["id"] as? Int64,
                      let json = row["roleProfile"] as? String,
                      let p = try? dec.decode(RoleProfile.self, from: json.data(using: .utf8)!) else { return nil }
                return Profiled(id: id, profile: p)
            }
        }
        // Overlay re-extracted profiles unless replaying raw DB state
        if label != "db" {
            let url = URL(fileURLWithPath: "\(outDir)/125-profiles-\(label).json")
            let overlay = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
            var replaced = 0
            profiled = profiled.map { pr in
                if let json = overlay["\(pr.id)"],
                   let p = try? dec.decode(RoleProfile.self, from: json.data(using: .utf8)!) {
                    replaced += 1
                    return Profiled(id: pr.id, profile: p)
                }
                return pr
            }
            print("overlaid \(replaced) profiles from label '\(label)'")
        }

        // Exact #113 admission replica (IndexingEngine.generateRoleCandidates)
        let freq = RoleJoins.CorpusFreq.build(profiled.map(\.profile))
        struct Cand { let a: Int64; let b: Int64; let join: RoleJoins.Candidate }
        var all: [Cand] = []
        for i in 0..<profiled.count {
            for j in (i + 1)..<profiled.count {
                guard let c = RoleJoins.join(profiled[i].profile, profiled[j].profile, freq: freq) else { continue }
                all.append(Cand(a: profiled[i].id, b: profiled[j].id, join: c))
            }
        }
        all.sort { l, r in
            if l.join.priority != r.join.priority { return l.join.priority < r.join.priority }
            if l.join.specificity != r.join.specificity { return l.join.specificity > r.join.specificity }
            if l.a != r.a { return l.a < r.a }
            return l.b < r.b
        }
        let caps: [Int: Int] = [1: 8, 2: 8, 3: 5, 4: 12]
        var degree: [String: Int] = [:]
        var admitted: [Cand] = []
        for c in all {
            let cap = caps[c.join.priority] ?? 8
            let ka = "\(c.a)#\(c.join.priority)", kb = "\(c.b)#\(c.join.priority)"
            if (degree[ka] ?? 0) < cap && (degree[kb] ?? 0) < cap {
                admitted.append(c)
                degree[ka, default: 0] += 1; degree[kb, default: 0] += 1
            }
        }

        func signHyp(_ c: Cand) -> Bool {
            c.join.priority == 3 && c.join.hypothesis.lowercased().contains("a sign —")
        }
        var byType: [Int: Int] = [:]
        for c in admitted { byType[c.join.priority, default: 0] += 1 }
        print("profiles: \(profiled.count)  raw candidates: \(all.count)  admitted: \(admitted.count)")
        print("admitted by join type: \(byType.sorted { $0.key < $1.key }.map { "join\($0.key)=\($0.value)" }.joined(separator: "  "))")
        print("sign-hypothesis (join3 'a sign —'): raw \(all.filter(signHyp).count), admitted \(admitted.filter(signHyp).count)")
        // Diagnostics: every join-3 candidate touching the G4 images, with admission state
        print("\njoin3 candidates touching 245/246 (specificity desc):")
        let g4cands = all.filter { $0.join.priority == 3 && ($0.a == 245 || $0.b == 245 || $0.a == 246 || $0.b == 246) }
        let admittedSet = Set(admitted.map { "\($0.a)-\($0.b)" })
        for c in g4cands.sorted(by: { $0.join.specificity > $1.join.specificity }).prefix(14) {
            let mark = admittedSet.contains("\(c.a)-\(c.b)") ? "ADMITTED" : "capped  "
            print("  \(mark) spec=\(String(format: "%.2f", c.join.specificity))  (\(c.a),\(c.b))  \(c.join.hypothesis.prefix(70))")
        }
        print("\ngolden/anchor pairs:")
        for (name, a, b) in goldenPairs {
            let hit = admitted.first { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
            let raw = all.first { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
            if let h = hit {
                print("  \(name) (\(a),\(b)): ADMITTED join\(h.join.priority)  \(h.join.hypothesis.prefix(90))")
            } else if let r = raw {
                print("  \(name) (\(a),\(b)): raw-only (capped out) join\(r.join.priority)")
            } else {
                print("  \(name) (\(a),\(b)): no join fired")
            }
        }
    }
}
