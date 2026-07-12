import Foundation

// MARK: - Findings (decision #127)
//
// The ThematicV2 judge no longer asks the LLM for a verdict. The LLM reports
// typed FINDINGS — each a specific link between the two captions, evidenced by
// verbatim quotes — and Swift verifies the quotes mechanically, then computes
// the verdict and confidence from what survives. Fabricated claims cannot pass
// verification (no caption span supports them), and confidence is a fixed,
// unit-testable table instead of a generated number. The narrow judgments that
// cannot be mechanized are emitted as `JudgeProbe` requests — small binary
// LLM questions the scorer runs before finalizing a confirm.

/// A link kind the extraction model may report. Raw values match the JSON
/// schema enum sent to Ollama.
public enum FindingKind: String, CaseIterable, Sendable {
    case textVsWorld = "text_vs_world"           // sign text in one image, idea enacted in the other
    case sourceReceiver = "source_receiver"       // phenomenon produced in one, received/blocked in the other
    case sameSubjectReversal = "same_subject_reversal" // same specific subject in opposed states
    case realVsDepicted = "real_vs_depicted"      // physically present vs image/toy/statue/mural
    case gestureEcho = "gesture_echo"             // same specific gesture/configuration in both
    case sharedCategory = "shared_category"       // same kind of scene — context only, never scores
}

/// One finding as reported by the extraction model, before verification.
public struct JudgeFinding: Sendable {
    public let kind: FindingKind
    public let quoteA: String
    public let quoteB: String
    public let explicitA: Bool
    public let explicitB: Bool
    public let note: String

    public init(kind: FindingKind, quoteA: String, quoteB: String,
                explicitA: Bool, explicitB: Bool, note: String) {
        self.kind = kind
        self.quoteA = quoteA
        self.quoteB = quoteB
        self.explicitA = explicitA
        self.explicitB = explicitB
        self.note = note
    }
}

/// A finding after mechanical verification against the two captions.
public struct VerifiedFinding: Sendable {
    public let finding: JudgeFinding
    /// Quote is non-empty and found in the corresponding caption.
    public let verifiedA: Bool
    public let verifiedB: Bool
    /// The quoted sign/text region of the caption the quote overlaps, when it
    /// is sign text (nil for world-register spans). The region — not the
    /// model's quote, which may include narration ("The bus has the words…") —
    /// is the message used for content gates and probes.
    public let signRegionA: String?
    public let signRegionB: String?

    public var signTextA: Bool { signRegionA != nil }
    public var signTextB: Bool { signRegionB != nil }
}

// MARK: - Evidence verification

public enum JudgeEvidence {

