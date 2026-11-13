"""MUISTI - Nemotron extraction step (v2).

Frame (blurred JPEG) + OCR lines  ->  structured memory record (JSON).

v2 changes vs v1 (extract_v1.py):
- OCR lines get IDs (L01, L02, ...). Every field must cite the line it came from.
- Code verifies EVERY cited field against its line, not only phone/hours.
  List items (e.g. "7TH FLOOR" -> "SAUNA AND POOL") must have label and value on the
  SAME line, which blocks wrong pairings when OCR loses the layout.
- kind is a fixed enum; detail goes to subtype.
- Prompt forbids describing text the model cannot read (no "Thai text", no invented names).
"""
import base64
import io
import json
import os
import random
import re
import time
from difflib import SequenceMatcher

from openai import (APIConnectionError, BadRequestError, InternalServerError,
                    OpenAI, RateLimitError)
from PIL import Image  # pip install openai pillow


def _load_dotenv(path: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")) -> None:
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.strip().split("=", 1)
                os.environ.setdefault(k, v)


_load_dotenv()

# Hackathon endpoint (Verda/DataCrunch vLLM container). Falls back to NVIDIA's public API.
BASE_URL = os.environ.get("LLM_BASE_URL", "https://integrate.api.nvidia.com/v1")
MODEL = os.environ.get("LLM_MODEL", "nvidia/nemotron-3.5-super-vl-120b-a12b")
API_KEY = os.environ.get("VERDA_INFERENCE_KEY") or os.environ["NVIDIA_API_KEY"]

client = OpenAI(base_url=BASE_URL, api_key=API_KEY, max_retries=0, timeout=120)

# Extraction knobs (ablations in eval/ablation.py change these).
EXTRACT_TEMPERATURE = 0.2
EXTRACT_THINKING = False
EXTRACT_MAX_TOKENS = 2500

KINDS = ["booth", "shop", "restaurant", "health", "service", "directory",
         "event", "transport", "notice", "street", "indoor_space", "other"]

# Things a person may want to find again later. Not exhaustive; guides the model.
OBJECT_CATEGORIES = ["navigation", "seating", "waste_smoking", "food_drink", "power_tech",
                     "sign_screen", "furniture", "vehicle", "nature", "building", "safety", "other"]

_NULLABLE_STR = {"type": ["string", "null"]}
_LINE = {"type": ["string", "null"], "description": "OCR line id like L03"}

RECORD_SCHEMA = {
    "type": "object",
    "properties": {
        "useful": {"type": "boolean"},
        "kind": {"type": ["string", "null"], "enum": KINDS + [None]},
        "subtype": _NULLABLE_STR,
        "name": _NULLABLE_STR, "name_line": _LINE,
        "phone": _NULLABLE_STR, "phone_line": _LINE,
        "hours": _NULLABLE_STR, "hours_line": _LINE,
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"label": {"type": "string"}, "value": {"type": "string"},
                               "line": {"type": "string"}},
                "required": ["label", "value", "line"],
            },
        },
        "other_text": _NULLABLE_STR,
        "scene": {
            "type": "object",
            "properties": {"place_type": {"type": "string"}, "indoor": {"type": "boolean"},
                           "lighting": {"type": "string"}},
            "required": ["place_type", "indoor", "lighting"],
        },
        "objects": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "category": {"type": "string", "enum": OBJECT_CATEGORIES},
                    "position": {"type": "string", "enum": ["left", "center", "right"]},
                    "distance": {"type": "string", "enum": ["near", "mid", "far"]},
                    "details": {"type": "string"},
                    "count": {"type": "integer"},
                },
                "required": ["name", "category", "position", "distance", "details", "count"],
            },
        },
        "relations": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"subject": {"type": "string"}, "relation": {"type": "string"},
                               "object": {"type": "string"}},
                "required": ["subject", "relation", "object"],
            },
        },
        "depictions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "medium": {"type": "string", "enum": ["banner", "poster", "screen", "sign", "billboard", "painting", "other"]},
                    "on": {"type": "string"},
                    "content": {"type": "string"},
                    "depicted": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["medium", "on", "content", "depicted"],
            },
        },
        "caption": {"type": "string"},
        "confidence": {"type": "number"},
    },
    "required": ["useful", "kind", "subtype", "name", "name_line", "phone", "phone_line",
                 "hours", "hours_line", "items", "other_text", "scene", "objects", "relations",
                 "depictions", "caption", "confidence"],
}

