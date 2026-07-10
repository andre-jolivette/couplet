import Foundation
import ConjunctEngine

// #121 caption-gender harness — bench-swap of BenchmarkRunner.swift.
// Calls the REAL OllamaCaptioningEngine (whatever prompt is currently in
// CaptioningEngine.swift) on a fixed case list: 18 misgendering targets
// (face-hidden subjects the production captions gender wrongly) plus 10
// anti-overcorrection controls/anchors (gender clearly visible and/or
// role-join content load-bearing for G4/G6/G7/G16).
// Usage: swift run conjunct-bench <label>   (label names the output TSV)
// Output: <scratchpad>/121-captions-<label>.tsv

@main
struct BenchmarkRunner {
    struct Case {
        let id: Int
        let file: String
        let kind: String   // target-<mode> | control | anchor
        let note: String
    }

    static let libraryRoot = "/Users/andrejolivette/Documents/00-projects/_couplet/00-test-pairing-folder"
    static let outDir = "/private/tmp/claude-501/-Users-andrejolivette-Documents-00-projects--couplet/59a9c022-84ea-41c5-9d11-99fa0f7995d9/scratchpad"

    static let cases: [Case] = [
        // Misgendered targets — face-hidden, caption must NOT gender
        Case(id: 277, file: "20250503-_DSF0200.jpg",  kind: "target-back",       note: "back to camera, man, captioned woman"),
        Case(id: 983, file: "20250515-_DSF2511.jpg",  kind: "target-back",       note: "back to camera, man, captioned woman"),
        Case(id: 875, file: "20250515-_DSF2517.jpg",  kind: "target-back",       note: "back to camera, man, captioned woman"),
        Case(id: 62,  file: "20250515-_DSF2454.jpg",  kind: "target-back",       note: "back to camera, man, captioned woman"),
        Case(id: 113, file: "20250515-_DSF2053.jpg",  kind: "target-back",       note: "back to camera, man, captioned woman"),
        Case(id: 205, file: "20250515-_DSF2444.jpg",  kind: "target-back",       note: "rodeo rider, man, captioned woman (#121 log)"),
        Case(id: 313, file: "20250322-_DSF1921.jpg",  kind: "target-far",        note: "side-turned/far, man, captioned woman"),
        Case(id: 867, file: "20240517-DSCF3269-positive.jpg", kind: "target-far", note: "side-turned/far, man, captioned woman"),
        Case(id: 833, file: "20250515-_DSF1815.jpg",  kind: "target-silhouette", note: "backlit silhouette, man, captioned woman"),
        Case(id: 812, file: "20250515-_DSF1009.jpg",  kind: "target-silhouette", note: "backlit silhouette, man, captioned woman"),
        Case(id: 766, file: "20200607-DSCF5031.jpg",  kind: "target-masked",     note: "masked, front 3/4 on horse, man, captioned woman"),
        Case(id: 152, file: "20200801-L1009481.jpg",  kind: "target-masked",     note: "masked + back to camera, man, captioned woman"),
        Case(id: 892, file: "20250523-_DSF3226.jpg",  kind: "target-hat",        note: "cowgirl head down, hat obscures face, captioned man"),
        Case(id: 599, file: "20200801-L1009607.jpg",  kind: "target-back",       note: "protester facing away, man, captioned woman (#121 log)"),
        Case(id: 6,   file: "20250316-_R013361.jpg",  kind: "target-helmet",     note: "dirt-bike rider, helmet, man, captioned woman (#121 log)"),
        Case(id: 940, file: "20240818-L1000153.jpg",  kind: "target-far",        note: "lying on pavement, too small to gender, captioned woman (#121 log)"),
        Case(id: 138, file: "20250319-_DSF1049.jpg",  kind: "target-halluc",     note: "no person present — caption invents a woman (#121 mode 1)"),
        Case(id: 267, file: "20250329-_R013838.jpg",  kind: "target-depicted",   note: "printed photo on sign read as real people (#121 mode 4, secondary scope)"),
        // Controls — gender clearly visible, MUST stay gendered
        Case(id: 80,  file: "42-20250326-_DSF3629.jpg", kind: "anchor-G6G7",     note: "smiling woman, face visible — 'woman' load-bearing for judge"),
        Case(id: 572, file: "20250405-_R014662.jpg",  kind: "anchor-G16",        note: "ears-woman, face visible; role content: hands cupping ears"),
        Case(id: 50,  file: "20250315-_DSF9076.jpg",  kind: "anchor-G16",        note: "megaphone man (mouth covered by megaphone — borderline); role content: megaphone/speech"),
        Case(id: 874, file: "07-20190120-_G130022.jpg", kind: "anchor-G6",       note: "man with glasses, face visible"),
        Case(id: 259, file: "96-20250823-_DSF6565.jpg", kind: "anchor-G7",       note: "only feet visible — degendering OK; role content: SMILE sidewalk text must survive"),
        Case(id: 245, file: "10-20201030-L1000519.jpg", kind: "anchor-G4",       note: "back to viewer — degendering OK; role content: pigeons must survive"),
        Case(id: 246, file: "87-20250706-R0024349.jpg", kind: "anchor-G4",       note: "woman face visible?; role content: peacock mural (depicted) must survive"),
        Case(id: 107, file: "20240720-_DSF7871.jpg",  kind: "control-male",      note: "smiling man, face visible, beard — must stay man"),
        Case(id: 78,  file: "20250405-_R014387.jpg",  kind: "control-male",      note: "long-bearded man, face visible — must stay man"),
        Case(id: 15,  file: "00-20241221-_DSF4186.jpg", kind: "control-male",    note: "beard visible, eyes closed — gender from beard, must stay man"),
    ]

