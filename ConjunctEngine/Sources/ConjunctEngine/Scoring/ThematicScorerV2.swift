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
You are evaluating whether two photographs form a meaningful thematic pair.

You will be given captions for two photographs. Your job is to determine whether \
there is a genuine thematic connection between them — not just surface similarity, \
but a shared context, tension, or resonance that makes them interesting together.

Look for connections across these dimensions:
- Shared subject or domain (sound, surveillance, animals, weapons, text)
- Complementary or opposing actions (one produces, one receives; one threatens, \
one plays; one commands, one obeys)
- Tonal or attitudinal resonance — two images that share an emotional register, \
an edge, an atmosphere, even if the subjects differ
- Text visible in an image can function as a message or command that the companion \
image responds to, literalizes, subverts, or ironizes

Respond ONLY with a valid JSON object. No preamble, no explanation, no markdown fences.

{"connected": true or false, "confidence": 0.0 to 1.0, "shared_context": "the domain \
or thread that links them — or null if none", "relationship_type": "complementary or \
contrastive or echo or ironic or tonal or none", "rationale": "one sentence explaining \
the connection, or why there is none"}

Definitions:
- complementary: the two images occupy opposite ends of the same phenomenon
- contrastive: opposing versions of the same subject or theme
- echo: the same thing in different contexts or scales
- ironic: surface elements create unexpected or humorous tension, including text in \
one image that the other responds to or subverts
- tonal: shared emotional register or atmosphere without necessarily sharing a subject
- none: no meaningful connection
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
        model: String = "llama3.2",
        timeoutSeconds: Double = 60
    ) {
        self.endpoint = URL(string: "\(host)/api/generate")!
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Scores a pair from its captions. Returns nil on connection failure or parse error.
    public func score(captionA: String, captionB: String) async -> ThematicV2Result? {
        let prompt = "IMAGE A: \(captionA)\n\nIMAGE B: \(captionB)"
        let body: [String: Any] = [
            "model": model,
            "system": Self.kSystemPrompt,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1]
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
            return nil
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("ThematicScorerV2: server returned HTTP \(code)")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawText = json["response"] as? String else {
            print("ThematicScorerV2: unexpected outer response format")
            return nil
        }

        return parseResult(from: rawText)
    }

    // MARK: - Private

    private func parseResult(from raw: String) -> ThematicV2Result? {
        // The model may append trailing whitespace or a stray character after the closing
        // brace. Find the last `}` and truncate there before parsing.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastBrace = text.lastIndex(of: "}") {
            text = String(text[...lastBrace])
        }

        guard let jsonData = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
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
