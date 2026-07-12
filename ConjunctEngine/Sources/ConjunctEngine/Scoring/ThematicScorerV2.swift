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

/// Evidence-grounded pair judge (decision #127). The LLM never emits a verdict:
/// it extracts typed FINDINGS with verbatim caption quotes (grammar-constrained
/// JSON via Ollama structured output); `JudgeEvidence` verifies every quote
/// mechanically against the captions and discards unsupported claims; and
/// `JudgeVerdict` computes connected/confidence/type/rationale from what
/// survives via a fixed, unit-tested table. Fabricated rationales cannot reach
/// the DB — the stored rationale is templated from verified quotes only.
///
/// One narrow judgment kernel remains an LLM question (Stage 4): a verified
/// text-vs-world finding between two images of the same scene kind may be
/// restatement ("solidarity" sign at a protest ↔ another protest); a tiny
/// binary probe decides "is the idea inherent to the scene kind?".
///
/// Warm extraction is ~5–11s per pair; cold model load needs extra headroom.
/// Throws on connection/HTTP errors; returns nil on unusable LLM output (#89).
public actor ThematicScorerV2 {

    /// Findings-extraction prompt. ONE prompt serves both the cold path and
    /// the validate path (the role hypothesis rides in the user prompt as a
    /// hint to ground) — constant system prompt maximizes KV prefix reuse (#93).
    static let kExtractPrompt = """
You analyze two photograph captions and report FINDINGS about how the images relate. \
You do NOT decide whether they form a good pair and you do NOT give a score — a \
separate system does that from your findings.

A finding is one specific link between the two captions. Report every finding you can \
see, each with VERBATIM evidence quotes. Kinds:

- text_vs_world: text/sign/writing quoted in one caption, and the OTHER caption \
describes that idea enacted, lived, or contradicted in the world. Evidence: the sign \
text span, and the enacting span.
- source_receiver: one caption describes producing/emitting a phenomenon (sound, \
command, care), the other describes receiving/blocking/reacting to that same \
phenomenon. Evidence: the producing span and the receiving span.
- same_subject_reversal: the SAME specific subject, place, or object appears in both \
captions in opposed states or outcomes. Evidence: both spans.
- real_vs_depicted: a thing physically present in one caption appears in the other \
only as an image, toy, statue, mural, or other depiction. Evidence: the real span and \
the depiction span.
- gesture_echo: the same specific gesture or physical configuration described in both \
captions. Evidence: both spans.
- shared_category: both captions describe the same kind of scene or subject (two \
protests, two portraits, two street scenes). Evidence: one span from each.

RULES for evidence:
- quoteA must be COPIED CHARACTER-FOR-CHARACTER from IMAGE A's caption; quoteB from \
IMAGE B's caption. Never paraphrase, never merge words from different sentences. Keep \
each quote under 15 words.
- For each side, set explicit=true only if the span DIRECTLY states the thing (a \
megaphone being spoken into is explicit sound production; "engaged in conversation" \
is implied sound, so explicit=false). A physical action that is directly described \
counts as explicit even when its purpose is interpreted — "hands cupping her ears as \
if blocking out noise" is EXPLICIT reception.
- If a link you suspect has no supporting span in a caption, set that quote to "" — \
do not invent one.
- If a PROPOSED CONNECTION is given, it comes from a noisy automated system: try to \
ground it in caption spans as a finding, but if the captions do not support it, do \
not force it — report only what the captions actually contain.
- Include a "note" ONLY for shared_category findings — 2-4 words naming the shared \
scene kind (e.g. "both protests", "two portraits"). Omit the note field entirely for \
every other finding kind; the quotes speak for themselves.

An empty findings list is a valid answer.
"""

    // MARK: Probe prompts (decision #127)
    //
    // The judgment kernels that cannot be mechanized, each a narrow
    // grammar-constrained question asked only on would-be confirms.

    static let kInherentPrompt = """
You answer one narrow question about photograph pairing. A sign in one photograph \
carries a message. Both photographs show the same kind of scene. Question: is the \
idea in the sign's message INHERENT to that kind of scene — i.e. would any typical \
scene of that kind already show the idea, so that pairing the sign with such a scene \
adds no meaning? Examples: "solidarity" is inherent to a protest (every protest shows \
solidarity); "smile" is NOT inherent to a street portrait (people in portraits are \
not necessarily smiling). Answer with JSON only.
"""

    static let kTextWorldLinkPrompt = """
You examine one proposed link between two photographs. A sign or text in one \
photograph carries a MESSAGE. A span from the other photograph's caption describes a \
SCENE. Task: name the single specific idea or feeling that the message states and the \
scene physically shows. It may be direct (message "Smile", scene of a woman smiling -> \
"smiling") or a slant emotional resonance (message about missing someone, scene of two \
figures holding hands -> "longing for closeness"). Rules: the idea must be present in \
BOTH the message's words and the scene's physical content. A message must state an \
idea — a bare noun or label matching an object in the scene is a word coincidence, not \
an idea (message "POLE", scene with a flag on a pole -> NONE). A generic everyday \
action anyone does (walking, standing, sitting, looking, entering) is not a shared \
idea (message "JUST WALK IN", scene of a girl walking -> NONE). If the scene merely \
happens near the message's topic, shares generic props, clothing, or posture, or is \
just the kind of place such a message appears, there is no link. Answer with JSON \
only: {"link": "2-5 words naming the shared idea, or exactly NONE"}
"""

    /// Hypothesis-grounding fallback (decision #127): when validate-path
    /// extraction produces NO verified scoring finding at all, ground the role
    /// hypothesis directly — one focused span-retrieval call per caption. The
    /// join templates are fixed strings, so the finding kind is inferred
    /// deterministically; the grounded spans still pass verification, the
    /// structural checks, and the probes. Recovers extraction decode-roll
    /// misses on genuine role pairs (G4 class) without re-rolling extraction.
    static let kGroundPrompt = """
You ground one claim from a noisy automated system in caption evidence. A HYPOTHESIS \
about a photograph PAIR is given, plus the CAPTION of ONE of the two photographs. \
Task: quote the single span from the CAPTION (copied character-for-character, under \
15 words) that shows THIS photograph's side of the hypothesis. If the caption does \
not support the hypothesis's claim about this photograph, answer exactly NONE. \
Answer with JSON only: {"span": "..."}
"""

    static let kSamePhenomenonPrompt = """
You examine one proposed source-receiver link between two photographs. A SOURCE span \
describes something being produced or emitted (sound, a command, care). A RECEIVER \
span from the other photograph describes a reaction. Two questions. First: does the \
receiver span describe receiving, blocking, or reacting to the SAME phenomenon the \
source emits — so that the phenomenon genuinely crosses from one photograph to the \
other? A woman cupping her ears blocks out the sound a megaphone produces (true). \
People dancing together are not receiving a speech (false). Two people making similar \
gestures or expressions are NOT source and receiver (false). CRUCIAL: if the RECEIVER \
span actually describes PRODUCING or EMITTING the same phenomenon too — both singing \
or speaking into microphones, both playing instruments, both shouting — then there \
are TWO SOURCES and no receiver: answer false. The receiver must be RECEIVING, not \
also producing. Second: is the link EXPLICIT on both sides — a directly described \
physical action or instrument on each side (megaphone to mouth; hands cupped over \
ears), rather than an inference from context ("engaged in conversation" implies sound \
but is not explicit)? Answer with JSON only: \
{"same_phenomenon": true or false, "explicit_both_sides": true or false}
"""

    static let kSameKindPrompt = """
You examine one proposed real-versus-depicted link between two photographs. SPAN 1 \
describes a thing physically present in one photograph. SPAN 2 describes a depicted, \
painted, sculpted, printed, or modeled thing in the other. Question: is the depicted \
thing a version of the SAME category of thing as the real one? Real pigeons and a \
painted peacock are both birds (true). A real bus and toy cars are not the same thing \
(false). Answer with JSON only: {"same_kind": true or false}
"""

    /// Retrieval fallback (decision #127): when extraction reports a verified
    /// sign-side quote but an empty/unverified world side (a recurring decode
    /// pattern on genuine embodiment pairs), ask the model the focused
    /// retrieval question instead of re-rolling the whole extraction. The
    /// returned span still passes mechanical verification and the link probe.
    static let kRetrievePrompt = """
You retrieve evidence from a photograph caption. A MESSAGE (text on a sign in a \
different photograph) is given, plus a CAPTION. Task: quote the single span from the \
CAPTION (copied character-for-character, under 15 words) that shows the message's \
idea or feeling physically present — an action, gesture, expression, or object that \
lives, embodies, or subverts the message. Slant emotional resonance counts (message \
about missing someone -> a span of two figures holding hands). If nothing in the \
caption shows the idea, answer exactly NONE. Answer with JSON only: {"span": "..."}
"""

    static let kSameSubjectPrompt = """
You examine one proposed contrast between two photographs. Two caption spans are \
given. For a genuine contrast BOTH must hold. (1) SAME INDIVIDUAL: the spans are the \
same specific person, place, or object — established by a name, distinctive shared \
clothing or features, or explicit continuity. Two people who merely share a generic \
description (two young women; two men in black shirts) are DIFFERENT subjects. Default \
to false unless there is positive evidence it is the same individual. (2) OPPOSED \
STATES: a genuine reversal of outcome or condition (triumph vs defeat; the same street \
empty vs crowded; celebrated vs mourned). A mere difference in pose or activity \
(standing vs sitting; arm raised vs resting; inside vs outside) is NOT opposition. If \
either fails, answer false. Answer with JSON only: {"same_subject_opposed": true or false}
"""

    static let kSameGesturePrompt = """
You examine one proposed gesture echo between two photographs. Two caption spans are \
given, each describing a gesture, and optionally the kind of scene both photographs \
share. Question: are they the SAME specific gesture or physical configuration (two \
raised fists; two open palms), AND is the gesture more than what the shared activity \
already implies (two skateboarders both balancing with arms out is inherent to \
skateboarding, not an echo; pointing up vs thumbs-down are different gestures)? \
Answer with JSON only: {"same_gesture": true or false}
"""

    private static let kExtractSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "findings": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "enum": FindingKind.allCases.map(\.rawValue)],
                        "quoteA": ["type": "string"],
                        "quoteB": ["type": "string"],
                        "explicitA": ["type": "boolean"],
                        "explicitB": ["type": "boolean"],
                        "note": ["type": "string"]
                    ],
                    // #129: "note" is optional (not required) — the model omits
                    // it for scoring findings (pure generation savings), and
                    // only fills it for shared_category, where the pipeline
                    // uses it as the category description for the inherent-idea
                    // probe. The parser defaults a missing note to "".
                    "required": ["kind", "quoteA", "quoteB", "explicitA", "explicitB"]
                ]
            ]
        ],
        "required": ["findings"]
    ]

    private static func boolSchema(_ field: String) -> [String: Any] {
        ["type": "object",
         "properties": [field: ["type": "boolean"]],
         "required": [field]]
    }

    private static let kLinkSchema: [String: Any] = [
        "type": "object",
        "properties": ["link": ["type": "string"]],
        "required": ["link"]
    ]

    private static let kSpanSchema: [String: Any] = [
        "type": "object",
        "properties": ["span": ["type": "string"]],
        "required": ["span"]
    ]

    private static let kPhenomenonSchema: [String: Any] = [
        "type": "object",
        "properties": ["same_phenomenon": ["type": "boolean"],
                       "explicit_both_sides": ["type": "boolean"]],
        "required": ["same_phenomenon", "explicit_both_sides"]
    ]

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
        model: String = "qwen2.5:14b-instruct",    // #102: benchmarked best local; #127 keeps it (task structure, not scale, was the bottleneck)
        timeoutSeconds: Double = 90                 // extraction is ~5–11s/pair warm; cold load needs headroom
    ) {
        self.endpoint = URL(string: "\(host)/api/generate")!
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Scores a pair from its captions (cold path — no hypothesis hint).
    ///
    /// - Returns: A `ThematicV2Result` on success, or `nil` when the LLM returned a
    ///   response the parser could not interpret (the pair stays unscored in the DB
    ///   and can be retried in a later pass). Also returns `nil` when the Swift task
    ///   is cancelled (caller should check `Task.isCancelled`).
    /// - Throws: Any underlying network or HTTP error when Ollama is unreachable or
    ///   returns a non-200 status. Callers use this to decide whether to abort.
    public func score(captionA: String, captionB: String) async throws -> ThematicV2Result? {
        try await judge(captionA: captionA, captionB: captionB, hypothesis: nil)
    }

    /// Validates a role-join candidate: the proposed connection is passed to the
    /// extractor as a hint to ground (#102's validation framing preserved — the
    /// hint aims extraction, but ungroundable hypotheses die at verification).
    /// Same return/throw contract as `score()`.
    public func validate(captionA: String, captionB: String, hypothesis: String) async throws -> ThematicV2Result? {
        try await judge(captionA: captionA, captionB: captionB, hypothesis: hypothesis)
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

    // MARK: - Pipeline

    private func judge(captionA: String, captionB: String, hypothesis: String?) async throws -> ThematicV2Result? {
        var prompt = "IMAGE A: \(captionA)\n\nIMAGE B: \(captionB)"
        if let hypothesis {
            prompt += "\n\nPROPOSED CONNECTION (from a noisy automated system — ground it or ignore it): \(hypothesis)"
        }
        guard let raw = try await callOllama(system: Self.kExtractPrompt, prompt: prompt,
                                             schema: Self.kExtractSchema) else { return nil }
        guard let findings = Self.parseFindings(from: raw) else {
            print("ThematicScorerV2: failed to parse findings — raw response: \(raw.prefix(400))")
            return nil
        }

        var verified = findings.map { JudgeEvidence.verify($0, captionA: captionA, captionB: captionB) }
        verified = try await retrievalPass(verified, captionA: captionA, captionB: captionB)
        let computed = JudgeVerdict.compute(findings: verified)
        var verdict = try await finalize(computed)

        // Grounding fallback: extraction decode rolls sometimes miss a genuine
        // role connection, or report it in a shape the structural checks
        // discard. When no candidate survived to be judged and a hypothesis
        // exists, ground the hypothesis directly and re-run the normal checks
        // (which the grounded finding must still pass — this cannot loop).
        if !verdict.connected, !computed.hadCandidates, let hypothesis,
           let grounded = try await groundHypothesis(hypothesis, captionA: captionA, captionB: captionB) {
            let categories = verified.filter { $0.finding.kind == .sharedCategory }
            verdict = try await finalize(JudgeVerdict.compute(findings: [grounded] + categories))
        }

        return ThematicV2Result(
            connected: verdict.connected,
            confidence: verdict.confidence,
            sharedContext: nil,
            relationshipType: verdict.relationshipType,
            rationale: verdict.rationale
        )
    }

    /// Runs the verdict's probes — narrow judgment kernels. All must pass;
    /// any failure rejects with an honest, templated rationale.
    private func finalize(_ computed: JudgeVerdictResult) async throws -> JudgeVerdictResult {
        var verdict = computed
        guard verdict.connected else { return verdict }
        for probe in verdict.probes {
            if let rejection = try await run(probe: probe, verdict: &verdict) {
                return .rejected(rejection)
            }
        }
        return verdict
    }

    /// Grounds a role-join hypothesis in one caption span per side. The join
    /// templates are fixed strings (RoleJoins), so the finding kind is a
    /// deterministic mapping; unknown templates don't ground.
    private func groundHypothesis(_ hypothesis: String,
                                  captionA: String, captionB: String) async throws -> VerifiedFinding? {
        let kind: FindingKind
        if hypothesis.contains("is the SOURCE of") {
            kind = .sourceReceiver
        } else if hypothesis.contains("announces or demands") || hypothesis.contains("warns of or names") {
            kind = .textVsWorld
        } else if hypothesis.contains("appears REAL in one image") {
            kind = .realVsDepicted
        } else {
            return nil
        }

        func span(in caption: String) async throws -> String? {
            guard let raw = try await callOllama(system: Self.kGroundPrompt,
                                                 prompt: "HYPOTHESIS: \(hypothesis)\n\nCAPTION: \(caption)",
                                                 schema: Self.kSpanSchema, stage: "grounding"),
                  let obj = Self.parseJSONObject(raw),
                  let s = obj["span"] as? String,
                  s.uppercased() != "NONE",
                  JudgeEvidence.quoteMatches(s, in: caption),
                  // Caption speculation ("perhaps a shout") cannot ground a
                  // hypothesis — grounding demands physical content.
                  !JudgeVerdict.isInterpretive(s) else { return nil }
            return s
        }

        guard let sA = try await span(in: captionA),
              let sB = try await span(in: captionB) else { return nil }
        let f = JudgeFinding(kind: kind, quoteA: sA, quoteB: sB,
                             explicitA: false, explicitB: false, note: "grounded hypothesis")
        return JudgeEvidence.verify(f, captionA: captionA, captionB: captionB)
    }

    /// Patches findings where the extraction found a sign-side quote but left
    /// the world side empty/unverified — a recurring decode pattern on genuine
    /// embodiment pairs (G6/G7/G14 class). One focused retrieval call per such
    /// finding (max 2 per pair); the retrieved span must still pass mechanical
    /// verification, and the rebuilt finding goes through the normal probes.
    private func retrievalPass(_ verified: [VerifiedFinding],
                               captionA: String, captionB: String) async throws -> [VerifiedFinding] {
        var out: [VerifiedFinding] = []
        var retrievals = 0
        for vf in verified {
            let signOnA = vf.signTextA && !vf.verifiedB
            let signOnB = vf.signTextB && !vf.verifiedA
            guard retrievals < 2, vf.finding.kind != .sharedCategory, signOnA != signOnB,
                  let message = vf.signRegionA ?? vf.signRegionB else {
                out.append(vf)
                continue
            }
            retrievals += 1
            let worldCaption = signOnA ? captionB : captionA
            guard let raw = try await callOllama(system: Self.kRetrievePrompt,
                                                 prompt: "MESSAGE: \(message)\nCAPTION: \(worldCaption)",
                                                 schema: Self.kSpanSchema, stage: "retrieval"),
                  let obj = Self.parseJSONObject(raw),
                  let span = obj["span"] as? String,
                  span.uppercased() != "NONE",
                  JudgeEvidence.quoteMatches(span, in: worldCaption) else {
                out.append(vf)
                continue
            }
            let f = vf.finding
            let patched = JudgeFinding(
                kind: f.kind,
                quoteA: signOnA ? f.quoteA : span,
                quoteB: signOnA ? span : f.quoteB,
                explicitA: signOnA ? f.explicitA : false,
                explicitB: signOnA ? false : f.explicitB,
                note: f.note)
            out.append(JudgeEvidence.verify(patched, captionA: captionA, captionB: captionB))
        }
        return out
    }

    /// Executes one probe. Returns nil when the probe passes (possibly
    /// enriching the verdict's rationale), or a rejection rationale when it
    /// fails. Unusable probe output fails CLOSED (reject) — a confirm must be
    /// positively supported. Network errors propagate (caller aborts the pass).
    private func run(probe: JudgeProbe, verdict: inout JudgeVerdictResult) async throws -> String? {
        func askBool(_ system: String, _ prompt: String, _ field: String) async throws -> Bool {
            guard let raw = try await callOllama(system: system, prompt: prompt,
                                                 schema: Self.boolSchema(field), stage: "probe"),
                  let obj = Self.parseJSONObject(raw),
                  let answer = obj[field] as? Bool else { return false }
            return answer
        }

        switch probe {
        case .textWorldLink(let message, let scene):
            guard let raw = try await callOllama(system: Self.kTextWorldLinkPrompt,
                                                 prompt: "MESSAGE: \(message)\nSCENE: \(scene)",
                                                 schema: Self.kLinkSchema, stage: "probe"),
                  let obj = Self.parseJSONObject(raw),
                  let link = obj["link"] as? String else {
                return "Link probe unusable — confirm withheld."
            }
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.uppercased() == "NONE" {
                return "The scene span does not live or subvert the sign's message — coexistence, not a third meaning."
            }
            // Enrich the rationale with the named idea (2–5 bounded words).
            if verdict.rationale.count + trimmed.count + 4 <= 200 {
                verdict.rationale = String(verdict.rationale.dropLast()) + " — \(trimmed)."
            }
            return nil

        case .inherentIdea(let message, let category):
            let prompt = "SIGN MESSAGE: \(message)\nSCENE KIND OF BOTH PHOTOGRAPHS: \(category)"
            if try await askBool(Self.kInherentPrompt, prompt, "inherent") {
                return "The sign's idea is inherent to the scene kind both images share — restatement, not a third meaning."
            }
            return nil

        case .samePhenomenon(let source, let receiver):
            let prompt = "SOURCE: \(source)\nRECEIVER: \(receiver)"
            guard let raw = try await callOllama(system: Self.kSamePhenomenonPrompt, prompt: prompt,
                                                 schema: Self.kPhenomenonSchema, stage: "probe"),
                  let obj = Self.parseJSONObject(raw),
                  let same = obj["same_phenomenon"] as? Bool else {
                return "Phenomenon probe unusable — confirm withheld."
            }
            guard same else {
                return "The phenomenon does not cross the pair — the reaction is not to what the source produces."
            }
            // The probe grades explicitness with both spans in view — more
            // reliable than the extraction call's per-side flags (#127 v4).
            let explicitBoth = (obj["explicit_both_sides"] as? Bool) ?? false
            verdict.confidence = explicitBoth ? 0.95 : min(verdict.confidence, 0.75)
            return nil

        case .sameSubjectOpposed(let a, let b):
            let prompt = "SPAN 1: \(a)\nSPAN 2: \(b)"
            if try await askBool(Self.kSameSubjectPrompt, prompt, "same_subject_opposed") {
                return nil
            }
            return "Not the same subject in opposed states — two different subjects of the same kind."

        case .sameGesture(let a, let b, let category):
            var prompt = "GESTURE 1: \(a)\nGESTURE 2: \(b)"
            if let category { prompt += "\nSHARED SCENE KIND: \(category)" }
            if try await askBool(Self.kSameGesturePrompt, prompt, "same_gesture") {
                return nil
            }
            return "Not the same specific gesture beyond what the shared activity implies."

        case .sameKindDepicted(let real, let depicted):
            let prompt = "SPAN 1: \(real)\nSPAN 2: \(depicted)"
            if try await askBool(Self.kSameKindPrompt, prompt, "same_kind") {
                return nil
            }
            return "The depicted thing is not a version of the real one — different kinds of thing."
        }
    }

    // MARK: - Ollama call

    /// Shared Ollama call with grammar-constrained structured output (`format`
    /// schema — eliminates the #89 unescaped-quote parse-failure class).
    /// Returns the model's raw `response` text, or nil on task cancellation.
    /// Throws on real network/HTTP failures so the caller can track consecutive
    /// failures and abort if the server is down.
    // Per-stage call counts + wall time, for throughput analysis (#129).
    // Negligible overhead; read via perfReport(), zero via resetPerf().
    private var stagePerf: [String: (calls: Int, ms: Double)] = [:]

    public func resetPerf() { stagePerf = [:] }
    public func perfReport() -> String {
        stagePerf.sorted { $0.key < $1.key }
            .map { "\($0.key)\tcalls=\($0.value.calls)\tms=\(Int($0.value.ms))" }
            .joined(separator: "\n")
    }

    private func callOllama(system: String, prompt: String, schema: [String: Any],
                            stage: String = "extraction") async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "format": schema,
            // num_predict bounds grammar-constrained decode: a degenerate
            // generation gets cut (→ parse fail → nil, retryable) instead of
            // hanging to the 90s timeout (→ throw → abort counter).
            "options": ["temperature": 0.0, "num_predict": 800]
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
        let t0 = Date()
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Swift task cancellation propagates as URLError.cancelled — not an Ollama problem.
            return nil
        } catch {
            print("ThematicScorerV2: connection error (is ollama running?) — \(error.localizedDescription)")
            throw error
        }
        let prev = stagePerf[stage] ?? (0, 0)
        stagePerf[stage] = (prev.calls + 1, prev.ms + Date().timeIntervalSince(t0) * 1000)

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

    // MARK: - Parsing

    static func parseJSONObject(_ raw: String) -> [String: Any]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Lenient findings parse: unknown keys are ignored; a finding with an
    /// unknown kind or missing fields is skipped rather than failing the pair.
    static func parseFindings(from raw: String) -> [JudgeFinding]? {
        guard let obj = parseJSONObject(raw),
              let list = obj["findings"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let kindRaw = item["kind"] as? String,
                  let kind = FindingKind(rawValue: kindRaw),
                  let quoteA = item["quoteA"] as? String,
                  let quoteB = item["quoteB"] as? String else { return nil }
            return JudgeFinding(
                kind: kind,
                quoteA: quoteA,
                quoteB: quoteB,
                explicitA: (item["explicitA"] as? Bool) ?? false,
                explicitB: (item["explicitB"] as? Bool) ?? false,
                note: (item["note"] as? String) ?? ""
            )
        }
    }
}
