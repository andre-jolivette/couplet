#!/usr/bin/env python3
"""#128 probe-precision validation — standalone, GPU-only.

Tests the two edited probe prompts (samePhenomenon directionality,
sameSubject identity/opposition) directly against Ollama, reading the EXACT
wording from ThematicScorerV2.swift so it validates what ships. Run this on a
CLEAN GPU (no live judge pass) — precision reads jitter under load.

    python3 diagnostics/128-probe-precision-test.py

Each case marks its required answer; a line prints FAIL if the model disagrees.
"""
import json, re, sys, urllib.request

SRC = "ConjunctEngine/Sources/ConjunctEngine/Scoring/ThematicScorerV2.swift"

def prompt(name):
    text = open(SRC).read()
    body = text.split(f"{name} = \"\"\"")[1].split('"""')[0]
    return body.replace("\\\n", "").strip()

def ask(system, user, schema):
    body = json.dumps({"model": "qwen2.5:14b-instruct", "system": system,
                       "prompt": user, "stream": False, "format": schema,
                       "options": {"temperature": 0.0, "num_predict": 200}}).encode()
    req = urllib.request.Request("http://127.0.0.1:11434/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(json.load(r)["response"])

NL = "\n"
PHEN = prompt("kSamePhenomenonPrompt")
SUBJ = prompt("kSameSubjectPrompt")
phen_schema = {"type": "object", "properties": {"same_phenomenon": {"type": "boolean"},
               "explicit_both_sides": {"type": "boolean"}}, "required": ["same_phenomenon", "explicit_both_sides"]}
subj_schema = {"type": "object", "properties": {"same_subject_opposed": {"type": "boolean"}},
               "required": ["same_subject_opposed"]}

fails = 0

print("=== samePhenomenon (directionality) ===")
phen_cases = [
    ("357/534 MIC pair — both sources", False,
     "He holds a microphone in his right hand",
     "he appears to be singing or speaking into a microphone"),
    ("two-singers variant — both sources", False,
     "singing into a microphone on stage",
     "belts out a song into her microphone"),
    ("G16 50/572 — genuine source/receiver", True,
     "holding a megaphone to his mouth",
     "her hands cupping her ears as if blocking out noise"),
    ("37/135 dancing — no reception", False,
     "The man is speaking into the megaphone",
     "They appear to be dancing or moving closely together"),
]
for name, want, src, rcv in phen_cases:
    got = ask(PHEN, f"SOURCE: {src}{NL}RECEIVER: {rcv}", phen_schema)["same_phenomenon"]
    tag = "ok" if got == want else "FAIL"
    if got != want:
        fails += 1
    print(f"  [{tag}] want={want} got={got}  {name}")

print("=== sameSubjectOpposed (identity + opposition) ===")
subj_cases = [
    ("390/512 — two different women", False,
     "A woman, likely in her twenties or thirties, stands in the foreground, holding a megaphone",
     "A woman, likely in her twenties or thirties, sits inside a white van"),
    ("552/759 — different women, pose diff", False,
     "Her left arm is extended outward, and her hand appears to be in motion",
     "Her hands rest on her knees"),
    ("186/390 control — two protest women", False,
     "a woman raising her fist, gripping a red flag",
     "a woman holding a megaphone and speaking passionately"),
    ("genuine same-subject reversal control", True,
     "the storefront stands shuttered and empty at dawn",
     "the same storefront overflows with a crowd at midday"),
]
for name, want, a, b in subj_cases:
    got = ask(SUBJ, f"SPAN 1: {a}{NL}SPAN 2: {b}", subj_schema)["same_subject_opposed"]
    tag = "ok" if got == want else "FAIL"
    if got != want:
        fails += 1
    print(f"  [{tag}] want={want} got={got}  {name}")

print(f"{NL}{'ALL PASS' if fails == 0 else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
