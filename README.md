# Couplet

A macOS app for street and documentary photographers. Couplet finds meaningful image pairs in your photo library — not duplicates or sequential shots, but conceptually resonant connections you might not have noticed. The serendipity machine goal: surface pairs that reward a second look.

**Status:** Pre-release. Not yet available for download.

## What it does

- Indexes a photo library using CLIP embeddings, perceptual hashing, and a captioning model (qwen2.5vl)
- Scores pairs across three axes: aesthetic (color harmony + tonal contrast), geometric (edge and composition similarity), and thematic (semantic cluster matching on captions)
- Surfaces the top pairs in a browsable grid with lightbox view, modality filters, and score breakdowns
- Exports diptychs as JPEG or PDF

## Stack

- Swift / SwiftUI, macOS 14+
- CoreML (CLIP), Ollama (qwen2.5vl:7b), GRDB (SQLite)
