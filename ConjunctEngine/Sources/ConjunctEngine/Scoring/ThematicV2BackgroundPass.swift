import Foundation
import GRDB

/// Candidate pair for ThematicV2 scoring: pairID + both captions. When `hypothesis`
/// is non-nil the pair is a role-join candidate (decision #102) — judged via
/// `validate()` against the proposed connection rather than cold `score()`.
private struct V2Candidate: Sendable {
    let pairID: Int64
    let captionA: String
    let captionB: String
    let hypothesis: String?
}

/// Runs ThematicScorerV2 sequentially over a candidate subset of existing pairs,
/// writing scores progressively to the DB. Respects Swift structured concurrency
/// cancellation — checking `Task.isCancelled` between each pair.
///
/// Candidates: pairs where thematicV2Score IS NULL and at least one of
/// aestheticScore or geometricScore exceeds the noise floor (0.3), and both
/// images have non-empty captions. Pure-color accent-echo pairs (aestheticSubmode
/// = 'accent_echo' with no thematic or geometric substance) are excluded as
/// spurious (decisions #91, #95); other accent-echo pairs stay eligible but are
/// deprioritised to the tail of the ordering. Candidates are ordered by holistic
/// compositeScore (decision #95) — which includes the thematic axis — rather than
/// raw aesthetic/geometric strength. Limit: 750 pairs.
///
/// Sequential execution is intentional — Ollama handles one request at a time,
/// and concurrent calls would not reduce wall-clock time.
public actor ThematicV2BackgroundPass {

    private let db: DatabaseManager
    private let scorer: ThematicScorerV2

    public init(db: DatabaseManager) {
        self.db = db
        self.scorer = ThematicScorerV2()
    }

    // MARK: - Public

    /// Runs the scoring pass, calling `onProgress(scored, total)` after each pair is written.
    /// The callback is awaited so callers can update UI on @MainActor without capturing self.
    public func run(onProgress: (@Sendable (Int, Int) async -> Void)? = nil) async {
        let candidates: [V2Candidate]
        do {
            candidates = try fetchCandidates()
        } catch {
            print("ThematicV2BackgroundPass: failed to fetch candidates — \(error)")
            return
        }

        guard !candidates.isEmpty else {
            print("ThematicV2BackgroundPass: no unscored candidates")
            return
        }

        print("ThematicV2BackgroundPass: scoring \(candidates.count) candidate pairs")
        var scored = 0
        // Only network/HTTP failures count toward the abort threshold. JSON parse
        // failures (LLM output format issues) do not — the server is clearly up
        // if we got a response at all, so we reset this counter on any HTTP response.
        var consecutiveConnectionFailures = 0
        let maxConsecutiveConnectionFailures = 3

        for candidate in candidates {
            guard !Task.isCancelled else {
                print("ThematicV2BackgroundPass: cancelled after \(scored)/\(candidates.count) pairs")
                return
            }

            let result: ThematicV2Result?
            do {
                if let hypothesis = candidate.hypothesis {
                    // Role-join candidate (#102) — validate the proposed connection.
                    result = try await scorer.validate(
                        captionA: candidate.captionA,
                        captionB: candidate.captionB,
                        hypothesis: hypothesis
                    )
                } else {
                    result = try await scorer.score(
                        captionA: candidate.captionA,
                        captionB: candidate.captionB
                    )
                }
            } catch {
                // Network or HTTP error — server may be down.
                if Task.isCancelled { return }
                consecutiveConnectionFailures += 1
                print("ThematicV2BackgroundPass: connection error for pair \(candidate.pairID) " +
                      "(\(consecutiveConnectionFailures)/\(maxConsecutiveConnectionFailures))" +
                      " — \(error.localizedDescription)")
                if consecutiveConnectionFailures >= maxConsecutiveConnectionFailures {
                    print("ThematicV2BackgroundPass: aborting — server appears to be down")
                    return
                }
                continue
            }

            guard let result else {
                // nil return: either task cancelled, or LLM produced unparseable JSON.
                if Task.isCancelled { return }
                // Parse failure — server responded (HTTP 200), just the model's output
                // was malformed. Reset the connection counter and skip this pair; it
                // stays NULL in the DB and will be a candidate in the next pass.
                consecutiveConnectionFailures = 0
                print("ThematicV2BackgroundPass: skipping pair \(candidate.pairID) — unparseable LLM output")
                continue
            }

            consecutiveConnectionFailures = 0  // reset on success

            do {
                try writeResult(pairID: candidate.pairID, result: result)
                scored += 1
                await onProgress?(scored, candidates.count)
            } catch {
                print("ThematicV2BackgroundPass: DB write failed for pair \(candidate.pairID) — \(error)")
            }
        }

        print("ThematicV2BackgroundPass: complete — scored \(scored)/\(candidates.count) pairs")
    }

    // MARK: - Private

    private static let budget = 750

    private func fetchCandidates() throws -> [V2Candidate] {
        try db.read { db in
            // captureDate filter in SQL: identical captureDates mean burst/sequential shots.
            // Filename base-name dedup is applied in Swift below (SQLite has no REGEXP by default).

            // ── Role-join candidates first (decision #102) ──
            // Entry-gate pairs the four-pool topK never surfaces (backlog #95). Judged
            // WITH their proposed connection (stored in `rationale`) via validate() —
            // the only judging that works locally. These are the high-value pairs, so
            // they get budget priority over the #100 non-role pool.
            let roleSQL = """
                SELECT p.id AS pairID,
                       COALESCE(a.caption, '') AS captionA,
                       COALESCE(b.caption, '') AS captionB,
                       COALESCE(a.filename, '') AS filenameA,
                       COALESCE(b.filename, '') AS filenameB,
                       COALESCE(p.rationale, '') AS hypothesis
                FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                WHERE p.thematicV2Score IS NULL
                  AND p.selectedFor = 'role'
                  AND COALESCE(a.caption, '') != ''
                  AND COALESCE(b.caption, '') != ''
                  AND a.isActive = 1
                  AND b.isActive = 1
                  AND (a.captureDate IS NULL OR b.captureDate IS NULL OR ABS(a.captureDate - b.captureDate) > 300)
                ORDER BY p.id
                LIMIT \(Self.budget)
            """
            var out: [V2Candidate] = []
            for row in try Row.fetchAll(db, sql: roleSQL) {
                guard let pairID = row["pairID"] as? Int64 else { continue }
                let fA = (row["filenameA"] as? String) ?? "", fB = (row["filenameB"] as? String) ?? ""
                guard !FilenameVariants.areVariants(fA, fB) else { continue }
                out.append(V2Candidate(
                    pairID: pairID,
                    captionA: (row["captionA"] as? String) ?? "",
                    captionB: (row["captionB"] as? String) ?? "",
                    hypothesis: (row["hypothesis"] as? String) ?? ""))
            }

            // ── Non-role pool (decision #95/#100) — cold score(), fills remaining budget ──
            // Narrow pure-color guard (replaces #91's blanket accent_echo exclusion) +
            // composite ordering with accent_echo deprioritised to the tail. Excludes
            // role rows (judged above).
            let remaining = Self.budget - out.count
            if remaining > 0 {
                let nonRoleSQL = """
                    SELECT p.id AS pairID,
                           COALESCE(a.caption, '') AS captionA,
                           COALESCE(b.caption, '') AS captionB,
                           COALESCE(a.filename, '') AS filenameA,
                           COALESCE(b.filename, '') AS filenameB
                    FROM pairs p
                    JOIN images a ON a.id = p.imageAID
                    JOIN images b ON b.id = p.imageBID
                    WHERE p.thematicV2Score IS NULL
                      AND (p.selectedFor IS NULL OR p.selectedFor != 'role')
                      AND (p.aestheticScore > 0.3 OR p.geometricScore > 0.3)
                      AND COALESCE(a.caption, '') != ''
                      AND COALESCE(b.caption, '') != ''
                      AND a.isActive = 1
                      AND b.isActive = 1
                      AND (a.captureDate IS NULL OR b.captureDate IS NULL OR ABS(a.captureDate - b.captureDate) > 300)
                      AND NOT (p.aestheticSubmode = 'accent_echo'
                               AND p.thematicScore < 0.15
                               AND p.geometricScore < 0.30)
                    ORDER BY (CASE WHEN p.aestheticSubmode = 'accent_echo' THEN 1 ELSE 0 END) ASC,
                             p.compositeScore DESC
                    LIMIT \(remaining)
                """
                for row in try Row.fetchAll(db, sql: nonRoleSQL) {
                    guard let pairID = row["pairID"] as? Int64 else { continue }
                    let fA = (row["filenameA"] as? String) ?? "", fB = (row["filenameB"] as? String) ?? ""
                    guard !FilenameVariants.areVariants(fA, fB) else { continue }
                    out.append(V2Candidate(
                        pairID: pairID,
                        captionA: (row["captionA"] as? String) ?? "",
                        captionB: (row["captionB"] as? String) ?? "",
                        hypothesis: nil))
                }
            }
            return out
        }
    }

    private func writeResult(pairID: Int64, result: ThematicV2Result) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE pairs
                    SET thematicV2Score            = ?,
                        thematicV2RelationshipType = ?,
                        thematicV2Rationale        = ?
                    WHERE id = ?
                """,
                arguments: [
                    Double(result.score),
                    result.relationshipType,
                    String(result.rationale.prefix(300)),
                    pairID
                ]
            )
        }
    }
}
