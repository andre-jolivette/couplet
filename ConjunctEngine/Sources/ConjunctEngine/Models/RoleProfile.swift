import Foundation

/// A structured, per-image description of *roles* extracted from a caption by an
/// LLM (decision #102). Where the cluster system and embeddings measure *aboutness*
/// (what an image is of), the RoleProfile encodes *relational position* — who
/// produces vs. receives a phenomenon, what a sign demands vs. what a subject
/// enacts or subverts, whether an object is real vs. depicted. This is what lets
/// the deterministic join rules (`RoleJoins`) surface third-meaning pairs that
/// score low on every cheap axis and never enter the four-pool topK (backlog #95).
///
/// Stored as JSON text in `images.roleProfile`. Decoding is tolerant: any missing
/// field defaults to empty/nil, so a model that omits a slot does not fail the row.
public struct RoleProfile: Codable, Sendable, Equatable {

    public struct Phenomenon: Codable, Sendable, Equatable {
        /// One of: sound, gaze, motion, force, touch, speech, heat, smell.
        public var phenomenon: String
        /// "source" (produces it) or "receiver" (receives/blocks it).
        public var role: String
        public init(phenomenon: String, role: String) {
            self.phenomenon = phenomenon; self.role = role
        }
    }

    public struct ObjectRole: Codable, Sendable, Equatable {
        public var object: String
        /// One of: real, toy, depicted, costume, sign.
        public var register: String
        /// One-word hypernym used by the object join (e.g. "weapon", "bird"). May be empty.
        public var category: String
        public init(object: String, register: String, category: String = "") {
            self.object = object; self.register = register; self.category = category
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            object   = (try? c.decode(String.self, forKey: .object)) ?? ""
            register = (try? c.decode(String.self, forKey: .register)) ?? ""
            category = (try? c.decode(String.self, forKey: .category)) ?? ""
        }
    }

    public struct Stance: Codable, Sendable, Equatable {
        public var attitude: String
        /// "viewer" or "subject".
        public var target: String
        public init(attitude: String, target: String) {
            self.attitude = attitude; self.target = target
        }
    }

    public var subjects: [String]
    public var phenomena: [Phenomenon]
    /// Statements a sign/text in the image displays, normalized to meaning ("SEE
    /// SOMETHING SAY SOMETHING" → "danger"). Intentional signals — not frequency-gated.
    public var claims: [String]
    /// Concepts the subject embodies (a smiling person → "smile").
    public var enacts: [String]
    /// Concepts the subject physically blocks/prevents (a covered mouth → "smile").
    public var subverts: [String]
    public var objects: [ObjectRole]
    /// Nameable targets of a gaze/action (#72; reserved — join 4 deferred in v1).
    public var directedAt: [String]
    public var stance: Stance?

    enum CodingKeys: String, CodingKey {
        case subjects, phenomena, claims, enacts, subverts, objects
        case directedAt = "directed_at"
        case stance
    }

    public init(
        subjects: [String] = [], phenomena: [Phenomenon] = [], claims: [String] = [],
        enacts: [String] = [], subverts: [String] = [], objects: [ObjectRole] = [],
        directedAt: [String] = [], stance: Stance? = nil
    ) {
        self.subjects = subjects; self.phenomena = phenomena; self.claims = claims
        self.enacts = enacts; self.subverts = subverts; self.objects = objects
        self.directedAt = directedAt; self.stance = stance
    }

    /// Tolerant decode — any absent field defaults to empty/nil so a model that
    /// omits a slot still yields a usable profile rather than throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subjects   = (try? c.decode([String].self, forKey: .subjects)) ?? []
        phenomena  = (try? c.decode([Phenomenon].self, forKey: .phenomena)) ?? []
        claims     = (try? c.decode([String].self, forKey: .claims)) ?? []
        enacts     = (try? c.decode([String].self, forKey: .enacts)) ?? []
        subverts   = (try? c.decode([String].self, forKey: .subverts)) ?? []
        objects    = (try? c.decode([ObjectRole].self, forKey: .objects)) ?? []
        directedAt = (try? c.decode([String].self, forKey: .directedAt)) ?? []
        stance     = try? c.decode(Stance.self, forKey: .stance)
    }
}