    // Crude gender-term detector for the summary column (full caption still reviewed by hand).
    static func genderTerms(in caption: String) -> String {
        let lower = " " + caption.lowercased()
            .replacingOccurrences(of: "[^a-z]", with: " ", options: .regularExpression) + " "
        var hits: [String] = []
        for term in ["woman", "women", "man", "men", "girl", "boy", "lady", "female", "male",
                     "she", "her", "hers", "he", "his", "him", "cowgirl", "cowboy"] {
            let count = lower.components(separatedBy: " \(term) ").count - 1
            if count > 0 { hits.append("\(term)×\(count)") }
        }
        return hits.isEmpty ? "-" : hits.joined(separator: ",")
    }

    static func main() async {
        let label = CommandLine.arguments.dropFirst().first ?? "run"
        let engine = OllamaCaptioningEngine()
        var tsv = "id\tfile\tkind\tgenderTerms\tcaption\tnote\n"

        print("#121 caption harness — \(cases.count) cases, label '\(label)'\n")
        for c in cases {
            let url = URL(fileURLWithPath: "\(libraryRoot)/\(c.file)")
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("‼️ MISSING FILE: \(c.file)"); continue
            }
            let start = Date()
            do {
                let caption = try await engine.caption(imageURL: url)
                let flat = caption.replacingOccurrences(of: "\t", with: " ")
                                  .replacingOccurrences(of: "\n", with: " ")
                let terms = genderTerms(in: caption)
                tsv += "\(c.id)\t\(c.file)\t\(c.kind)\t\(terms)\t\(flat)\t\(c.note)\n"
                print("── \(c.id) \(c.file) [\(c.kind)] \(String(format: "%.1fs", Date().timeIntervalSince(start)))")
                print("   gender: \(terms)")
                print("   \(caption)\n")
            } catch {
                print("‼️ ERROR \(c.id) \(c.file): \(error)")
                tsv += "\(c.id)\t\(c.file)\t\(c.kind)\tERROR\t\(error)\t\(c.note)\n"
            }
        }

        let outPath = "\(outDir)/121-captions-\(label).tsv"
        try? tsv.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("\nWrote \(outPath)")
    }
}
