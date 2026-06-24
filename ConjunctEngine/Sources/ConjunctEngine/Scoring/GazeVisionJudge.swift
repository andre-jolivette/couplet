import Foundation

/// Verdict from the vision judge for one directed-attention candidate.
public struct GazeJudgeResult: Sendable {
    public let accepted: Bool
    public let confidence: Float
    public let rationale: String
    /// Derived display score: confidence when accepted, 0 when not (mirrors ThematicV2Result).
    public var score: Float { accepted ? confidence : 0 }
}

/// Confirms or rejects a geometrically-nominated "call and response" gaze pair
/// (backlog #72, decision #109) by actually LOOKING at both images — the text
/// ThematicV2 judge is structurally blind to this visual signal. Calls a
/// vision-language model (`qwen2.5vl`) via the local Ollama server with both cached
/// thumbnails in a single request. Sequential, one pair at a time (Ollama serves one
/// inference at a time). Returns nil on connection failure or unparseable JSON.
///
/// The nominator is recall-oriented (it pairs a strong lateral looker with a
/// gutter-side subject); this judge is the precision backstop. Its hardest job is
/// rejecting **internal gaze** — a person looking at something inside their OWN frame
/// (a phone, a companion) whose look only coincidentally points toward the gutter.
public actor GazeVisionJudge {

    // Describe-first prompt: the model must commit to WHAT the looker is looking at
    // (a `looker_target` + `leaves_frame` field) before the verdict — without this it
    // rubber-stamps every pair. Internal gaze (a phone in hand, a companion) is the
    // hardest reject and is only perceivable at PREVIEW resolution, not thumbnails —
    // the pass must feed previews. See decision #109. Prompt still being tuned (it can
    // over-reject borderline-resonant targets).
    private static let kSystemPrompt = """
You judge whether two photographs form a "call and response" gaze pair. IMAGE 1 is on the \
LEFT, IMAGE 2 on the RIGHT. One image holds a person looking sideways toward the gutter; \
the claim is that their look leaves their own frame and lands on the OTHER image's subject, \
making one line of sight neither image carries alone.

Work in this order and record it in the JSON:
1. looker_target — look closely at the person in the looker image and name what they are \
actually looking at: a phone or object in their hands, a companion right next to them, or \
something off the edge of the frame.
2. leaves_frame — true ONLY if the look exits their own frame (NOT a held object, NOT a \
person beside them).
3. accepted — true only if leaves_frame is true AND the other image's subject is a \
plausible thing for that look to land on, creating a third meaning (not two unrelated \
images side by side).

Be skeptical; when unsure, reject. Respond with exactly this JSON, no preamble or markdown:
{"looker_target": "...", "leaves_frame": true or false, "accepted": true or false, "confidence": 0.0 to 1.0, "rationale": "one sentence"}

CONFIDENCE: 0.9–1.0 the look unmistakably reaches the other subject; 0.7–0.89 clear with \
a moment's thought; 0.5–0.69 weak but real; below 0.5 set accepted=false.
"""

    private let endpoint: URL
    private let model: String
    private let timeoutSeconds: Double
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300   // VLM cold load can be slow
        return URLSession(configuration: config)
    }()

    public init(
        host: String = "http://127.0.0.1:11434",  // IPv4 explicit — localhost resolves IPv6 first on macOS
        model: String = "qwen2.5vl:7b",            // base VLM; freeze to a custom model once the prompt stabilises (#109)
        timeoutSeconds: Double = 240
    ) {
        self.endpoint = URL(string: "\(host)/api/generate")!
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Judges one candidate. `lookerIsLeft` tells the model which image holds the looker
    /// (the nominator oriented the diptych so the look points toward the gutter, but
    /// stating it removes ambiguity). `leftJPEG`/`rightJPEG` are raw thumbnail bytes.
    /// Same return/throw contract as ThematicScorerV2: nil on parse failure or
    /// cancellation; throws on network/HTTP error.
    public func judge(leftJPEG: Data, rightJPEG: Data, lookerIsLeft: Bool) async throws -> GazeJudgeResult? {
        let lookerNum = lookerIsLeft ? 1 : 2, targetNum = lookerIsLeft ? 2 : 1
        let prompt = """
        The person looking sideways is in IMAGE \(lookerNum); the proposed target subject is in IMAGE \(targetNum). \
        Does IMAGE \(lookerNum)'s look leave its own frame and land on the subject of IMAGE \(targetNum)?
        """
        guard let raw = try await callOllama(
            prompt: prompt,
            images: [leftJPEG.base64EncodedString(), rightJPEG.base64EncodedString()]
        ) else { return nil }
        return parseResult(from: raw)
    }

    /// Reachable + model present. Gate the pass on this for a clean skip (mirrors ThematicScorerV2).
    public static func isAvailable(
        host: String = "http://127.0.0.1:11434",
        model: String = "qwen2.5vl:7b"
    ) async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        let session = URLSession(configuration: .ephemeral)
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
    }

    // MARK: - Private

    private func callOllama(prompt: String, images: [String]) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "system": Self.kSystemPrompt,
            "prompt": prompt,
            "images": images,
            "stream": false,
            "options": ["temperature": 0.0]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            print("GazeVisionJudge: failed to serialise request body")
            return nil
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = timeoutSeconds

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
        } catch {
            print("GazeVisionJudge: connection error (is ollama running?) — \(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("GazeVisionJudge: server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawText = json["response"] as? String else {
            print("GazeVisionJudge: unexpected outer response format")
            throw URLError(.cannotParseResponse)
        }
        return rawText
    }

    /// Tolerant JSON extraction (mirrors ThematicScorerV2.parseResult).
    private func parseResult(from raw: String) -> GazeJudgeResult? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = text.range(of: "```") { text = String(text[fence.upperBound...]) }
        if let start = text.firstIndex(of: "{") { text = String(text[start...]) }
        if let lastBrace = text.lastIndex(of: "}") { text = String(text[...lastBrace]) }

        func tryParse(_ s: String) -> [String: Any]? {
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }
        var parsed = tryParse(text)
        if parsed == nil, text.hasPrefix("{"), let lastQuote = text.lastIndex(of: "\"") {
            parsed = tryParse(String(text[...lastQuote]) + "}")
        }
        guard let parsed else {
            print("GazeVisionJudge: failed to parse JSON — raw: \(raw)")
            return nil
        }
        guard let rawAccepted = parsed["accepted"] as? Bool,
              let rationale = parsed["rationale"] as? String else {
            print("GazeVisionJudge: missing required fields — \(parsed.keys.joined(separator: ", "))")
            return nil
        }
        // Enforce the perceptual gate: a look that does not leave its own frame can never
        // be accepted, regardless of what the model put in `accepted`. Internal gaze is
        // the dominant failure, so we hard-gate on the model's own `leaves_frame` reading.
        let leavesFrame = (parsed["leaves_frame"] as? Bool) ?? true
        let accepted = rawAccepted && leavesFrame
        let confidence: Double = (parsed["confidence"] as? Double)
            ?? (parsed["confidence"] as? NSNumber)?.doubleValue
            ?? (accepted ? 0.6 : 0.0)
        return GazeJudgeResult(accepted: accepted, confidence: Float(confidence), rationale: rationale)
    }
}
