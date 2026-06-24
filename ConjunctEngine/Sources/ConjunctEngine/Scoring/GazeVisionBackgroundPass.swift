import Foundation
import GRDB

/// Drains the geometrically-nominated gaze candidates (`selectedFor='gaze'`,
/// `gazeJudgeScore` NULL) through the two-step `GazeVisionJudge` and writes verdicts
/// (`gazeJudgeScore` / `gazeJudgeRationale`, v19). Backlog #72, decision #109.
///
/// Two-step, amortized: step 1 (egress) runs once per LOOKER image — if the look
/// does not leave its frame (internal gaze: a phone, a companion), ALL of that
/// looker's pairs are rejected without a resonance call. Step 2 (resonance) runs only
/// for pairs whose looker passed. Single-image perception is reliable; the two-image
/// call is not, so the perceptual judgment is isolated.
///
/// Images come from an injected `imageProvider` returning ~1024px JPEG bytes — the
/// resolution where the VLM perceives the gaze target (thumbnails at 512px are too
/// small; it rubber-stamps). The app supplies a bookmark-resolving provider; a
/// headless harness supplies a direct-read one. Sequential (Ollama serves one
/// inference at a time); cancellable; aborts after repeated connection failures.
public actor GazeVisionBackgroundPass {

    /// Returns ~1024px JPEG bytes for an image, or nil if unavailable.
    public typealias ImageProvider = @Sendable (_ imageID: Int64, _ path: String, _ folderPath: String) async -> Data?

    private let db: DatabaseManager
    private let judge: GazeVisionJudge
    private let imageProvider: ImageProvider

    public init(db: DatabaseManager, judge: GazeVisionJudge = GazeVisionJudge(), imageProvider: @escaping ImageProvider) {
        self.db = db
        self.judge = judge
        self.imageProvider = imageProvider
    }

    private struct Candidate: Sendable {
        let pairID: Int64
        let lookerID: Int64, targetID: Int64
        let lookerIsLeft: Bool       // looker == imageAID (left display)
        let lookerPath: String, lookerFolder: String
        let targetPath: String, targetFolder: String
        let lookerGazeAbs: Double    // |gazeDirectionX| of the looker
        let coherence: Double        // how far the target subject sits toward the gutter
    }

    /// Score for a VALID pair, from geometry only (the VLM verdict is binary — its number
    /// is discarded). Ranks valid pairs by how *clearly* this is a real, well-aimed
    /// directed look: a strong lateral gaze (|gaze| up to ~0.6) landing on a subject that
    /// hugs the gutter scores higher. NOT a quality score — interestingness is the human's
    /// call. Lands in [0.60, 0.95]. See decision #109.
    static func clarityScore(lookerGazeAbs: Double, coherence: Double) -> Double {
        let gazeStrength = min(max((lookerGazeAbs - 0.22) / (0.60 - 0.22), 0), 1)
        let coherenceNorm = min(max(coherence / 0.45, 0), 1)
        let clarity = 0.5 * gazeStrength + 0.5 * coherenceNorm
        return 0.60 + 0.35 * clarity
    }

    public func run(onProgress: (@Sendable (Int, Int) async -> Void)? = nil) async {
        let candidates: [Candidate]
        do { candidates = try fetchCandidates() }
        catch { print("GazeVisionBackgroundPass: fetch failed — \(error)"); return }
        guard !candidates.isEmpty else { print("GazeVisionBackgroundPass: no unjudged gaze candidates"); return }

        print("GazeVisionBackgroundPass: judging \(candidates.count) gaze candidates")
        var done = 0
        var connectionFailures = 0
        let maxConnectionFailures = 3
        // Step-1 egress cached per looker image (amortized across that looker's pairs).
        var egressCache: [Int64: LookerEgress?] = [:]
        // Image bytes cached per image id (a looker/target appears in several pairs).
        var bytesCache: [Int64: Data?] = [:]

        func bytes(_ id: Int64, _ path: String, _ folder: String) async -> Data? {
            if let c = bytesCache[id] { return c }
            let d = await imageProvider(id, path, folder)
            bytesCache[id] = d
            return d
        }

        for c in candidates {
            guard !Task.isCancelled else { print("GazeVisionBackgroundPass: cancelled after \(done)"); return }

            // ── Step 1: egress (cached per looker) ──
            let egress: LookerEgress?
            if let cached = egressCache[c.lookerID] {
                egress = cached
            } else {
                guard let lookerBytes = await bytes(c.lookerID, c.lookerPath, c.lookerFolder) else {
                    print("GazeVisionBackgroundPass: no image bytes for looker \(c.lookerID) — skipping")
                    continue   // do not cache a transient image failure as an egress verdict
                }
                do {
                    egress = try await judge.analyzeLooker(jpeg: lookerBytes)
                    egressCache[c.lookerID] = egress
                    connectionFailures = 0
                } catch {
                    if Task.isCancelled { return }
                    connectionFailures += 1
                    print("GazeVisionBackgroundPass: egress connection error (\(connectionFailures)/\(maxConnectionFailures))")
                    if connectionFailures >= maxConnectionFailures { print("GazeVisionBackgroundPass: aborting — server down"); return }
                    continue
                }
            }

            // Egress is the whole verdict (#109): no second model call. A look that does
            // not leave the frame (internal gaze / facing away) is rejected; a real
            // off-frame look is VALID, scored by geometry. The nominator already aimed it
            // (the target subject sits at the gutter where the gaze lands), so the model
            // never sees the target — its two-image aim reads were unreliable.
            guard let egress else {
                // Unparseable egress — leave the pair NULL and retry next pass (don't cache).
                continue
            }
            let score: Float
            let rationale: String
            if egress.leavesFrame {
                score = Float(Self.clarityScore(lookerGazeAbs: c.lookerGazeAbs, coherence: c.coherence))
                rationale = "A clear off-frame look (\(egress.target)); the gaze geometry points toward this image's subject."
            } else {
                score = 0
                rationale = "Not an off-frame look — the figure is looking at \(egress.target)."
            }
            if writeVerdict(pairID: c.pairID, score: score, rationale: rationale) {
                done += 1; await onProgress?(done, candidates.count)
            }
        }
        print("GazeVisionBackgroundPass: complete — judged \(done)/\(candidates.count)")
    }

    // MARK: - Private

    private func fetchCandidates() throws -> [Candidate] {
        try db.read { db in
            // Looker = the side that qualifies as the nominator's looker (|gaze| ≥ 0.22,
            // faceCount == 1). The nominator oriented the diptych so the looker faces the
            // gutter; we recover which side that is from the stored gaze.
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS pairID, p.imageAID AS aID, p.imageBID AS bID,
                       a.gazeDirectionX AS aGaze, a.faceCount AS aFace, a.weightCentroidX AS aCx, a.path AS aPath, fa.path AS aFolder,
                       b.gazeDirectionX AS bGaze, b.faceCount AS bFace, b.weightCentroidX AS bCx, b.path AS bPath, fb.path AS bFolder
                FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                LEFT JOIN folders fa ON fa.id = a.folderID
                LEFT JOIN folders fb ON fb.id = b.folderID
                WHERE p.selectedFor = 'gaze' AND p.gazeJudgeScore IS NULL
                  AND a.isActive = 1 AND b.isActive = 1
                ORDER BY p.id
            """)
            func d(_ r: Row, _ k: String) -> Double { (r[k] as? Double) ?? (r[k] as? Int64).map(Double.init) ?? 0 }
            func i(_ r: Row, _ k: String) -> Int { (r[k] as? Int) ?? (r[k] as? Int64).map(Int.init) ?? 0 }
            return rows.compactMap { r -> Candidate? in
                guard let pairID = r["pairID"] as? Int64,
                      let aID = r["aID"] as? Int64, let bID = r["bID"] as? Int64 else { return nil }
                // Looker is the qualifying side; prefer the stronger gaze when both qualify.
                let aQualifies = i(r, "aFace") == 1 && abs(d(r, "aGaze")) >= 0.22
                let bQualifies = i(r, "bFace") == 1 && abs(d(r, "bGaze")) >= 0.22
                let lookerIsLeft: Bool
                if aQualifies && bQualifies { lookerIsLeft = abs(d(r, "aGaze")) >= abs(d(r, "bGaze")) }
                else if aQualifies { lookerIsLeft = true }
                else if bQualifies { lookerIsLeft = false }
                else { lookerIsLeft = abs(d(r, "aGaze")) >= abs(d(r, "bGaze")) }   // fallback: stronger gaze
                // Coherence: the target subject's centroid distance toward the gutter side.
                // Rightward looker (lookerIsLeft) → target on right, gutter is its left → 0.5 − cx.
                let targetCx = lookerIsLeft ? d(r, "bCx") : d(r, "aCx")
                let coherence = lookerIsLeft ? (0.5 - targetCx) : (targetCx - 0.5)
                return Candidate(
                    pairID: pairID,
                    lookerID: lookerIsLeft ? aID : bID, targetID: lookerIsLeft ? bID : aID,
                    lookerIsLeft: lookerIsLeft,
                    lookerPath: (lookerIsLeft ? r["aPath"] : r["bPath"]) as? String ?? "",
                    lookerFolder: (lookerIsLeft ? r["aFolder"] : r["bFolder"]) as? String ?? "",
                    targetPath: (lookerIsLeft ? r["bPath"] : r["aPath"]) as? String ?? "",
                    targetFolder: (lookerIsLeft ? r["bFolder"] : r["aFolder"]) as? String ?? "",
                    lookerGazeAbs: abs(lookerIsLeft ? d(r, "aGaze") : d(r, "bGaze")),
                    coherence: coherence)
            }
        }
    }

    /// Writes a verdict. Returns true on success. score = confidence when accepted, 0 when rejected.
    private func writeVerdict(pairID: Int64, score: Float, rationale: String) -> Bool {
        do {
            try db.write { db in
                try db.execute(sql: """
                    UPDATE pairs SET gazeJudgeScore = ?, gazeJudgeRationale = ? WHERE id = ?
                """, arguments: [Double(score), String(rationale.prefix(300)), pairID])
            }
            return true
        } catch {
            print("GazeVisionBackgroundPass: DB write failed for pair \(pairID) — \(error)")
            return false
        }
    }
}
