"""Object-recognition prompt tuning loop.

Runs prompt variants (prompts/<name>.py) on hand-labelled frames with the SAME text-line
input (from Emir's side / results/tune/ocr.json), so only the object-recognition prompt
changes. Scores against eval/tune_labels.json.

A variant module may define any of: SYSTEM_PROMPT, FEW_SHOTS, TEMPERATURE, MAX_TOKENS.
Anything not defined falls back to extract.py.

Usage:
  python eval/tune.py v7 v8 --split train      # compare variants on the training frames
  python eval/tune.py v8 --split test          # final check on held-out frames
  python eval/tune.py v8 --show em_07          # print one frame's output
"""
import importlib
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from difflib import SequenceMatcher

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import extract as E  # noqa: E402

TUNE = os.path.join(ROOT, "results", "tune")
LABELS = json.load(open(os.path.join(ROOT, "eval", "tune_labels.json"), encoding="utf-8"))["frames"]
META = {m["file"][:-4]: m for m in json.load(open(os.path.join(TUNE, "frames.json"), encoding="utf-8"))}
TEXT = json.load(open(os.path.join(TUNE, "ocr.json"), encoding="utf-8"))

# Words that name the same kind of thing. Keys are the label vocabulary.
SYN = {
    "screen": ["display", "tv", "television", "monitor", "video screen", "led screen", "digital billboard",
               "jumbotron", "video wall", "digital display", "led display", "electronic billboard"],
    "billboard": ["advertisement", "ad", "advertising", "sign board", "signboard", "hoarding", "banner"],
    "store": ["shop", "storefront", "shop front", "boutique", "shopfront", "retail", "outlet", "showroom"],
    "street lamp": ["lamp post", "street light", "streetlight", "light pole", "lamppost", "lantern", "lamp"],
    "car": ["vehicle", "sedan", "suv", "automobile", "minivan", "van"],
    "taxi": ["cab", "yellow cab", "taxicab"],
    "stairs": ["staircase", "steps", "stairway", "stair"],
    "pedicab": ["rickshaw", "bike taxi", "tricycle", "bicycle", "bike", "cycle rickshaw", "trishaw"],
    "column": ["pillar", "post"],
    "plant": ["flower", "potted plant", "flower basket", "hanging basket", "planter", "flower pot", "bush", "shrub"],
    "flower": ["plant", "bouquet", "flower pot", "potted plant", "flowers"],
    "table": ["dining table", "desk", "cafe table"],
    "chair": ["seat", "stool", "armchair"],
    "bench": ["seat", "seating", "sofa", "couch", "banquette"],
    "display case": ["showcase", "display counter", "glass case", "vitrine", "counter", "display cabinet", "display"],
    "trash bin": ["bin", "garbage can", "trash can", "waste bin", "rubbish bin", "litter bin", "dustbin", "recycling bin"],
    "glass door": ["door", "entrance", "glass entrance", "sliding door"],
    "railing": ["handrail", "balustrade", "rail", "guardrail", "glass railing", "fence", "barrier"],
    "crosswalk": ["zebra crossing", "pedestrian crossing", "crossing"],
    "crane": ["construction crane", "tower crane"],
    "building": ["skyscraper", "office building", "tower", "facade", "mall", "high-rise", "highrise"],
    "scaffolding": ["scaffold", "construction"],
    "mannequin": ["dummy", "display figure"],
    "clothing rack": ["clothes rack", "rack", "garment rack", "hanger"],
    "poster": ["advertisement", "banner", "billboard", "print"],
    "chandelier": ["pendant light", "ceiling lamp", "hanging light", "light fixture"],
    "counter": ["service counter", "bar", "display counter", "food counter"],
    "slide": ["spiral slide", "tube slide", "playground slide"],
    "aquarium": ["fish tank", "tank"],
    "hat": ["cap", "hats"],
    "display": ["display case", "showcase", "shelf", "shelves", "display shelf", "window display"],
    "escalator": ["moving stairs", "moving staircase"],
    "sign": ["signage", "signboard", "store sign", "shop sign", "neon sign", "logo", "lettering"],
    "metro sign": ["subway sign", "m sign", "metro entrance sign", "metro"],
    "entrance": ["arch", "archway", "doorway", "door", "gate"],
    "kiosk": ["booth", "stand", "stall", "news stand", "newsstand", "buffet", "snack bar"],
    "umbrella": ["parasol", "patio umbrella"],
    "statue": ["sculpture", "monument"],
    "flag": ["american flag", "us flag", "banner flag"],
    "traffic light": ["traffic signal", "signal light", "stoplight"],
    "fish": ["seafood"],
    "lamp": ["lantern", "wall lamp", "light", "street lamp", "lamp post"],
    "tree": ["bare tree", "trees"],
    "cooler": ["fridge", "refrigerator", "drink cooler", "freezer", "display fridge", "beverage cooler", "chest cooler"],
    "wet floor sign": ["caution sign", "warning sign", "wet floor", "floor sign", "caution board", "a-frame sign", "sandwich board"],
    "exit sign": ["emergency exit sign", "exit"],
    "doormat": ["mat", "floor mat", "entrance mat", "rug"],
    "window": ["glass wall", "glass panel", "window panel", "glazing", "glass facade"],
    "door": ["glass door", "entrance", "doorway", "double door"],
}
PEOPLE = re.compile(r"\b(person|people|man|men|woman|women|child|children|kid|boy|girl|crowd|face|"
                    r"attendee|visitor|staff|guy|lady|hand|head|pedestrian|tourist|performer)s?\b", re.I)


