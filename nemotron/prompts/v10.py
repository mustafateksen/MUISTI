"""v10 = v9 + code rule: an object whose own details say it is a costume/performer/mascot is a person.

Why: on the held-out set v9 still listed the Times Square Statue-of-Liberty performer as
"statue" with details "blue Statue of Liberty costume" - the model's details contradict its label.
"""
import re

import prompts.v9 as v9

SYSTEM_PROMPT = v9.SYSTEM_PROMPT
MAX_TOKENS = v9.MAX_TOKENS

_PERSONLIKE = re.compile(r"\b(costume|costumed|performer|mascot|cosplay|living statue|dressed as|person|wearing)\b", re.I)


def postprocess(rec: dict) -> dict:
    rec = v9.postprocess(rec)
    kept = []
    for o in rec.get("objects") or []:
        if _PERSONLIKE.search(o.get("details") or "") and o.get("name") in ("statue", "sculpture", "figure", "mannequin", "monument"):
            # 'mannequin wearing a hat' is a real mannequin: only drop when details say costume/performer/person.
            if o["name"] == "mannequin" and not re.search(r"costume|performer|person|mascot", o.get("details") or "", re.I):
                kept.append(o)
                continue
            rec.setdefault("rejected", []).append({"field": "object", "value": o["name"], "line": None,
                                                   "line_text": "details describe a person in costume"})
            continue
        kept.append(o)
    rec["objects"] = kept
    return rec
