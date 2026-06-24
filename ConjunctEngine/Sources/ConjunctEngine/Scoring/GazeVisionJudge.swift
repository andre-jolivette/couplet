import Foundation

/// Step-1 result: what the looker is actually looking at, and whether that look
/// leaves their own frame. Determined from the LOOKER IMAGE ALONE — the model's
/// single-image perception is reliable at 1024px, but in a two-image diptych call it
/// degrades (it read a phone-in-hand as "a companion"). So egress is judged in
/// isolation and amortized per looker. See decision #109.
public struct LookerEgress: Sendable {
    public let leavesFrame: Bool
    public let target: String
}

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

    // STEP 1 — egress, judged on the LOOKER IMAGE ALONE. Single-image perception is
    // reliable at 1024px; the two-image call is not (it misreads a held phone as "a
    // companion"). Internal gaze (looking at a held object / a person beside them) is
    // the dominant failure, so this cheap per-looker check culls it up front. See #109.
    private static let kEgressPrompt = """
You are shown ONE photograph. A person in it is looking to one side. Determine what they \
are actually looking at — look closely at their eyeline:
- an object in their OWN hands (a phone, a camera, a cup),
- another person or thing right NEXT TO them, inside this same frame,
- or something OFF the edge of the frame, not visible in this photo.

Respond with exactly this JSON, no preamble or markdown:
{"target": "what they are looking at, in a few words", "leaves_frame": true or false}

leaves_frame is true ONLY if their look clearly exits this frame entirely — NOT a held \
object, NOT someone beside them. When unsure, answer false.
"""

    // STEP 2 — resonance, judged on BOTH images. Egress (step 1) already confirmed the
    // look leaves the looker's frame, so this call only weighs whether the OTHER image's
    // subject is a resonant thing for that look to land on. Still tuning. See #109.
    private static let kResonancePrompt = """
Two photographs are shown side by side: IMAGE 1 on the LEFT, IMAGE 2 on the RIGHT. It is \
already established that a person in one of them is looking OFF the edge of their own frame, \
toward the other image. Your only job: decide whether the SUBJECT of the other image is a \
plausible, resonant thing for that look to land on — so the two frames lock into one line \
of sight that creates a meaning neither image carries alone — OR whether pairing them is \
arbitrary (the look could not plausibly be directed at that subject, or it just places two \
unrelated images side by side).

Be skeptical; when unsure, reject. Respond with exactly this JSON, no preamble or markdown:
{"accepted": true or false, "confidence": 0.0 to 1.0, "rationale": "one sentence"}

CONFIDENCE: 0.9–1.0 the look unmistakably completes on the other subject; 0.7–0.89 clear \
with a moment's thought; 0.5–0.69 weak but real; below 0.5 set accepted=false.
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

    /// STEP 1 — does the looker's gaze leave their own frame? Judged on the looker image
    /// alone (`jpeg` ~1024px). Amortize per looker image, not per pair. Same nil/throw
    /// contract as ThematicScorerV2.
    public func analyzeLooker(jpeg: Data) async throws -> LookerEgress? {
        guard let raw = try await callOllama(
            system: Self.kEgressPrompt,
            prompt: "What is the person looking at, and does their look leave this frame?",
            images: [jpeg.base64EncodedString()]
        ) else { return nil }
        guard let obj = parseJSON(from: raw) else { return nil }
        let leaves = (obj["leaves_frame"] as? Bool) ?? false
        let target = (obj["target"] as? String) ?? ""
        return LookerEgress(leavesFrame: leaves, target: target)
    }

    /// STEP 2 — is the other image's subject a resonant target for the (already
    /// frame-leaving) look? Judged on both images. `lookerIsLeft` = looker is imageAID.
    public func judgeResonance(leftJPEG: Data, rightJPEG: Data, lookerIsLeft: Bool) async throws -> GazeJudgeResult? {
        let lookerNum = lookerIsLeft ? 1 : 2, targetNum = lookerIsLeft ? 2 : 1
        let prompt = "The person looking off-frame is in IMAGE \(lookerNum); judge whether the subject of IMAGE \(targetNum) is what their look lands on."
        guard let raw = try await callOllama(
            system: Self.kResonancePrompt,
            prompt: prompt,
            images: [leftJPEG.base64EncodedString(), rightJPEG.base64EncodedString()]
        ) else { return nil }
        guard let parsed = parseJSON(from: raw) else { return nil }
        guard let accepted = parsed["accepted"] as? Bool,
              let rationale = parsed["rationale"] as? String else {
            print("GazeVisionJudge: resonance missing fields — \(parsed.keys.joined(separator: ", "))")
            return nil
        }
        let confidence: Double = (parsed["confidence"] as? Double)
            ?? (parsed["confidence"] as? NSNumber)?.doubleValue
            ?? (accepted ? 0.6 : 0.0)
        return GazeJudgeResult(accepted: accepted, confidence: Float(confidence), rationale: rationale)
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

    private func callOllama(system: String, prompt: String, images: [String]) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "system": system,
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

    /// Tolerant JSON extraction (mirrors ThematicScorerV2.parseResult): strips a code
    /// fence, isolates the outer object, and recovers an unclosed object.
    private func parseJSON(from raw: String) -> [String: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = text.range(of: "```") { text = String(text[fence.upperBound...]) }
        if let start = text.firstIndex(of: "{") { text = String(text[start...]) }
        if let lastBrace = text.lastIndex(of: "}") { text = String(text[...lastBrace]) }

        func tryParse(_ s: String) -> [String: Any]? {
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }
        if let obj = tryParse(text) { return obj }
        if text.hasPrefix("{"), let lastQuote = text.lastIndex(of: "\"") {
            if let obj = tryParse(String(text[...lastQuote]) + "}") { return obj }
        }
        print("GazeVisionJudge: failed to parse JSON — raw: \(raw)")
        return nil
    }
}