def norm(s: str) -> str:
    return E._singular(re.sub(r"[^a-z0-9 ]", " ", (s or "").lower()).strip())


def same(a: str, b: str) -> bool:
    a, b = norm(a), norm(b)
    if not a or not b:
        return False
    if a == b or a in b.split() or b in a.split() or (len(b) > 3 and b in a) or (len(a) > 3 and a in b):
        return True
    return SequenceMatcher(None, a, b).ratio() >= 0.85


def matches(obj: str, label: str) -> bool:
    return any(same(obj, x) for x in [label] + SYN.get(label, []))


def load_variant(name: str):
    mod = importlib.import_module(f"prompts.{name}")
    saved = {k: getattr(E, k) for k in ("SYSTEM_PROMPT", "FEW_SHOTS", "EXTRACT_TEMPERATURE", "EXTRACT_MAX_TOKENS")}
    return mod, saved


def run_variant(name: str, frames: list[str], workers: int = 8) -> dict:
    mod, saved = load_variant(name)
    E.SYSTEM_PROMPT = getattr(mod, "SYSTEM_PROMPT", saved["SYSTEM_PROMPT"])
    E.FEW_SHOTS = getattr(mod, "FEW_SHOTS", saved["FEW_SHOTS"])
    E.EXTRACT_TEMPERATURE = getattr(mod, "TEMPERATURE", saved["EXTRACT_TEMPERATURE"])
    E.EXTRACT_MAX_TOKENS = getattr(mod, "MAX_TOKENS", saved["EXTRACT_MAX_TOKENS"])
    hook = getattr(mod, "postprocess", None)

    def one(f):
        jpeg = open(os.path.join(TUNE, "frames", f + ".jpg"), "rb").read()
        t = time.time()
        try:
            rec = E.extract(jpeg, TEXT.get(f + ".jpg") or [])
            if hook:
                rec = hook(rec)
        except Exception as ex:
            rec = {"error": f"{type(ex).__name__}: {ex}"[:200], "objects": [], "depictions": [], "rejected": []}
        return f, rec, time.time() - t

    try:
        with ThreadPoolExecutor(workers) as pool:
            out = {f: (rec, dt) for f, rec, dt in pool.map(one, frames)}
    finally:
        for k, v in saved.items():
            setattr(E, k, v)
    return out


