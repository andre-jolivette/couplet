# Couplet

A macOS app that finds meaningful image pairs in your photo library — not duplicates or sequential shots, but conceptually resonant connections you might not have noticed.

> **Heads up:** This project was built entirely through [vibe coding](https://en.wikipedia.org/wiki/Vibe_coding) with Claude. The architecture is non-trivial but the codebase has not been audited, production-hardened, or reviewed by anyone other than an AI. Use at your own risk.

**Status:** Pre-release, under active development. Not yet available for download.

---

## What it does

Couplet indexes a photo library, scores every possible image pair across three axes, and surfaces the top pairs in a browsable grid. The goal is to find pairs where two images create a meaning that exists in neither image alone — where juxtaposing them reveals something.

Examples of pairs it's looking for:
- A violinist playing outdoors + a woman pressing her hands over her ears (source and receiver of the same phenomenon)
- A toy gun in a shop window + a real holstered pistol on a belt (real vs. depicted object, category irony)
- Two images with a strong shared accent color that creates a visual rhyme

The [pairing theory document](PAIRING_THEORY.md) explains the full thinking behind what makes a pair work.

## How it works

### Indexing pipeline

Each time you index a folder, Couplet runs through a series of phases:

1. **Scan** — reads EXIF data (capture date, color profile) from every image
2. **Duplicate detection** — groups true duplicates using perceptual hashing (dHash, Hamming distance ≤ 6) plus a filename-variant rule that catches crop/re-export copies
3. **Thumbnails** — generates 512px cached thumbnails
4. **CLIP embeddings** — runs each image through a bundled CLIP CoreML model to get a semantic embedding vector
5. **Captioning** — sends each image to a locally-running Ollama instance running `qwen2.5vl-caption`, which produces a detailed plain-text description of the image
6. **Role extraction** — reads each caption through `qwen2.5:14b-instruct` to extract a structured "role profile": what the subject is doing, what phenomena they emit or receive (sound, gaze, motion, force), what claims or signs appear in the image, and what concepts the subject embodies or contradicts
7. **Accent color extraction** — identifies the most visually prominent saturated color in each image
8. **Saliency and gaze** — uses Apple's Vision framework to find where attention is drawn in each image, and whether any face is looking left or right
9. **Pair scoring** — scores every pair of images across three axes and selects the top pairs using four candidate pools (composite top-150, thematic top-50, geometric top-5, aesthetic top-5 per image)

After each index, a background pass sends candidate pairs to `qwen2.5:14b-instruct` to judge whether they have a genuine conceptual connection, and if so, what kind.

### Three scoring axes

**Aesthetic (40% weight)**
Three-way max of: color harmony (HSL histogram intersection), tonal contrast (LAB palette distance), or accent color echo (images sharing a prominent hue). Suppresses false echoes from skin tones using a saturation gate.

**Geometric (20% weight)**
Measures structural composition similarity, directional complement (figures facing each other, or strong lines leading from one image into the next), and breath (dense/busy image paired with open/spare image). Uses Vision's saliency maps and face landmarks to detect gaze direction.

**Thematic (40% weight, boosted to 60% when dominant)**
Scores how well two captions share vocabulary from 29 semantic concept clusters organized into emotional/dramatic, contextual, and ambient tiers. When a role profile match exists, the background pass judges the pair directly from the proposed connection rather than scoring cold — this significantly improves precision for conceptual pairs.

### Candidate generation via role joins

The four-pool topK scoring can only surface pairs where the images are already visually similar in some measurable way. Role extraction adds a parallel path: three deterministic join rules identify candidate pairs based on relational structure (source/receiver of a phenomenon, claim vs. enactment, real vs. depicted object), bypassing the visual similarity gate entirely. These candidates go to the background judge with a hypothesis about the connection.

## Requirements

- macOS 14.0+
- [Ollama](https://ollama.com) running locally
- Two Ollama models: `qwen2.5vl-caption` (bundled via setup flow) and `qwen2.5:14b-instruct`

The first launch runs a setup flow that installs the models automatically. Ollama itself must be installed first.

## Stack

- Swift / SwiftUI, macOS 14+
- CoreML (CLIP ViT-B/32, bundled in the app)
- Ollama (`qwen2.5vl:7b` for captioning, `qwen2.5:14b-instruct` for role extraction and pair judging)
- GRDB (SQLite)
- Apple Vision framework (saliency, face landmarks)
- Apple CGImageSource (EXIF, thumbnails)

## Repository layout

```
_couplet/
├── ConjunctEngine/          # Swift Package — indexing engine, scoring, DB
│   ├── Sources/
│   ├── Tests/
│   └── Modelfile            # bundled Ollama model config
├── Couplet MacOS App/       # Xcode app project
│   └── Couplet/
├── CLAUDE.md                # Claude Code context file (see below)
├── DECISIONS.md             # Full architectural decisions log
└── PAIRING_THEORY.md        # Conceptual foundation: what makes a pair work
```

## CLAUDE.md

This file is the context prompt that was fed to Claude throughout the build. It describes the architecture, gotchas, and invariants that any AI assistant (or human contributor) needs to know to work on the codebase without breaking things. It's public here as an artifact of how this project was built.

## Known limitations

- The captioning model (`qwen2.5vl`) sometimes misidentifies objects — a holstered gun read as "a camera," a hands-over-ears gesture read as distress rather than reaching-to-hear. Captions drive the thematic axis, so these errors propagate into pair scoring.
- The background thematic judging pass scores 750 pairs per run. At roughly 3–4 seconds per pair on a 14B model, a full pass takes ~45 minutes warm. Successive runs are faster as the unscored pool shrinks.
- Running Ollama with `OLLAMA_KV_CACHE_TYPE=q8_0` corrupts caption output into systematic garbling. If captions look wrong, check `ps eww $(pgrep ollama) | tr ' ' '\n' | grep OLLAMA`.

## Development

The codebase is documented in two ways:
- **[DECISIONS.md](DECISIONS.md)** — every significant architectural choice, with the reasoning behind it. 100+ decisions logged in order.
- **[CLAUDE.md](CLAUDE.md)** — the operational reference that describes invariants and gotchas discovered during development.

If you want to understand why something is built the way it is, start with DECISIONS.md.