# Used when Nemotron stands in for Apple Vision (offline tests). Same-row rule keeps
# "7TH FLOOR   SAUNA AND POOL" together so pairs survive.
OCR_PROMPT = """Transcribe the readable English text in this image, one visual row per line.
- If a label and its value sit side by side on the same row (e.g. a floor number and a room name), keep them on ONE line.
- Copy exactly as written. Do not translate, correct, complete or guess words.
- Skip text that is too small, blurry or in a language you cannot read with certainty.
If there is no readable text, reply with exactly: NO_TEXT"""

# v13c prompt (selected by eval/tune.py on 40 hand-labelled frames; see eval/ITERATIONS.md).
SYSTEM_PROMPT = """You turn photos from smart glasses into memory records, so the wearer can later ask
"where did I see X?" about ANYTHING useful they walked past, not only text.

You get the image and OCR_LINES: text read by a separate OCR engine, one line per row, each with an id (L01, L02, ...). OCR may contain small errors. OCR_LINES may be "(none)".

TEXT rules (strict):
- name, phone, hours, items, other_text must come from OCR_LINES. Put the id of the line where a value starts in the matching *_line field (or "line" for items). A name may continue over the next 1-2 lines; phone, hours and items must be on one line.
- If OCR_LINES does not contain it, use null. Do NOT read text from the image that is missing from OCR_LINES.
- other_text: remaining useful text from OCR_LINES (slogan, website, address, date, price), joined with " / ".
- items: label -> value pairs (directory floors, menu prices) ONLY when both are on the SAME line.

VISUAL rules:
- objects: describe the scene so that ANY clearly visible thing can be found again later. List 8-15 objects.
  Go through these groups and include what is clearly visible from each (largest / most useful first):
    1. ways to move: stairs, escalator, elevator, door, entrance, exit, crosswalk, ramp, bridge
    2. structures and landmarks: building (say what kind in details: mall, office tower, shop front), store, statue,
       crane, scaffolding, column, arch, fountain, aquarium, slide, stage
    3. vehicles: car, taxi, bus, bicycle, pedicab, scooter, truck
    4. furniture and amenities: bench, chair, table, sofa, counter, trash bin, ashtray, umbrella, chandelier, lamp,
       street lamp, railing, kiosk, vending machine, ATM
    5. signs and media: sign, screen, billboard, poster, banner, flag, traffic light, QR code
    6. nature: tree, plant, flower, water
    7. goods on display: mannequin, clothing rack, display case, hat, shoe, fish
  Use these words exactly when they fit:
    screen = an electronic display showing video or changing images (TV, LED wall, monitor, digital billboard).
    sign = fixed lettering or a logo, lit or not (shop sign, neon sign, store name). A lit sign is NOT a screen.
    billboard = a large printed or digital advertisement panel on a building or pole.
    poster = a printed picture or advert on a wall, window or stand. banner = hanging fabric/vinyl.
  For each: name (simple English noun, singular), category, position in the frame (left/center/right), distance (near/mid/far),
  details (at most 12 words: colour, material, kind, state, what is on it), count (how many of this thing are visible in THIS frame).
  Numbers on plaques, indicators and screens: say in details what the number MEANS only if it is clear
  (e.g. "elevator position indicator showing 4", "floor label 5TH FLOOR at top of directory").
  If you cannot tell what a number means, write "unlabeled number 4". Never decide which floor the viewer is on.
  Only list things you can actually see.
  People are never objects - including costumed performers, mascots and 'living statues' (a person dressed as the
  Statue of Liberty is a person, not a statue). A real statue is stone or metal on a pedestal.
  Every shop front you can see counts as a store (put what it sells in details). A small street booth selling
  snacks, drinks or newspapers is a kiosk. Name the goods on stalls and in windows (fish, flowers, hats, shoes).
  A QR code on a banner, poster, screen or sign is its own object: list it as "qr code" (details: what it is on).
  Direction / wayfinding signs: name it "direction sign" and put every destination WITH its arrow direction in details
  (e.g. "arrows: P + METRO left, CENTRE straight ahead"). A direction sign is not the place it points to: do not use
  its destinations as kind, subtype or name.
  Large numbers or codes painted on walls or pillars (B2, 05, L3) are floor labels: name "sign", details "floor label B2".
  Elevator only if you clearly see elevator doors AND call buttons or a floor indicator; a plain wall or door is not one.
  Use these names when they fit: drink cooler (glass-front fridge with drinks), wet floor sign (yellow warning stand),
  traffic sign (yield, no entry, crossing, roundabout), traffic light, doormat.
  count: repeated things are counted (8 street lamps = one object with count 8).
  In dark or night scenes still list what you can see: lit lamps, lit signs, windows, vehicles with lights, silhouettes.
  Rare or striking things (aquarium, fountain, statue, slide, stage) only if you are certain: a blue wall, tiles
  or a screen showing water is not an aquarium.
- relations (max 6): spatial facts between visible things that help someone find them, e.g. "stairs" "behind" "directory screen", "ashtray" "next to" "entrance door", "elevator" "right of" "directory screen". Use simple relations: behind, in front of, left of, right of, next to, above, below, on, inside.
- scene: place_type (e.g. event hall, corridor, elevator lobby, street, cafe, entrance), indoor true/false, lighting (bright/dim/dark/colored).
- Never describe real people in the scene, their faces, clothing, body or license plates. People are not objects.

PICTURES (depictions) - keep them apart from the real scene:
- Banners, posters, screens, billboards and signs often SHOW pictures: a photo of a man at a desk, a car, a beach, a game, a product.
  Things inside a picture are NOT physically there. Never put them in objects or relations.
- For each picture you can make out (max 4, largest first), add one depictions item:
  medium (banner/poster/screen/sign/billboard/painting/other), on (which real object or booth it is on, e.g. "Cloudinary banner", "large screen at stage"),
  content (at most 15 words: what the picture shows, e.g. "photo of a man working on a laptop at a desk"),
  depicted (simple nouns of what is in the picture, e.g. ["man", "laptop", "desk"]).
- People INSIDE pictures may be described generically (a man, a woman, a team, a child; what they are doing). Never guess who they are.
- The banner/screen itself still goes in objects; only its picture content goes in depictions. Text on it stays in the TEXT fields.

OTHER:
- kind must be one of: booth, shop, restaurant, health, service, directory, event, transport, notice, street, indoor_space, other. Use street / indoor_space when there is no business or sign. Specific type goes in subtype.
- caption: 1-2 sentences describing the place and the most useful things in it. Never mention languages or text you cannot read.
- useful=false only if the frame shows nothing worth remembering (blurred, floor, ceiling, a close-up of a person).

Return ONLY one JSON object with keys: useful, kind, subtype, name, name_line, phone, phone_line, hours, hours_line, items, other_text, scene, objects, relations, depictions, caption, confidence.

The examples only show the JSON format. They are different places: never add an object because it appeared in an
example. Describe only what is in THIS photo."""