def score(out: dict) -> dict:
    must_hit = must_all = listed = ok_listed = people = absent_hits = fact_hit = fact_all = 0
    absent_list = []
    pic_tp = pic_fn = pic_fp = pic_tn = errors = 0
    suspects, missed = [], []
    lat = []
    for f, (rec, dt) in out.items():
        lab = LABELS[f]
        lat.append(dt)
        if rec.get("error"):
            errors += 1
        objs = [o["name"] for o in rec.get("objects") or []]
        people += sum(1 for r in rec.get("rejected") or [] if r.get("field") == "object") + sum(1 for o in objs if PEOPLE.search(o))
        for m in lab["must"]:
            must_all += 1
            if any(matches(o, m) for o in objs):
                must_hit += 1
            else:
                missed.append(f"{f}:{m}")
        for a in lab.get("absent") or []:
            if any(norm(o) == norm(a) or matches(o, a) and norm(a) in norm(o) for o in objs) or (
                    a == "metro station" and re.search(r"metro station", f"{rec.get('subtype')} {rec.get('kind')}", re.I)):
                absent_hits += 1
                absent_list.append(f"{f}:{a}")
        blob = " ".join([json.dumps(rec.get("objects")), json.dumps(rec.get("relations")), json.dumps(rec.get("items")),
                         str(rec.get("other_text")), str(rec.get("caption"))]).lower()
        for rx in lab.get("facts") or []:
            fact_all += 1
            if re.search(rx, blob, re.I):
                fact_hit += 1
            else:
                missed.append(f"{f}:FACT /{rx}/")
        for o in objs:
            listed += 1
            if any(matches(o, x) for x in lab["must"] + lab["ok"]):
                ok_listed += 1
            else:
                suspects.append(f"{f}:{o}")
        if lab.get("pictures") is not None:
            has = bool(rec.get("depictions"))
            if lab["pictures"] and has: pic_tp += 1
            elif lab["pictures"]: pic_fn += 1
            elif has: pic_fp += 1
            else: pic_tn += 1
    return {
        "frames": len(out), "errors": errors,
        "recall_must": f"{must_hit}/{must_all} ({100 * must_hit / max(1, must_all):.0f}%)",
        "precision_est": f"{ok_listed}/{listed} ({100 * ok_listed / max(1, listed):.0f}%)",
        "objects_per_frame": round(listed / max(1, len(out)), 1),
        "people_as_objects": people,
        "absent_listed": absent_hits,
        "facts": f"{fact_hit}/{fact_all}",
        "pictures": f"found {pic_tp}/{pic_tp + pic_fn}, false {pic_fp}/{pic_fp + pic_tn}",
        "avg_latency_s": round(sum(lat) / max(1, len(lat)), 2),
        "_suspects": suspects, "_missed": missed, "_absent": absent_list,
    }


if __name__ == "__main__":
    flags_with_value = {"--split", "--show"}
    argv = sys.argv[1:]
    args = [a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or argv[i - 1] not in flags_with_value)]
    split = sys.argv[sys.argv.index("--split") + 1] if "--split" in sys.argv else "train"
    show = sys.argv[sys.argv.index("--show") + 1] if "--show" in sys.argv else None
    frames = [show] if show else sorted(f for f, m in META.items() if f in LABELS and (split == "all" or m["split"] == split))
    os.makedirs(os.path.join(TUNE, "runs"), exist_ok=True)
    for name in args:
        out = run_variant(name, frames)
        if show:
            rec = out[show][0]
            print(json.dumps({k: rec.get(k) for k in ("kind", "subtype", "name", "scene", "objects", "relations", "depictions", "caption", "rejected")}, indent=1, ensure_ascii=False))
            continue
        s = score(out)
        json.dump({"variant": name, "split": split, "score": s, "records": {f: r for f, (r, _) in out.items()}},
                  open(os.path.join(TUNE, "runs", f"{name}_{split}.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
        print(f"== {name} [{split}]", json.dumps({k: v for k, v in s.items() if not k.startswith("_")}, ensure_ascii=False))
        print("   suspects:", ", ".join(s["_suspects"][:60]))
        print("   missed:  ", ", ".join(s["_missed"][:60]))
        print("   ABSENT LISTED:", ", ".join(s["_absent"]))
