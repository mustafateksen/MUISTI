"""v13c = v13b + code rule: when the object's NAME does not appear in its own details but the head of the
details names another known object, trust the details.
  "ashtray | yellow wet floor sign standing on the floor"  -> wet floor sign
  "car | silver taxi with headlights on"                    -> taxi
  "vending machine | glass-fronted drink cooler with cans"  -> drink cooler
  "trash bin | blue trash bag on the ground"                -> bag
"""
import re

import prompts.v13b as b

SYSTEM_PROMPT = b.SYSTEM_PROMPT
FEW_SHOTS = b.FEW_SHOTS
MAX_TOKENS = 2500

VOCAB = ["wet floor sign", "direction sign", "exit sign", "traffic sign", "traffic light", "street lamp", "drink cooler",
         "trash bin", "glass door", "qr code", "vending machine", "display case", "clothing rack", "fire extinguisher",
         "taxi", "bus", "car", "bicycle", "scooter", "truck", "cooler", "fridge", "bag", "poster", "banner", "billboard",
         "screen", "sign", "lamp", "door", "table", "chair", "sofa", "bench", "plant", "tree", "window", "doormat", "mat",
         "railing", "stairs", "escalator", "elevator", "kiosk", "counter", "column", "statue", "umbrella", "flag",
         "cone", "barrier", "mannequin", "box", "can", "bottle"]
_PREP = re.compile(r"\b(on|in|at|near|above|below|with|by|behind|next|under|over|beside|inside|from|showing|of)\b")


def rename(name: str, details: str) -> str:
    d = (details or "").lower()
    if not d or re.search(rf"\b{re.escape(name)}s?\b", d):
        return name
    head = _PREP.split(d, maxsplit=1)[0]
    for v in VOCAB:  # multi-word first
        if re.search(rf"\b{re.escape(v)}s?\b", head):
            return "drink cooler" if v in ("cooler", "fridge") else v
    return name


def postprocess(rec: dict) -> dict:
    seen = set()
    out = []
    for o in rec.get("objects") or []:
        o["name"] = rename(o["name"], o.get("details"))
        if o["name"] in seen:
            continue
        seen.add(o["name"])
        out.append(o)
    rec["objects"] = out
    return rec