# v13c few-shots: neutral (no elevator/ashtray pairings); third shot = direction sign with arrows.
_FEW_SHOTS_JSON = r'''[
 [
  "OCR_LINES:\nL01 DENTAL CLINIC\nL02 Bright Smile Dental\nL03 Tel. 040 123 4567\nL04 Mon-Fri 8-18\nL05 Gentle care for\nL06 the whole family",
  {
   "useful": true,
   "kind": "health",
   "subtype": "dentist",
   "name": "Bright Smile Dental",
   "name_line": "L02",
   "phone": "040 123 4567",
   "phone_line": "L03",
   "hours": "Mon-Fri 8-18",
   "hours_line": "L04",
   "items": [],
   "other_text": "DENTAL CLINIC / Gentle care for the whole family",
   "scene": {
    "place_type": "street",
    "indoor": false,
    "lighting": "bright"
   },
   "objects": [
    {
     "name": "sign",
     "category": "sign_screen",
     "position": "center",
     "distance": "near",
     "details": "white dentist sign with blue text",
     "count": 1
    },
    {
     "name": "door",
     "category": "navigation",
     "position": "left",
     "distance": "near",
     "details": "glass entrance door of the clinic",
     "count": 1
    },
    {
     "name": "poster",
     "category": "sign_screen",
     "position": "right",
     "distance": "near",
     "details": "poster in the clinic window",
     "count": 1
    }
   ],
   "relations": [
    {
     "subject": "sign",
     "relation": "above",
     "object": "door"
    },
    {
     "subject": "poster",
     "relation": "right of",
     "object": "door"
    }
   ],
   "depictions": [
    {
     "medium": "poster",
     "on": "window poster of Bright Smile Dental",
     "content": "photo of a smiling woman in a dentist chair",
     "depicted": [
      "woman",
      "dentist chair"
     ]
    }
   ],
   "caption": "A dentist entrance with a sign above a glass door and a poster in the window.",
   "confidence": 0.9
  }
 ],
 [
  "OCR_LINES:\nL01 3RD FLOOR\nL02 4TH FLOOR CAFE & LOUNGE\nL03 3RD FLOOR WORKSHOP ROOM\nL04 2ND FLOOR\nL05 RECEPTION\nL06 CITYHUB",
  {
   "useful": true,
   "kind": "directory",
   "subtype": "floor directory",
   "name": "CITYHUB",
   "name_line": "L06",
   "phone": null,
   "phone_line": null,
   "hours": null,
   "hours_line": null,
   "items": [
    {
     "label": "4TH FLOOR",
     "value": "CAFE & LOUNGE",
     "line": "L02"
    },
    {
     "label": "3RD FLOOR",
     "value": "WORKSHOP ROOM",
     "line": "L03"
    }
   ],
   "other_text": null,
   "scene": {
    "place_type": "corridor",
    "indoor": true,
    "lighting": "bright"
   },
   "objects": [
    {
     "name": "directory screen",
     "category": "sign_screen",
     "position": "left",
     "distance": "near",
     "details": "vertical digital directory screen listing floors",
     "count": 1
    },
    {
     "name": "sign",
     "category": "sign_screen",
     "position": "right",
     "distance": "near",
     "details": "floor label 3 painted large on the wall",
     "count": 1
    },
    {
     "name": "door",
     "category": "navigation",
     "position": "right",
     "distance": "mid",
     "details": "grey corridor door, closed",
     "count": 1
    }
   ],
   "relations": [
    {
     "subject": "directory screen",
     "relation": "left of",
     "object": "door"
    }
   ],
   "depictions": [],
   "caption": "A corridor with a floor directory screen, a large floor label 3 on the wall and a closed door.",
   "confidence": 0.8
  }
 ],
 [
  "OCR_LINES:\nL01 CITY CENTRE\nL02 P + METRO",
  {
   "useful": true,
   "kind": "street",
   "subtype": "road junction",
   "name": null,
   "name_line": null,
   "phone": null,
   "phone_line": null,
   "hours": null,
   "hours_line": null,
   "items": [],
   "other_text": "CITY CENTRE / P + METRO",
   "scene": {
    "place_type": "street",
    "indoor": false,
    "lighting": "dark"
   },
   "objects": [
    {
     "name": "direction sign",
     "category": "navigation",
     "position": "center",
     "distance": "mid",
     "details": "arrows: CITY CENTRE straight ahead, P + METRO right",
     "count": 1
    },
    {
     "name": "street lamp",
     "category": "furniture",
     "position": "center",
     "distance": "mid",
     "details": "lit lamp posts along the road",
     "count": 4
    },
    {
     "name": "crosswalk",
     "category": "navigation",
     "position": "left",
     "distance": "near",
     "details": "white striped crossing",
     "count": 1
    },
    {
     "name": "bus",
     "category": "vehicle",
     "position": "right",
     "distance": "far",
     "details": "city bus with lit windows",
     "count": 1
    }
   ],
   "relations": [
    {
     "subject": "direction sign",
     "relation": "above",
     "object": "crosswalk"
    }
   ],
   "depictions": [],
   "caption": "A dark road junction with a direction sign (city centre ahead, parking and metro to the right), four lit street lamps and a crossing.",
   "confidence": 0.8
  }
 ]
]'''
FEW_SHOTS = [tuple(x) for x in json.loads(_FEW_SHOTS_JSON)]


