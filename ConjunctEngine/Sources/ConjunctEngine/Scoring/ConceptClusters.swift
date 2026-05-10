import Foundation

public enum ConceptClusters {

    public struct Cluster: Sendable {
        public let name: String
        public let keywords: Set<String>
        /// If set, the cluster fires only when the tokenised caption contains ≥1 keyword
        /// from **each** group. Prevents false positives from a single loose term
        /// (e.g. "surreal" alone for vivid lighting, "absurd" alone for any street scene).
        /// All groups must be satisfied; order does not matter.
        public let requiredGroups: [Set<String>]?

        public init(name: String, keywords: Set<String>, requiredGroups: [Set<String>]? = nil) {
            self.name = name
            self.keywords = keywords
            self.requiredGroups = requiredGroups
        }
    }

    public static let all: [Cluster] = [

        // ── Existing clusters (expanded) ─────────────────────────────────

        Cluster(name: "skilled_performance", keywords: [
            "perform", "performanc", "play", "rope", "race", "compet", "ride",
            "throw", "catch", "swing", "danc", "juggl", "acrobat", "athlet",
            "skill", "techniqu", "craft", "musician", "artist", "rodeo", "lasso",
            "concert", "recit", "rehears", "execut", "demonstr", "exhibit",
            "stag", "act", "present"
        ]),

        Cluster(name: "tenderness_care", keywords: [
            "hold", "embrac", "comfort", "gentl", "care", "nurtur", "protect",
            "tend", "cradl", "hug", "kiss", "touch", "sooth", "love", "affection",
            "parent", "child", "mother", "father", "tender", "stroking", "caress",
            "support", "lean", "cling", "shelter", "shield", "guard", "devot"
        ]),

        Cluster(name: "isolation_solitude", keywords: [
            "alone", "solitar", "empt", "quiet", "still", "silent", "lone",
            "isol", "distant", "apart", "withdrawn", "contemplat", "reflec",
            "ponder", "introspect", "solitud", "separatd", "outsid", "margin",
            "exclud", "ignor", "invisible", "unnoticed", "detach"
        ]),

        Cluster(name: "community_gathering", keywords: [
            "crowd", "group", "togeth", "famil", "friend", "communiti",
            "celebrat", "gather", "assembl", "audienc", "spectator",
            "festival", "parad", "event", "congregat", "march", "rally",
            "meet", "collect", "cluster", "mass", "throng", "public"
        ]),

        Cluster(name: "tension_conflict", keywords: [
            "tense", "confront", "fight", "resist", "push", "pull", "struggl",
            "conflict", "agress", "defiant", "protest", "argument", "clash",
            "compet", "rival", "oppos", "stand-off", "demand", "challeng",
            "anger", "fist", "standoff", "barrier", "block", "defi"
        ]),

        Cluster(name: "joy_celebration", keywords: [
            "smil", "laugh", "celebrat", "joy", "happi", "excit", "cheer",
            "delight", "elat", "triumphant", "festiv", "jubilant", "grin",
            "beam", "gleam", "exuber", "playful", "danc", "jump", "raise",
            "toast", "applaud", "chant", "sing"
        ]),

        Cluster(name: "grief_sorrow", keywords: [
            "cri", "mourn", "grief", "sorrow", "pain", "sad", "weep",
            "lament", "despair", "anguish", "desolat", "heartbreak", "loss",
            "tear", "mournful", "somber", "distress", "agoni", "suffer",
            "bow", "slump", "hollow", "numb", "bereft", "griev"
        ]),

        Cluster(name: "labor_effort", keywords: [
            "work", "build", "lift", "carri", "toil", "effort", "strain",
            "labor", "sweat", "haul", "construct", "repair", "fix", "craft",
            "mend", "forc", "exert", "industri", "grip", "heav", "push",
            "drag", "pull", "hoist", "load", "burden", "task", "grind"
        ]),

        Cluster(name: "movement_energy", keywords: [
            "run", "chase", "fast", "motion", "blur", "energi", "dynam",
            "rush", "sprint", "leap", "jump", "bound", "gallop", "charg",
            "hurri", "speed", "swift", "rapid", "dash", "bolt", "lunge",
            "pivot", "spin", "wheel", "burst", "flash"
        ]),

        Cluster(name: "stillness_rest", keywords: [
            "sit", "rest", "paus", "calm", "still", "wait", "sleep",
            "quiet", "serene", "peac", "relax", "linger", "dwell", "reclin",
            "settl", "repos", "lean", "slouch", "crouch", "kneel", "perch",
            "station", "remain", "idle", "languid"
        ]),

        Cluster(name: "ritual_ceremony", keywords: [
            "ritual", "ceremoni", "traditi", "sacr", "prayer", "worship",
            "bless", "anoint", "consecrat", "solemn", "formal", "inaugur",
            "initiat", "rite", "observ", "ceremonial", "devout", "kneel",
            "bow", "vow", "oath", "incens", "altar", "procession", "march"
        ]),

        Cluster(name: "urban_street", keywords: [
            "street", "citi", "urban", "sidewalk", "alley", "downtown",
            "intersection", "pedestrian", "storefron", "graffiti", "neon",
            "commut", "passerby", "corner", "block", "pavement", "curb",
            "traffic", "signal", "billboard", "awning", "stoop", "stair"
        ]),

        // nature_landscape: removed "tree", "light", "shadow", "open", "vast" —
        // these fire in urban contexts ("urban greenery", "play of light",
        // "shadow on pavement", "open street"). The remaining keywords are
        // specific enough to imply a genuine landscape or natural environment.
        Cluster(name: "nature_landscape", keywords: [
            "sky", "water", "earth", "landscap",
            "sunset", "dawn", "forest", "field", "horizon", "cloud",
            "wind", "rain", "storm", "mountain", "river", "ocean",
            "meadow", "bloom", "wildernes", "foliag", "canopi", "grove"
        ]),

        Cluster(name: "vulnerability_exposure", keywords: [
            "vulnerabl", "expos", "bare", "raw", "open", "unguard",
            "unprotect", "fragil", "delic", "susceptibl", "naked",
            "wound", "broken", "weak", "strip", "reveal", "unshield",
            "defenceless", "tender", "shaking", "trembl"
        ]),

        Cluster(name: "power_dominance", keywords: [
            "power", "dominat", "control", "command", "authoriti", "strength",
            "forc", "impos", "assert", "overwhelm", "loom", "tower",
            "presid", "reign", "sovereign", "imposing", "larg", "vast",
            "march", "uniform", "weapon", "badge", "insignia"
        ]),

        Cluster(name: "youth_age", keywords: [
            "child", "young", "old", "elder", "age", "youth", "teen",
            "infant", "toddler", "wrinkl", "generat", "grown",
            "ancient", "aged", "matur", "veteran", "elderli", "juvenil",
            "small", "tini", "frail", "bent", "gnarled", "sprightly"
        ]),

        Cluster(name: "waiting_anticipation", keywords: [
            "wait", "anticipat", "expect", "watch", "look", "gaze",
            "observ", "scan", "survey", "monitor", "vigil", "guard",
            "patienc", "hopeful", "anxious", "peer", "squint", "search",
            "horizon", "listen", "alert", "ready", "brac", "tension"
        ]),

        Cluster(name: "transformation_change", keywords: [
            "transform", "chang", "becom", "evolv", "shift", "transit",
            "convert", "alter", "adapt", "emerg", "begin",
            "end", "dissolv", "collaps", "shed", "strip", "reveal",
            "renew", "born", "die", "pass", "grown", "ripen"
        ]),

        // ── New clusters ──────────────────────────────────────────────────

        // sound_music: single-signal. Fires for any image involving musical performance,
        // sound reception, or listening gesture.
        //
        // Removed from original: "play" (244 corpus hits via "play of light",
        // "play between shadows" — photography language, not sound). Also removed
        // "press", "cover", "plug", "shield", "block" — these are pure sensory_overwhelm
        // territory and don't add sound meaning on their own; keeping them created
        // artificial shared clusters between unrelated pairs.
        //
        // Kept: "ear", "hear", "listen" — genuinely about sound reception. A woman
        // cupping her ear correctly co-fires sound_music + sensory_overwhelm +
        // bodily_gesture; that's accurate, not a false positive.
        Cluster(name: "sound_music", keywords: [
            // instruments
            "violin", "guitar", "trumpet", "drum", "piano", "bass",
            "fiddle", "banjo", "saxophon", "tuba", "clarinet", "flute",
            "instrument", "string", "bow",
            // active music-making
            "strum", "pluck", "beat", "strik", "blow",
            "musician", "band", "orchestra", "mariachi",
            // musical phenomenon
            "sound", "music", "note", "melody", "song", "tune",
            "rhythm", "lyric", "chord", "hum", "resonat", "audibl",
            "ring", "echo",
            // sound reception / listening
            "ear", "hear", "listen", "deaf", "mute",
            "concert", "recit", "gig", "audienc", "speaker", "amp"
        ]),

        Cluster(name: "sensory_overwhelm", keywords: [
            // physical gestures of blocking/reacting
            "ear", "press", "cover", "cup", "block", "plug",
            "shield", "brace", "wince", "flinch", "recoil", "cringe",
            "squint", "shut", "clos", "grip", "clutch", "grasp",
            // states of overwhelm
            "overwhelm", "drown", "flood", "barrag", "assail",
            "nois", "loud", "blaring", "pierc", "sharp",
            "sensori", "stimul", "intens", "excess", "too much",
            // facial/bodily distress
            "distress", "strain", "grimac", "tighten", "taut",
            "knit", "furrow", "contort", "tense", "rigid"
        ]),

        // looking_watching: pruned heavily. Removed "look" (fires from "looking"
        // in nearly every portrait caption), "eye"/"focus"/"attention" (ambient
        // portrait language), "frame"/"camera"/"lens"/"glass"/"window"/"reflect"/
        // "reveal"/"expos"/"point"/"aim"/"direct" (photography-description words
        // that aren't about the human act of watching). What remains is
        // vocabulary that specifically describes intent, sustained gaze, or
        // deliberate observation.
        Cluster(name: "looking_watching", keywords: [
            // deliberate gaze / sustained watching
            // "gaz" added alongside "gaze": the stemmer strips "-ing" from 7-char words
            // (gazing → gaz) but not 6-char "gazing"-fail-case words, so both forms needed.
            "watch", "stare", "gaze", "gaz", "peer", "squint",
            "glance", "glimps", "observ", "witness", "behold",
            "survey", "scan", "scrutin",
            // being seen / caught in the act
            "seen", "noticed", "caught", "regard"
        ]),

        Cluster(name: "bodily_gesture", keywords: [
            // hands
            "hand", "fist", "finger", "grip", "point", "reach",
            "raise", "open", "spread", "clasp", "wave", "gesture",
            // arms and body
            "arm", "shoulder", "back", "chest", "lean", "stretch",
            "extend", "fold", "cross", "hunch", "arch",
            // head and face
            "bow", "tilt", "nod", "shake", "turn", "lift",
            // whole body
            "kneel", "crouch", "sprawl", "press", "push", "pull"
        ]),

        Cluster(name: "devotion_belief", keywords: [
            "faith", "believ", "devout", "pious", "spirit", "soul",
            "sacred", "holi", "divin", "pray", "worship", "cross",
            "church", "temple", "mosque", "shrine", "altar",
            "sign", "symbol", "icon", "flag", "banner", "emblem",
            "pledge", "vow", "commit", "convict", "passionat", "fervent"
        ]),

        Cluster(name: "confinement_freedom", keywords: [
            "cage", "fence", "wall", "bar", "lock", "bound", "trap",
            "confin", "restrict", "limit", "enclos", "behind",
            "free", "open", "escape", "break", "through", "beyond",
            "vast", "wide", "expand", "liberat", "releas", "flee",
            "border", "threshold", "door", "gate", "barrier"
        ]),

        // ── Photographer-influence clusters (#15) ─────────────────────────
        // Designed through research into the humanist street and documentary
        // tradition (Paul Graham, Rebecca Norris Webb, Daniel Arnold, Jeremy
        // Paige, Melissa O'Shaughnessy, Andre Wagner, Rosalind Fox Solomon,
        // Sage Sohier). Validated against 1,080 live qwen2.5vl captions before
        // implementation.
        //
        // humor_absurdity and uncanny_ordinary use requiredGroups (two-signal)
        // because their individual keywords are high-frequency in street captions:
        // "absurd" (121×), "juxtaposition" (121×), "surreal" (59×), "obscured" (91×).
        // Without two-signal gating these would fire on nearly every street photo.

        Cluster(
            name: "humor_absurdity",
            // Union of both groups — kept so any keyword-browsing code sees the full set.
            keywords: [
                "absurd", "humor", "irony", "ironic", "comic", "whimsic", "juxtaposi",
                "laugh", "amuse", "delight", "play", "cheer", "glee"
            ],
            requiredGroups: [
                // G1 — comic/absurd tone is present
                ["absurd", "humor", "irony", "ironic", "comic", "whimsic", "juxtaposi"],
                // G2 — visible reaction or tonal resolution (amused, laughing, playful, etc.)
                ["laugh", "amuse", "delight", "play", "cheer", "glee"]
            ]
        ),

        Cluster(
            name: "uncanny_ordinary",
            keywords: [
                // G1: eerie/dreamlike register
                // "surrealism" added explicitly — stem("surrealism") = "surrealism"
                // (no suffix match in stemmer), so it doesn't collapse to "surreal".
                // qwen writes "a touch of surrealism" rather than "surreal" when
                // describing halo effects and dreamlike light quality.
                "surreal", "surrealism", "unsettl", "eerie", "ghost", "haunt", "dreamlike", "mysterio",
                // G2: specific visual mechanism (mirroring, concealment, unawareness)
                "mirror", "echo", "obscure", "oblivio", "unaware", "synchro", "double"
            ],
            requiredGroups: [
                // G1 — eerie/dreamlike register
                ["surreal", "surrealism", "unsettl", "eerie", "ghost", "haunt", "dreamlike", "mysterio"],
                // G2 — specific visual mechanism: mirroring, concealment, unawareness
                ["mirror", "echo", "obscure", "oblivio", "unaware", "synchro", "double"]
            ]
        ),

        // economic_precarity: two-signal — prevents "worn cobblestone" or "weathered
        // sunlight" from firing via G2 alone.
        //
        // Added "struggle" (base form). "struggl" only catches "struggling"
        // (strip -ing); stem("struggle") = "struggle" (no suffix match in stemmer),
        // so the base word was silently missed.
        //
        // G1 = social condition or systemic framing; G2 = visible material evidence.
        Cluster(
            name: "economic_precarity",
            keywords: [
                // G1: social condition / systemic framing
                "marginalize", "inequalit", "precario", "systemic", "forgotten",
                "overlook", "neglect", "struggl", "struggle", "hardship", "surviv",
                "downtrodden", "fallen",
                // G2: visible material evidence
                "weather", "worn", "dishevel", "makeshift", "tatter"
            ],
            requiredGroups: [
                // G1 — social condition or framing (required anchor)
                ["marginalize", "inequalit", "precario", "systemic", "forgotten",
                 "overlook", "neglect", "struggl", "struggle", "hardship", "surviv",
                 "downtrodden", "fallen"],
                // G2 — visible material evidence on the person or environment
                ["weather", "worn", "dishevel", "makeshift", "tatter"]
            ]
        ),

        // solitude_in_crowd: two-signal required to distinguish from isolation_solitude.
        // isolation_solitude fires for aloneness in any context; this cluster requires
        // at least one crowd-context word so a lone figure on an empty street doesn't
        // co-fire both clusters.
        Cluster(
            name: "solitude_in_crowd",
            keywords: [
                "crowd", "bustl", "amid", "pedestrian", "passerby", "surround", "throng",
                "stream", "mass",
                "alone", "solitary", "detach", "withdrawn", "invisible", "unnoticed",
                "ignored", "disconnect", "periphery", "adrift"
            ],
            requiredGroups: [
                // G1 — crowd context (at least one required)
                ["crowd", "bustl", "amid", "pedestrian", "passerby", "surround", "throng",
                 "stream", "mass"],
                // G2 — solitude / psychological disconnection
                ["alone", "solitary", "detach", "withdrawn", "invisible", "unnoticed",
                 "ignored", "disconnect", "periphery", "adrift"]
            ]
        ),

        // domestic_intimacy: two-signal — requires BOTH an enclosed personal space
        // AND a domestic behavioral register word.
        //
        // Removed from original single-signal:
        //   "tend"    — stem catches "tender" (tenderness_care territory), extremely
        //               common in humanist portrait captions. Was causing near-universal
        //               false-positive co-fire with tenderness_care.
        //   "window"  — too ambient in street/architectural photography.
        //   "settled" — too vague.
        //   "lived"   — too broad ("lived experience", "lived through").
        //
        // Added enclosure vocabulary per user intent: fires for subjects in their
        // own personal bubble of space — car interior, tent, home interior, etc.
        // even when that space is in a public setting.
        Cluster(
            name: "domestic_intimacy",
            keywords: [
                // G1: enclosed personal space (home or home-like bubble in public)
                "domestic", "household", "interior", "cozy", "curtain", "famili",
                "belonging", "doorstep", "windshield", "dashboard", "backseat",
                "tent", "camper", "room",
                // G2: domestic or intimate behavioral register
                "nurtur", "groom", "nest", "habitual", "intimate", "caring"
            ],
            requiredGroups: [
                // G1 — enclosed personal space (at least one required)
                ["domestic", "household", "interior", "cozy", "curtain", "famili",
                 "belonging", "doorstep", "windshield", "dashboard", "backseat",
                 "tent", "camper", "room"],
                // G2 — domestic behavioral or intimate register
                ["nurtur", "groom", "nest", "habitual", "intimate", "caring"]
            ]
        ),

        // animal_presence: two-signal — requires BOTH a specific animal subject AND
        // a behavioral or relational context word. Single-signal "dog" would fire on
        // nearly any street caption that incidentally mentions a dog in the background.
        //
        // Tier 0.2 (demoted from 0.75 in #47, 2026-05-06): "two dogs" is ambient
        // subject context, not resonance. Animal pairs now only score meaningfully
        // when they share a genuine emotional cluster (tenderness_care, isolation_solitude,
        // etc.). The two-signal gate is retained to prevent false positives.
        //
        // G1 uses exact short nouns (dog, cat, horse, bird) that the stemmer leaves
        // unchanged. G2 uses behavioral/relational words that indicate the animal is
        // the emotional anchor of the scene, not just scenery.
        Cluster(
            name: "animal_presence",
            keywords: [
                // G1: specific animal subject nouns
                "dog", "cat", "horse", "bird", "pup", "mutt", "hound",
                "stray", "pigeon", "crow", "donkey", "canine", "equine",
                "feline", "anim", "creature", "colt", "mare",
                // G2: behavioral or relational context (animal as emotional anchor)
                "leash", "tether", "patient", "roam", "trot", "sniff",
                "paw", "tongue", "companion", "follow", "wag", "rider",
                "mount", "gallop"
            ],
            requiredGroups: [
                // G1 — a specific animal must be present as subject
                ["dog", "cat", "horse", "bird", "pup", "mutt", "hound",
                 "stray", "pigeon", "crow", "donkey", "canine", "equine",
                 "feline", "anim", "creature", "colt", "mare"],
                // G2 — animal behavior or human-animal relational context
                ["leash", "tether", "patient", "roam", "trot", "sniff",
                 "paw", "tongue", "companion", "follow", "wag", "rider",
                 "mount", "gallop"]
            ]
        ),
    ]

