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
/// deprioritised into their own low-weight tail bucket. Non-role candidates are
/// selected via fixed compositeScore-band stratified sampling, not a straight
/// compositeScore-ordered queue — see the `nonRoleBucket*` doc comments below for
/// why (decision #115, backlog #93). Limit: 750 pairs.
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
    /// Cap on role candidates per pass so the non-role pool (#100) keeps at least
    /// `budget - roleBudget` slots and isn't starved while a large role backlog drains
    /// (decision #102). Role candidates still get priority within their cap.
    private static let roleBudget = 500

    /// Stratified sampling for the non-role pool (decision #115, backlog #93).
    ///
    /// Straight `compositeScore DESC` ordering is circular: an unjudged pair's composite
    /// falls back to the weak cluster `thematicScore` — exactly the signal ThematicV2
    /// exists to correct — so pairs whose only weakness is a low cluster-Dice score (the
    /// exact case ThematicV2 fixes) never reach the front of the ~250-slot/pass judge
    /// queue against ~119k eligible candidates. Confirmed on the live DB (#90): four golden
    /// Mode-1 pairs sat at ranks 89k–108k, structurally unreachable.
    ///
    /// Fix: bucket the eligible pool by fixed `compositeScore` bands and give every band a
    /// guaranteed non-zero slot share each pass, instead of one global score-ordered queue.
    /// Bands are fixed score VALUES, not equal-population quartiles — quartiles were tried
    /// first and rejected: the live distribution is dense in the middle (compositeScore
    /// 0.40–0.50 alone holds ~62% of the eligible pool) with a sparse low tail, so an
    /// equal-population bottom quartile would still contain ~30k pairs, unreachable at
    /// ~250 slots/pass. Fixed value bands are narrow exactly where the pool is sparse
    /// (0.15–0.40, where under-scored-by-Dice pairs live) and wide where it's dense.
    /// `nonRoleBucketWeights[i]` is the slot weight for band
    /// `[nonRoleBucketBounds[i-1], nonRoleBucketBounds[i])` (band 0 is `< nonRoleBucketBounds[0]`,
    /// the last band is `>= nonRoleBucketBounds.last`). accent_echo pairs (decision #100's
    /// tail-deprioritization) go to their own dedicated lowest-weight tail band regardless
    /// of score, preserving that intent under the new scheme.
    ///
    /// Within a band, candidates are ordered by `pairID ASC`, not `compositeScore DESC`.
    /// This matters: bands are narrow enough that score-ordering within a band still
    /// systematically starves whichever pair happens to sit at the bottom of its own band
    /// forever (verified in simulation — one golden pair sat at rank 10,687 of 10,949
    /// *within* its band, worse than four-digit passes to reach). `pairID` is unrelated to
    /// score, so every candidate in a band gets a turn as higher-id members ahead of it are
    /// judged and drop out of the `thematicV2Score IS NULL` pool each pass — no extra
    /// "last considered" column needed.
    ///
    /// Weights were tuned empirically against the live DB (2026-07-07, ~119,354 eligible
    /// candidates) so: (a) every band gets ≥1 slot every pass — verified no band was ever
    /// starved while candidates remained in it; (b) the 0.40–0.50 band (the pool's dense
    /// core, previously exclusively favored) keeps the single largest weight, so
    /// previously-strong candidates aren't starved in the other direction; (c) the four
    /// golden pairs from #90 (composite 0.158–0.346) land in bands that reach them within
    /// a multi-pass horizon of tens of passes, not hundreds — simulated result: passes
    /// 40 / 46 / 56 / 74 respectively at a steady ~250 slots/pass. Re-tune these constants
    /// if a future pass over the live DB shows drift from this distribution.
    private static let nonRoleBucketBounds: [Double] = [0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50]
    private static let nonRoleBucketWeights: [Int] = [1, 3, 25, 48, 10, 40, 25, 57, 36]
    private static let nonRoleAccentEchoTailWeight = 5
    private static let nonRoleAccentEchoTailBucket = nonRoleBucketWeights.count

    /// SQL CASE expression assigning each candidate row to a bucket index, per
    /// `nonRoleBucketBounds`/`nonRoleAccentEchoTailBucket` above.
    private static func nonRoleBucketCaseSQL() -> String {
        var clauses = ["WHEN p.aestheticSubmode = 'accent_echo' THEN \(nonRoleAccentEchoTailBucket)"]
        for (i, bound) in nonRoleBucketBounds.enumerated() {
            clauses.append("WHEN p.compositeScore < \(bound) THEN \(i)")
        }
        clauses.append("ELSE \(nonRoleBucketWeights.count - 1)")
        return "CASE " + clauses.joined(separator: " ") + " END"
    }

    /// Per-bucket slot count for this pass, scaled from `nonRoleBucketWeights` +
    /// `nonRoleAccentEchoTailWeight` proportionally to the actual remaining budget (which
    /// varies pass to pass with the role-candidate backlog). Every bucket gets ≥1 slot
    /// whenever `remaining > 0`; any rounding overflow is trimmed from the largest buckets
    /// first so the total never meaningfully exceeds `remaining`.
    private static func nonRoleBucketSlots(remaining: Int) -> [Int] {
        let weights = nonRoleBucketWeights + [nonRoleAccentEchoTailWeight]
        guard remaining > 0 else { return Array(repeating: 0, count: weights.count) }
        let total = weights.reduce(0, +)
        var slots = weights.map { max(1, Int((Double($0) / Double(total) * Double(remaining)).rounded())) }
        var overflow = slots.reduce(0, +) - remaining
        var i = 0
        while overflow > 0 {
            if slots[i] > 1 {
                slots[i] -= 1
                overflow -= 1
            }
            i = (i + 1) % slots.count
        }
        return slots
    }

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
                       p.roleHypothesis AS hypothesis
                FROM pairs p
                JOIN images a ON a.id = p.imageAID
                JOIN images b ON b.id = p.imageBID
                WHERE p.thematicV2Score IS NULL
                  AND p.roleHypothesis IS NOT NULL
                  AND COALESCE(a.caption, '') != ''
                  AND COALESCE(b.caption, '') != ''
                  AND a.isActive = 1
                  AND b.isActive = 1
                  AND (a.captureDate IS NULL OR b.captureDate IS NULL OR ABS(a.captureDate - b.captureDate) > 300)
                ORDER BY p.id
                LIMIT \(Self.roleBudget)
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

            // ── Non-role pool (decision #95/#100, stratified #115) — cold score(), fills
            // remaining budget. Narrow pure-color guard (replaces #91's blanket accent_echo
            // exclusion) still applies as a hard exclusion before bucketing. Excludes role
            // rows (judged above). See nonRoleBucketBounds/-Weights doc comments for why
            // straight compositeScore ordering was replaced with fixed-band stratified
            // sampling (decision #115, backlog #93).
            let remaining = Self.budget - out.count
            if remaining > 0 {
                let slots = Self.nonRoleBucketSlots(remaining: remaining)
                let bucketFilter = slots.enumerated()
                    .filter { $0.element > 0 }
                    .map { "(bucket = \($0.offset) AND rankInBucket <= \($0.element))" }
                    .joined(separator: " OR ")
                let nonRoleSQL = """
                    WITH eligible AS (
                        SELECT p.id AS pairID,
                               COALESCE(a.caption, '') AS captionA,
                               COALESCE(b.caption, '') AS captionB,
                               COALESCE(a.filename, '') AS filenameA,
                               COALESCE(b.filename, '') AS filenameB,
                               \(Self.nonRoleBucketCaseSQL()) AS bucket
                        FROM pairs p
                        JOIN images a ON a.id = p.imageAID
                        JOIN images b ON b.id = p.imageBID
                        WHERE p.thematicV2Score IS NULL
                          AND p.roleHypothesis IS NULL
                          AND (p.aestheticScore > 0.3 OR p.geometricScore > 0.3)
                          AND COALESCE(a.caption, '') != ''
                          AND COALESCE(b.caption, '') != ''
                          AND a.isActive = 1
                          AND b.isActive = 1
                          AND (a.captureDate IS NULL OR b.captureDate IS NULL OR ABS(a.captureDate - b.captureDate) > 300)
                          AND NOT (p.aestheticSubmode = 'accent_echo'
                                   AND p.thematicScore < 0.15
                                   AND p.geometricScore < 0.30)
                    ),
                    ranked AS (
                        SELECT *,
                               ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY pairID ASC) AS rankInBucket
                        FROM eligible
                    )
                    SELECT pairID, captionA, captionB, filenameA, filenameB
                    FROM ranked
                    WHERE \(bucketFilter)
                    ORDER BY bucket ASC, rankInBucket ASC
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