# --- helpers -------------------------------------------------------------------

def _image_part(jpeg_bytes: bytes) -> dict:
    b64 = base64.b64encode(jpeg_bytes).decode()
    return {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}


def _repair_json(text: str) -> dict:
    """Last resort for runaway output cut mid-JSON: drop the unfinished tail and close open brackets."""
    t = text[text.index("{"):]
    for cut in range(len(t), 0, -1):
        if t[cut - 1] not in "}]\"0123456789el":  # end at a value boundary
            continue
        head, stack, in_str, esc = t[:cut], [], False, False
        for ch in head:
            if in_str:
                esc = (ch == "\\") and not esc
                if ch == '"' and not esc:
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch in "{[":
                stack.append("}" if ch == "{" else "]")
            elif ch in "}]" and stack:
                stack.pop()
        if in_str:
            continue
        try:
            return json.loads(head.rstrip(", ") + "".join(reversed(stack)))
        except json.JSONDecodeError:
            continue
    raise ValueError("could not repair model JSON")


def _parse_json(text: str) -> dict:
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"no JSON in model output: {text[:200]}")
    return json.loads(match.group(0))


def downscale(jpeg_bytes: bytes, long_side: int = 1536) -> bytes:
    """12 MP photos are wasteful: model tiles images into 512x512 (256 tokens each)."""
    img = Image.open(io.BytesIO(jpeg_bytes)).convert("RGB")
    img.thumbnail((long_side, long_side))
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=85)
    return out.getvalue()