    /// Lowercase, straighten curly quotes, collapse whitespace.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: "\u{2018}", with: "'")
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"")
        t = t.replacingOccurrences(of: "\u{201D}", with: "\"")
        let parts = t.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return parts.joined(separator: " ")
    }

    /// Quote-mark-free form: the extraction model re-quotes sign text with its
    /// own quote style ('X' vs "X"), so containment checks compare bare forms.
    private static func bare(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// True when `quote` is supported by `caption`: either a contiguous
    /// normalized substring (quote marks ignored), or — for light compressions
    /// like "Two mannequins hold hands" quoted from "Two mannequins, one
    /// dressed …, hold hands." — an ordered token subsequence confined to a
    /// SINGLE caption sentence. Cross-sentence stitching is rejected: a caption
    /// sentence is the claim unit, and assembling words from different
    /// sentences can construct a claim the caption never makes.
    public static func quoteMatches(_ quote: String, in caption: String) -> Bool {
        let q = normalize(quote)
        guard !q.isEmpty else { return false }
        let c = normalize(caption)
        if bare(c).contains(bare(q)) { return true }

        // Fallback: in-order token subsequence within one sentence.
        let qTokens = tokens(q)
        guard qTokens.count >= 3 else { return false }
        for sentence in c.split(whereSeparator: { ".!?".contains($0) }) {
            let sTokens = tokens(String(sentence))
            var i = 0
            for tok in sTokens where tok == qTokens[i] {
                i += 1
                if i == qTokens.count { return true }
            }
        }
        return false
    }

    /// Regions of the caption enclosed in quote marks — captions consistently
    /// quote sign/text content ("DO SOMETHING", 'I CAN'T BREATHE'), so this
    /// mechanically distinguishes the text register from the world register.
    /// Handles both double quotes and single-quote regions; an apostrophe
    /// inside a word (CAN'T) or after one (a possessive — mannequins') never
    /// OPENS a region.
    static func quotedRegions(of caption: String) -> [String] {
        let c = normalize(caption)
        var regions: [String] = []
        let chars = Array(c)

        // Double quotes: simple toggle.
        var start: Int? = nil
        for i in 0..<chars.count where chars[i] == "\"" {
            if let s = start {
                regions.append(String(chars[(s + 1)..<i]))
                start = nil
            } else {
                start = i
            }
        }

        // Single quotes: opening requires non-letter before AND letter/digit
        // after (so intra-word and possessive apostrophes can't open); any
        // non-intra-word quote closes an open region.
        start = nil
        for i in 0..<chars.count where chars[i] == "'" {
            let before = i > 0 ? chars[i - 1] : " "
            let after = i + 1 < chars.count ? chars[i + 1] : " "
            if before.isLetter && after.isLetter { continue } // intra-word: CAN'T
            if let s = start {
                regions.append(String(chars[(s + 1)..<i]))
                start = nil
            } else if !before.isLetter && (after.isLetter || after.isNumber) {
                start = i
            }
        }
        return regions
    }

    /// The quoted sign/text region the quote overlaps, or nil when the quote
    /// is world-register. Besides substring containment, a region matches
    /// when its content words (≥2 of them) all appear in the quote — the
    /// extraction model sometimes garbles its copy ("[...]", "&"→"and"),
    /// which passes token-subsequence verification but would otherwise slip
    /// past the register check and let a sign pose as a world span.
    public static func signRegion(_ quote: String, in caption: String) -> String? {
        let q = bare(normalize(quote)).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let qTokens = Set(tokens(q))
        return quotedRegions(of: caption).first {
            let r = bare($0).trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty else { return false }
            if r.contains(q) || q.contains(r) { return true }
            let rWords = JudgeVerdict.contentWords(r)
            return rWords.count >= 2 && rWords.allSatisfy { qTokens.contains($0) }
        }
    }

    /// True when the quote overlaps quoted sign/text content in the caption.
    public static func isSignText(_ quote: String, in caption: String) -> Bool {
        signRegion(quote, in: caption) != nil
    }

    /// Verify one finding's quotes against the two captions.
    public static func verify(_ f: JudgeFinding, captionA: String, captionB: String) -> VerifiedFinding {
        let vA = quoteMatches(f.quoteA, in: captionA)
        let vB = quoteMatches(f.quoteB, in: captionB)
        return VerifiedFinding(
            finding: f,
            verifiedA: vA,
            verifiedB: vB,
            signRegionA: vA ? signRegion(f.quoteA, in: captionA) : nil,
            signRegionB: vB ? signRegion(f.quoteB, in: captionB) : nil
        )
    }
}

// MARK: - Computed verdict

/// A narrow LLM question the scorer must run before finalizing a confirm —
/// the judgment kernels that cannot be mechanized. Every probe is a small
/// grammar-constrained call; failure rejects the pair.
public enum JudgeProbe: Sendable {
    /// Does the scene span live/embody/subvert the sign's message (slant counts)?
    case textWorldLink(message: String, scene: String)
    /// Is the sign's idea inherent to the scene kind both images share?
    case inherentIdea(message: String, category: String)
    /// Does the receiver span react to the SAME phenomenon the source emits?
    /// The probe also grades explicitness, which sets the confidence.
    case samePhenomenon(source: String, receiver: String)
    /// Are the two spans the SAME specific subject in genuinely opposed states?
    case sameSubjectOpposed(a: String, b: String)
    /// Same specific gesture, beyond what a shared activity implies?
    case sameGesture(a: String, b: String, category: String?)
    /// Is the depicted thing a version of the SAME category as the real one?
    case sameKindDepicted(real: String, depicted: String)
}

/// The deterministic verdict computed from verified findings, plus the probes
/// the scorer must pass before the confirm stands.
public struct JudgeVerdictResult: Sendable {
    public let connected: Bool
    public var confidence: Float
    public let relationshipType: String
    public var rationale: String
    public let probes: [JudgeProbe]
    /// Whether any scoring finding survived the structural checks. When false
    /// on the validate path, the hypothesis-grounding fallback gets a shot —
    /// the grounded finding passes the same checks, so this cannot loop.
    public let hadCandidates: Bool

