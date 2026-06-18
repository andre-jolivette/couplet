# Couplet — Pairing Theory

*A foundational document written mid-build, after the keyword-cluster system reached its ceiling (decisions #45–#49) and before the caption prompt redesign (#50). Its purpose: define what we're actually trying to find, so we can evaluate whether the architecture can express it. Some sections reference in-progress work that has since been completed or evolved — see [DECISIONS.md](DECISIONS.md) for the current state.*

---

## The Central Claim

A good image pair is not *necessarily* two images that differ in subject, mood, or visual style. The composite score exists precisely because different kinds of pairs work through different combinations of axes. Not all three axes need to fire strongly for a pair to be great — a pair can be excellent on two, or even one if that one is deep enough.

There are at least two distinct modes of great pairing:

**Mode 1: The semantic pair.** Two images that occupy complementary positions within the same human experience arc — where neither image alone names the arc, but together they make it visible. Musician + ears woman. This is Eisenstein's "third meaning": the idea or feeling that exists in neither image alone but emerges from their juxtaposition. The pair creates a gap; the viewer's mind bridges it; the bridge is the meaning.

**Mode 2: The lyrical/formal pair.** Two images that resonate through visual and emotional harmony rather than semantic opposition — where the connection is more poetic than argumentative. Alex Webb and Rebecca Norris Webb both work extensively in this mode, independently and together. Their pairings often share an emotional register, a quality of light, a formal tension — the thematic resonance is real but operates below the level of explicit meaning. These pairs feel true without explaining why. The connection is felt before it's named.

The current scoring system is structurally oriented toward Mode 1 (thematic cluster overlap) and only partially equipped for Mode 2 (aesthetic + geometric axes that don't yet capture what makes a Webb-style pair work). **This is a significant gap worth its own investigation** — see the backlog note at the end of this document.

Both modes can produce pairs that pass the third-meaning test. The difference is *where* the third meaning lives: in Mode 1, it's an idea or relationship that can be articulated. In Mode 2, it's a feeling, a mood-echo, a formal truth that resists articulation but is immediately perceived.

---

## What Makes the Musician + Ears Pair Work

The canonical test case: a violinist playing beside a car trunk at a charreada (a Mexican rodeo) in a Latinx neighborhood, paired with a woman sitting on steps pressing her hands over her ears. Note on the ears image: the caption tends to read her as blocking sound out, but she is actually cupping her ears because she is straining to hear a speaker. The gesture is reaching-toward, not shutting-out.

These images share almost nothing:
- Different subjects, demographics, locations, activities
- No shared visual style, palette, or light
- Completely different emotional registers on the surface

Yet the pairing is immediately compelling. Why?

**They occupy opposite ends of the same experiential arc.**

The violinist is a *source* — generating sensation, putting sound into the world, offering it outward, perhaps obliviously. The woman is a *receiver straining toward* — cupping her ears to pull in more of the world, trying to hear something. Not blocking out: reaching in.

This correction matters. The third meaning isn't "someone pours sound into a world where someone drowns in it" — it's closer to: *sound moves through the city; one person makes it, another hungers for it.* The arc is still source/receiver, emitter/receiver. But the relationship is more tender than combative. The viewer supplies the bridge: does she hear him? Could she? The geographic and contextual distance between them makes the yearning more poignant, not less. Neither image contains that meaning. It emerges from the gap.

Three things make this work:

1. **Different positions, same arc.** One is emitting; the other is receiving. The arc they share is: sound as a force in the world that can give and be hungrily sought.

2. **The distance earns the bridge.** Because these images are visually and contextually far apart — different neighborhoods, different demographics, different activities — the viewer has to do real cognitive work to connect them. That work is the experience. Pairs that are too similar require no work; pairs that are too dissimilar offer no handhold. The musician+ears pair is at the productive tension point.

3. **Each image changes in meaning.** When you see the musician alone, he's a local scene. Paired with the woman, he becomes something more charged — is he the source of her overwhelm? Is she blocking out a world he's trying to enrich? The woman alone is just someone having a bad moment. Paired with the musician, her gesture becomes a response to something specific. **Each image elevates the other.** This mutual elevation is a strong signal of a good pair.

---

## What Makes Two Dogs a Bad Pair

Two dogs on leashes in different parts of the city share:
- Subject (dogs)
- Urban context
- Body language vocabulary (movement_energy, bodily_gesture)
- Behavioral context (walking, alert, domestic)

They score well by keyword matching. But the pairing is unrewarding. Why?

**They occupy the same position in the same arc.** Both images are simply: "a dog exists in an urban environment." The pair creates no third meaning. It just asserts: there are two dogs. The viewer already knew dogs existed.

No mutual elevation occurs. You could swap either dog with any other dog image in the library and the "pair" would be equally valid (or invalid). That interchangeability is a diagnostic: **if the specific pairing doesn't matter, the pair has no meaning.**

The dogs also fail another test: **the images don't need each other.** A good pair is one where neither image is complete without the other — where seeing one makes you want the other. The dogs are each independently comprehensible scenes that happen to be placed together.

---

## The Taxonomy of Bad Pairs (in descending order of failure)

**1. Taxonomic pairs.** Both images belong to the same category. Two dogs. Two hands with rings. Two musicians. Two mannequins. The "connection" is just category membership, which the viewer already possesses. Zero third meaning.

**2. Same-event pairs.** Both images are from the same event, location, or situation — two protest images, two festival images. The connection is historical (they were at the same place), not semantic. The viewer gets: "this photographer was at a protest." Not interesting.

**3. Incidental overlap pairs.** Both images happen to contain the same ambient element — both were shot on streets, both have trees, both have people in motion. The connection is genre (street photography) rather than human experience. Matches every pair in the library equally, so it discriminates nothing.

**4. Geometric rhyme pairs (without thematic)** — both have diagonal compositions, or similar subject scale, or similar tonal range. This *can* work when it serves a thematic connection — including a nuanced statement about the human experience — or fits as a Mode 2 pairing. When compositional similarity is all there is and it serves neither purpose, it's decorative — the images look like they belong together without saying anything together.

---

## The Architecture Problem, Stated Precisely

The current system measures **shared vocabulary in scene descriptions**. Scene descriptions answer the question: *what is in the frame?*

What makes a pair interesting is: *what position in human experience does this frame occupy?*

Those are different questions. And the answer to the second question is largely **absent from scene descriptions**.

A qwen2.5vl caption of the musician: something like *"A man plays violin beside the open trunk of a car on a residential street in a predominantly Latin neighborhood. He appears focused on his performance, perhaps a busker or an informal musician. The street is quiet; a few parked cars are visible."*

A qwen2.5vl caption of the ears woman: *"A woman in her 30s sits on a set of concrete steps, pressing both palms firmly over her ears. Her expression suggests discomfort or distress. The urban environment around her is indistinct."*

These captions share no vocabulary relevant to their experiential arc. The connection between them — SOURCE and RECEIVER of sensation — is nowhere in the text. The word "ear" appears in the second and gets matched to the `sound_music` and `sensory_overwhelm` clusters, which gives them some shared vocabulary. But that's an accidental lexical collision, not a recognition of the arc-relationship.

Two dogs, by contrast, produce captions full of shared vocabulary: leash, walk, street, urban, dog. The system rewards the dogs precisely because their captions are easily described in the same words.

**The mismatch is structural:** keyword matching on scene descriptions will always over-reward subject redundancy and under-reward cross-context resonance.

---

## What Each Scoring Axis Is Actually For

### Thematic (target weight: 0.40, boosted to 0.60)

**What it should measure:** The degree to which two images occupy complementary positions in the same human experience arc.

**What it currently measures:** Overlap in scene-description vocabulary, filtered through semantic clusters.

**The gap:** Scene vocabulary captures SUBJECT (what is present), not POSITION (what role the subject plays in a human situation). The musician and ears-woman share little subject vocabulary. The musician and another musician share lots of it.

**Good thematic pairs have these properties:**
- *Different* subjects, contexts, situations
- *Same* underlying human situation (the arc)
- Different positions within that arc (source/receiver, performer/audience, giver/receiver, cause/effect, question/answer, before/after emotionally)
- Neither image announces the arc; both participate in it implicitly
- Each image gains meaning from the other

**The current cluster system can express this when:**
- The arc maps onto a single named human experience (grief, isolation, devotion)
- Both images happen to use vocabulary that triggers the same cluster
- The vocabulary isn't so broad that it fires on everything

**The current cluster system cannot express this when:**
- The images participate in different *halves* of an arc (sound-making vs. sound-receiving)
- The arc is relational rather than categorical (it's about the connection between two states, not the states themselves)
- The vocabulary describing the two halves has no overlap

### Geometric (target weight: 0.20)

**What it should measure:** Whether the visual structures of the two images create productive tension or visual conversation when placed side by side.

**Good geometric pairs have these properties:**
- Complementary compositions (a strong diagonal left / a strong diagonal right — together they complete a shape)
- Productive visual tension (ordered vs. chaotic, dense vs. spare, figure at left edge / figure at right edge)
- Visual echo without redundancy (similar structural logic applied to different subjects)

**What it currently measures:** Structural similarity — edge orientation cosine similarity and composition grid similarity. This rewards images that *look the same structurally*.

**The gap:** Structural similarity is not the same as visual conversation. Two images with similar diagonal compositions might be redundant (same visual statement twice) or might complete each other (mirror diagonals creating a dynamic tension). The current scorer can't distinguish these.

**The secondary problem:** Street photography genre conventions mean many images share structural characteristics simply because of the genre (person-in-frame, urban background, similar subject scale). The geometric scorer is vulnerable to rewarding genre-similarity rather than meaningful visual resonance.

**What geometric should not do:** Act as a secondary subject-similarity measure. If two images score high geometric because both are medium-distance shots of a person in front of a wall, that's genre, not resonance.

### Aesthetic (target weight: 0.40, complementary to thematic)

**What it should measure:** Whether the two images could inhabit the same world — the sense that they were made by the same sensibility, in conditions that speak to each other.

**Good aesthetic pairs have these properties:**
- Tonal compatibility (both dark and interior, or both harsh midday sun)
- Color relationship (complementary palettes, or consistent desaturation)
- Light quality alignment (flat diffuse / flat diffuse; directional harsh / directional harsh)
- NOT necessarily identical — productive tension is valid here too (a high-key bright image against a dark image can work if the tonal opposition serves a thematic purpose)

**The current approach (HSL histogram intersection + LAB palette contrast) measures:**
- Color/tone compatibility reasonably well
- Visual harmony in the classical sense

**The gap:** Aesthetic compatibility, correctly understood, is in service of thematic compatibility. A cross-context thematic pair (musician + ears) *should* be able to work aesthetically even when the two images look different, if the tonal distance is itself part of the meaning. The current system may penalize valid thematic pairs for aesthetic distance when the distance is meaningful.

---

## The "Third Meaning" Test

A practical evaluation criterion: **Does the pair create a meaning that exists in neither image alone?**

Apply it to candidates:

*Two dogs on leashes.* Third meaning: "There are two dogs in the world." This was already known. → Fail.

*Musician + ears woman.* Third meaning: Sound as a force that moves through the city — given by one, blocked out by another. The city as sensory environment, simultaneously rich and overwhelming. → Pass.

*Two protest images.* Third meaning: "People protest." Already known from either image. → Fail. *(Unless the specific visual relationship creates something — one image is the crowd speaking, the other is a face listening. Then maybe.)*

*Grief face + hands offering flowers.* Third meaning: The gesture of comfort reaching toward the wound of loss. → Pass.

*Two mannequin displays.* Third meaning: "Mannequins exist in commercial spaces." → Fail.

*Person alone in crowd + person making eye contact in empty space.* Third meaning: The geometry of connection — the one surrounded but unseen, the one alone but seen. Presence and witness as complements. → Pass.

The test is intuitive. A pair passes when you can articulate what it's *about* — not what the images contain, but what they say together. A pair fails when the best description of the pair just restates what each image independently contains.

---

## Why "Cross-Context" Is the Signal

The visual diversity multiplier (decision #45) was on the right track philosophically even if it was insufficient technically. The insight behind it: **visually similar images are likely to be same-subject pairs; visually dissimilar images that still score thematically are likely to be arc-position pairs.**

A CLIP cosine below 0.30 means the images are visually very different. If they still have thematic connection, that connection is genuinely semantic — not just shared subject vocabulary producing incidental cluster overlap.

A CLIP cosine above 0.60 means the images are visually similar. Thematic overlap is more likely to be subject redundancy: both images contain the same thing, both captions describe the same thing, both match the same clusters.

This is why the visual diversity multiplier was structurally sound: it was a proxy for the taxonomic/arc-position distinction. But it can't overcome a keyword system that fundamentally can't detect arc-positions.

---



---

## Three Modes, Not Two

The earlier framing of Mode 1 (semantic arc) and Mode 2 (slant rhyme) misses something that Soth and Graham are doing that is neither. A third mode needs to be named before the architectural implications can be properly stated.

**Mode 1 — Semantic arc:** Two images occupy complementary positions in the same human experience arc. The connection is specific, cross-context, and can be articulated once seen. Musician + ears-woman. The third meaning is an idea.

**Mode 2 — Slant rhyme:** Two images share a specific formal property — a color echo, a geometric form, a light quality — while diverging on everything else. The connection is felt before it is named, and naming it diminishes it. Red vinyl + red wattles. The third meaning is a perception.

**Mode 3 — Ambient existential register:** Two images share a quality of *attention* — to the fragile, the fleeting, the ordinary made briefly legible. Soth's two towels. Graham's butterfly floating in blue space. These images are not formally echoing each other. They are not occupying opposite ends of an arc. They share something quieter: a way of looking that finds weight in things the world overlooks. The third meaning is a feeling — the drift of human existence, the texture of ordinary time.

Mode 3 is not purely aesthetic. The formal sparseness — quiet light, simple subject, open composition — is in *service* of thematic content, but the thematic content is real. You can't score Mode 3 pairs through caption vocabulary because no cluster captures "the fragile and ephemeral qualities of ordinary life" reliably. And you can't score them through formal echo because there's no specific property that rhymes between Soth's towels and Graham's butterfly. What they share is a quality of the photographer's attention, which is the hardest thing of all to detect algorithmically.

Mode 3 is named here as a boundary condition, not a current implementation target.

---

## Architectural Implications: The Two Real Paths for Mode 1

The architecture for improving Mode 1 scoring has exactly two distinct approaches. There is no coherent third option.

**Path A — Per-image feature improvement (role clusters + caption redesign).**

The current system analyzes each image independently, extracts features, then compares feature sets pairwise. Improving the features improves what the comparison can detect.

*Caption redesign (Backlog #50):* Change the qwen prompt to elicit relational position rather than scene description. Current implicit question: *What do you see?* Needed question: *What is this person's relationship to their situation — what are they doing to or for the world, and what is the world doing to them?* The risk is that language models describe things rather than positions regardless of prompt framing. Prompt engineering can shift this; it probably can't eliminate it.

*Role clusters:* Add clusters that describe the subject's relational position rather than their topic or state:
- `emitting` — generating something outward into the world (sound, energy, care, gaze)
- `receiving_straining` — reaching toward something from outside, absorbing or straining for it
- `witnessing` — observing without participating, seeing what others don't
- `sealed_off` — turned inward, isolated from environment despite being in it
- `offered_up` — exposed, vulnerable, available to be seen

These form axis pairs: `emitting ↔ receiving_straining`, `witnessing ↔ sealed_off`. When the musician fires `emitting` and the ears-woman fires `receiving_straining` without firing each other's cluster, the axis bonus fires at ambient floor.

*Where Path A succeeds:* Clean vocabulary separation — the emitting image doesn't contain receiving vocabulary and vice versa. Unambiguous role from scene description. Arcs that are human, relational, and action-based.

*Where Path A fails:* Topic clusters create shared overlap that puts Dice above ambient floor, disabling the axis bonus. Role vocabulary bleeds across images (both captions mention "sound" and "ear"). Arcs that are symbolic or representational (the stripe pair — no role relationship between a shirt and a flag). Mode 3 pairs (ambient existential) entirely out of reach. Most Mode 2 pairs out of reach.

Path A is worth implementing because it's cheap and directionally right for a specific class of pairs. It is not a complete solution and should not be expected to be.

**Path B — Selective pair-level VLM scoring.**

The fundamental architectural difference:

```
Path A:  features(A) + features(B) → compare(features(A), features(B))
Path B:  caption(A) + caption(B) → describe_each → extract_direction → score_complementarity
```

Path B is not asking the model to *reason about the relationship* — that produced generic comparative language in testing ("contrasting yet interconnected," "public creation vs. private introspection"). It is asking the model to *describe what each subject is doing*, then a rule-based parser extracts role direction from those descriptions.

This distinction matters: the intelligence is in the parser, not the prompt. The model's job is to produce short concrete action descriptions. The scoring system's job is to classify direction (outward vs. inward) and detect shared domain.

*What the prompt produces:*
```json
{"a": "playing violin alone on a residential street",
 "b": "pressing palms over ears on concrete steps",
 "arc": "sound and the urban body"}
```

*What the parser does with it:*
- `a` contains "playing" → outward direction
- `b` contains "pressing over ears" → inward direction  
- `arc` contains "sound" → shared domain confirmed
- Opposite directions + shared domain → complementary pair signal fires

The descriptions don't need to use role vocabulary. "Playing violin" is sufficient — the parser knows playing is outward. "Pressing over ears" is sufficient — pressing-over is inward. The model produces what it naturally produces (concrete description); the parser extracts the signal.

*The `arc` field and Mode 3:* The arc field is useful but its role is domain detection at this stage, not interpretation. "Sound and the urban body" is good. "Urban solitude" is too generic to be useful. "Human experience" is useless. When the arc field collapses to generic language it should be treated as null. A separate backlog item covers refining arc output for Mode 3 scoring — see below.

*Timing:* Warm inference ~2–3.3s per pair (caption-only, no images). 500 candidates → ~25 minutes single-threaded, ~7 minutes with 4 concurrent Ollama workers. Viable as a background Phase 3 process. Results stream into the pair grid progressively as calls complete, same `AsyncStream` pattern as Phase 2.

*Candidate selection for Phase 3:* Pairs in the CLIP 0.20–0.45 range with moderate thematic (0.15–0.35) — the cross-context candidates that almost but don't quite make topK. Axis-pair candidates that scored at ambient floor. Estimated 300–600 candidates per 1K-image library.

*What Path B cannot do:* Score Mode 2 slant rhymes. The color echo between red vinyl and red wattles is not in either caption. Caption-only pair-level inference is blind to visual properties. Mode 2 requires image-feature work on the aesthetic and geometric axes.

**Backlog — Refine `arc` field for Mode 3 scoring.** The `arc` field in Path B JSON output currently functions as domain detection (sound, light, movement). Its potential is larger: a well-formed arc field could name the shared existential dimension of a Mode 3 pair ("the weight of ordinary time," "the fragility of brief visibility") — the ambient register that Soth and Graham work in. This would require few-shot prompt examples showing what a useful arc description looks like vs. a generic one, and a calibration pass against known Mode 3 candidates. Defer until Path B is validated for Mode 1 complementarity first.

---

## Summary: What Good Thematic Scoring Requires

| Criterion | Current System | Path A (Role clusters) | Path B (Pair-level VLM) |
|-----------|----------------|----------------------|------------------------|
| **What it detects** | Shared scene vocab | Relational position per image | Relationship between images |
| **Mode 1 arc pairs** | Partially, when vocab overlaps | Better, when vocab separates cleanly | Yes, when captions are adequate |
| **Mode 2 slant rhymes** | No | No | No (caption-blind to visual echo) |
| **Mode 3 ambient register** | No | No | Possibly, weakly |
| **Cost** | Zero (keyword match) | Zero (keyword match, new prompting) | 10–20 min per 500 candidates |
| **Brittleness** | High | High | Lower |

---

## Expanding Thematic Beyond Human Experience

The current cluster vocabulary is heavily weighted toward human social and emotional situations. This reflects the library — street and documentary photography is largely about people. But the thematic axis need not be limited to human experience.

Consider: a field of used car tires stretching to the horizon, paired with a natural spring. No people, no social situation. But a genuine third meaning: waste and renewal, the industrial scar and the world's indifference to it, entropy and regeneration. Ecological opposites occupying opposite ends of the same arc of consequence.

Or: a brutalist concrete parking structure paired with a grove of old-growth trees. Material entropy vs. biological time. The structures of human permanence vs. the structures that predate them.

These are arc-position pairs in exactly the same sense as the human pairs — just where the "positions" are held by things and ecologies rather than people. The cluster system could, in principle, capture this with the right vocabulary. The caption system could surface it if the prompts ask about what the subject *represents* or *participates in*, not just what it *is*.

**This is a significant expansion of the thematic project.** The current 29 clusters are all human-situation-oriented. Extending to ecological, material, temporal, and architectural arc-pairs would require both new cluster vocabulary and new caption prompting. Scope this carefully — the human-situation clusters are already the hardest problem. But don't close the door.

**Backlog item: Thematic scope expansion beyond human-situation pairs.** Define a small set of non-human-situation pair types (ecological, material, architectural, temporal) and evaluate whether the caption + cluster architecture can be extended to capture them without degrading the existing human-situation scoring.

---

## Mode 2 in Depth: The Slant Rhyme

### The Webbs' Own Articulation

Alex Webb named the mode precisely. A slant rhyme in poetry is a near-rhyme — "eyes" and "light," "blue" and "moon." Similar but not identical sounds. The visual equivalent is two images that share a formal or tonal property — but at a slant, not a perfect match.

From *Slant Rhymes* (the book): *"Sometimes we find our photographic slant rhymes share a similar palette or tone or geometry. Other times, our paired photographs strike a similar note — often a penchant for surreal or surprising or enigmatic moments — although often in two different keys."*

Rebecca Norris Webb describes her own practice: *"How I work is akin to a kind of listening — seeing as a way of listening deeply to the rhythm and the stillness."* Her photographs rarely contain people; animals, objects, and landscapes carry the emotional weight. The inanimate speaks human meanings.

The LensCulture review of *Slant Rhymes* describes two specific pairs that are worth holding closely, because they're concrete:

**Pair A:** The red vinyl of a car seat (Alex, urban) alongside the red comb and wattles of a chicken (Rebecca, rural/agricultural). No shared subject. No shared location. No narrative connection. What they share: a specific shade of red in a specific quality of light. The third meaning: color as the world's secret vocabulary, the same note played in two registers simultaneously.

**Pair B:** The wings of a bird on a fresco (Alex) alongside the splayed hands of a little girl holding onto cathedral grating (Rebecca). No shared subject. What they share: a specific splayed, reaching, five-point geometric form — feathers and fingers rhyming across media, scale, and species. The third meaning: the gesture of reaching/opening/spreading, found in both the sacred and the animal.

These are not semantic pairs. They don't share a human experience arc. They don't create a narrative. They create a *perception* — the sudden recognition that two things share a hidden formal truth. The viewer doesn't think "these are about the same thing." They feel "these are the same shape / the same color / the same quality of light," and that recognition is itself the experience.

---

### The Four Mechanisms of Mode 2

From the Webbs' work and their own descriptions, Mode 2 pairs connect through one or more of these mechanisms:

**1. Color echo.** Not overall palette similarity (that's what the current HSL scorer measures) — but a specific, dominant color note present in both images, possibly surrounded by entirely different contexts. Red wattles + red vinyl. Saturated blue shadow + saturated blue sky. A color that appears in the world twice, in two unrelated places, as if the world placed it there deliberately.

The key distinction from palette harmony: a Mode 1 aesthetic pair might be two images with harmonious overall palettes (both warm, both desaturated). A Mode 2 color echo is one where a *specific* color — often quite small in frame — is the resonating element, while everything else is different. The specificity and the contrast between the echo and its surrounding difference is what creates the recognition.

**2. Geometric/formal echo.** A specific shape, form, or spatial structure that appears in both images in different subjects. Bird wings and child's hands. The arc of a bridge and the arc of a spine. A dense cluster of vertical forms (crowd of people / forest of poles) rhyming structurally. This is different from the current geometric scorer, which measures overall compositional similarity. A Mode 2 geometric echo might live in a small region of each frame — two images that are compositionally quite different except for this one formal element they share.

**3. Light quality echo.** Not tonal range (light/dark ratio) — the *character* of the illumination itself. Late oblique sun with long shadows and warm color cast. Hard noon light with no shadow graduation. Flat grey diffuse overcast. Candlelight or tungsten. Two images lit with the same quality of light feel like they inhabit the same world even when they contain entirely different things. Alex Webb's signature — the sharp tropical light of the Caribbean, high-contrast with deep saturated shadows — means his images resonate with each other across subjects because they share that light.

**4. Gestural/energetic echo.** The specific energy or quality of movement in a scene — stillness vs. blur, centripetal vs. centrifugal composition, weight pressing down vs. lightness rising — shared across two images with different subjects. Not what's moving, but *how* it's moving. Two images with a similar sense of compressed, held tension. Two images where figures lean in the same direction, as if pulled by the same invisible force.

---

### The Slant: What Makes It Not Just Similarity

The crucial distinction between a Mode 2 pair and a same-subject pair is the *distance* between the two images on every axis *except* the one they rhyme on.

Red vinyl + red wattles: completely different subjects, scales, contexts, locations. The only thing they share is that specific red. That singularity of the echo — the fact that *everything else* is different — is what produces the recognition. If the images also shared location, subject type, and composition, the red would become incidental, buried in all the other similarities.

This is the slant. The pair resonates at one frequency while diverging on all others. The divergence is not noise; it's necessary signal. It's what makes the echo audible.

**Implication for scoring:** A Mode 2 pair should have *low* overall CLIP similarity (different subjects, contexts) but high similarity on one specific sub-dimension — a localized color feature, a specific geometric form, a light-quality signature. Current CLIP cosine collapses everything into one number, losing the sub-dimensional specificity. This is one reason CLIP-based approaches can't easily find Mode 2 pairs.

---

### What the Current Architecture Can and Cannot Do

| Mode 2 Mechanism | Current Scorer | Gap |
|------------------|----------------|-----|
| **Color echo** | HSL histogram intersection measures overall palette similarity | Cannot detect a single-color echo in dissimilar-palette images |
| **Geometric echo** | Edge orientation + composition grid similarity measures overall structure | Cannot detect localized geometric rhymes (small wing-shaped region in two very different images) |
| **Light quality echo** | Not measured | Entirely absent |
| **Gestural/energetic echo** | Not measured | Entirely absent |
| **Low overall similarity, high sub-dimensional echo** | CLIP collapses to one score | Structure needed to reward this specific combination |

---

### A Possible Scoring Architecture for Mode 2

**Light quality as a computable property.** Light quality can be approximated from pixel statistics without deep learning: ratio of highlight to shadow pixels (hard vs. soft light), distribution of shadow depth (how dark do shadows go?), color temperature of highlights vs. shadows, spatial frequency of illumination variation (flat diffuse vs. directional). These are coarse proxies but directionally right. Two images matching on three of these would have similar light quality even with different subjects.

**Localized color echo.** Instead of — or in addition to — full-image HSL histogram, extract the dominant *accent* color: the most saturated non-neutral color cluster present in significant but not dominant proportion (5–20% of pixels). If two images share the same accent color while having different overall palettes, that's a Mode 2 color echo. This is more tractable than it sounds: it's a one-dimensional feature per image (hue + saturation of dominant accent) that can be compared with a simple distance metric.

**The CLIP mid-range zone.** Webb's own description implies that Mode 2 pairs are visually distinct enough to not be same-subject (CLIP > 0.30) but share enough visual world to resonate (CLIP < ~0.50). The current visual diversity multiplier already operates in this space but uses it as a penalty zone (neutral, ×1.0). A dedicated Mode 2 bonus — awarded when CLIP is in the 0.25–0.45 range AND the aesthetic score is above a threshold — might be a minimal implementation that surfaces some slant rhymes without requiring a full sub-dimensional CLIP analysis.

**The honest assessment:** True Mode 2 detection — the thing the Webbs do instinctively — probably requires either (a) training a specialized model on labeled Mode 2 pairs, or (b) a VLM that can answer "does this image share a specific formal quality with that image?" for many candidate quality dimensions. Both are out of scope for a local on-device app today. The tractable version is: improve the aesthetic and geometric axes to capture the *sub-dimensional* properties (accent color, light quality, localized geometric form) rather than only full-image statistics. This won't fully solve Mode 2 but it will surface some slant rhymes that the current system completely misses.

---

### Refining the Color Echo: Hierarchy, Not Dominance

A critical correction to the initial color echo formulation. The echo doesn't have to be in the *dominant* color of either image — it has to be prominent in the *color hierarchy* of each image, and it has to be playing a structural role in both.

The red car vinyl + red chicken wattles pair works not because red dominates either image, but because red is the primary accent color in each — the most saturated, attention-claiming color element in both frames. Each image has other colors doing other work; the red is specific, vivid, and commanding in both without being the only thing in either.

This works with pale or desaturated colors too. Two frames that share a light, desaturated blue — one with a building painted blue and white, another with a group of people in the same approximate blue — can complement each other and create harmony even if the compositions are very different and the human register is nuanced (gestural, humanist) or structural. The shared color doesn't have to be saturated to play a structural role; it has to be *intentional* and prominent in the hierarchy of each image.

Conversely, two images each with blue sky do not make a color echo pair even if blue is the largest color area in both. Sky-blue is ambient — environmental, incidental, present in most outdoor photographs. It doesn't play a structural role; it's just the world behind the subject.

**The rule: a color echo requires the shared color to be the primary accent** — the most chromatic, intentional, or compositionally weighted color element in each image's hierarchy — **surrounded by meaningfully different supporting colors in each image.** Ideally the supporting colors are relatively simple: shared neutrals are fine, but different or absent secondary and tertiary colors. The supporting difference is what makes the echo resonate. If everything surrounding the accent is also similar, the pair collapses into overall palette harmony rather than a color echo.

Applied to your two candidate pairs:

---

### Your Candidate Pairs Analyzed

**Pair 1: `_R017085` + `R0024458` — dominant red, dark humor**

Two urban environments sharing little except: a dominant red playing a structural role in each, and a shared emotional register that the color both signals and amplifies — grim, somber.

This is a strong Mode 2 candidate. The red isn't incidental in either image. The dark/sardonic register is real thematic content, but it's not legible from captions — qwen would describe what's in the frame, not the gallows quality. So the pair would fail Mode 1 scoring entirely.

What the current system can/can't do with this pair:
- The red would not be detected by HSL histogram intersection (overall palette similarity) if the surrounding colors differ — the intersection score would be dragged down by the dissimilar context colors
- The emotional register ("grim," "gallows humor") might partially surface via cluster vocabulary — `humor_absurdity` (if the captions capture the sardonic quality), `tension_conflict` — but gallows humor is notoriously hard to caption
- CLIP cosine: likely low (< 0.35) given different environments, which means the visual diversity multiplier would give the thematic score a ×1.35 boost — but only if thematic clusters fire, which is uncertain

**The architectural gap this exposes:** The color echo is the *primary* connection here. The thematic register (dark humor) is secondary and reinforces it, but the pair would feel right even without being able to name why. The current system has no path to this pair.

---

**Pair 2: `R0011458` + `_DSF3227` — stripes as America**

An older woman's striped shirt echoing the stripes of an American flag. Different subjects, different contexts, different times. What they share: a specific visual structure (parallel horizontal stripes) and through that structure, a quietly pointed third meaning about America — something about the way the nation's symbol becomes indistinguishable from the fabric of ordinary people's clothing. Or the reverse: that ordinary people already carry the flag on their bodies without knowing it.

This is a genuinely interesting Mode 2/Mode 1 hybrid. The connection is both formal (geometric echo: the stripes) and semantic (the third meaning about America is articulable once you see it). The formal echo is what catches the eye; the semantic meaning is what rewards the look.

What the current system can/can't do:
- The geometric echo (stripes as repeating horizontal structure) would potentially score well on the current edge orientation + grid similarity scorer — both images have strong horizontal banding energy. This might be one of the rare cases where the current geometric scorer accidentally captures a Mode 2 connection
- The thematic content (America, flag, civic identity, ordinary lives) would not be captured by any current cluster vocabulary — there are no civic-identity or political-symbol clusters
- CLIP cosine: uncertain. The stripes create a visual similarity, possibly pushing CLIP above 0.35–0.45, which could put the pair in the neutral zone of the diversity multiplier

**The architectural gap this exposes:** The semantic content here (the America reading) requires the system to understand what a flag *represents* — not just what it looks like. This is squarely in the domain of the caption redesign (backlog #50): a prompt that asks "what does this image participate in or represent beyond what it depicts?" would potentially get a response about civic symbols, national identity, or the ordinary made political.

---

### Paul Graham and Alec Soth: What Other Formal Traditions Teach

#### Graham's Shimmer: The Cutaway Pair Is in Scope

A correction to the earlier framing. The cutaway image — the butterfly, the melting cherries, the unfocused glance at something beside the main action — was described as out of scope for Couplet because it falls through the floor of the thematic system. That was wrong.

The cutaway pair is absolutely within scope. It just requires the **aesthetic and geometric axes to be doing real work**, rather than relying on thematic cluster vocabulary. A charged portrait of a person in a fraught situation, paired with a quiet image of late light on a wall — that pair may have no cluster overlap, no semantic arc, and low CLIP similarity. But if the aesthetic axis can recognize *tonal weight* (the charged image is dense, complex, saturated; the quiet image is spare, open, still), and the geometric axis can recognize *compositional breathing room* (the charged image is layered and dense; the quiet image is open and has weight at the edge rather than the center), the pair can score.

Graham himself says the cutaway is borrowed from the haiku form: *"In a haiku there's a moment where it breaks away and touches upon the weather or the season, like 'blossoms,' just a word or two, hinting at something beyond the instant concern."* The cutaway's formal qualities — sparseness, ambient subject matter, low narrative density — are what make it do its work next to a charged image. Those are computable properties.

**The Present** is a different matter and remains correctly excluded. Graham's diptychs from *The Present* are taken seconds apart from the same location. The pairing is about the texture of time within a single moment; the sequential penalty (≤30s: ×0.40) correctly kills these in Couplet. The goal of *The Present* is the opposite of Couplet's goal. Couplet penalizes temporal proximity because it values conceptual distance. Right for both projects.

**American Night** introduces a third formal mode worth naming: **tonal dichotomy as political argument**. Graham juxtaposes severely overexposed images (the poor, the marginalized, nearly erased from visibility) against richly saturated full-color images (prosperity, new construction, consumption). The pair is a political argument made entirely through exposure contrast — the technique *is* the content. This is detectible in principle (exposure histogram contrast is computable), but it's a very specific formal language. Worth noting as a boundary case, not a current target.

---

#### Alec Soth: Tonal Weight and Genre Alternation

Soth's *Sleeping by the Mississippi* sequences portraits, landscapes, interiors, and objects together across 46 images. The sequencing principle, as he describes it, evolved from an earlier project called *From Here to There*: "one picture led to another, linked by an idea or a theme." But the linking is not semantic in the cluster-vocabulary sense. It's atmospheric: a mood of loneliness, longing, and reverie that persists across entirely different subjects and genres.

What makes a Soth pair work:

**1. Genre alternation as breathing.** Portrait → landscape → interior → object → portrait. Each genre shift acts like a breath — the landscape releases the pressure of the portrait; the object image allows the viewer to sit quietly before the next human encounter. In Couplet terms: a high-human-density image (close portrait, gestural street scene) paired with a low-human-density image (landscape, architectural detail, still life) creates this breathing structure. The pair doesn't need to share content; it needs to be *complementary in density and human presence*.

**2. Tonal weight matching across genre.** Soth's images all share what critics describe as a "dreamlike and drained atmosphere" — a quality that persists whether he's photographing a graveyard, a muscle-bound construction worker, or a houseboat. The mood is consistent even when the subject is wildly different. In Couplet terms: *emotional register* as a computable property of the image, independent of what the image depicts. Two images with the same tonal weight — not the same tonal value, but the same degree of heaviness, stillness, or charge — pair well even when they share no subject.

**3. The "beautiful in the banal" principle.** *Two Towels* — Soth's photograph of two folded towels on a motel bedspread — is described as "filled with the beauty of love" despite depicting nothing explicitly emotional. This is the Soth version of Graham's cutaway: the image that has no obvious narrative content but carries, through its composition, light, and the deliberate act of looking, a sense of something deeply felt. These images pair powerfully with charged human images because they provide a space of quiet attention. You can't detect this from captions. It's in the image's formal qualities: simplicity of subject, specificity of observation, quality of light on an ordinary surface.

---

#### What Other Formal Traditions Contribute

**Robert Frank — *The Americans*:** Frank sequences images to build a cumulative political and emotional argument about America — the flag recurring across the book in different contexts (over a jukebox, over a political rally, draped over a car dealer), creating a rhyme that accumulates meaning with each repetition. This is neither Mode 1 nor Mode 2 but a **serial echo**: the same subject recurring in different contexts, where the accumulation is the meaning. For Couplet, a two-image version of this — flag in a formal context + flag on an ordinary person's shirt — is already described in your stripe pair. The formal echo is the vehicle for the political observation.

**Duane Michals — Sequences:** Michals works in extended sequences (5–10 images) that function like short films or fables. His approach is the inverse of Couplet's interest: he *stages* narratives rather than finding them. But his core insight is relevant: "the literal appearance of things is less important than the communication of a concept." He was the first photographer to insist that meaning in sequential photography lives *between* images — in the gap the viewer's imagination fills — rather than in any single frame. This is Eisenstein's third meaning, arrived at from a different direction.

---

#### Synthesizing Into Aesthetic and Geometric: What Needs to Change

Bringing together the Webbs, Graham, and Soth, three new formal qualities emerge that the current scoring system doesn't capture but should:

**Tonal weight (Aesthetic axis).** Not tonal range (light/dark ratio) — the *density of visual charge* an image carries. A dense, layered, complex image (Webb's Caribbean streets) has high tonal weight. A spare, open, quiet image (Soth's two towels, Graham's butterfly) has low tonal weight. Two images with complementary tonal weights — one dense, one sparse — can form a strong pair across genre, subject, and geography. This is what makes the cutaway pair work; it's what Soth does with portrait/landscape alternation; it's what Graham does with the haiku cutaway.

*Possible computation:* A proxy for tonal weight is available from existing image statistics: edge density (many edges = high complexity = high tonal weight), number of distinct regions in the composition grid, histogram spread, and presence/absence of large uniform areas. These are all either already computed (edges, grid) or cheap to add.

**Compositional density and openness (Geometric axis).** Related to tonal weight but distinct: the geometric property of how filled the frame is. A Webb image has multiple overlapping planes, figures at different scales, foreground/background tension. A Soth landscape has one thing in the frame, with open sky or flat water taking up most of the space. These are opposites that pair well for the same reason portrait/landscape alternates well in a book: the viewer needs breathing room. The current geometric scorer measures compositional *similarity* — it would penalize a dense/sparse pair because the structures don't match. It should be able to recognize the dense/sparse complement as a valid pairing mode.

*Possible computation:* Compositional density can be approximated from grid variance (already stored per pair as `gridVariance`) and the ratio of edge pixels to total pixels. A high-density/low-density pair scores high on this complementarity metric even if it scores low on overall compositional similarity.

**Accent color as structural echo (Aesthetic axis).** Already articulated in the color echo section — the specific, dominant-but-not-exclusive color playing a structural role in each image's color hierarchy. Elaborating on what "structural role" means computationally: the accent color is the hue cluster with the highest saturation value that accounts for at least 5% but no more than 40% of the image's pixels. It's prominent but not overwhelming. Two images sharing this accent hue within a defined angular distance on the color wheel (±20°) constitute a color echo. The surrounding colors should be dissimilar (measured by the remaining HSL histogram intersection excluding the accent band) for the echo to be meaningful rather than just palette harmony.

---

#### The Gap Table Updated

| Formal Quality | Current Scorer | What's Needed |
|---------------|----------------|---------------|
| Tonal weight (density of visual charge) | Not measured | Edge density + grid complexity as a complementarity metric |
| Compositional density/openness | Similarity only (penalizes dense+sparse) | Complementarity version: reward high/low density pairs |
| Accent color echo | Full HSL histogram (masks accent) | Extract dominant accent hue per image; match on accent ± dissimilar context |
| Light quality | Not measured | Highlight/shadow ratio, color temperature of shadows |
| Gestural/energetic echo | Not measured | Motion blur metrics, directional energy of edges |
| Serial/recurrent echo (Frank) | Not measured | Requires library-wide subject recurrence detection — out of scope today |

---

### What to Look for in Your Library

When you search your library for a Mode 2 candidate pair, you're looking for two images that you'd place together in a book for a reason you can't fully articulate — where the connection is felt rather than argued. Specifically:

- Images shot in **different places, different times, different subjects** — but that feel like they inhabit the same world
- Where there's a **specific echo**: same color, same shape, same quality of stillness or motion, where that echo plays a *structural role* in each image rather than being ambient
- Where you'd feel slightly embarrassed trying to *explain* the connection, because the explanation would diminish it
- Where each image feels **more complete** for having the other nearby, even though you can't say why

That experience of "slightly embarrassed explanation" is the diagnostic. It means the connection is operating below the level of semantic content — which is exactly where Mode 2 lives.

---

---

## The Aesthetic Axis: What It Should Do

### What "Aesthetic" Means in a Pair

Aesthetic compatibility is not about two images looking the same. It is about two images being able to *coexist* — to inhabit the same visual world without one overwhelming or canceling the other. In a book, two facing images need to be in some kind of conversation, even when that conversation is one of productive tension.

There are three distinct modes of aesthetic relationship in good pairs:

**Harmony:** Both images share a quality of light, a tonal atmosphere, an emotional register that makes them feel like they were made by the same sensibility in related conditions. Soth's *Sleeping by the Mississippi* achieves this across wildly different subjects — a graveyard, a construction worker, a houseboat — because all his images share the same dreamlike, drained atmosphere. The aesthetic axis should reward this.

**Complementarity:** One image is dense, charged, layered; the other is spare, quiet, open. The pair works because the viewer needs the breathing room the quiet image provides. Graham's haiku cutaway. Soth's portrait-to-landscape shift. The two images are aesthetically *different* in a productive way. The aesthetic axis should reward this too, even though it looks like mismatch on a similarity scorer.

**Echo:** One specific formal property — a color, a quality of light, a tonal character — rhymes across two images that otherwise diverge aesthetically. The Webbs' red vinyl + red wattles. Your two urban red images. The echo is narrow; everything surrounding it is dissimilar. The aesthetic axis should detect and reward this specifically.

The current scorer (HSL histogram intersection + LAB palette contrast) is tuned only toward harmony. It measures how similar two images are in overall color distribution. It misses complementarity (penalizes the dense/sparse pair), misses the accent echo (the specific red is swamped by the overall palette difference), and doesn't capture the qualities of light and atmosphere that make Soth's images feel unified despite different subjects.

---

### What the Aesthetic Axis Currently Measures and the Gaps

**HSL histogram intersection** measures how much the two images' full color distributions overlap. This is a reasonable proxy for overall palette harmony. It works when the pairing mode is harmony. It fails for:

- Complementarity pairs: a warm, densely colored street scene and a cool, spare landscape have low HSL intersection even if they'd pair beautifully
- Echo pairs: two images sharing a specific saturated red but otherwise having dissimilar palettes have low intersection even though the echo is real
- Monochrome + color pairs: any B&W image intersects poorly with any color image regardless of tonal relationship

**LAB palette contrast** measures something like color richness differential — how different the two images are in colorfulness. This is useful for detecting the dense/spare contrast at a gross level but it's a single number that can't distinguish "usefully complementary" from "just different."

What's entirely absent:

**Light quality.** The character of illumination — hard directional vs. soft diffuse, warm tungsten vs. cool overcast, harsh noon vs. oblique late afternoon — is one of the strongest determinants of whether two images feel like they could inhabit the same world. Two images lit with the same quality of light resonate across subjects because they share the same atmospheric conditions. This is a core part of how Webb's images cohere, how Soth's images cohere, and how the Webbs' pairs across photographers work in *Slant Rhymes*. It is currently completely unmeasured.

**Tonal weight.** The density of visual charge an image carries — how much is competing for attention, how layered and complex the content is. This is distinct from tonal range (bright/dark distribution) and distinct from color saturation. A Webb street scene with five overlapping planes of action is high tonal weight. A Soth two-towels image is low tonal weight. A dense/sparse complement is a valid and productive pairing mode. Not currently rewarded.

**Emotional register.** The affective quality of an image that persists independently of its subject — melancholy, tension, joy, stillness. Soth's whole body of work demonstrates that this quality can be consistent across landscape, portrait, interior, and object. Two images sharing an emotional register pair well even when they share no subject. Currently not measured at all; would require either caption-derived inference or a learned perceptual model.

---

### A Redesigned Aesthetic Axis

Three components, each targeting a different valid pairing mode:

**Component 1: Palette harmony (keep, refine).** The current HSL histogram intersection, but separated by B&W and color images. B&W + B&W pairs should be evaluated on tonal distribution only, not hue. B&W + color pairs should receive a baseline score rather than near-zero. Currently a B&W + color pair is heavily penalized; but many strong pairs cross this divide deliberately. The `colorProfile` column already tracks this per image.

*Weight within aesthetic:* 0.35 → carries the harmony mode.

**Component 2: Accent color echo (new).** Extract the primary accent color per image: the hue cluster with the highest mean saturation, present in 5–40% of pixels. Compare accent hues across the pair: match within ±20° on the color wheel scores high; match within ±40° scores partial; beyond that, zero. Then compute how *dissimilar* the non-accent palettes are (the remainder of the HSL histogram excluding the accent band) — the more dissimilar the surrounding context, the stronger the echo signal. The final score rewards: same accent hue × different surrounding palette. Two images both dominated by red but with similar overall palettes are just harmonious, not an echo; the contextual dissimilarity is what makes the echo.

*Weight within aesthetic:* 0.35 → carries the echo mode.

**Component 3: Tonal weight complementarity (new).** Compute a tonal weight score per image from existing signals: normalized edge density (`maxEdgePeakedness`), normalized grid variance (`maxGridVariance`), and a large-uniform-area ratio (percentage of the image in regions below an edge threshold — approximates open sky, flat walls, empty space). High tonal weight = many edges, high grid variance, low uniform area. Low tonal weight = few edges, low grid variance, high uniform area.

The complementarity score for a pair: highest when one image is high tonal weight and the other is low, near zero when both are high or both are low. Mathematically: `1 - |weightA - weightB|` rewards matched weight; `|weightA - weightB|` rewards complementary weight. The aesthetic scorer should use the *complementarity* version.

Note that tonal weight should *not* replace the geometric distinctiveness multiplier — that multiplier penalizes geometrically boring pairs regardless of tonal weight. These are orthogonal properties.

*Weight within aesthetic:* 0.30 → carries the complementarity mode.

**Light quality: deferred.** Light quality (hard/soft, warm/cool, directional/flat) is the most important missing property and the hardest to compute reliably without a learned model. A coarse proxy exists — ratio of highlight to shadow pixels approximates hard vs. soft light; dominant shadow color temperature approximates warm vs. cool — but the signal is noisy. Defer to a subsequent iteration once the three components above are validated. Placeholder weight: when implemented, redistribute from palette harmony (0.35 → 0.25) and light quality gets 0.10.

---

### What the Redesigned Aesthetic Axis Would Do to Test Pairs

**Red urban pair (`_R017085` + `R0024458`):**
- Accent echo: both have dominant red as primary accent; surrounding urban palette likely dissimilar → high echo score
- Tonal weight: both urban scenes, probably both moderate-high weight → low complementarity; balanced
- Palette harmony: depends on overall color character; may be moderate
- Expected outcome: strong score driven by accent echo component. Currently: likely low due to overall palette dissimilarity.

**Stripe pair (`R0011458` + `_DSF3227`):**
- Accent echo: flag has red+white+blue accent structure; shirt has one stripe color. Partial match possible depending on stripe color.
- Tonal weight: depends on how busy each frame is; potentially complementary if one is a close-up and the other is wider
- Expected: moderate improvement from accent and tonal weight. The geometric axis is doing more work here.

**Musician + ears (Mode 1 test pair):**
- Accent echo: unlikely to share accent colors; probably no score here
- Tonal weight: street scene (moderate) + sitting figure (lower); mild complementarity
- Expected: modest improvement; aesthetic is not the primary axis for this pair. Thematic and caption redesign are still the fix.

**Cutaway pair (hypothetical: dense street scene + quiet landscape):**
- Accent echo: unlikely unless there's a specific color rhyme
- Tonal weight: high + low → maximum complementarity score
- Expected: strong improvement on tonal weight component alone. The cutaway pair is finally scoreable.

---

## The Geometric Axis: What It Should Do

### What "Geometric" Means in a Pair

Geometry in a pair is about the spatial and structural *conversation* between two images when they sit side by side. There are three valid geometric relationships:

**Rhyme:** Both images share the same structural logic — a strong diagonal, a centered subject, a dense cluster of vertical forms — applied to different subjects. This is what the current scorer detects. It's valid but insufficient on its own. The stripe pair is partly a geometric rhyme (horizontal banding in both). It only pays off if the rhyme is formal enough to produce recognition.

**Complement:** One image pulls left, the other right. One image has weight at the bottom, the other at the top. One image is centrifugal (energy radiating outward from center), the other is centripetal (energy converging on center). These pairs create visual tension — the eye moves between them, pulled in both directions simultaneously. The current scorer penalizes this as dissimilarity.

**Breath:** One image is compositionally dense (layered, complex, multiple competing elements), the other is compositionally open (one thing, wide sky, flat surface). The breath pair allows the viewer to recover from the dense image and approach the next one with fresh attention. The current distinctive multiplier actively suppresses the open image (low variance = low multiplier), killing these pairs specifically.

---

### What the Geometric Axis Currently Measures and the Gaps

**Edge orientation cosine similarity** measures whether two images have edges pointing in the same directions. Strong horizontal and vertical structure in both → high score. This detects architectural similarity, figure-scale similarity, and genre-level similarity (street photos tend to share edge orientation because they share framing conventions). It can accidentally detect formal rhymes (the stripe pair). It is the right tool for the rhyme mode but too coarse for complement or breath.

**Composition grid cosine similarity** measures whether the spatial distribution of visual weight across the frame is similar. Both images having weight at center → high score. One image with weight at left, one with weight at right → low score (complement mode wrongly penalized).

**Distinctiveness multiplier** (`edgePeakednessMult × gridVarianceMult`) requires both images to be geometrically interesting — peaky edge histograms and high grid variance — to receive full geometric credit. This is the right idea for preventing generic visual similarity from scoring well. But it has a side effect: compositionally open images (low grid variance, diffuse edges — landscapes, quiet interiors, Soth's towels) receive a very low multiplier regardless of how intentional or beautiful their openness is. The multiplier treats "not complex" as "not interesting," which is wrong for the breath mode.

**What's missing:**

**Directional weight and pull.** Where in the frame does the visual weight sit? A figure at the left edge of frame A, looking right, creates a "pull" rightward. A figure at the right edge of frame B, looking left, creates a "pull" leftward. Side by side, these two images face each other and create a visual conversation even if they have nothing else in common. The current grid cosine similarity would score this pair low because the weight is on opposite sides. It should score this pair *high* on the complement axis.

**Compositional openness as a positive signal.** Open, sparse images — dominated by sky, water, empty architecture — have a geometric character that is *intentional*, not merely low-information. A photographer who composes a vast empty sky with one small figure has made a deliberate geometric choice. The distinctiveness multiplier can't tell the difference between a badly composed flat image and a beautifully composed open one. Both get punished equally.

**Localized geometric echo.** The wing/hands pair from *Slant Rhymes* — a splayed five-point form in each image, in entirely different subjects. The current scorer compares full-image edge orientation and grid structure; it cannot detect that a small region of both images shares the same geometric form. True localized geometric echo detection would require something like region-level feature matching, which is architecturally complex. Noted as a long-term target.

---

### A Redesigned Geometric Axis

Three components:

**Component 1: Structural similarity (keep, but bound).** The current edge orientation + grid cosine similarity, with the existing distinctiveness multiplier. This is the rhyme detector. It works. The issue is its weight in the composite — geometric at 0.20 can still dominate pairs where it shouldn't, because street photography tends toward genre-level structural similarity. The multiplier helps but the bound matters: this component should not carry the axis alone.

*Weight within geometric:* 0.40 → rhyme mode.

**Component 2: Directional complement (new).** Compute the center of visual mass for each image using the composition grid: where is the weight concentrated? Express this as a 2D vector (horizontal and vertical position of weighted centroid). Two images with weight on opposite sides of the horizontal axis (left-heavy + right-heavy) score high on horizontal complement. Two images with weight at opposite vertical positions score high on vertical complement. The complement score is: distance between the two weight centroids, normalized by frame size, capped at 1.0.

This directly rewards the visual conversation pairs — figures facing each other, compositions that complete each other spatially. Currently penalized; should be rewarded.

One important constraint: this should not reward *random* weight asymmetry. Two images with low grid variance (both uniformly distributed) should score near zero on both similarity and complement, not reward each other for being equally featureless. Gate with: at least one image must have meaningful visual weight concentration (grid variance above the `gridVarianceFloor` threshold) for the complement score to fire.

*Weight within geometric:* 0.35 → complement mode.

**Component 3: Tonal weight differential (shared with aesthetic, applied geometrically).** The geometric expression of the tonal weight concept: high edge density paired with low edge density. Computationally: `abs(normalizedEdgeDensityA - normalizedEdgeDensityB)`. Maximum when one image is busy and the other is open. Zero when both are equally dense or equally sparse.

This specifically rescues the breath pair — the cutaway image next to the charged image. The distinctiveness multiplier should be modified or given an exception path: when one image is intentionally sparse (uniform-area ratio above threshold) and the other is dense, the pair should not be fully suppressed by the multiplier.

*Weight within geometric:* 0.25 → breath mode.

---

### The Distinctiveness Multiplier: Patch Needed

The existing multiplier (`edgePeakednessMult = pow(normPeakA × normPeakB, 0.4)`) uses the *product* of both images' peakedness. This means one flat image drags the score to near-zero even if the other image is visually rich. That's the right behavior for suppressing two-flat-images pairs — generic street photos with no geometric interest. But it's wrong for the breath pair.

The patch: when the *difference* between the two images' peakedness values is large (above a threshold), apply a weaker version of the multiplier rather than the full product form. Concretely:

- Current: `mult = pow(normPeakA × normPeakB, 0.4)` — both must be interesting
- Proposed exception: `if abs(normPeakA - normPeakB) > 0.5 { mult = max(mult, pow(max(normPeakA, normPeakB), 0.4) × 0.6) }` — if one is very interesting and the other is very open, give partial credit based on the interesting one

This is a targeted fix that doesn't change behavior for pairs where both images are similar in complexity (the common case). It only fires when there's a strong asymmetry — which is precisely the signal that a breath pair is present.

---

### What the Redesigned Geometric Axis Would Do to Test Pairs

**Stripe pair (`R0011458` + `_DSF3227`):**
- Structural similarity: strong horizontal banding in both → high rhyme score
- Directional complement: depends on where the visual weight sits in each image
- Tonal weight differential: depends on how busy each frame is
- Expected: already likely scoring moderate on structure; directional complement adds if the images have spatial tension; overall improvement.

**Dense street scene + quiet landscape (cutaway pair):**
- Structural similarity: low — different structures entirely
- Directional complement: depends on spatial weight placement
- Tonal weight differential: high — dense + sparse → maximum breath score
- Distinctiveness multiplier exception: fires because of strong asymmetry → partial credit
- Expected: previously near-zero. After redesign: moderate-to-good score driven by tonal weight differential and multiplier exception.

**Two dogs:**
- Structural similarity: moderate (similar subject scale, similar framing)
- Directional complement: probably low (both centered subjects)
- Tonal weight differential: probably low (similar complexity)
- Expected: no benefit from geometric redesign. Still penalized by thematic (ambient floor) and visual diversity multiplier in composite. Fine.

**Musician + ears:**
- Structural similarity: probably low (different framing, subject scale)
- Directional complement: potential — if musician faces one way and the ears-woman faces another, they might create a spatial conversation
- Expected: mild geometric improvement. Not enough alone; thematic and caption redesign still required.

---

## Summary: What the Three Axes Should Do Together

| Axis | Mode 1 (Semantic arc) | Mode 2 (Slant rhyme) | Mode 2 (Cutaway/breath) |
|------|-----------------------|---------------------|------------------------|
| **Thematic** | Primary carrier | Supporting or absent | Absent |
| **Aesthetic** | Supporting harmony | Accent echo + light quality | Tonal weight complement |
| **Geometric** | Supporting harmony | Localized echo | Tonal density + directional complement |
| **CLIP visual diversity** | Boosts cross-context thematic | Validates subject dissimilarity | Validates genre dissimilarity |

The three axes are not redundant. Each pair type is carried primarily by a different axis, with the others playing supporting or neutral roles. A pair where only one axis fires strongly (deep thematic resonance with mismatched aesthetic/geometric, or a perfect accent color echo with no thematic content) can still be a great pair at the composite level — because the composite boost only requires thematic ≥ 0.20, and a strong sub-score on any axis contributes.

The failure mode to avoid: penalizing a valid pair on one axis because that axis is tuned only for similarity, when the pair's relationship on that axis is complementarity or echo. The redesigned aesthetic and geometric axes each have explicit paths for all three valid relationship modes.

---

### Prioritized Implementation Order

Based on tractability, impact on the most failing pair types, and use of signals already in the DB:

1. **Tonal weight differential** — geometric axis, breath pairs. Uses `maxEdgePeakedness` already stored per image. Requires a patch to the distinctiveness multiplier (one exception path in `PairScorer.swift`). Highest impact for lowest cost.

2. **Accent color echo** — aesthetic axis, echo pairs. Requires new per-image computation at index time (accent hue extraction, stored in `images` table). Changes `AestheticScorer.swift`. Medium cost, directly fixes the red urban pair class.

3. **Directional complement** — geometric axis, conversation pairs. Requires computing and storing the weight centroid per image. Changes `GeometricAnalyser.swift` and schema. Medium cost, fixes spatially facing pairs.

4. **Light quality** — aesthetic axis, the strongest missing signal. Requires new per-image computation. Hardest to get right; defer until 1–3 are validated against test pairs.

5. **Caption redesign** (backlog #50) — thematic axis, Mode 1 arc pairs. Separate track; can proceed in parallel with 1–3 since it doesn't touch the scoring code, only the captioning pipeline.

---

*Last updated: 2026-05-09. Full aesthetic and geometric axis analysis added. Implementation priority order established. See decisions log for scoring architecture history; see backlog #50 for caption prompt redesign.*