def number_lines(ocr: str | list[str]) -> dict[str, str]:
    lines = ocr.splitlines() if isinstance(ocr, str) else ocr
    lines = [l.strip() for l in lines if l.strip()]
    return {f"L{i + 1:02d}": l for i, l in enumerate(lines)}


# --- verification: the evidence rule lives here, not in the prompt -------------

_OCR_FIX = str.maketrans({"O": "0", "o": "0", "l": "1", "I": "1", "S": "5", "B": "8"})


def _digits(s: str) -> str:
    return re.sub(r"\D", "", s.translate(_OCR_FIX))


def _norm(s: str) -> str:
    return re.sub(r"[^A-Z0-9]+", " ", s.upper()).strip()


def fuzzy_in(value: str, line: str, threshold: float = 0.8) -> bool:
    """value appears in line, tolerating small OCR errors (e.g. 'Smi1e' vs 'Smile')."""
    v, l = _norm(value), _norm(line)
    if not v:
        return False
    # Numbers are never fuzzy: '5TH FLOOR' must not match '7TH FLOOR'.
    line_nums = re.findall(r"\d+", l)
    if any(n not in line_nums for n in re.findall(r"\d+", v)):
        return False
    if v in l:
        return True
    n = len(v)
    if n > len(l) + 2:
        return False
    best = max((SequenceMatcher(None, v, l[i:i + n]).ratio() for i in range(max(1, len(l) - n + 1))),
               default=0)
    return best >= threshold


def phone_supported(phone: str | None, line: str) -> bool:
    if not phone:
        return False
    want = _digits(phone)
    return len(want) >= 6 and want in _digits(line)


