import Foundation
import ConjunctEngine

// #122 — before/after axisScore replay validation.
// Replays the display-layer axisScore math (convertToPair) for every pair, with
// and without the #122 event-proximity thematic discount, using default weights
// (aesthetic 0.40, geometric 0.20, thematic 0.40). Reports the 8 named pairs and
// all golden pairs (rank + axisScore before/after), and confirms no golden pair
// is discounted. Read-only. Usage: RescoreDiag <pairs.json>

struct P: Decodable {
    let pairID: Int; let a: Int; let b: Int
    let aesth: Double; let geo: Double; let clusterThematic: Double
    let v2: Double?; let roleHyp: Int; let selectedFor: String; let gaze: Double?
    let dateA: Double?; let dateB: Double?; let capA: String; let capB: String
}

let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let pairs = try! JSONDecoder().decode([P].self, from: data)

let wA: Float = 0.40, wG: Float = 0.20, wT: Float = 0.40

func temporalPenalty(_ da: Double?, _ db: Double?) -> Float {
    guard let a = da, let b = db else { return 1.0 }
    let gap = abs(a - b)
    if gap <= 30 { return 0.40 }; if gap <= 60 { return 0.55 }
    if gap <= 120 { return 0.75 }; if gap <= 300 { return 0.90 }
    return 1.0
}

func date(_ d: Double?) -> Date? { d.map { Date(timeIntervalSince1970: $0) } }

// Mirror convertToPair's axisScore, `applyDiscount` toggles the #122 factor.
func axisScore(_ p: P, applyDiscount: Bool) -> Float {
    // geoScore: use gaze mapping when valid, else stored geometricScore.
    let geoScore: Float
    if p.selectedFor == "gaze", let g = p.gaze, g > 0 {
        geoScore = min(max(0.50 + (Float(g) - 0.60) / 0.35 * 0.26, 0.50), 0.76)
    } else { geoScore = Float(p.geo) }
    var effThematic: Float
    if p.roleHyp == 1, (p.v2 ?? -1) == 0 { effThematic = Float(p.clusterThematic) }
    else { effThematic = Float(p.v2 ?? p.clusterThematic) }
    if applyDiscount {
        effThematic *= eventProximityThematicFactor(
            captureDateA: date(p.dateA), captureDateB: date(p.dateB),
            captionA: p.capA.isEmpty ? nil : p.capA, captionB: p.capB.isEmpty ? nil : p.capB)
    }
    let tp = temporalPenalty(p.dateA, p.dateB)
    let composite = (Float(p.aesth) * wA + geoScore * wG + effThematic * wT) * tp
    let peak = max(Float(p.aesth), geoScore * 0.8, effThematic) * tp
    return 0.6 * peak + 0.4 * composite
}

let before = pairs.map { axisScore($0, applyDiscount: false) }
let after  = pairs.map { axisScore($0, applyDiscount: true) }

// rank (1 = highest) by axisScore desc
func ranks(_ scores: [Float]) -> [Int: Int] {
    let order = scores.enumerated().sorted { $0.element > $1.element }
    var r: [Int: Int] = [:]
    for (rank, item) in order.enumerated() { r[item.offset] = rank + 1 }
    return r
}
let rBefore = ranks(before), rAfter = ranks(after)
var idx: [Int: Int] = [:]   // (a*100000+b) unordered key -> array index
for (i, p) in pairs.enumerated() { idx[min(p.a,p.b)*100000+max(p.a,p.b)] = i }

func show(_ label: String, _ a: Int, _ b: Int) {
    guard let i = idx[min(a,b)*100000+max(a,b)] else { print("\(label): NOT IN DB"); return }
    let p = pairs[i]
    let gapDays = (p.dateA != nil && p.dateB != nil) ? abs(p.dateA! - p.dateB!)/86400 : -1
    let factor = eventProximityThematicFactor(
        captureDateA: date(p.dateA), captureDateB: date(p.dateB),
        captionA: p.capA.isEmpty ? nil : p.capA, captionB: p.capB.isEmpty ? nil : p.capB)
    let flag = (before[i] != after[i]) ? "  <== DISCOUNTED" : ""
    print(String(format: "%-34@  axis %.3f→%.3f  rank %6d→%6d  factor %.2f  gap %.2fd%@",
                 label as NSString, before[i], after[i], rBefore[i]!, rAfter[i]!, factor, gapDays, flag as NSString))
}

print("### total pairs: \(pairs.count)   weights a/g/t = 0.40/0.20/0.40\n")
print("########## NAMED #122 PAIRS ##########")
show("P1 protest 105/220", 105, 220)
show("P2 protest 486/804", 486, 804)
show("P3 protest 339/670", 339, 670)
show("P4 protest 363/695", 363, 695)
show("P5 pets    238/811", 238, 811)
show("P6 protest 18/126",  18, 126)
show("P7 skate   729/1009 (same-event)", 729, 1009)
show("P8 skate   278/643  (same-event)", 278, 643)

print("\n########## GOLDEN PAIRS (must be unchanged) ##########")
let golden: [(String,Int,Int)] = [
  ("G4 pigeons/peacock",245,246),("G6 smile",874,80),("G7 smile",259,80),
  ("G16 megaphone/ears",50,572),("G1 rose/flowers",176,494),("G5 musician/ears",822,572),
  ("G8 smile/hoop",259,598),("G9 cage/escape",367,153),("G10 see/eyes",474,513),
  ("G13 flags",371,293),("G14 miss/mannequins",645,587),("G15 pride",61,564)]
for (l,a,b) in golden { show(l,a,b) }

let changed = zip(before, after).filter { $0 != $1 }.count
print("\n### pairs whose axisScore changed: \(changed) of \(pairs.count)")
// golden regression check
var goldenHit = false
for (l,a,b) in golden {
    if let i = idx[min(a,b)*100000+max(a,b)], before[i] != after[i] {
        print("!!! GOLDEN DISCOUNTED: \(l)"); goldenHit = true
    }
}
print(goldenHit ? "### REGRESSION: a golden pair was discounted" : "### OK: no golden pair discounted")
