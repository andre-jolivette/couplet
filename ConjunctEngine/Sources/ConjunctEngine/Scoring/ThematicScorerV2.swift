import Foundation

// MARK: - Result

/// Structured result returned by ThematicScorerV2 for a single pair.
public struct ThematicV2Result: Sendable {
    public let connected: Bool
    public let confidence: Float
    public let sharedContext: String?
    public let relationshipType: String
    public let rationale: String

    /// Derived display score: confidence when connected, 0 when not.
    public var score: Float { connected ? confidence : 0 }
}

// MARK: - Scorer

/// Calls llama3.2 via the local Ollama server to evaluate whether two photographs
/// form a meaningful thematic pair. Runs sequentially — one request at a time —
/// because Ollama handles one inference at a time.
///
/// Cold start for llama3.2 3B is ~26s; warm inference is ~1–2s per pair.
/// Returns nil on connection failure or unparseable JSON — never throws.
public actor ThematicScorerV2 {

    private static let kSystemPrompt = """
You evaluate whether two photographs form a meaningful thematic pair.

A pair is connected ONLY if it creates meaning that neither image conveys alone. \
Shared genre, shared location, or shared lighting alone do not make a pair connected.

Visual properties are evaluated by a separate system — do not use them as the \
basis for a thematic connection. This includes: shared color, palette, vibrancy, \
brightness, light quality, or compositional style. If you find yourself writing a \
rationale that mentions color, hue, tone, brightness, or visual style — stop. \
That is an aesthetic connection, not a thematic one. Set connected=false. \
A thematic connection must be based solely on subject, action, role, emotion, \
or narrative — things that have nothing to do with how the image looks.

Respond with exactly this JSON structure. No preamble, no markdown, no other text:
{"connected": true or false, "confidence": 0.0 to 1.0, "relationship_type": "one word", \
"rationale": "one sentence"}

RELATIONSHIP TYPE — output exactly one word from this list: \
complementary / contrastive / echo / ironic / tonal / none
Use "none" when connected is false.

Definitions — use the narrowest definition that fits:
- complementary: one image is the SOURCE of something; the other is the RECEIVER \
(sound produced vs. heard; command issued vs. obeyed; tenderness offered vs. accepted)
- contrastive: the same subject or role in opposing versions \
(triumph vs. defeat; the same street empty vs. crowded)
- echo: near-identical visual form — the same object, gesture, or shape in both images \
(two open hands, two mouths, two doorways). Shared theme alone is NOT echo.
- ironic: text, sign, or symbol visible in one image that the other literalizes, \
subverts, or contradicts
- tonal: shared emotional atmosphere where subjects completely differ \
(both carry dread, or absurdity, or tenderness — without sharing subject or form)
- none: no meaningful connection

CONFIDENCE SCALE:
- 0.9–1.0: connection is undeniable, immediately apparent to any viewer
- 0.7–0.89: clear but requires a moment of thought
- 0.5–0.69: weak but real — the connection exists but is easily missed
- below 0.5: set connected=false
"""

    /// Validation prompt (decision #102): the role-join layer already proposed a
    /// connection; the judge only confirms or rejects it. This converts the judge's
    /// task from cold *discovery* (which no local model does — 14b scores 0/8 cold)
    /// to *validation* (where 14b scores 6/7 recall, 4/4 precision). The join layer
    /// does recall; this prompt does precision.
    private static let kValidatePrompt = """
You are validating a PROPOSED thematic connection between two photographs. A separate \
system already noticed a possible link and named it; your job is to confirm whether it \
is a genuine THIRD-MEANING pair — one that creates meaning neither image carries alone — \
or a coincidence.

Confirm (connected=true) only if the proposed connection holds and produces a real third \
meaning. Reject (connected=false) if the link is superficial (shared clothing, shared \
generic action like walking or looking, same setting) or simply does not hold.

Do NOT use visual properties (color, light, composition) as the basis. Judge on subject, \
action, role, claim-vs-enactment, real-vs-depiction, or source-vs-receiver.

Respond with exactly this JSON, no preamble, no markdown, no other text:
{"connected": true or false, "confidence": 0.0 to 1.0, "relationship_type": "one word", \
"rationale": "one sentence"}

relationship_type — exactly one word from: complementary / contrastive / echo / ironic / \
tonal / none. Use "none" when connected is false.
"""

    private let endpoint: URL
    private let model: String
    private let timeoutSeconds: Double
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150
        return URLSession(configuration: config)
    }()

    public init(
        host: String = "http://127.0.0.1:11434",  // IPv4 explicit — localhost resolves IPv6 first on macOS
        model: String = "qwen2.5:14b-instruct",    // #102: 14b validates role hypotheses 6/7,4/4; benchmarked best local
        timeoutSeconds: Double = 90                 // 14b is ~3.5s/pair warm; cold load needs headroom
    ) {
        self.endpoint = URL(string: "\(host)/api/generate")!
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Scores a pair from its captions.
    ///
    /// - Returns: A `ThematicV2Result` on success, or `nil` when the LLM returned a
    ///   response the JSON parser could not interpret (model output format issue — the
    ///   pair stays unscored in the DB and can be retried in a later pass). Also returns
    ///   `nil` when the Swift task is cancelled (caller should check `Task.isCancelled`).
    /// - Throws: Any underlying network or HTTP error when Ollama is unreachable or
    ///   returns a non-200 status. Callers use this to decide whether to abort.
    public func score(captionA: String, captionB: String) async throws -> ThematicV2Result? {
        let prompt = "IMAGE A: \(captionA)\n\nIMAGE B: \(captionB)"
        guard let raw = try await callOllama(system: Self.kSystemPrompt, prompt: prompt) else { return nil }
        return parseResult(from: raw)
    }

    /// Validates a role-join candidate against its proposed connection (decision #102).
    /// Same return/throw contract as `score()`.
    public func validate(captionA: String, captionB: String, hypothesis: String) async throws -> ThematicV2Result? {
        let prompt = "IMAGE A: \(captionA)\n\nIMAGE B: \(captionB)\n\nPROPOSED CONNECTION: \(hypothesis)\n\nIs this a genuine third-meaning pair?"
        guard let raw = try await callOllama(system: Self.kValidatePrompt, prompt: prompt) else { return nil }
        return parseResult(from: raw)
    }

    // MARK: - Private

    /// Shared Ollama call. Returns the model's raw `response` text, or nil on task
    /// cancellation. Throws on real network/HTTP failures so the caller can track
    /// consecutive failures and abort if the server is down.
    private func callOllama(system: String, prompt: String) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.0]
        ]
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("ThematicScorerV2: failed to serialise request body — \(error)")
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Swift task cancellation propagates as URLError.cancelled — not an Ollama problem.
            return nil
        } catch {
            print("ThematicScorerV2: connection error (is ollama running?) — \(error.localizedDescription)")
            throw error
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("ThematicScorerV2: server returned HTTP \(code)")
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawText = json["response"] as? String else {
            print("ThematicScorerV2: unexpected outer response format")
            throw URLError(.cannotParseResponse)
        }
        return rawText
    }

    private func parseResult(from raw: String) -> ThematicV2Result? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Attempt 1: find the last `}` and truncate there (handles trailing whitespace
        // or stray characters after the closing brace).
        if let lastBrace = text.lastIndex(of: "}") {
            text = String(text[...lastBrace])
        }

        // Attempt 2: if the object is still unclosed (model emitted a stray `)` or
        // similar after the last field — e.g. when the rationale contains "(IMAGE B)"
        // and the model "matches" it at the JSON level), strip back to the last `"`
        // and append a closing brace. This recovers the rationale value intact.
        func tryParse(_ s: String) -> [String: Any]? {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        var parsed: [String: Any]?
        parsed = tryParse(text)
        if parsed == nil, text.hasPrefix("{"), let lastQuote = text.lastIndex(of: "\"") {
            let recovered = String(text[...lastQuote]) + "}"
            parsed = tryParse(recovered)
            if parsed != nil {
                print("ThematicScorerV2: recovered unclosed JSON for pair")
            }
        }

        guard let parsed else {
            print("ThematicScorerV2: failed to parse JSON — raw response: \(raw)")
            return nil
        }

        guard let connected = parsed["connected"] as? Bool,
              let confidence = parsed["confidence"] as? Double,
              let relationshipType = parsed["relationship_type"] as? String,
              let rationale = parsed["rationale"] as? String else {
            print("ThematicScorerV2: missing required fields in JSON — \(parsed.keys.joined(separator: ", "))")
            return nil
        }

        let sharedContext = parsed["shared_context"] as? String

        return ThematicV2Result(
            connected: connected,
            confidence: Float(confidence),
            sharedContext: sharedContext,
            relationshipType: relationshipType,
            rationale: rationale
        )
    }
}
