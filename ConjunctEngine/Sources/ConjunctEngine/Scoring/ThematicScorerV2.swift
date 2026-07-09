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

/// Calls qwen2.5:14b-instruct via the local Ollama server to evaluate whether two
/// photographs form a meaningful thematic pair. Runs sequentially — one request at
/// a time — because Ollama handles one inference at a time.
///
/// Warm inference is ~3–4s per pair; cold model load needs extra headroom.
/// Throws on connection/HTTP errors; returns nil on unparseable LLM output (#89).
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

THE THIRD-MEANING TEST: before connecting a pair, form the best one-sentence description \
of what the pair says TOGETHER. If that sentence merely restates what both images share — \
"both show skateboarders performing tricks", "both show people carrying animals", "both \
show protesters holding signs" — the pair is a category, not a connection. Set \
connected=false. A shared category does not by itself disqualify a pair, but the \
connection must then be something specific BEYOND the category, stated in the captions: \
the same subject in opposing versions, a genuine source and a genuine receiver of one \
phenomenon, or a claim one image makes that the other subverts. Do not invent a \
relational story ("one action leads to the next") to link two images of the same kind \
of scene. Adding "but they differ in mood, message, or approach" to a shared category is \
STILL restatement — any two images of the same kind of scene differ somehow; difference \
within a category is not a connection ("both protests, one confrontational and one \
peaceful" = two protests = reject). Self-check: if your rationale would begin "Both \
images show..." followed by a shared category of subject or activity, that is \
restatement — set connected=false, even when a "but they contrast in..." clause follows. \
Likewise if it merely describes each image separately ("one shows X, while the other \
shows Y") without naming a specific relationship that crosses the pair.

EVIDENCE RULE: every claim in your rationale must be traceable to specific caption text. \
Never assert a distinction the captions do not state — do not call one image "real" and \
the other "staged", or one "earnest" and the other "theatrical", unless a caption \
explicitly describes a staging, depiction, or performance. If the relationship cannot \
be supported by caption evidence, set connected=false.

Respond with exactly this JSON structure. No preamble, no markdown, no other text:
{"together": "one sentence: what the pair says TOGETHER beyond what the images share — \
if you can only describe each image separately or name a shared category, write exactly \
RESTATEMENT here and set connected=false", \
"connected": true or false, "confidence": 0.0 to 1.0, "relationship_type": "one word", \
"rationale": "one sentence"}

RELATIONSHIP TYPE — output exactly one word from this list: \
complementary / contrastive / echo / ironic / tonal / none
Use "none" when connected is false.

Definitions — use the narrowest definition that fits:
- complementary: one image is the SOURCE of something; the other is the RECEIVER \
(sound produced vs. heard; command issued vs. obeyed; tenderness offered vs. accepted). \
The phenomenon must CROSS the pair — its source in one image, its reception in the \
other. If each image contains its own self-contained version of the same relationship \
(each shows a person with their own animal; each shows a performer with their own \
audience), that is a category, not complementary.
- contrastive: the same subject or role in opposing versions \
(triumph vs. defeat; the same street empty vs. crowded). It must be the SAME subject \
or role — two different subjects in different moods or activities are NOT contrastive. \
"Opposing versions" means a genuine reversal of state or outcome, not variation within \
a category: two protests with different tones, two women with different emotions, two \
signs with different messages are category variation, not contrast — reject them.
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

Work through these checks in order:

CHECK 1 — PREMISE. The proposal comes from a noisy automated system: every FACTUAL claim \
in it must be supported by the captions. A real-versus-depicted premise requires one \
caption to actually describe a depiction — a mural, drawing, statue, toy, poster, or \
printed image of the thing; words or graphics printed on a real sign do not make the \
sign a "depicted version". If a factual claim fails, reject. The proposed LABEL (ironic \
/ contrastive / complementary) is different — it is only a guess. If the facts hold but \
the label fits imperfectly, do NOT reject; confirm and choose the fitting \
relationship_type yourself.

CHECK 2 — TEXT-VS-WORLD. When the link is a sign or text in one image and the named idea \
enacted in the other, text and world are different registers, so this IS a genuine \
third-meaning pattern: a sidewalk sign saying "SMILE" paired with an unrelated woman \
genuinely beaming is a REAL pair — one image states the idea, the other lives it. \
Embodiment alone is enough; contradiction is NOT required; confirm it (usually as \
ironic). The pattern fails only when the enacting image is the same kind of scene the \
sign belongs to and the idea is inherent there: a protest sign demanding "solidarity" \
paired with another protest showing solidarity is restatement — every protest shows \
solidarity.

CHECK 3 — THIRD MEANING. If the best description of the pair merely restates what both \
images share ("two protests", "two people holding signs"), reject: category membership \
is not a third meaning, even when the proposed connection technically matches both \
captions. A shared category does not by itself disqualify the pair, but the connection \
must then be specific and beyond the category, and it must run through the MAIN subjects \
of both images — a link through an incidental or background object (an American flag \
appearing somewhere in each of two political scenes) connects nothing; the pair remains \
"two political events". Also reject when the link is superficial: shared clothing, \
shared generic action (walking, looking), same setting.

EVIDENCE RULE: your rationale must cite the specific caption details the connection rests \
on. Never assert a distinction the captions do not state — real vs. staged, earnest vs. \
theatrical, nuanced vs. unified.

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

    /// Returns true if the Ollama server is reachable and `model` is available.
    /// Gate the background pass on this so a missing model produces a clean skip
    /// instead of HTTP errors that trip the consecutive-failure abort (decision #102).
    public static func isAvailable(
        host: String = "http://127.0.0.1:11434",
        model: String = "qwen2.5:14b-instruct"
    ) async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        let session = URLSession(configuration: .ephemeral)
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
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
