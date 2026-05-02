#!/usr/bin/env python3
"""
Tools/convert_clip.py
─────────────────────
Converts clip-vit-base-patch32 from HuggingFace to a Core ML .mlpackage.

Requirements:
    pip install torch transformers coremltools Pillow

Usage:
    python Tools/convert_clip.py
    python Tools/convert_clip.py --large
    python Tools/convert_clip.py --output path/to/output.mlpackage
"""

import argparse
import os
import sys

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="openai/clip-vit-base-patch32")
    parser.add_argument("--output", default=None)
    parser.add_argument("--large", action="store_true")
    args = parser.parse_args()

    if args.large:
        args.model = "openai/clip-vit-large-patch14"

    model_short = args.model.split("/")[-1]
    output_path = args.output or f"{model_short}.mlpackage"

    print(f"Converting {args.model} → {output_path}")

    try:
        import torch
        import coremltools as ct
        from transformers import CLIPModel
    except ImportError as e:
        print(f"\nMissing dependency: {e}")
        print("Install with:  pip install torch transformers coremltools Pillow")
        sys.exit(1)

    print(f"Downloading model weights ({args.model})…")
    model = CLIPModel.from_pretrained(args.model)
    model.eval()

    class CLIPVisionWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.vision_model = clip_model.vision_model
            self.visual_projection = clip_model.visual_projection

        def forward(self, pixel_values):
            vision_outputs = self.vision_model(pixel_values=pixel_values)
            pooled = vision_outputs.pooler_output
            embedding = self.visual_projection(pooled)
            embedding = embedding / embedding.norm(dim=-1, keepdim=True).clamp(min=1e-8)
            return embedding

    wrapper = CLIPVisionWrapper(model)
    wrapper.eval()

    example_input = torch.zeros(1, 3, 224, 224)
    print("Tracing model…")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_input)

    print("Converting to Core ML…")
    image_input = ct.ImageType(
        name="image",
        shape=(1, 3, 224, 224),
        scale=1 / 255.0,
        bias=[
            -0.48145466 / 0.26862954,
            -0.4578275  / 0.26130258,
            -0.40821073 / 0.27577711,
        ],
        channel_first=True,
        color_layout=ct.colorlayout.RGB,
    )

    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        outputs=[ct.TensorType(name="embeddings")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )

    mlmodel.short_description = f"CLIP visual encoder — {model_short}"
    mlmodel.input_description["image"]      = "224×224 RGB image, centre-cropped"
    mlmodel.output_description["embeddings"] = "L2-normalised 512-d embedding (float32)"
    mlmodel.save(output_path)

    size_mb = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, files in os.walk(output_path)
        for f in files
    ) / (1024 * 1024)

    print(f"\n✓ Saved {output_path}  ({size_mb:.0f} MB)")
    print(f"\nNext step — run the benchmark:")
    print(f"  swift run conjunct-bench /path/to/photos --model {output_path}")

if __name__ == "__main__":
    main()