def _windows(lines: dict[str, str], lid: str, span: int = 3) -> list[str]:
    """The cited line plus contiguous windows around it: sign names often wrap
    over 2-3 OCR lines ('ARDUINO' / 'HARDWARE LAB')."""
    keys = list(lines)
    if lid not in lines:
        return []
    i = keys.index(lid)
    out = []
    for start in range(max(0, i - span + 1), i + 1):
        for end in range(i + 1, min(len(keys), start + span) + 1):
            out.append(" ".join(lines[k] for k in keys[start:end]))
    return out


def verify(record: dict, lines: dict[str, str]) -> dict:
    """Null out every value that its cited OCR line does not support. Keep a reject log."""
    rejected = []

    def check(field: str, ok_fn, multiline: bool = False):
        val, lid = record.get(field), record.get(f"{field}_line")
        if not val:
            return
        line = lines.get(lid or "", "")
        texts = _windows(lines, lid) if multiline else [line]
        if not line or not any(ok_fn(val, t) for t in texts):
            rejected.append({"field": field, "value": val, "line": lid, "line_text": line})
            record[field] = None
            record[f"{field}_line"] = None

    check("name", fuzzy_in, multiline=True)  # names may wrap; items/phones may not
    check("phone", phone_supported)
    check("hours", fuzzy_in)

    # other_text may span many lines: each ' / ' part must appear somewhere in the OCR text.
    if record.get("other_text"):
        full = " ".join(lines.values())
        parts = [p.strip() for p in record["other_text"].split("/") if p.strip()]
        kept = [p for p in parts if fuzzy_in(p, full)]
        for p in parts:
            if p not in kept:
                rejected.append({"field": "other_text", "value": p, "line": None, "line_text": ""})
        record["other_text"] = " / ".join(kept) or None

    good_items = []
    for it in record.get("items") or []:
        line = lines.get(it.get("line", ""), "")
        if line and fuzzy_in(it.get("label", ""), line) and fuzzy_in(it.get("value", ""), line):
            good_items.append(it)
        else:
            rejected.append({"field": "item", "value": f"{it.get('label')} -> {it.get('value')}",
                             "line": it.get("line"), "line_text": line})
    record["items"] = good_items

    if record.get("kind") not in KINDS:
        record["kind"] = "other" if record.get("useful") else None

    _clean_visual(record, rejected)
    record["rejected"] = rejected
    # Not useful if no text evidence survived AND nothing worth finding is visible.
    if record.get("useful") and not any(record.get(f) for f in ("name", "phone", "hours", "other_text")) \
            and not record["items"] and not record["objects"] and not record["depictions"]:
        record["useful"] = False
    return record


_PEOPLE = re.compile(r"\b(person|people|man|men|woman|women|child|children|kid|boy|girl|crowd|face|"
                     r"attendee|visitor|staff|guy|lady|hand|head)s?\b", re.I)


_KEEP_PLURAL = {"stairs", "glasses", "scissors", "steps", "headphones", "pants", "news", "series"}


def _singular(name: str) -> str:
    """'chairs' -> 'chair', 'boxes' -> 'box', 'stairs' stays (last word only)."""
    *head, last = name.split()
    if last in _KEEP_PLURAL or len(last) <= 3 or not last.endswith("s") or last.endswith("ss"):
        return name
    if last.endswith(("xes", "ches", "shes")):
        last = last[:-2]
    elif last.endswith("ies"):
        last = last[:-3] + "y"
    else:
        last = last[:-1]
    return " ".join(head + [last])


_SIGNLIKE = re.compile(r"\b(neon|lit sign|illuminated sign|light[- ]?box|logo|lettering|letters|store sign|shop sign|"
                       r"signboard|name sign)\b", re.I)
_VIDEO = re.compile(r"\b(video|showing|displaying|image|images|footage|game|ad|advert|advertisement|animation|moving)\b", re.I)
_COSTUME = re.compile(r"\b(costume|costumed|performer|mascot|cosplay|living statue|dressed as)\b", re.I)


