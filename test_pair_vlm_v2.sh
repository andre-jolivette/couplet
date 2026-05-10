#!/bin/bash
# test_pair_vlm_v2.sh
#
# Revised prompt test based on v1 findings:
# — Ask "what the subject is doing" not "human condition"
# — Concrete action language is sufficient for role-direction extraction
# — JSON structure from Variant C retained (reliable, fast, parseable)
# — arc field kept but expectations lowered: domain detection, not poetry
#
# Scoring logic this enables:
#   1. Parse a and b for action direction (outward vs inward)
#   2. Check arc for shared domain
#   3. Opposite directions + shared domain = complementary pair signal
#
# Run: bash test_pair_vlm_v2.sh
# Prerequisites: ollama serve running, qwen2.5vl-caption available, jq installed

OLLAMA_URL="http://localhost:11434/api/generate"
MODEL="qwen2.5vl-caption"
TRIALS=5

CAPTION_A="A man in his fifties plays violin beside the open trunk of a parked car
on a quiet residential street at what appears to be a charreada, a Mexican rodeo.
He is absorbed in the performance, eyes slightly closed, bow moving in long strokes.
The neighborhood has a distinctly Latin character — murals, Spanish signage, warm
afternoon light on stucco walls. There is no visible audience. The music seems to
be offered to the street itself."

CAPTION_B="A woman sits alone on a concrete stoop, both palms pressed firmly over
her ears, eyes closed. She appears to be in her thirties, dressed plainly. The urban
environment around her is indistinct — steps, a door, a sliver of street. Her posture
is concentrated, almost yearning, as if she is trying to pull something in rather
than block something out."

# ---------------------------------------------------------------------------
# PROMPT — concrete action, JSON output, arc as domain not interpretation
# ---------------------------------------------------------------------------

PROMPT='Read these two image descriptions. Reply with JSON only — no other text,
no markdown, no explanation. Use this exact format:
{"a": "what the subject is doing in image A, 6-8 words",
 "b": "what the subject is doing in image B, 6-8 words",
 "arc": "what both images involve in common, 3-5 words, or null"}

Image A: '"${CAPTION_A}"'
Image B: '"${CAPTION_B}"

echo "=== V2 PROMPT — action language, JSON, arc as domain ==="
echo "Prompt length: $(echo "$PROMPT" | wc -c) chars"
echo ""

TOTAL=0

for i in $(seq 1 $TRIALS); do
    START=$(date +%s%3N)
    RESPONSE=$(curl -s -X POST "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$MODEL" \
            --arg prompt "$PROMPT" \
            '{model: $model, prompt: $prompt, stream: false,
              options: {num_predict: 80, temperature: 0.2}}'
        )")
    END=$(date +%s%3N)
    ELAPSED=$(( END - START ))
    TOTAL=$(( TOTAL + ELAPSED ))

    TEXT=$(echo "$RESPONSE" | jq -r '.response // "ERROR"')

    # Try to parse the JSON the model returned
    PARSED=$(echo "$TEXT" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
# strip markdown fences if present
raw = raw.replace('\`\`\`json','').replace('\`\`\`','').strip()
try:
    obj = json.loads(raw)
    a = obj.get('a','MISSING')
    b = obj.get('b','MISSING')
    arc = obj.get('arc','MISSING')
    print(f'  a:   {a}')
    print(f'  b:   {b}')
    print(f'  arc: {arc}')
    # role direction heuristic
    outward = ['plays','performs','playing','performing','offering','giving','producing','sending','making','expressing','directing']
    inward  = ['blocking','covering','straining','listening','receiving','absorbing','closing','hiding','pressing']
    a_dir = 'OUTWARD' if any(w in a.lower() for w in outward) else ('INWARD' if any(w in a.lower() for w in inward) else 'UNCLEAR')
    b_dir = 'OUTWARD' if any(w in b.lower() for w in outward) else ('INWARD' if any(w in b.lower() for w in inward) else 'UNCLEAR')
    print(f'  direction A: {a_dir}  |  direction B: {b_dir}')
    if a_dir != b_dir and 'UNCLEAR' not in (a_dir, b_dir):
        print(f'  ✓ COMPLEMENTARY — opposite directions, arc: {arc}')
    elif a_dir == b_dir:
        print(f'  ✗ PARALLEL — same direction')
    else:
        print(f'  ? UNCLEAR — one or both directions ambiguous')
except Exception as e:
    print(f'  PARSE ERROR: {e}')
    print(f'  Raw: {raw[:200]}')
" 2>&1)

    echo "Trial $i (${ELAPSED}ms):"
    echo "$PARSED"
    echo ""
done

AVG=$(( TOTAL / TRIALS ))
echo "Average: ${AVG}ms"
echo ""
echo "---"
echo "What to evaluate:"
echo "  JSON reliability: did every trial produce valid parseable JSON?"
echo "  Action language: is 'a' a concrete action (playing, pressing, offering)?"
echo "  Direction detection: does the heuristic correctly classify outward/inward?"
echo "  Arc quality: is it a shared domain (sound, music, urban noise) or generic"
echo "    (urban solitude, human experience)? Domain > theme > generic."
echo "  Complementary signal: does COMPLEMENTARY fire on this known-good pair?"