    static func rejected(_ rationale: String, hadCandidates: Bool = false) -> JudgeVerdictResult {
        JudgeVerdictResult(connected: false, confidence: 0, relationshipType: "none",
                           rationale: rationale, probes: [], hadCandidates: hadCandidates)
    }
}

public enum JudgeVerdict {

    /// Depiction-register vocabulary: a real-vs-depicted finding must carry
    /// one of these in exactly one span, or the register flip is unverified
    /// (the join-3 false-premise class: two physical signs are the same register).
    static let kDepictionWords: Set<String> = [
        "mural", "statue", "poster", "drawing", "painting",
        "sculpture", "photograph", "photo", "picture", "illustration", "cartoon",
        "billboard", "mannequin", "mannequins", "figurine", "miniature",
        "replica", "artwork", "graffiti", "depicted", "drawn"
        // NOT "toy": "possibly a phone or a toy" hedges, and a toy in hand is a
        // real object — the sameKindDepicted probe carries the register burden.
        // NOT "painted"/"printed"/"print": "a face painted with a clown design",
        // "a printed shirt" are REAL things wearing paint/print, not depictions
        // (#128, 96/631 flag pair). The noun forms (painting/photograph/print-as-
        // artwork) are covered by their own entries; the sameKindDepicted probe
        // catches the rest.
    ]

    /// Generic everyday actions: a stem overlap on these alone is not direct
    /// embodiment ("JUST WALK IN" ↔ a girl walking is a word coincidence).
    static let kGenericActionStems: Set<String> = [
        "walk", "stan", "sit", "sitt", "look", "hold", "wear", "go", "goin", "enter"
    ]

    /// Interpretive caption language: a scene span that reads the mood rather
    /// than describing physical content cannot carry a 0.95 confirm.
    static let kInterpretiveMarkers: [String] = [
        "sense of", "suggest", "seems", "appears", "atmosphere", "mood",
        "impression", "possibly", "perhaps", "likely"
    ]

    /// Stopwords for the sign-message content gate: a message with no content
    /// word ("We are NOT.") cannot ground a text-vs-world link.
    static let kStopwords: Set<String> = [
        "a", "an", "the", "we", "are", "is", "am", "be", "been", "was", "were",
        "not", "no", "yes", "you", "your", "us", "our", "they", "them", "it",
        "its", "this", "that", "these", "those", "do", "does", "did", "don",
        "dont", "t", "s", "to", "of", "in", "on", "at", "and", "or", "too",
        "much", "so", "very", "will", "can", "cant", "have", "has", "had",
        "with", "for", "from", "by", "as", "if", "but", "than", "then", "there",
        "here", "what", "who", "how", "why", "when", "all", "any", "some", "my",
        "me", "i", "he", "she", "his", "her", "him", "up", "down", "out", "off",
        // Pro-forms and contractions: "DO SOMETHING" states no graspable idea.
        "something", "anything", "nothing", "everything", "someone", "anyone",
        "everyone", "youre", "theyre", "were", "im", "ive", "id", "isnt",
        "arent", "wasnt", "wont", "lets", "gonna"
    ]

    static func contentWords(_ s: String) -> [String] {
        JudgeEvidence.tokens(JudgeEvidence.normalize(s))
            .filter { $0.count >= 3 && !kStopwords.contains($0) }
    }

    /// Shared word-stem between two texts (4-char prefix, or full equality for
    /// shorter words) — "smile"/"smiling" overlap, "racism"/"caps" do not.
    /// Generic-action stems don't count toward DIRECT embodiment.
    static func stemOverlap(_ x: String, _ y: String) -> Bool {
        let xs = contentWords(x).filter { !kGenericActionStems.contains(String($0.prefix(4))) }
        let ys = contentWords(y).filter { !kGenericActionStems.contains(String($0.prefix(4))) }
        for a in xs {
            for b in ys {
                if a == b { return true }
                if a.count >= 4 && b.count >= 4 && a.prefix(4) == b.prefix(4) { return true }
            }
        }
        return false
    }

    static func isInterpretive(_ span: String) -> Bool {
        let s = JudgeEvidence.normalize(span)
        return kInterpretiveMarkers.contains { s.contains($0) }
    }