_VOCAB = ["wet floor sign", "direction sign", "exit sign", "traffic sign", "traffic light", "street lamp", "drink cooler", "trash bin", "glass door", "qr code", "vending machine", "display case", "clothing rack", "fire extinguisher", "taxi", "bus", "car", "bicycle", "scooter", "truck", "cooler", "fridge", "bag", "poster", "banner", "billboard", "screen", "sign", "lamp", "door", "table", "chair", "sofa", "bench", "plant", "tree", "window", "doormat", "mat", "railing", "stairs", "escalator", "elevator", "kiosk", "counter", "column", "statue", "umbrella", "flag", "cone", "barrier", "mannequin", "box", "can", "bottle"]
_PREP = re.compile(r"\b(on|in|at|near|above|below|with|by|behind|next|under|over|beside|inside|from|showing|of)\b")


def _rename_by_details(name: str, details: str) -> str:
    """If the object's name is not in its own details but the head of the details names another
    known object, trust the details (v13c, eval/tune.py)."""
    d = (details or "").lower()
    if not d or re.search(rf"\b{re.escape(name)}s?\b", d):
        return name
    head = _PREP.split(d, maxsplit=1)[0]
    for v in _VOCAB:
        if re.search(rf"\b{re.escape(v)}s?\b", head):
            return "drink cooler" if v in ("cooler", "fridge") else v
    return name


def _clean_visual(record: dict, rejected: list) -> None:
    """Visual facts cannot be checked against OCR, so enforce what code CAN check:
    no people as objects, no duplicates, and relations must connect listed objects."""
    seen, objs = set(), []
    for o in record.get("objects") or []:
        name = (o.get("name") or "").strip().lower()
        if not name or _PEOPLE.search(name):
            if name:
                rejected.append({"field": "object", "value": name, "line": None, "line_text": "person/empty"})
            continue
        name = _singular(name)
        d = o.get("details") or ""
        # The model's own details sometimes contradict its label; trust the details.
        if name == "screen" and _SIGNLIKE.search(d) and not _VIDEO.search(d):
            name = "sign"  # "screen | blue vertical neon sign" is a sign
        if name in ("statue", "sculpture", "figure", "monument", "mannequin") and _COSTUME.search(d):
            rejected.append({"field": "object", "value": name, "line": None,
                             "line_text": "details describe a person in costume"})
            continue
        name = _rename_by_details(name, d)  # "ashtray | yellow wet floor sign" -> wet floor sign
        if name in seen:
            continue
        seen.add(name)
        try:
            cnt = max(1, min(50, int(o.get("count") or 1)))
        except (TypeError, ValueError):
            cnt = 1
        objs.append({**o, "name": name, "count": cnt})
    record["objects"] = objs[:15]

    def known(x: str) -> bool:
        x = (x or "").strip().lower()
        return bool(x) and any(x == n or x in n or n in x for n in seen)

    rels = []
    for r in record.get("relations") or []:
        subj, obj = _singular((r.get("subject") or "").lower().strip() or "x"), _singular((r.get("object") or "").lower().strip() or "x")
        if known(subj) and known(obj) and subj != obj:
            rels.append({"subject": subj, "relation": (r.get("relation") or "").strip().lower(), "object": obj})
        else:
            rejected.append({"field": "relation", "value": f"{subj} {r.get('relation')} {obj}",
                             "line": None, "line_text": "refers to an object not listed"})
    record["relations"] = rels
    # Pictures: keep only ones with content; drop real-scene objects that are only in a picture.
    deps = []
    for d in record.get("depictions") or []:
        content = (d.get("content") or "").strip()
        if not content:
            continue
        depicted = [_singular(x.strip().lower()) for x in d.get("depicted") or [] if x and x.strip()]
        deps.append({"medium": d.get("medium") or "other", "on": (d.get("on") or "").strip(),
                     "content": content, "depicted": depicted[:12]})
    record["depictions"] = deps[:6]
    sc = record.get("scene") or {}
    record["scene"] = {"place_type": sc.get("place_type") or "unknown", "indoor": bool(sc.get("indoor", True)),
                       "lighting": sc.get("lighting") or "unknown"}


