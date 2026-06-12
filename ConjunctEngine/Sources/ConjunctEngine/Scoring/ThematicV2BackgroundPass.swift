import Foundation
import GRDB

/// Candidate pair for ThematicV2 scoring: pairID + both captions.
private struct V2Candidate: Sendable {
    let pairID: Int64
    let captionA: String
    let captionB: String
}

/// Strips leading numeric prefix ("63-foo.jpg" → "foo.jpg") and trailing numeric
/// suffix ("foo-2.jpg" → "foo.jpg"), then lowercases. Mirrors PairScorer.sharesBaseName.
private func normalizedBaseName(_ filename: String) -> String {
    var s = filename
    s = s.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"-\d+(\.\w+)$"#, with: "$1", options: .regularExpression)
    return s.lowercased()
}

/// Runs ThematicScorerV2 sequentially over a candidate subset of existing pairs,
/// writing scores progressively to the DB. Respects Swift structured concurrency
/// cancellation — checking `Task.isCancelled` between each pair.
///
/// Candidates: pairs where thematicV2Score IS NULL and at least one of
/// aestheticScore or geometricScore exceeds the noise floor (0.3), and both
/// images have non-empty captions. Ordered strongest-first. Limit: 500 pairs.
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
                result = try await scorer.score(
                    captionA: candidate.captionA,
                    captionB: candidate.captionB
                )
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

    private func fetchCandidates() throws -> [V2Candidate] {
        try db.read { db in
            // captureDate filter in SQL: identical captureDates mean burst/sequential shots.
            // Filename base-name dedup is applied in Swift below (SQLite has no REGEXP by default).
            let sql = """
                SELECT p.id AS pairID,
                       COALESCE(a.caption, '') AS captionA,
                       COALESCE(b.caption, '') AS captionB,
                       COALESCE(a.filename, '') AS filenameA,
                       COALESCE(b.filename, '') AS filenameB
                FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                WHERE p.thematicV2Score IS NULL
                  AND (p.aestheticScore > 0.3 OR p.geometricScore > 0.3)
                  AND COALESCE(a.caption, '') != ''
                  AND COALESCE(b.caption, '') != ''
                  AND a.isActive = 1
                  AND b.isActive = 1
                  AND (a.captureDate IS NULL OR b.captureDate IS NULL OR ABS(a.captureDate - b.captureDate) > 300)
                ORDER BY MAX(p.aestheticScore, p.geometricScore) DESC
                LIMIT 500
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.compactMap { row -> V2Candidate? in
                guard let pairID = row["pairID"] as? Int64 else { return nil }
                let captionA = (row["captionA"] as? String) ?? ""
                let captionB = (row["captionB"] as? String) ?? ""
                let filenameA = (row["filenameA"] as? String) ?? ""
                let filenameB = (row["filenameB"] as? String) ?? ""
                // Skip numeric-prefix variants (e.g. "63-foo.jpg" paired with "foo.jpg").
                guard normalizedBaseName(filenameA) != normalizedBaseName(filenameB) else { return nil }
                return V2Candidate(pairID: pairID, captionA: captionA, captionB: captionB)
            }
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
