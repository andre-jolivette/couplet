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
    /// / targets respectively.
    public struct Image: Sendable, Equatable {
        public let id: Int64
        public let gaze: Float?
        public let centroidX: Float?
        public let captureDate: Double?
        public init(id: Int64, gaze: Float?, centroidX: Float?, captureDate: Double?) {
            self.id = id; self.gaze = gaze; self.centroidX = centroidX
            self.captureDate = captureDate
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

    // Defaults are the calibrated values (dev library, 2026-06-23): ~435 candidates,
    // 256 distinct images — same order as one ThematicV2 budget, good diversity.
    public static let defaultThreshold: Float = 0.20    // |gaze| ≥ 0.20 → a clear lateral look
    public static let defaultCoherenceMin: Float = 0.05 // target subject at least slightly gutter-side
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
        capPerLooker: Int = defaultCapPerLooker,
        capPerTarget: Int = defaultCapPerTarget,
        burstGapSeconds: Double = defaultBurstGapSeconds
    ) -> [Candidate] {
        // Strongest lookers pick first; id tiebreaker for reproducibility.
        let lookers = images
            .filter { ($0.gaze.map { abs($0) } ?? 0) >= threshold }
            .sorted { a, b in
                let ga = abs(a.gaze ?? 0), gb = abs(b.gaze ?? 0)
                return ga != gb ? ga > gb : a.id < b.id
            }
        let targets = images.filter { $0.centroidX != nil }

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