# --- model call ----------------------------------------------------------------

def _call(messages: list, response_format: dict, max_tokens: int = 800, temperature: float = 0.2,
          thinking: bool = False) -> str:
    """One request with backoff on 429/5xx."""
    for attempt in range(5):
        try:
            resp = client.chat.completions.create(
                model=MODEL,
                messages=messages,
                temperature=temperature,
                top_p=0.95,
                max_tokens=max_tokens,
                response_format=response_format,
                # Reasoning is ON by default and shares max_tokens -> empty content. Turn it off.
                extra_body={"chat_template_kwargs": {"enable_thinking": thinking}},
            )
            choice = resp.choices[0]
            if not choice.message.content:
                raise ValueError(f"empty content, finish_reason={choice.finish_reason}")
            return choice.message.content
        except (RateLimitError, InternalServerError, APIConnectionError):
            time.sleep(min(30, 2 ** attempt) + random.random())
    raise RuntimeError("Nemotron unavailable after retries")


def ocr(jpeg_bytes: bytes) -> list[str]:
    """Temporary OCR via Nemotron (stand-in for Apple Vision in offline tests)."""
    text = _call([{"role": "user", "content": [_image_part(downscale(jpeg_bytes)),
                                               {"type": "text", "text": OCR_PROMPT}]}],
                 {"type": "text"}, max_tokens=500, temperature=0.0).strip()
    if text.upper().startswith("NO_TEXT"):
        return []
    return [l for l in text.splitlines() if l.strip()]


# v6: frames without text are still described (objects, relations). Set False for text-only.
SCENE_MODE = True


def extract(jpeg_bytes: bytes, ocr_lines: str | list[str]) -> dict:
    lines = number_lines(ocr_lines)
    if not lines and not SCENE_MODE:
        return {"useful": False, "kind": None, "items": [], "objects": [], "relations": [],
                "rejected": [], "caption": "", "skipped": "no OCR text"}
    ocr_block = "OCR_LINES:\n" + ("\n".join(f"{k} {v}" for k, v in lines.items()) or "(none)")

    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for user, answer in FEW_SHOTS:
        messages += [{"role": "user", "content": user},
                     {"role": "assistant", "content": json.dumps(answer)}]
    messages.append({"role": "user", "content": [
        {"type": "text", "text": ocr_block},  # OCR before image tends to help text-VQA
        _image_part(downscale(jpeg_bytes)),
    ]})
    try:
        content = _call(messages, {"type": "json_schema",
                                   "json_schema": {"name": "memory", "schema": RECORD_SCHEMA}},
                        max_tokens=6000 if EXTRACT_THINKING else EXTRACT_MAX_TOKENS,
                        temperature=EXTRACT_TEMPERATURE, thinking=EXTRACT_THINKING)
    except BadRequestError:
        content = _call(messages, {"type": "json_object"}, max_tokens=6000 if EXTRACT_THINKING else EXTRACT_MAX_TOKENS,
                        temperature=EXTRACT_TEMPERATURE, thinking=EXTRACT_THINKING)
    try:
        parsed = _parse_json(content)
    except (ValueError, json.JSONDecodeError):
        # Rare runaway output (8-9k chars, cut mid-JSON). One retry at temperature 0.
        content = _call(messages, {"type": "json_schema", "json_schema": {"name": "memory", "schema": RECORD_SCHEMA}},
                        max_tokens=EXTRACT_MAX_TOKENS, temperature=0.0, thinking=False)
        try:
            parsed = _parse_json(content)
        except (ValueError, json.JSONDecodeError):
            parsed = _repair_json(content)
    record = verify(parsed, lines)
    record["ocr_lines"] = lines
    return record


if __name__ == "__main__":
    import sys

    img_path, ocr_path = sys.argv[1], sys.argv[2]
    with open(img_path, "rb") as f, open(ocr_path, encoding="utf-8") as g:
        print(json.dumps(extract(f.read(), g.read()), ensure_ascii=False, indent=2))
