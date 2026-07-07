import Foundation

// MARK: - Protocol

/// Extracts a structured `RoleProfile` from an image caption (decision #102).
/// Per-image (≈990 one-time calls), not per-pair — the join rules (`RoleJoins`)
/// then pair profiles deterministically. Text-only: it reads the caption the
/// captioning engine already produced, so it adds no image decoding.
public protocol RoleExtractionEngine: Sendable {
    func extract(caption: String) async throws -> RoleProfile
}

// MARK: - Ollama implementation

/// Calls a locally-running ollama server using `qwen2.5:14b-instruct`. The 14B
/// model was benchmarked as the sweet spot for this task: it does claim
/// normalization ("SEE SOMETHING SAY SOMETHING" → "danger") and subversion
/// inference (a covered mouth → subverts "smile") that the 3B cannot, while
/// bigger local models (32B/27B) were slower without better recall and 70B-class
/// quality is only reached by frontier models we keep off-device. Local-only is a
/// hard constraint. See decision #102.
///
/// The prompt is the validated/hardened extraction prompt (claim normalization,
/// subversion inference, enacts-are-concepts-not-nouns, object `category`).
public actor OllamaRoleExtractionEngine: RoleExtractionEngine {

    private let endpoint: URL
    private let model: String
    private let timeoutSeconds: Double
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 200
        return URLSession(configuration: config)
    }()

    public init(
        host: String = "http://127.0.0.1:11434",  // IPv4 explicit — localhost resolves IPv6 first on macOS
        model: String = "qwen2.5:14b-instruct",
        timeoutSeconds: Double = 180               // ~9s/caption warm on M1 Max; cold load needs headroom
    ) {
        self.endpoint = URL(string: "\(host)/api/generate")!
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    private static let systemPrompt = """
You extract a structured ROLE PROFILE from a one-paragraph photo caption. Output ONLY a JSON object, nothing else.

Fields:
- subjects: array of main subject nouns (people, animals, key objects).
- phenomena: array of {"phenomenon": one of [sound,gaze,motion,force,touch,speech,heat,smell], "role": "source" or "receiver"}. A musician PRODUCES sound = source; someone covering their ears BLOCKS/RECEIVES sound = receiver. Only include when the image clearly shows producing or receiving it.
- claims: array of short statements DISPLAYED as text or signs in the image. CRITICAL: do NOT copy the sign's words verbatim — translate each sign to the ACTION OR IDEA IT DEMANDS, as a 1-2 word concept. "SMILE you're beautiful" -> ["smile"]; "SHOOT HERE" -> ["shoot"]; "CAN YOU ESCAPE?" -> ["escape"]; "NO PARKING" -> ["parking"]. A sign may yield MORE THAN ONE concept when it clearly implies several: a surveillance/vigilance exhortation demands both alarm and watching, so "SEE SOMETHING SAY SOMETHING" -> ["danger","watch"]. Never output a full sign sentence. Empty if no legible text.
- enacts: array of abstract CONCEPTS (emotions, intentions, social meanings, actions) the SUBJECT embodies — never plain object names. A smiling person -> ["smile"]; printed or drawn eyes/face that seem to watch -> ["watch"]; a person openly carrying a real gun -> ["danger","threat"] (NOT "gun"). When a gesture or posture carries a clear emotional meaning, ALSO emit that affect as a concept, not just the literal action: two figures holding hands -> ["hold hands","tenderness"]; a hunched downcast figure -> ["sorrow"]; a raised fist -> ["defiance"]. Do not put object nouns like "gun", "taco", "car" here — those go in objects.
- subverts: array of concepts the subject physically PREVENTS, BLOCKS, COVERS, or CONTRADICTS — infer this from the physical description even when no text is present. A mouth covered by a mask/net/hand so it cannot smile or speak -> ["smile","speak"]; hands clamped over ears blocking sound -> []; a "keep out" gesture on a welcome mat -> ["welcome"]. ALSO: when a cage, bars, fence, pen, enclosure, or barrier physically CONFINES the subject or prevents it from leaving, emit the prevented action -> ["escape"]; a wall or barrier blocking the subject's path or movement -> ["movement"]. Look hard for a body part, object, or enclosure that negates an expected action. Empty if nothing is blocked.
- objects: array of {"object": noun, "register": one of [real,toy,depicted,costume,sign], "category": a one-word hypernym}. Real handgun -> {"object":"gun","register":"real","category":"weapon"}; toy water gun -> {"object":"gun","register":"toy","category":"weapon"}; live pigeon -> {"object":"pigeon","register":"real","category":"bird"}; painted peacock mural -> {"object":"peacock","register":"depicted","category":"bird"}. When a culturally, politically, or religiously LOADED symbol (a flag, cross, rainbow, crescent, star) appears, record the SYMBOL itself as an object rather than only the plain item it decorates: an American-flag bag -> {"object":"flag","register":"depicted","category":"symbol"}; a cross tattoo -> {"object":"cross","register":"depicted","category":"symbol"}; a rainbow flag -> {"object":"rainbow flag","register":"real","category":"symbol"}. This adds the symbol; do NOT start enumerating ordinary clothing or accessories that carry no such meaning.
- directed_at: array of things a person's gaze or action is aimed at, if nameable.
- stance: {"attitude": word, "target": "viewer" or "subject"} or null. Performer glaring at camera -> {"attitude":"provocation","target":"viewer"}.

Output only the JSON object.
"""

    public func extract(caption: String) async throws -> RoleProfile {
        let body: [String: Any] = [
            "model": model,
            "system": Self.systemPrompt,
            "prompt": "CAPTION: \(caption)",
            "stream": false,
            "options": ["temperature": 0, "top_k": 1]   // greedy — deterministic profiles
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeoutSeconds

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RoleExtractionError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw RoleExtractionError.malformedResponse
        }
        // The model is instructed to emit only JSON, but be defensive: take the
        // substring from the first '{' to the last '}'.
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else {
            throw RoleExtractionError.noJSON
        }
        let jsonSlice = String(text[start...end])
        guard let sliceData = jsonSlice.data(using: .utf8) else {
            throw RoleExtractionError.noJSON
        }
        do {
            return try JSONDecoder().decode(RoleProfile.self, from: sliceData)
        } catch {
            throw RoleExtractionError.parseFailure(jsonSlice.prefix(160).description)
        }
    }

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

    public enum RoleExtractionError: Error, LocalizedError {
        case serverError(Int)
        case malformedResponse
        case noJSON
        case parseFailure(String)

        public var errorDescription: String? {
            switch self {
            case .serverError(let code):
                return "Ollama server returned HTTP \(code). Is qwen2.5:14b-instruct pulled? Run: ollama pull qwen2.5:14b-instruct"
            case .malformedResponse: return "Unexpected response format from ollama"
            case .noJSON:            return "Model output contained no JSON object"
            case .parseFailure(let s): return "Could not decode RoleProfile JSON: \(s)"
            }
        }
    }
}

// MARK: - Stub (no extraction)

/// Used when ollama is not available. Returns an empty profile so the pipeline
/// proceeds without role candidates.
public struct MockRoleExtractionEngine: RoleExtractionEngine, Sendable {
    public init() {}
    public func extract(caption: String) async throws -> RoleProfile { RoleProfile() }
}
