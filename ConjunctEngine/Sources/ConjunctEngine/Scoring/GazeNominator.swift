import Foundation

/// Deterministic, pure geometric nomination of directed-attention "call and
/// response" pairs (backlog #72, decision #109): a figure in one image looks
/// toward something that is the SUBJECT of the paired image (a person looking
/// off-frame paired with the thing their look lands on).
///
/// This signal is **visual**, not textual — the caption can only name what is
/// inside the frame, so the off-frame target it can't describe. The role/caption
/// pipeline is the wrong tool (an earlier caption-based attempt matched co-named
/// subjects and produced overwhelmingly "two dogs" pairs — 91% internal-gaze).
/// So this nominator produces a recall-oriented candidate set from geometry alone,
/// and a separate VISION judge (which sees both images) is the precision backstop.
///
/// Geometry used (both already extracted per image):
/// - `gazeDirectionX` (pupil offset, +1 = looking right, −1 = looking left).
///   A strong lateral gaze means the look exits toward a frame edge → off-frame.
/// - `weightCentroidX` (saliency/human centroid, 0 = left edge, 1 = right edge).
///   For the look to *land* on the target's subject, that subject should sit
///   toward the **gutter** side of the target frame (adjacent to the looker), not
///   off the far edge. This "coherence" filter is what makes the diptych read.
///
/// Orientation follows the existing gaze convention (decision #71): the
/// rightward-gazer is placed on the **left** (imageAID) so the look points *into*
/// the companion frame. A leftward-gazer is placed on the right.
public enum GazeNominator {

    /// Per-image geometry the nominator reads. `gaze`/`centroidX` are nil when the
    /// detector found no face / no salient subject — such images can't be lookers
    /// / targets respectively. `faceCount` and `subjectDominance` gate ambiguous
    /// multi-subject images out of both roles (decision #109, live-review feedback).
    public struct Image: Sendable, Equatable {
        public let id: Int64
        public let gaze: Float?
        public let centroidX: Float?
        public let captureDate: Double?
        public let faceCount: Int?
        public let humanCount: Int?
        public let subjectDominance: Float?
        public init(id: Int64, gaze: Float?, centroidX: Float?, captureDate: Double?,
                    faceCount: Int? = nil, humanCount: Int? = nil, subjectDominance: Float? = nil) {
            self.id = id; self.gaze = gaze; self.centroidX = centroidX
            self.captureDate = captureDate
            self.faceCount = faceCount; self.humanCount = humanCount
            self.subjectDominance = subjectDominance
        }
    }

    /// A nominated diptych. `leftID`/`rightID` are the display orientation
    /// (imageAID/imageBID); `lookerID` is whichever of the two carries the gaze.
    public struct Candidate: Sendable, Equatable {
        public let leftID: Int64
        public let rightID: Int64
        public let lookerID: Int64
        public let coherence: Float
        public init(leftID: Int64, rightID: Int64, lookerID: Int64, coherence: Float) {
            self.leftID = leftID; self.rightID = rightID
            self.lookerID = lookerID; self.coherence = coherence
        }
    }

    // Calibrated against the live thumbnails (2026-06-23, the cases Andre flagged):
    // - threshold 0.22: the subject-clarity gates (below) remove the crowds that made
    //   low thresholds noisy, so 0.22 is safe — it recovers good soft-gaze lookers
    //   (L1007801 at 0.24) without dipping into the ~0.20 zone that "didn't read".
    //   The 0.22→0.25 step is a cliff (23 lookers → 15); below 0.22 adds ~nothing.
    // - dominanceMin 0.55: target distribution is p10=0.49 / p50=0.62; 0.55 cuts the
    //   scattered-subject tail (DSF0343 at 0.43) while keeping clear subjects (0.61+).
    public static let defaultThreshold: Float = 0.22    // |gaze| ≥ 0.22 → a clear lateral look
    public static let defaultCoherenceMin: Float = 0.05 // target subject at least slightly gutter-side
    public static let defaultDominanceMin: Float = 0.55  // target has one dominant subject, not a scattered crowd
    public static let defaultCapPerLooker = 4
    public static let defaultCapPerTarget = 3
    public static let defaultBurstGapSeconds: Double = 300