    // MARK: - Cluster weights

    /// Pairing weight per cluster for weighted Dice scoring.
    /// 1.0 = emotionally/dramatically specific; 0.5 = ambient setting/context.
    public static let weights: [String: Float] = [
        // Tier 1.0 — high specificity, rare, emotionally charged
        "grief_sorrow":           1.0,
        "vulnerability_exposure": 1.0,
        "isolation_solitude":     1.0,
        "ritual_ceremony":        1.0,
        "tension_conflict":       1.0,
        "tenderness_care":        1.0,
        "devotion_belief":        1.0,
        "power_dominance":        1.0,
        "sensory_overwhelm":      1.0,
        // Tier 0.75 — meaningful but moderate frequency
        "transformation_change":  0.75,
        "skilled_performance":    0.75,
        "labor_effort":           0.75,
        "stillness_rest":         0.75,
        "waiting_anticipation":   0.75,
        "movement_energy":        0.75,
        "bodily_gesture":         0.75,
        "looking_watching":       0.75,
        "confinement_freedom":    0.75,
        "youth_age":              0.75,
        "sound_music":            0.75,
        "joy_celebration":        0.75,
        // Tier 0.2 — ambient setting/context clusters.
        // These fire on the majority of street photography images and are expected
        // co-occurrences, not meaningful resonance signals. Weight 0.2 means they
        // contribute minimally to the Dice numerator even when shared, and three of
        // them combined (0.6) still cannot clear the meaningful-tier gate in weightedDice.
        "urban_street":           0.2,
        "nature_landscape":       0.2,
        "community_gathering":    0.2,
        // ── Photographer-influence clusters (#15) ────────────────────────
        // Tier 1.0 — emotionally/dramatically specific; rare when firing correctly
        "uncanny_ordinary":       1.0,
        "economic_precarity":     1.0,
        "solitude_in_crowd":      1.0,
        "domestic_intimacy":      1.0,
        // Tier 0.75 — meaningful; two-signal gate prevents ambient over-firing
        "humor_absurdity":        0.75,
        // Tier 0.2 — ambient subject context (#47, 2026-05-06)
        // "Two dogs" is shared context, not resonance. Demoted from 0.75 so
        // animal pairs must share an emotional cluster to score meaningfully.
        "animal_presence":        0.2,
    ]