    /// A world/scene span that talks about a sign is text-register content
    /// regardless of quoting — a sign "answered" by another sign is one
    /// register, not text-vs-world. "Sign" needs context: a peace sign or a
    /// sign of exhaustion is a gesture/idiom, not a signboard (G6's caption
    /// has "fingers forming a peace sign").
    static let kUnambiguousSignNouns: Set<String> = [
        "banner", "banners", "poster", "posters", "placard", "placards",
        "billboard", "billboards"
    ]

    static func mentionsSign(_ span: String) -> Bool {
        let toks = JudgeEvidence.tokens(JudgeEvidence.normalize(span))
        for (i, t) in toks.enumerated() where t == "sign" || t == "signs" {
            let prev = i > 0 ? toks[i - 1] : ""
            let next = i + 1 < toks.count ? toks[i + 1] : ""
            if prev == "peace" || prev == "hand" || next == "of" { continue }
            return true
        }
        return !Set(toks).isDisjoint(with: kUnambiguousSignNouns)
    }

    static func containsDepictionWord(_ s: String) -> Bool {
        !Set(JudgeEvidence.tokens(JudgeEvidence.normalize(s))).isDisjoint(with: kDepictionWords)
    }

    static func relationshipType(for kind: FindingKind) -> String {
        switch kind {
        case .textVsWorld: return "ironic"
        case .sourceReceiver: return "complementary"
        case .sameSubjectReversal: return "contrastive"
        case .realVsDepicted: return "contrastive"
        case .gestureEcho: return "echo"
        case .sharedCategory: return "none"
        }
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    /// One scoring candidate after structural correction.
    private struct Candidate {
        let vf: VerifiedFinding
        let kind: FindingKind        // re-kinded, may differ from vf.finding.kind
        let confidence: Float
        let probes: [JudgeProbe]
        let rationale: String
    }

    /// Compute the verdict from verified findings. Pure and deterministic;
    /// the returned probes (if any) must all pass for the confirm to stand.
    public static func compute(findings: [VerifiedFinding]) -> JudgeVerdictResult {
        let scoring = findings.filter {
            $0.finding.kind != .sharedCategory && $0.verifiedA && $0.verifiedB
        }
        let categories = findings.filter {
            $0.finding.kind == .sharedCategory && ($0.verifiedA || $0.verifiedB)
        }
        let categoryNote: String? = categories.first.map {
            $0.finding.note.isEmpty ? "\($0.finding.quoteA) / \($0.finding.quoteB)" : $0.finding.note
        }

        var candidates: [Candidate] = []
        for vf in scoring {
            if let c = candidate(for: vf, categoryNote: categoryNote) {
                candidates.append(c)
            }
        }

        guard let best = candidates.max(by: { a, b in
            if a.confidence != b.confidence { return a.confidence < b.confidence }
            let pa = kindPriority.firstIndex(of: a.kind) ?? .max
            let pb = kindPriority.firstIndex(of: b.kind) ?? .max
            return pa > pb
        }) else {
            let why: String
            if !scoring.isEmpty {
                why = "The reported links fail structural checks (same register, or no verifiable depiction)."
            } else if let note = categoryNote {
                why = "Only a shared category links the images — \(clip(note, 130))."
            } else {
                why = "No caption-verifiable link between the two images."
            }
            return .rejected(clip(why, 200), hadCandidates: false)
        }

        return JudgeVerdictResult(connected: true, confidence: best.confidence,
                                  relationshipType: relationshipType(for: best.kind),
                                  rationale: best.rationale, probes: best.probes,
                                  hadCandidates: true)
    }

    private static let kindPriority: [FindingKind] = [
        .textVsWorld, .sourceReceiver, .sameSubjectReversal, .realVsDepicted, .gestureEcho
    ]

    // Rationale sizing (#128): the stored rationale is templated from verified
    // quotes; the old 70/200 caps truncated real quotes mid-phrase ("…depicted
    // in the oth…"). Widened so a two-quote rationale rarely clips. TEXT column,
    // no DB limit; the lightbox rail wraps.
    static let kQuoteInRationaleMax = 130
    static let kRationaleMax = 340

    /// Structural correction + confidence table for one verified finding.
    private static func candidate(for vf: VerifiedFinding, categoryNote: String?) -> Candidate? {
        let f = vf.finding
        let signCount = (vf.signTextA ? 1 : 0) + (vf.signTextB ? 1 : 0)
        let qA = clip(f.quoteA, kQuoteInRationaleMax), qB = clip(f.quoteB, kQuoteInRationaleMax)

        // Two sign texts = the same register on both sides. Whatever kind the
        // model reported, nothing is depicted and nothing is enacted — two
        // signs from the same discourse are a category, not a pair.
        if signCount == 2 { return nil }

        // Exactly one sign side: structurally text-vs-world regardless of the
        // reported kind (the model mislabels this shape as real_vs_depicted).
        if signCount == 1 {
            // The MESSAGE is the caption's quoted region — not the model's
            // quote, which may include narration ("The bus has the words…").
            let message = vf.signRegionA ?? vf.signRegionB ?? ""
            let scene = vf.signTextA ? f.quoteB : f.quoteA
            // A message with no content word cannot ground a link; a scene
            // span about a sign is text-register, not world; and caption
            // speculation ("perhaps a shout") is not physical evidence.
            guard !contentWords(message).isEmpty, !mentionsSign(scene),
                  !isInterpretive(scene) else { return nil }

            // The link probe always runs — direct lexical embodiment sets the
            // confidence, not the verdict (a bare noun echoing an object is a
            // word coincidence the probe rejects).
            let direct = stemOverlap(message, scene)
            var probes: [JudgeProbe] = [.textWorldLink(message: message, scene: scene)]
            if let cat = categoryNote {
                probes.append(.inherentIdea(message: message, category: cat))
            }
            let sceneQ = vf.signTextA ? qB : qA
            return Candidate(
                vf: vf, kind: .textVsWorld,
                confidence: direct ? 0.95 : 0.75,
                probes: probes,
                rationale: clip("Text \"\(clip(message, kQuoteInRationaleMax))\" in one image is lived in the other: \"\(sceneQ)\".", kRationaleMax))
        }

        // No sign side.
        switch f.kind {
        case .textVsWorld:
            // No mechanically-verified text register on either side — there
            // is no evidence any text exists. Discard; if a hypothesis names
            // real sign text, the grounding fallback recovers it properly.
            return nil
        case .sourceReceiver:
            let conf: Float = (f.explicitA && f.explicitB) ? 0.95
                            : (f.explicitA || f.explicitB) ? 0.75 : 0.60
            return Candidate(vf: vf, kind: .sourceReceiver, confidence: conf,
                             probes: [.samePhenomenon(source: f.quoteA, receiver: f.quoteB)],
                             rationale: clip("\"\(qA)\" meets \"\(qB)\" — source and receiver of one phenomenon.", kRationaleMax))
        case .sameSubjectReversal:
            // Capped below the top tier: caption spans can't prove two spans
            // are the SAME person, so the probe's yes is weaker evidence than
            // a verified register or phenomenon (the 186/220 jitter class).
            let conf: Float = (f.explicitA && f.explicitB) ? 0.80 : 0.70
            return Candidate(vf: vf, kind: .sameSubjectReversal, confidence: conf,
                             probes: [.sameSubjectOpposed(a: f.quoteA, b: f.quoteB)],
                             rationale: clip("\"\(qA)\" against \"\(qB)\" — the same subject in opposed states.", kRationaleMax))
        case .realVsDepicted:
            // The register flip must be verifiable: a depiction word in
            // exactly one span. Two real things (truck ↔ truck) or none fail.
            // The probe then checks the depicted thing is a version of the
            // SAME kind of thing (bus ↔ toy cars is not).
            let depA = containsDepictionWord(f.quoteA)
            let depB = containsDepictionWord(f.quoteB)
            guard depA != depB else { return nil }
            let real = depA ? f.quoteB : f.quoteA
            let depicted = depA ? f.quoteA : f.quoteB
            return Candidate(vf: vf, kind: .realVsDepicted, confidence: 0.90,
                             probes: [.sameKindDepicted(real: real, depicted: depicted)],
                             rationale: clip("\"\(qA)\" ↔ \"\(qB)\" — the same thing real in one frame, depicted in the other.", kRationaleMax))
        case .gestureEcho:
            return Candidate(vf: vf, kind: .gestureEcho, confidence: 0.70,
                             probes: [.sameGesture(a: f.quoteA, b: f.quoteB, category: categoryNote)],
                             rationale: clip("The same gesture in both frames: \"\(qA)\" / \"\(qB)\".", kRationaleMax))
        case .sharedCategory:
            return nil
        }
    }
}