    /// Returns the nominated directed-attention candidates, deterministically.
    /// Lookers are processed strongest-gaze-first (fair first pick); each looker's
    /// targets are ranked by gutter coherence. Per-looker and per-target degree caps
    /// bound the pool and keep it diverse (no single subject absorbs every looker).
    public static func nominate(
        _ images: [Image],
        threshold: Float = defaultThreshold,
        coherenceMin: Float = defaultCoherenceMin,
        dominanceMin: Float = defaultDominanceMin,
        capPerLooker: Int = defaultCapPerLooker,
        capPerTarget: Int = defaultCapPerTarget,
        burstGapSeconds: Double = defaultBurstGapSeconds
    ) -> [Candidate] {
        // LOOKER: a clear lateral gaze AND a single unambiguous subject — exactly one
        // face AND at most one human. Both are needed: in a crowd Vision often detects
        // only ONE face but many humans (measured: a 7-person scene → faceCount 1,
        // humanCount 7), so faceCount alone lets crowds through. The human gate is what
        // catches them, and excludes looks that land on someone else inside the frame.
        // (humanCount ≤ 1 also admits tight face-crops where no full human is detected.)
        // Strongest gaze picks first. See decision #109.
        let lookers = images
            .filter {
                ($0.gaze.map { abs($0) } ?? 0) >= threshold
                    && $0.faceCount == 1 && ($0.humanCount ?? 99) <= 1
            }
            .sorted { a, b in
                let ga = abs(a.gaze ?? 0), gb = abs(b.gaze ?? 0)
                return ga != gb ? ga > gb : a.id < b.id
            }
        // TARGET: a salient subject that is also DOMINANT (one clear thing for the
        // gaze to land on, not a scattered crowd). A nil dominance fails the gate.
        let targets = images.filter { $0.centroidX != nil && ($0.subjectDominance ?? 0) >= dominanceMin }

        func isBurst(_ a: Image, _ b: Image) -> Bool {
            guard let da = a.captureDate, let db = b.captureDate else { return false }
            return abs(da - db) <= burstGapSeconds
        }

        var degree: [Int64: Int] = [:]
        var seen = Set<String>()
        var out: [Candidate] = []

        for looker in lookers {
            guard let g = looker.gaze else { continue }
            let looksRight = g > 0
            if (degree[looker.id] ?? 0) >= capPerLooker { continue }

            // Score eligible targets by gutter coherence (subject leans toward the looker).
            var ranked: [(coh: Float, t: Image)] = []
            for t in targets where t.id != looker.id {
                guard let cx = t.centroidX else { continue }
                let coh = looksRight ? (0.5 - cx) : (cx - 0.5)
                if coh < coherenceMin { continue }
                if isBurst(looker, t) { continue }
                ranked.append((coh, t))
            }
            ranked.sort { a, b in a.coh != b.coh ? a.coh > b.coh : a.t.id < b.t.id }

            var takenForLooker = 0
            for (coh, t) in ranked {
                if takenForLooker >= capPerLooker { break }
                if (degree[looker.id] ?? 0) >= capPerLooker { break }
                if (degree[t.id] ?? 0) >= capPerTarget { continue }
                let key = looker.id < t.id ? "\(looker.id)_\(t.id)" : "\(t.id)_\(looker.id)"
                if seen.contains(key) { continue }
                let (leftID, rightID) = looksRight ? (looker.id, t.id) : (t.id, looker.id)
                out.append(Candidate(leftID: leftID, rightID: rightID,
                                     lookerID: looker.id, coherence: coh))
                seen.insert(key)
                degree[looker.id, default: 0] += 1
                degree[t.id, default: 0] += 1
                takenForLooker += 1
            }
        }
        return out
    }
}
