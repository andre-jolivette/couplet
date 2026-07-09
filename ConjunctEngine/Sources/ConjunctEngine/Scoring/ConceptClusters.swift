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

        // #120 (2026-07-08) collision removals: "demonstr" (28% of 348 firings —
        // political "demonstration", not demonstrating skill), "play" (55/69 the mood
        // adjective "playful"; instrument-playing captions still fire via
        // guitar/drum/perform/musician), "present" ("Two men are present"). The rich
        // performance vocabulary (rodeo/lasso/rope/ride/danc/perform) is untouched.
        Cluster(name: "skilled_performance", keywords: [
            "perform", "performanc", "rope", "race", "compet", "ride",
            "throw", "catch", "swing", "danc", "juggl", "acrobat", "athlet",
            "skill", "techniqu", "craft", "musician", "artist", "rodeo", "lasso",
            "concert", "recit", "rehears", "execut", "exhibit",
            "stag", "act"
        ]),

        // #120 (2026-07-08) collision removals: "hold" (85% of the cluster's 662 corpus
        // firings; 45-sample review ≈90% instrumental — phones/signs/cups/cigarettes;
        // only 62/565 hold-captions contain any tender register word; judged-pair
        // enrichment 4% = base; explicit hand-holding is carried by the role pipeline,
        // #116/G14), "lean" (15% — physical leaning on railings/walls), "shield"
        // (13/15 "shielding eyes from sun"; the sensory sense lives in
        // sensory_overwhelm). Reachability fixes: "gentl" matched NOTHING — "gently"
        // stems to "gent" (36 captions of genuinely tender language were invisible),
        // "gentle" to itself; "affection" stems to "affec"; bare "embrace"/"shelter"
        // stem to "embrace"/"shelt". "touch"/"child"/"support" kept (mixed but below
        // the ~80% artifact bar; see #120 verdict table).
        Cluster(name: "tenderness_care", keywords: [
            "embrac", "embrace", "comfort", "gent", "gentle", "care", "nurtur", "protect",
            "tend", "cradl", "hug", "kiss", "touch", "sooth", "love",
            "affec", "affectionate",
            "parent", "child", "mother", "father", "tender", "stroking", "caress",
            "support", "cling", "shelt", "guard", "devot"
        ]),

        // #120 (2026-07-08) collision removals: "quiet" (57% of 130 firings —
        // boilerplate, often "quiet interaction between two people" = anti-isolation;
        // quiet stays in stillness_rest where the register fits), "still" (32% —
        // "standing still" ≠ solitude; stays in stillness_rest), "apart" (7/7 "legs
        // apart"). Reachability: the cluster could not match its own name — "solitud"
        // never matched "solitude" (10 captions), "solitar" never matched "solitary"
        // (5), "empt" never matched "empty" (6). "contemplat"/"introspect" left
        // as-is (near-dead) — deliberately NOT fixed to "contempl"/"introspective":
        // those are captioner mood-summary boilerplate (79/16 captions) and would
        // recreate the calm/relax problem.
        Cluster(name: "isolation_solitude", keywords: [
            "alone", "solitary", "empty", "silent", "lone",
            "isol", "distant", "withdrawn", "contemplat", "reflec",
            "ponder", "introspect", "solitude", "separatd", "outsid", "margin",
            "exclud", "ignor", "invisible", "unnoticed", "detach"
        ]),

        Cluster(name: "community_gathering", keywords: [
            "crowd", "group", "togeth", "famil", "friend", "communiti",
            "celebrat", "gather", "assembl", "audienc", "spectator",
            "festival", "parad", "event", "congregat", "march", "rally",
            "meet", "collect", "cluster", "mass", "throng", "public"
        ]),

        // #120 (2026-07-08) collision removals: "protest" (67% of 167 firings —
        // scene-classifier boilerplate on every protest photo = same-subject
        // coincidence, not tension resonance; the 30% enrichment reflects protest-pair
        // co-occurrence, not a relational signal), "pull" ("hair pulled back"), "push"
        // (strollers/wagons). "conflict"/"tense" kept despite negation-context noise
        // ("no signs of conflict") — token matching can't see the negation, but the
        // counts are small. Post-cleanup ≈49 genuine firings.
        Cluster(name: "tension_conflict", keywords: [
            "tense", "confront", "fight", "resist", "struggl",
            "conflict", "agress", "defiant", "argument", "clash",
            "compet", "rival", "oppos", "stand-off", "demand", "challeng",
            "anger", "fist", "standoff", "barrier", "block", "defi"
        ]),

        // #120 (2026-07-08) reachability adds (no removals — this cluster's keywords
        // are clean): "celebr"/"celebratory" ("celebration" stems to "celebr" via the
        // -ation strip — 45 captions the cluster was blind to), "excite" ("excitement"
        // → "excite" via -ment), "smile" (bare "smile", 13 captions — "smil" only
        // caught "smiling"/"smiles"), "dance" (bare "dance"/"dancer"). "festive" was
        // deliberately NOT added (34 captions, mostly "festive atmosphere" mood
        // boilerplate — the calm/relax lesson).
        Cluster(name: "joy_celebration", keywords: [
            "smil", "smile", "laugh", "celebrat", "celebr", "celebratory",
            "joy", "happi", "excit", "excite", "cheer",
            "delight", "elat", "triumphant", "festiv", "jubilant", "grin",
            // "rais" not "raise" — same keyword-reachability fix as bodily_gesture
            // above (#96 pass 3, 2026-07-07): "raise" never matched stemmed "rais".
            "beam", "gleam", "exuber", "playful", "danc", "dance", "jump", "rais",
            "toast", "applaud", "chant", "sing"
        ]),

        // #120 (2026-07-08): the cluster had only 21 corpus firings and 16 were
        // collisions — "bow" (48%: hair bows + violin bows, never bowing in grief)
        // and "numb" (29%: matches "number" via the -er strip — bus route 77, jersey
        // 16). "cri" matched nothing ("crying"/"cries" survive stemming intact due to
        // the length guard) → "crying"; "somber" was absent (stems to itself, 4
        // captions). Post-cleanup ≈9 genuine firings — rare-but-correct is the
        // tier-1.0 design intent.
        Cluster(name: "grief_sorrow", keywords: [
            "crying", "mourn", "grief", "sorrow", "pain", "sad", "weep",
            "lament", "despair", "anguish", "desolat", "heartbreak", "loss",
            "tear", "mournful", "somber", "distress", "agoni", "suffer",
            "slump", "hollow", "bereft", "griev"
        ]),

        // #120 (2026-07-08) collision removals: "build" (53% of 273 firings — background
        // "building" architecture, the single largest collision found in the audit),
        // "lift" ("foot lifted" mid-stride), "sweat" (matches ONLY "sweater" via the
        // -er strip), "pull" ("hair pulled back"). "grip"/"task"/"work"/"carri" kept
        // — genuine effort. Post-cleanup ≈96 firings.
        Cluster(name: "labor_effort", keywords: [
            "work", "carri", "toil", "effort", "strain",
            "labor", "haul", "construct", "repair", "fix", "craft",
            "mend", "forc", "exert", "industri", "grip", "heav", "push",
            "drag", "hoist", "load", "burden", "task", "grind"
        ]),

        // #120 (2026-07-08): removed "wheel" (steering wheels, Ferris wheels — not
        // motion). Reachability adds: "dynamic" (29 captions of "dynamic pose/movement"
        // — "dynam" only caught the rare bare stem), "runn" ("running" stems to "runn",
        // 11 captions — bare "run" matched 0), "runs". "blur" left as-is (do NOT add
        // "blurr": 49 captions of depth-of-field "blurred background", not motion).
        Cluster(name: "movement_energy", keywords: [
            "run", "runn", "runs", "chase", "fast", "motion", "blur", "energi", "dynam", "dynamic",
            "rush", "sprint", "leap", "jump", "bound", "gallop", "charg",
            "hurri", "speed", "swift", "rapid", "dash", "bolt", "lunge",
            "pivot", "spin", "burst", "flash"
        ]),

        // #120 (2026-07-08) collision removals: "rest" (47% of 590 firings — ≈90%
        // "hand rests on hip/lap" posture idiom, enrichment 4% = base), "relax" (37% —
        // captioner boilerplate "mood is casual and relaxed", enrichment 0%), "calm"
        // (28% — "calm and serene atmosphere" boilerplate), "sit" (near-inert: only
        // bare "sit" matched — "sits"/"sitting" stem to "sits"/"sitt"; ENABLING it
        // would add 226 scene-description firings, so removed instead), "station"
        // ("gas station"). Reachability: bare "pause" stems to itself (9 captions);
        // "stationary" added for the genuine still sense. "peac" left as-is (dead:
        // "peaceful" stems to "peace" — not added, it's "peaceful protest" + mood
        // boilerplate). Do NOT change "settl" to "sett": "setting" stems to "sett"
        // (490 captions!). "lean"/"quiet"/"still" kept — genuine rest postures/register.
        Cluster(name: "stillness_rest", keywords: [
            "paus", "pause", "still", "wait", "sleep",
            "quiet", "serene", "peac", "linger", "dwell", "reclin",
            "settl", "repos", "lean", "slouch", "crouch", "kneel", "perch",
            "stationary", "remain", "idle", "languid"
        ]),

        // "observ" removed (#96 pass 2, 2026-07-07): stem collision with "observing"
        // (photographic watching), not "observance" — 77% of this cluster's judged-pool
        // firings were this collision. Watching is already covered by looking_watching.
        // #120 (2026-07-08) collision removals: "kneel" (36% of the remaining 39
        // firings — mundane kneeling: holding a phone, tying shoelaces, playful;
        // stays in bodily_gesture/stillness_rest where it's genuine) and "bow"
        // (26% — hair/violin bows, same collision as grief_sorrow). Post-cleanup
        // ≈15 genuine firings (ceremonial/solemn/march/procession).
        Cluster(name: "ritual_ceremony", keywords: [
            "ritual", "ceremoni", "traditi", "sacr", "prayer", "worship",
            "bless", "anoint", "consecrat", "solemn", "formal", "inaugur",
            "initiat", "rite", "ceremonial", "devout",
            "vow", "oath", "incens", "altar", "procession", "march"
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

        // #120 (2026-07-08) collision removals: "open" (45% of 188 firings — "mouth
        // open", car doors), "strip" (40% — striped clothing; the SAME stem collision
        // #96 removed from transformation_change but missed here). "vulnerabl" could
        // never match bare "vulnerable" (stems to itself) → "vulnerable" (inert on
        // this corpus but correct, #96 obscure-class). "bare"/"reveal" kept — bare
        // feet/back and revealing-outfit senses are genuine exposure here.
        Cluster(name: "vulnerability_exposure", keywords: [
            "vulnerable", "expos", "bare", "raw", "unguard",
            "unprotect", "fragil", "delic", "susceptibl", "naked",
            "wound", "broken", "weak", "reveal", "unshield",
            "defenceless", "tender", "shaking", "trembl"
        ]),

        // #120 (2026-07-08) collision removals: "control" (20% of 60 firings —
        // "balance and control over the horse/bike", "gun control" signs, not
        // dominance), "larg" (matches ONLY comparative "larger": "part of a larger
        // crowd"), "tower" (literal water/city towers). "loom"/"uniform"/"badge"
        // kept — genuine authority register. Post-cleanup ≈36 firings.
        Cluster(name: "power_dominance", keywords: [
            "power", "dominat", "command", "authoriti", "strength",
            "forc", "impos", "assert", "overwhelm", "loom",
            "presid", "reign", "sovereign", "imposing", "vast",
            "march", "uniform", "weapon", "badge", "insignia"
        ]),

        // #120 (2026-07-08) collision removals: "small" (63% of 415 firings — "small
        // object/dog/bag" size adjective, nothing to do with youth) and "bent" ("arm/
        // legs bent" posture). Reachability: "toddler" stems to "toddl" via the -er
        // strip, so the keyword could never match its own word → "toddl". Post-cleanup
        // ≈174 firings (young/teen/child/aged/elder).
        Cluster(name: "youth_age", keywords: [
            "child", "young", "old", "elder", "age", "youth", "teen",
            "infant", "toddl", "wrinkl", "generat", "grown",
            "ancient", "aged", "matur", "veteran", "elderli", "juvenil",
            "tini", "frail", "gnarled", "sprightly"
        ]),

        // #120 (2026-07-08) — the second-largest polluter in the system (755 firings).
        // Removed the entire looking/watching vocabulary that belongs to
        // looking_watching, not waiting: "look" (71% — ubiquitous "looking at/toward"),
        // "gaze" (37% — the captioner's standard face formula), "observ"/"watch"
        // (observing/watching ≠ waiting), "listen" (belongs to sound_music). These
        // duplicated looking_watching and made "waiting" fire on nearly every portrait.
        // Reachability: the cluster could not match its own name — "anticipat" never
        // matched "anticipation" (stems to "anticip", 22 captions). Post-cleanup
        // ≈76 genuinely-waiting firings.
        Cluster(name: "waiting_anticipation", keywords: [
            "wait", "anticip", "expect",
            "scan", "survey", "monitor", "vigil", "guard",
            "patienc", "hopeful", "anxious", "peer", "squint", "search",
            "horizon", "alert", "ready", "brac", "tension"
        ]),

        // "strip" removed (#96 pass 2, 2026-07-07): stem collision with "striped"
        // clothing description, not "strip away" — 78% of this cluster's judged-pool
        // firings were this collision. Change sense retained via shed/reveal/transform.
        // #120 (2026-07-08) collision removals: "reveal" (52% of the remaining 21
        // firings — "background reveals", "revealing outfit"; the exposure sense lives
        // in vulnerability_exposure), "end" ("END ZONE", "rear end"), "born" (sock/sign
        // text), "pass" ("watching her pass"). Reachability: bare "change" stems to
        // itself (4 captions) — "chang" only caught "changing". Post-cleanup ≈6 firings.
        Cluster(name: "transformation_change", keywords: [
            "transform", "chang", "change", "becom", "evolv", "shift", "transit",
            "convert", "alter", "adapt", "emerg", "begin",
            "dissolv", "collaps", "shed",
            "renew", "die", "grown", "ripen"
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
            "instrument",
            // active music-making
            "strum", "pluck", "beat", "strik", "blow",
            "musician", "band", "orchestra", "mariachi",
            // musical phenomenon
            "sound", "music", "note", "melody", "song", "tune",
            "rhythm", "lyric", "chord", "hum", "resonat", "audibl",
            "echo",
            // sound reception / listening
            // #120 (2026-07-08): removed "ear" (13 firings, 11 "phone to his ear" — not
            // sound-as-force; the cupping-ears sensory case lives in sensory_overwhelm
            // via "cupp"/"noise"), "ring" (finger rings/jewelry), "bow" (hair bows;
            // violin-bow captions still fire via "violin"/"guitar"), "string" (string
            // lights; guitar strings fire via "guitar"). Added "heard" (genuine
            // sound-reception language). Post-cleanup ≈65 firings.
            "hear", "heard", "listen", "deaf", "mute",
            "concert", "recit", "gig", "audienc", "speaker", "amp"
        ]),

        // #120 (2026-07-08) collision removals: "cover" (46 firings — "ground covered
        // with dirt", "graffiti-covered walls"), "cup" (drinking cups), "grip"
        // (reins/handlebars motor action), "ear" (11/13 "phone to his ear"; note bare
        // "ears" also stemmed to "ear"), "nois" (dead — "noise" stems to itself).
        // Reachability/precision adds: "cupp" (catches "cupping her ears" — both G5
        // ears-women 572/712 and cupped hands — with zero drinking-cup hits), "noise",
        // "intense" (was unreachable; "intensity"→intens was already covered).
        // The ears-women stay in-cluster via cupp/noise/loud even without "ear".
        // "clos" ("eyes closed") kept — genuinely sensory.
        Cluster(name: "sensory_overwhelm", keywords: [
            // physical gestures of blocking/reacting
            "press", "cupp", "block", "plug",
            "shield", "brace", "wince", "flinch", "recoil", "cringe",
            "squint", "shut", "clos", "clutch", "grasp",
            // states of overwhelm
            "overwhelm", "drown", "flood", "barrag", "assail",
            "noise", "loud", "blaring", "pierc", "sharp",
            "sensori", "stimul", "intens", "intense", "excess", "too much",
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
        // #120 (2026-07-08): removed "seen" (14 firings — "can be seen in the distance"
        // passive-visibility filler, not the act of watching) and the dead keyword
        // "gaz" (real firings all come from "gaze"; the stemmer never produces bare
        // "gaz" from any corpus word — hygiene). This is the correct home for
        // gaze/watch/observe (reallocated out of waiting_anticipation above).
        Cluster(name: "looking_watching", keywords: [
            // deliberate gaze / sustained watching
            "watch", "stare", "gaze", "peer", "squint",
            "glance", "glimps", "observ", "witness", "behold",
            "survey", "scan", "scrutin",
            // being seen / caught in the act
            "noticed", "caught", "regard"
        ]),

        Cluster(name: "bodily_gesture", keywords: [
            // hands
            // "rais" not "raise" (#96 pass 3, 2026-07-07): matchedClusters compares
            // stemmed caption tokens against these RAW keyword strings — "raised"/
            // "raising" stem to "rais", so the dictionary-word "raise" never matched.
            // Verified: 170 corpus hits, all genuinely about raising a hand/arm/sign.
            "hand", "fist", "finger", "grip", "point", "reach",
            "rais", "open", "spread", "clasp", "wave", "gesture",
            // arms and body
            // #120 (2026-07-08): removed "fold" (14/15 "folding chairs") and "bow"
            // (hair bows — the gesture sense of bowing is unreached; same collision as
            // grief_sorrow/ritual_ceremony). The cluster's ubiquity (94% of corpus via
            // "hand" alone) is addressed by the Phase-4 tier demotion, not keyword edits.
            "arm", "shoulder", "back", "chest", "lean", "stretch",
            "extend", "cross", "hunch", "arch",
            // head and face
            "tilt", "nod", "shake", "turn", "lift",
            // whole body
            "kneel", "crouch", "sprawl", "press", "push", "pull"
        ]),

        // #120 (2026-07-08) collision removals: "sign" (65% of the cluster's 373 corpus
        // firings — literal bus-stop/storefront/street signs, not religious/political
        // signage), "cross" (23% — "arms crossed"/"crossing the street", never a
        // religious cross), "banner" (sponsor/rodeo banners). "flag" KEPT deliberately:
        // 18% judged-pair enrichment vs 2.4% base — genuinely political in a
        // protest-heavy library. Reachability fixes: "passionat" matched nothing
        // (nothing stems to it) → "passion"/"passionate"; "holi" never matched bare
        // "holy" (stems to itself) → "holy".
        Cluster(name: "devotion_belief", keywords: [
            "faith", "believ", "devout", "pious", "spirit", "soul",
            "sacred", "holy", "divin", "pray", "worship",
            "church", "temple", "mosque", "shrine", "altar",
            "symbol", "icon", "flag", "emblem",
            "pledge", "vow", "commit", "convict", "passion", "passionate", "fervent"
        ]),

        // #120 (2026-07-08) — worst collision density in the system: 12 keywords removed.
        // "behind" (63% of 550 firings — bare spatial preposition, enrichment 1% < base),
        // "wall" (18% — background scenery), "open" (16% — "mouth open"), "wide"
        // ("wide-brimmed hat"), "fence" (rodeo-arena/background fences; cf #114's
        // incidental-fence finding), "door"/"free"/"through"/"beyond"/"bar"/"break"
        // (scenery, "her hand is free", "taking a break", nightclub bars).
        // Reachability: bare "barrier" stems to "barri" via the -er strip (14 captions —
        // glass/concrete barriers, the cluster's genuine core); "freedom" was unreachable
        // via the removed "free". Cluster becomes rare-but-correct (~41 firings).
        Cluster(name: "confinement_freedom", keywords: [
            "cage", "lock", "bound", "trap",
            "confin", "restrict", "limit", "enclos",
            "freedom", "escape",
            "vast", "expand", "liberat", "releas", "flee",
            "border", "threshold", "gate", "barri"
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
            // #120 (2026-07-08): added "humorou" to G1 — "humorous"/"humorously" stem
            // to "humorou", so the keyword "humor" (which only matches bare "humor")
            // was blind to the far more common adjective form (14 captions).
            keywords: [
                "absurd", "humor", "humorou", "irony", "ironic", "comic", "whimsic", "juxtaposi",
                "laugh", "amuse", "delight", "play", "cheer", "glee"
            ],
            requiredGroups: [
                // G1 — comic/absurd tone is present
                ["absurd", "humor", "humorou", "irony", "ironic", "comic", "whimsic", "juxtaposi"],
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
                // "obscur" not "obscure" (#96 pass 3, 2026-07-07): matchedClusters compares
                // stemmed caption tokens against these RAW keyword strings — "obscured" stems
                // to "obscur", so the dictionary-word "obscure" never matched. Verified inert
                // on the current corpus (0 of 86 obscur-containing images also satisfy G1),
                // but a genuine latent defect independent of that rarity.
                "mirror", "echo", "obscur", "oblivio", "unaware", "synchro", "double"
            ],
            requiredGroups: [
                // G1 — eerie/dreamlike register
                ["surreal", "surrealism", "unsettl", "eerie", "ghost", "haunt", "dreamlike", "mysterio"],
                // G2 — specific visual mechanism: mirroring, concealment, unawareness
                ["mirror", "echo", "obscur", "oblivio", "unaware", "synchro", "double"]
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

    /// Picks a single representative cluster name from a set, deterministically:
    /// highest weight first, then alphabetical. Never rely on bare `Set.first` for
    /// display purposes — its iteration order depends on Swift's per-process hash
    /// seed and is stable within a run but not guaranteed across app launches
    /// (confirmed: repeated `swift test` invocations against identical input picked
    /// different elements). See decision #118.
    public static func representativeCluster(in clusters: Set<String>) -> String? {
        clusters.sorted { a, b in
            let wa = weights[a] ?? 0
            let wb = weights[b] ?? 0
            if wa != wb { return wa > wb }
            return a < b
        }.first
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