    // MARK: - Complementary axis pairs

    /// Cluster pairs that are opposite ends of the same phenomenon.
    /// A bonus is added to thematic score when imageA fires one end and imageB the other
    /// (evaluated symmetrically — A↔B or B↔A both fire).
    /// (#48, 2026-05-06)
    public static let axisPairs: [(a: String, b: String, bonus: Float)] = [
        ("sound_music",         "sensory_overwhelm",      0.35),  // source ↔ receiver of sound
        ("power_dominance",     "vulnerability_exposure",  0.35),  // power ↔ its subject
        ("skilled_performance", "looking_watching",        0.25),  // performer ↔ audience
        ("tenderness_care",     "isolation_solitude",      0.25),  // connection ↔ disconnection
        ("joy_celebration",     "grief_sorrow",            0.30),  // joy ↔ grief
        ("power_dominance",     "confinement_freedom",     0.25),  // authority ↔ constraint
        ("labor_effort",        "stillness_rest",          0.20),  // work ↔ rest
        ("movement_energy",     "stillness_rest",          0.20),  // motion ↔ stillness
        ("devotion_belief",     "tension_conflict",        0.20),  // faith ↔ discord
    ]

    // MARK: - Weighted Dice floor

    // The tier weight scheme has three levels: 1.0 (emotionally specific),
    // 0.75 (meaningful but moderate), 0.2 (ambient context: urban_street,
    // nature_landscape, community_gathering).
    //
    // The ambient tier fires on the majority of street photos — sharing urban_street
    // is expected coincidence, not resonance. The meaningful-tier gate in weightedDice
    // requires ≥1 cluster in the intersection with weight ≥ 0.75 before a real Dice
    // score is computed. Pairs whose shared clusters are all ambient-tier (max combined
    // weight 3 × 0.2 = 0.6) return kAmbientFloor instead.
    //
    // Ambient weights (0.2) still contribute to the Dice denominator when present in
    // only one image, lightly penalising asymmetry — but when shared they add only 0.2
    // to the numerator alongside genuine emotional clusters, keeping their influence
    // proportional to their semantic value.
    //
    // ⚠️  If you add a new ambient cluster, keep its weight ≤ 0.24 so that all
    //     possible ambient-only shared sums stay below 0.75 (the meaningful-tier
    //     floor). Or add it to kAmbientClusters and extend the explicit guard.
    /// Score returned when the shared intersection contains no meaningful-tier cluster
    /// (weight ≥ 0.75) — a weak ambient signal, not genuine thematic resonance.
    private static let kAmbientFloor: Float = 0.1

    // MARK: - Scoring

    public static func matchedClusters(for caption: String) -> Set<String> {
        let wordSet = Set(tokenize(caption))
        var matched = Set<String>()
        for cluster in all {
            if let groups = cluster.requiredGroups {
                // Two-signal mode: every group must contribute at least one keyword hit.
                if groups.allSatisfy({ !wordSet.isDisjoint(with: $0) }) {
                    matched.insert(cluster.name)
                }
            } else {
                if !wordSet.isDisjoint(with: cluster.keywords) {
                    matched.insert(cluster.name)
                }
            }
        }
        return matched
    }

    public static func thematicScore(captionA: String, captionB: String) -> Float {
        let cA = matchedClusters(for: captionA)
        let cB = matchedClusters(for: captionB)
        guard !cA.isEmpty, !cB.isEmpty else { return 0 }
        return weightedDice(clustersA: cA, clustersB: cB)
    }

    /// Weighted Dice on pre-matched cluster sets.
    /// Use from PairScorer (which already has the sets) to avoid re-tokenising.
    /// Asymmetry and saturation gates are the caller's responsibility.
    public static func weightedDice(clustersA: Set<String>, clustersB: Set<String>) -> Float {
        // Weighted Dice: 2 × Σweights(A∩B) / (Σweights(A) + Σweights(B))
        // Emotionally specific clusters (weight 1.0) contribute more than ambient
        // setting clusters (weight 0.2). Unknown clusters default to 0.5.
        let shared = clustersA.intersection(clustersB)
        // Meaningful-tier gate: the shared intersection must contain at least one
        // cluster with weight ≥ 0.75. If the overlap is only ambient clusters
        // (urban_street / nature_landscape / community_gathering, weight 0.2),
        // that's expected coincidence in a street photography library — not resonance.
        guard shared.contains(where: { (weights[$0] ?? 0) >= 0.75 }) else {
            return kAmbientFloor
        }
        let weightedShared = shared.reduce(0.0) { $0 + (weights[$1] ?? 0.5) }
        let sumA = clustersA.reduce(0.0) { $0 + (weights[$1] ?? 0.5) }
        let sumB = clustersB.reduce(0.0) { $0 + (weights[$1] ?? 0.5) }
        let denom = sumA + sumB
        return denom > 0 ? Float(2 * weightedShared / denom) : 0
    }

    // MARK: - Tokenizer

    /// Splits caption into stemmed word tokens, filtering stop-words.
    static func tokenize(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "the","a","an","is","are","in","on","at","and","or","of","to",
            "with","by","for","their","his","her","they","he","she","it",
            "this","that","there","has","have","from","what","who","which",
            "when","where","while","been","being","was","were","will","would",
            "could","should","may","might","both","each","such","some","more"
        ]
        return text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .map { stem($0) }
    }

    /// Strips common English suffixes to approximate word roots.
    /// Order matters — longer suffixes first to avoid over-stripping.
    static func stem(_ word: String) -> String {
        var w = word
        let suffixes = [
            "ation", "tion", "ance", "ence", "ness", "ment",
            "able", "ible", "ing", "ity", "ies", "ed", "er",
            "al", "ly", "ful", "es", "s"
        ]
        for suffix in suffixes {
            if w.hasSuffix(suffix) && w.count > suffix.count + 3 {
                w = String(w.dropLast(suffix.count))
                break
            }
        }
        return w
    }
}
