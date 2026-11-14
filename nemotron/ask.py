"""MUISTI - /ask: spoken question -> evidence-grounded answer.

Pipeline (at most 2 Nemotron calls, often 1):
  1. parse    Nemotron turns the question into {target, attribute, time}   (1 call)
  2. search   lexical + fuzzy scoring over memory docs, time as soft filter  (0 calls)
  3. gate     nothing relevant -> DONT_KNOW without calling the model        (0 calls)
  4. answer   Nemotron answers ONLY from evidence E1..E5 and must quote it   (1 call)
  5. verify   code checks the quote is really in the cited evidence;
              failure -> DONT_KNOW. Numbers must match exactly.

Memory here is loaded from process_video results (stand-in for Aiven/pgvector).
"""
import datetime as dt
import glob
import json
import os
import re
import time
from difflib import SequenceMatcher

import extract as E
import embed

ATTRIBUTES = ["location", "phone", "hours", "name", "description", "list", "when", "current_location", "other"]
TIMES = ["just_now", "last_hour", "today", "any"]
# What the user wants. Decided by the model in the same parse call (no extra call), not by keyword rules.
INTENTS = ["memory", "live", "summary", "forget", "chat"]

PARSE_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string", "enum": INTENTS},
        "minutes": {"type": ["number", "null"]},
        "target": {"type": ["string", "null"]},
        "category": {"type": ["string", "null"]},
        "attribute": {"type": "string", "enum": ATTRIBUTES},
        "time": {"type": "string", "enum": TIMES},
        "synonyms": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["intent", "minutes", "target", "category", "attribute", "time", "synonyms"],
}

PARSE_PROMPT = """Turn what the user says to their smart-glasses memory assistant into JSON.
- intent: what kind of request it is:
  memory  - about something they saw EARLIER (where/which/when, did I see, what did it say, phone, hours, where am I now).
  live    - about what is in front of them RIGHT NOW (what is this, what am I looking at, read this for me).
  summary - a recap of what they saw over a period (summarise, what did I see in the last minutes, what happened today).
  forget  - they want recent memories deleted (forget the last 10 minutes, delete that).
  chat    - anything else: greetings, small talk, the time or date, general questions, what can you do.
- minutes: the period they name in minutes ("last 10 minutes" -> 10, "last hour" -> 60, "a few minutes" -> 5), else null.
- target: the specific thing they ask about, using their words (e.g. "arduino hardware lab", "sauna", "info desk"), or null.
- category: a general type if they ask about a kind of thing (e.g. "gaming", "database", "dentist"), else null.
- attribute: what they want: location (where is X / which floor is X on), phone, hours, name, description (what did it say/show), list (which ones did I see), when (when did I see it),
  current_location (where am I NOW / which floor am I on / where am I standing), other.
- time: just_now (last ~15 min), last_hour, today, any.
- synonyms: up to 5 other simple English words for the target or category that a sign or a photo description might use
  (e.g. "somewhere to smoke" -> ["ashtray", "smoking area", "cigarette bin"]; "coffee" -> ["cafe", "coffee machine", "espresso"];
  "way upstairs" -> ["stairs", "staircase", "escalator", "elevator"]). Empty list if none.
Return ONLY JSON with keys intent, minutes, target, category, attribute, time, synonyms."""

ANSWER_SCHEMA = {
    "type": "object",
    "properties": {
        "label": {"type": "string", "enum": ["SEEN", "DONT_KNOW"]},
        "answer": {"type": "string"},
        "evidence": {"type": "array", "items": {"type": "string"}},
        "quotes": {"type": "array", "items": {"type": "string"}},
        "support": {"type": "string", "enum": ["stated", "inferred"]},
        "observations": {"type": "string"},
    },
    "required": ["label", "answer", "evidence", "quotes", "support", "observations"],
}

ANSWER_PROMPT = """You are a memory assistant on smart glasses. Answer the question using ONLY the evidence below.
Each evidence item is something the glasses actually saw, with an id (E1, E2...).
The glasses are worn by the user, so if the glasses saw something, the user was there and walked past or looked at it.

Rules:
- If the evidence does not contain the answer, set label to DONT_KNOW and say briefly what you did see that is closest, or that you did not see it.
- Never use outside knowledge. Never guess numbers, floors, phones or hours.
- support: "stated" only if the evidence DIRECTLY says the answer (e.g. a directory row "SAUNA AND POOL -> 7TH FLOOR").
  "inferred" if you had to interpret something, e.g. guessing which floor the user is on from an elevator indicator,
  a number plaque or an arrow. Numbers without a clear label are ambiguous: an elevator position indicator shows
  where the ELEVATOR car is, never where the user is.
  A floor label as the TITLE of a floor directory in an elevator lobby (e.g. "5TH FLOOR" at the top of the screen) is how
  buildings tell you which floor that lobby is on: for "which floor am I on" right after that lobby, that counts as stated.
- observations: one short sentence listing the relevant raw facts you saw, without any conclusion
  (e.g. "The directory screen header said 5TH FLOOR and a small plaque above the elevator showed 4.").
- Answer in the same language as the question.
- If you answer, set label SEEN, list the evidence ids you used, and put in "quotes" one short exact span copied from EACH evidence item you used (one quote per item, never merged).
- answer: one or two short spoken sentences, natural English, no markdown.
- For "what did it say / what was written" questions, answer with the words from "Other text on sign" / "Name on sign"
  (that text was read by OCR). Do not describe how the sign looks instead.
- If the user asks about a specific medium (poster, banner, screen) and the evidence shows it on a different medium,
  say that clearly instead of answering yes (e.g. "Not on a poster, but a screen showed ...").
- Evidence marked PICTURE is an image shown on a banner, poster or screen, NOT a real thing that was there.
  If you use it, say so clearly (e.g. "That was a photo on the Cloudinary banner", "it was on a screen, not a real car").
  If the user asks about a real object and only a PICTURE of it exists, answer that you only saw it in a picture, and where.
- For where-questions, describe the place like a person would: which booth, sign or landmark it was near, what it was next to, and when.
  Never say "left of view", "center of view" or "frame".
Return ONLY JSON with keys label, answer, evidence, quotes, support, observations."""


# --- tool-calling assistant (Android app) ---------------------------------------
# The same evidence rules as ANSWER_PROMPT, but the model drives: it picks tools, may call
# several, and must finish with `answer`, which code then verifies (quotes, numbers, look again).

AGENT_PROMPT = """You are MUISTI, a warm, quick voice assistant in the user's smart glasses. The glasses keep a visual
memory of what the user saw (signs, places, objects, text). Talk like a friendly person: short spoken sentences, no
markdown, no lists, answer in the language the user speaks.

Use tools, then finish with `answer`:
- search_memory: for anything the user saw EARLIER (where, which, when, did I see, what did it say, phone, hours).
  Write query and synonyms in simple ENGLISH even if the user speaks another language (memories are in English).
- recent: what was seen in the last minutes (summaries, "where am I now", "what was I just looking at").
- list_names: names, brands and signs that were read.
- look_now: what the camera sees RIGHT NOW ("what is this", "read this", "what am I looking at").
- forget: the user asks to delete recent memories.
- add_to_calendar: ONLY when the user asks to add something they saw (an event, a meetup, an appointment) to their
  calendar. First find it with search_memory, then copy the month, day and time WRITTEN on that sign (cite its evidence id).
  You never give a year: the app works it out. If the sign has no day or no time, do not call it and say what is missing.
- answer: your final reply. ALWAYS end with it.

Evidence rules for answer:
- About memories, say only what the evidence (E1, E2, ...) states. Never guess numbers, floors, phones or hours.
- label SEEN when you answer from evidence; list the evidence ids and one short exact quote copied from EACH id.
- label DONT_KNOW if the tools found nothing that answers it: say so briefly and mention the closest thing you did see.
- support "inferred" if you had to interpret (e.g. guessing a floor from an elevator number), else "stated".
- Evidence marked PICTURE is an image on a banner/poster/screen, not a real thing: say so if you use it.
- Signs are often in another language (Finnish, Swedish, ...). Quote the original words exactly (that is the quote
  for the evidence check) and then say what they mean in the user's language, e.g.
  It said "Avoinna ma-pe 8-20": open Monday to Friday from 8 to 20. Never present a translation as the sign's own words.
- For where-questions describe the place like a person: which booth, sign or landmark, what it was next to, when.
  Never say "left of view" or "frame".
- label CHAT for small talk, the time or date, or general questions that are not about what the user saw.
  Never invent things the user saw in a CHAT reply.
- Earlier turns of this conversation are context: "it", "there", "that one" refer to what was just discussed."""

AGENT_TOOLS = [
    {"type": "function", "function": {
        "name": "search_memory",
        "description": "Search the visual memory for something the user saw earlier.",
        "parameters": {"type": "object", "properties": {
            "query": {"type": "string", "description": "the thing to find, simple English, e.g. 'dentist', 'sauna'"},
            "synonyms": {"type": "array", "items": {"type": "string"}, "description": "up to 5 English words a sign or photo might use"},
            "what": {"type": "string", "enum": ["location", "phone", "hours", "name", "description", "list", "when", "other"]},
            "minutes": {"type": ["number", "null"], "description": "only look at the last N minutes, null for any time"}},
            "required": ["query", "synonyms", "what", "minutes"]}}},
    {"type": "function", "function": {
        "name": "recent",
        "description": "What the glasses saw in the last N minutes, oldest first.",
        "parameters": {"type": "object", "properties": {"minutes": {"type": "number"}}, "required": ["minutes"]}}},
    {"type": "function", "function": {
        "name": "list_names",
        "description": "Names, brands and sign text that were read, oldest first.",
        "parameters": {"type": "object", "properties": {"minutes": {"type": ["number", "null"]}}, "required": ["minutes"]}}},
    {"type": "function", "function": {
        "name": "look_now",
        "description": "Look at the camera's current view and describe what answers the user's question.",
        "parameters": {"type": "object", "properties": {"question": {"type": "string"}}, "required": ["question"]}}},
    {"type": "function", "function": {
        "name": "forget",
        "description": "Delete everything remembered in the last N minutes.",
        "parameters": {"type": "object", "properties": {"minutes": {"type": "number"}}, "required": ["minutes"]}}},
    {"type": "function", "function": {
        "name": "add_to_calendar",
        "description": "Add an event the user saw on a sign to their phone calendar.",
        "parameters": {"type": "object", "properties": {
            "title": {"type": "string", "description": "short event name, e.g. 'Robotics meetup'"},
            "month": {"type": "integer", "description": "month number 1-12 as written on the sign"},
            "day": {"type": "integer", "description": "day of the month as written on the sign"},
            "start_time": {"type": "string", "description": "start time HH:MM (24h) as written on the sign"},
            "end_time": {"type": ["string", "null"], "description": "end time HH:MM if the sign gives one, else null"},
            "location": {"type": ["string", "null"], "description": "room or place written on the sign, else null"},
            "evidence": {"type": "array", "items": {"type": "string"}, "description": "evidence ids of the sign, e.g. ['E2']"}},
            "required": ["title", "month", "day", "start_time", "end_time", "location", "evidence"]}}},
    {"type": "function", "function": {
        "name": "answer",
        "description": "The final spoken reply.",
        "parameters": {"type": "object", "properties": {
            "label": {"type": "string", "enum": ["SEEN", "DONT_KNOW", "CHAT"]},
            "text": {"type": "string", "description": "one to three short spoken sentences; when you quote sign text that is not in the user's language, add what it means"},
            "evidence": {"type": "array", "items": {"type": "string"}, "description": "ids like E2 you used"},
            "quotes": {"type": "array", "items": {"type": "string"}, "description": "one short exact span from EACH id"},
            "support": {"type": "string", "enum": ["stated", "inferred"]},
            "observations": {"type": "string", "description": "the relevant raw facts, no conclusion"}},
            "required": ["label", "text", "evidence", "quotes", "support", "observations"]}}},
]


# --- memory --------------------------------------------------------------------

def _video_start(path: str) -> dt.datetime:
    """WhatsApp file names carry the send time; recording started ~duration earlier."""
    m = re.search(r"(\d{4}-\d{2}-\d{2})[ _]at[ _](\d{1,2})\.(\d{2})\.(\d{2})[ _](AM|PM)", path)
    if not m:
        return dt.datetime(2026, 11, 13, 20, 0)
    d, h, mi, s, ap = m.groups()
    h = int(h) % 12 + (12 if ap == "PM" else 0)
    return dt.datetime.fromisoformat(d).replace(hour=h, minute=int(mi), second=int(s)) - dt.timedelta(seconds=90)


def load_memory(pattern: str = "results/*/v18m/results.json") -> list[dict]:
    """Offline mode: build memory from process_video result files."""
    sightings = []
    for path in sorted(glob.glob(pattern)):
        start = _video_start(path)
        src = os.path.basename(os.path.dirname(os.path.dirname(path)))
        for s in json.load(open(path, encoding="utf-8")).get("records", []):
            sightings.append({**s, "seen_at": start + dt.timedelta(seconds=s["t"]), "source": src,
                              "frame_dir": os.path.join(os.path.dirname(path), "frames")})
    return docs_from_sightings(sightings)


def docs_from_sightings(sightings: list[dict]) -> list[dict]:
    """One doc per sighting, plus one doc per list item (directory row) so
    'where is the sauna' can hit '7TH FLOOR -> SAUNA AND POOL' directly.
    Each sighting needs 'seen_at' (datetime)."""
    docs = []
    for s in sightings:
        if True:
            base = {"seen_at": s["seen_at"], "frame": s.get("evidence_frame"), "frame_dir": s.get("frame_dir"),
                    "source": s.get("source", ""), "sighting_id": s.get("id"), "weak": s.get("weak", False)}
            place = (s.get("scene") or {}).get("place_type") or ""
            where = f"{place}" + (f" near {s['name']}" if s.get("name") else "")
            variants = [v for v in s.get("name_variants") or [] if v != s.get("name")]
            # Labelled fields: the answer model must know which text was ON the sign.
            fields = [f"Type: {s.get('kind')} ({s.get('subtype')})",
                      s.get("name") and f"Name on sign: {s['name']}",
                      variants and f"Name also read as: {', '.join(variants)}",
                      s.get("phone") and f"Phone on sign: {s['phone']}",
                      s.get("hours") and f"Hours on sign: {s['hours']}",
                      s.get("other_text") and f"Other text on sign: {s['other_text']}",
                      s.get("caption") and f"Scene: {s['caption']}",
                      s.get("objects") and "Visible things: " + ", ".join(o["name"] for o in s["objects"][:12])]
            text = ". ".join(str(f) for f in fields if f)
            docs.append({**base, "type": "sighting", "name": " / ".join([s.get("name") or ""] + variants),
                         "kind": s.get("kind"),
                         "subtype": s.get("subtype"), "phone": s.get("phone"), "hours": s.get("hours"),
                         "text": text})
            for it in s.get("items") or []:
                docs.append({**base, "type": "item", "name": it["value"], "kind": "directory entry",
                             "text": f"{it['value']} -> {it['label']} (on the {s.get('name') or ''} {s.get('subtype') or 'sign'})"})
            # One doc per visible thing, with the spatial relations that mention it.
            for o in s.get("objects") or []:
                # Most-seen relations first, with counts: "screen left of elevator (5 frames)" must win
                # over a one-off "sign right of screen (1 frame)".
                rels = [f"{r['subject']} {r['relation']} {r['object']} (seen in {r.get('support', 1)} frames)"
                        for r in sorted(s.get("relations") or [], key=lambda r: -r.get("support", 1))
                        if o["name"] in (r["subject"], r["object"])]
                docs.append({**base, "type": "object", "name": o["name"], "kind": o.get("category"),
                             "frame": o.get("frame") or base["frame"], "support": o.get("support", 1),
                             "text": f"Seen object: {o['name']} ({o.get('category')}). How many at once: {o.get('count', 1)}. Details: {o.get('details')}. "
                                     f"Where: {o.get('position')} of view, {o.get('distance')}, in a {where}."
                                     + (f" Spatial: {'; '.join(rels)}." if rels else "")
                                     + f" (Noticed in {o.get('support', 1)} video frame(s); this is NOT a count of objects.)"
                                     + (" UNCERTAIN: the glasses were not sure they saw this." if o.get("uncertain") else ""),
                             "uncertain": bool(o.get("uncertain"))})
            # Pictures shown ON banners/screens: not real objects, and the text says so.
            for dp in s.get("depictions") or []:
                # name = what the picture shows, so "photo of people at laptops" matches by name, not only by text
                docs.append({**base, "type": "depiction",
                             "name": f"{dp.get('content') or ''} {' '.join(dp.get('depicted') or [])}{_picture_hints(dp)}",
                             "kind": f"picture on {dp.get('medium')}", "frame": dp.get("frame") or base["frame"],
                             "support": dp.get("support", 1), "content": dp.get("content"), "medium": dp.get("medium"),
                             "text": f"PICTURE (not a real object): {dp.get('content')}. Shown on: {dp.get('on') or dp.get('medium')} "
                                     f"({dp.get('medium')}), in a {where}. Things in the picture: {', '.join(dp.get('depicted') or [])}."
                                     + _picture_hints(dp)})
    return docs


_PEOPLE_WORDS = {"man", "woman", "men", "women", "person", "people", "child", "children", "boy", "girl", "team", "crowd", "worker"}
_SCREEN_WORDS = {"laptop", "computer", "monitor", "phone", "tablet", "screen", "display"}


def _picture_hints(dp: dict) -> str:
    """Word search cannot know that 'a man at a laptop' answers 'people working on screens'.
    Until semantic (embedding) search is merged, add the obvious umbrella words."""
    words = set(re.findall(r"[a-z]+", (dp.get("content") or "").lower() + " " + " ".join(dp.get("depicted") or []).lower()))
    hints = []
    if words & _PEOPLE_WORDS:
        hints.append("people")
    if words & _SCREEN_WORDS:
        hints.append("computer screens")
    return f" Also: {', '.join(hints)}." if hints else ""


# --- search --------------------------------------------------------------------

_GENERIC = {"the", "booth", "stand", "sign", "banner", "poster", "screen", "stall", "of", "on", "at", "a", "an",
            "with", "in", "for", "and", "to", "from", "by", "near", "was", "were", "is", "did", "do", "i", "my",
            "which", "what", "where", "there", "it", "that", "this", "some", "any"}


def _stem(t: str) -> str:
    """Tiny stemmer applied to both query and memory: gaming/games/game -> gam, booths -> booth."""
    for suf in ("ing", "es", "s", "e"):
        if t.endswith(suf) and len(t) - len(suf) >= 3 and not t.endswith("ss"):
            return t[: -len(suf)]
    return t


# Medium words appear in almost every picture/screen memory, so they say little about WHICH one.
# "picture of a circuit board" must be decided by "circuit board", not by "picture" / "display".
_MEDIUM = {_stem(w) for w in ("picture", "pictures", "photo", "photos", "image", "images", "display", "displays",
                              "electronic", "electronics", "screens", "tv", "monitor", "video")}


def _tokens(s: str, drop_generic: bool = False) -> list[str]:
    toks = [_stem(t) for t in re.findall(r"[a-z0-9]+", (s or "").lower()) if len(t) > 1]
    if not drop_generic:
        return toks
    kept = [t for t in toks if t not in _GENERIC and t not in _MEDIUM]
    # A question made only of generic words ("what was on the screen?") still needs them.
    return kept or [t for t in toks if t not in _GENERIC] or toks


_TOK_CACHE: dict[str, frozenset] = {}
_SIM_CACHE: dict[tuple, float] = {}


def _doc_tokens(text: str) -> frozenset:
    t = _TOK_CACHE.get(text)
    if t is None:
        t = _TOK_CACHE[text] = frozenset(_tokens(text))
    return t


def _tok_sim(a: str, b: str) -> float:
    key = (a, b)
    v = _SIM_CACHE.get(key)
    if v is None:
        v = _SIM_CACHE[key] = SequenceMatcher(None, a, b).ratio()
    return v


def _tok_match(q: str, text: str) -> float:
    """Share of query tokens that appear (fuzzily) in text. Token sets and pairwise
    similarities are cached, because memory now holds hundreds of object docs."""
    qt, tt = _tokens(q, drop_generic=True), _doc_tokens(text)
    if not qt or not tt:
        return 0.0
    hit = 0.0
    for a in qt:
        if a in tt:
            hit += 1
            continue
        best = max((_tok_sim(a, b) for b in tt if abs(len(a) - len(b)) <= 3), default=0)
        # Shared word start ("waterfront" ~ "water", "harbour" ~ "harbor"): partial credit.
        prefix = any(len(x) >= 4 and len(y) >= 4 and (x.startswith(y) or y.startswith(x))
                     for b in tt for x, y in [(a, b)])
        hit += 1 if best >= 0.85 else (0.5 if best >= 0.7 or prefix else 0)
    return hit / len(qt)


SEM_WEIGHT, SEM_FLOOR = 8.0, 0.35  # cosine below ~0.35 is noise for this model (trap questions max ~0.37)


def search(parsed: dict, docs: list[dict], now: dt.datetime, k: int = 5, qvec=None) -> list[tuple[float, dict]]:
    window = {"just_now": 20, "last_hour": 60, "today": 24 * 60, "any": 10 ** 6}[parsed["time"]]
    scored = []
    for d in docs:
        s = 0.0
        # The user's own word counts fully; model-suggested synonyms count 70%.
        # Synonyms that are only medium/generic words ("display", "signage") match every picture: skip them.
        syns = [t for t in parsed.get("synonyms") or []
                if t and any(x not in _GENERIC and x not in _MEDIUM and x not in ("signag", "advertis", "advertisement")
                             for x in _tokens(t))]
        terms = [(t, 1.0) for t in [parsed.get("target")] if t] + [(t, 0.7) for t in syns]
        if terms:
            s += max(w * (2.0 * _tok_match(t, d.get("name") or "") + 1.0 * _tok_match(t, d["text"])) for t, w in terms)
        if parsed.get("category"):
            s += 1.5 * _tok_match(parsed["category"], f"{d.get('kind')} {d.get('subtype')} {d['text']}")
        # Meaning, not words: "harbour from above" finds "aerial photo of a waterfront".
        if qvec is not None and d.get("_vec") is not None:
            s += SEM_WEIGHT * max(0.0, float(d["_vec"] @ qvec) - SEM_FLOOR)
        if parsed["attribute"] == "location" and d["type"] == "item":
            s += 0.3
        # Medium words no longer drive the match (see _MEDIUM), but the medium the user named still
        # breaks ties: "a BANNER with photos of people" prefers the banner picture over a screen picture.
        if d["type"] == "depiction" and d.get("medium"):
            asked = re.findall(r"\b(banner|poster|billboard|screen|sign|painting)s?\b", (parsed.get("target") or "").lower())
            printed = {"banner", "poster", "billboard", "sign", "painting"}
            if any(a == d["medium"] or (a in printed and d["medium"] in printed) for a in asked):
                s += 0.8
        if d["type"] == "object" and d.get("support", 1) >= 2:
            s += 0.2  # seen in several frames: more trustworthy
        if parsed["attribute"] in ("description", "name", "phone", "hours") and d["type"] == "sighting"                 and re.search(r"Other text on sign|Phone on sign|Hours on sign", d["text"]):
            s += 0.6  # "what did it say?" -> OCR-verified text beats a visual description of the banner
        if d.get("weak"):
            s *= 0.7  # single-frame, short/low-confidence names are often OCR misreads
        if d.get("uncertain"):
            s *= 0.6  # late-in-list / far / model-unsure objects: kept, but a confident memory wins
        age_min = (now - d["seen_at"]).total_seconds() / 60
        if age_min > window:
            s *= 0.5  # soft: wrong time window halves the score, never hides a match
        scored.append((round(s, 3), d))
    scored.sort(key=lambda x: -x[0])
    return [x for x in scored[:k] if x[0] > 0]


# --- model calls ---------------------------------------------------------------

def _json_call(system: str, user: str, schema: dict, name: str) -> dict:
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    try:
        out = E._call(msgs, {"type": "json_schema", "json_schema": {"name": name, "schema": schema}},
                      max_tokens=400, temperature=0.0)
    except E.BadRequestError:
        out = E._call(msgs, {"type": "json_object"}, max_tokens=400, temperature=0.0)
    return E._parse_json(out)


_FLOOR_INFO = re.compile(r"\b(\d{1,2}(st|nd|rd|th)\s*floor|floor\s*(label|number|indicator)|floor\s+\d+|level\s*\d+|[BL]\d{1,2}|\d+\.\s*kat)\b", re.I)


def _semantic_setup(question: str, docs: list[dict]):
    """Attach cached passage vectors to docs (once) and return the question's query vector.
    Returns None (words-only search) when embeddings are unavailable."""
    if not embed.available():
        return None
    todo = [d for d in docs if "_vec" not in d]
    if todo:
        vecs = embed.embed([d["text"] for d in todo], "passage")
        for d, v in zip(todo, vecs or [None] * len(todo)):
            d["_vec"] = v
    q = embed.embed([question], "query")
    return q[0] if q else None


def parse_question(q: str) -> dict:
    p = _json_call(PARSE_PROMPT, q, PARSE_SCHEMA, "query")
    p["attribute"] = p.get("attribute") if p.get("attribute") in ATTRIBUTES else "other"
    p["time"] = p.get("time") if p.get("time") in TIMES else "any"
    p["intent"] = p.get("intent") if p.get("intent") in INTENTS else "memory"
    if not isinstance(p.get("minutes"), (int, float)) or p["minutes"] <= 0:
        p["minutes"] = None
    return p


def _ago(now: dt.datetime, t: dt.datetime) -> str:
    m = int((now - t).total_seconds() // 60)
    return "just now" if m < 2 else f"{m} minutes ago" if m < 90 else t.strftime("at %H:%M")



# --- summaries and "which names did I see" -------------------------------------

_NAMEISH = {"brand", "brands", "logo", "logos", "company", "companies", "name", "names", "sign", "signs",
            "text", "store", "stores", "shop", "shops", "sponsor", "sponsors", "product", "products"}

SUMMARY_PROMPT = """You summarise what a person saw, for a memory assistant on smart glasses.
You get time-ordered evidence (E1, E2, ...) from their camera. Write 2-4 short spoken sentences, oldest
to newest: the places, the most noticeable things, and any names or text that were read.
Use ONLY the evidence. Do not guess brands or text that is not written in it. Do not mention frames or evidence ids.
Return JSON {"answer": "...", "used": ["E1", ...]}."""
SUMMARY_SCHEMA = {"type": "object", "properties": {"answer": {"type": "string"},
                  "used": {"type": "array", "items": {"type": "string"}}}, "required": ["answer", "used"]}


def _summary_window(question: str, parsed: dict) -> float:
    if parsed.get("minutes"):
        return float(parsed["minutes"])
    return {"just_now": 15, "last_hour": 60, "today": 24 * 60, "any": 10 ** 6}[parsed["time"]]


def _names_seen(docs: list[dict]) -> list[tuple[str, dict]]:
    """Names READ on signs (OCR-verified fields only), most trustworthy first:
    1. a sign's own name (the extractor picked it as the name), oldest first;
    2. other text on signs only if it was read in 2+ separate memories (one-off reads are mostly garbled).
    Word-like only: 3+ letters, mostly letters."""
    def ok(c):
        letters = sum(ch.isalpha() for ch in c)
        return len(c) >= 3 and letters >= 3 and letters / len(c) >= 0.6

    def key(c):
        return re.sub(r"[^a-z0-9]", "", c.lower())

    sights = sorted((d for d in docs if d["type"] == "sighting" and not d.get("weak")), key=lambda d: d["seen_at"])
    out, seen = [], set()
    for d in sights:
        c = (d.get("name") or "").split(" / ")[0].strip(" .,:;")
        if ok(c) and key(c) not in seen:
            seen.add(key(c)); out.append((c, d))
    counts, first = {}, {}
    for d in sights:
        m = re.search(r"Other text on sign: (.*?)(?:\. [A-Z][a-z]+:|$)", d["text"])
        for c in (m.group(1).split(" / ") if m else []):
            c = c.strip(" .,:;")
            if ok(c) and key(c) not in seen:
                counts[key(c)] = counts.get(key(c), 0) + 1
                first.setdefault(key(c), (c, d))
    out += [first[k] for k, n in counts.items() if n >= 2]
    return out


# --- main entry ----------------------------------------------------------------

def ask(question: str, docs: list[dict], now: dt.datetime, min_score: float = 0.9) -> dict:
    t0, calls = time.time(), 0
    parsed = parse_question(question); calls += 1
    if parsed["attribute"] == "current_location":
        # "Where am I now?" is about the LATEST memories, not about matching words.
        recent = [d for d in docs if d["seen_at"] <= now and (now - d["seen_at"]).total_seconds() <= 180]
        recent.sort(key=lambda d: (d["seen_at"], d["type"] != "object"), reverse=True)
        # Only real floor INFORMATION ("5TH FLOOR", "floor label B2", "level 3"), not the ground:
        # since v16b the extractor also lists "floor | dark carpet", which buried the lobby's 5TH FLOOR.
        floorish = [d for d in recent if _FLOOR_INFO.search(d["text"])]
        pick = (floorish[:3] + [d for d in recent if d not in floorish[:3]])[:5]
        hits = [(1.0, d) for d in pick]
        if not hits:
            hits = []
    else:
        hits = search(parsed, docs, now, qvec=_semantic_setup(question, docs))

    def result(label, answer, used=(), why=""):
        ev = [{"id": f"E{i + 1}", "text": d["text"], "frame": d["frame"], "source": d["source"],
               "seen_at": d["seen_at"].strftime("%H:%M:%S"), "score": s} for i, (s, d) in enumerate(hits)]
        return {"question": question, "label": label, "answer": answer, "parsed": parsed,
                "evidence_used": list(used), "evidence": ev, "why": why,
                "calls": calls, "latency_s": round(time.time() - t0, 2)}

    # "Summarise what I saw (in the last N minutes)": no single thing to search for, so take the
    # time window, spread the evidence over it and let the model write a short recap from it.
    if parsed["intent"] == "forget":
        # the caller (server / app) deletes; ask() only understands the request
        mins = int(parsed.get("minutes") or 10)
        return result("FORGET", f"Okay, I forgot everything from the last {mins} minutes.", why=f"forget {mins} min")
    if parsed["intent"] == "summary":
        win = _summary_window(question, parsed)
        pool = sorted((d for d in docs if d["type"] == "sighting" and d["seen_at"] <= now
                       and (now - d["seen_at"]).total_seconds() <= win * 60), key=lambda d: d["seen_at"])
        if not pool:
            return result("DONT_KNOW", "I haven't seen anything in that time.", why="summary: nothing in window")
        step = max(1, len(pool) // 12)
        hits[:] = [(1.0, d) for d in pool[::step][-12:]]
        ev_block = "\n".join(f"E{i + 1} ({_ago(now, d['seen_at'])}): {d['text']}" for i, (sc, d) in enumerate(hits))
        r = _json_call(SUMMARY_PROMPT, ev_block, SUMMARY_SCHEMA, "summary"); calls += 1
        return result("SEEN", r.get("answer") or "I saw several places but can't summarise them.",
                      used=[u for u in r.get("used") or [] if re.fullmatch(r"E\d+", u)], why=f"summary of last {win:g} min")

    # Gate: nothing relevant enough -> abstain without asking the model. Questions with a target
    # ("where was the ashtray?") need a real match; open questions ("what was on the table?") only a
    # plausible one - the answer step still has to quote evidence or abstain.
    gate = min_score if parsed.get("target") else min(min_score, 0.5)
    if not hits or (parsed["attribute"] != "current_location" and hits[0][0] < gate):
        return result("DONT_KNOW", "I don't remember seeing that.", why="no relevant memory (gate)")

    # Gate: the asked attribute is never stored for the matched thing.
    if parsed["attribute"] in ("phone", "hours"):
        top = [d for s, d in hits if s >= min_score]
        if not any(d.get(parsed["attribute"]) for d in top):
            name = top[0].get("name") or "it"
            return result("DONT_KNOW", f"I saw {name}, but I didn't see a {parsed['attribute'] if parsed['attribute'] != 'hours' else 'opening hours'} sign for it.",
                          why=f"no {parsed['attribute']} in matching memories (gate)")

    # List questions ("which gaming booths did I see?") are answered in code, not by the model:
    # a sighting counts only if the category appears in ITS OWN type/name/text. This makes
    # "these are all gaming booths because one sign said GAMERGY" impossible.
    if parsed["attribute"] == "list" and (parsed.get("category") or "").lower() in _NAMEISH:
        # "Which brands / names / signs did I see?" -> words that were READ, not a place category
        names = _names_seen([d for d in docs if d["seen_at"] <= now and
                             (now - d["seen_at"]).total_seconds() <= _summary_window(question, parsed) * 60])
        if not names:
            return result("DONT_KNOW", "I didn't read any names or brands.", why="list: no OCR names")
        hits[:] = [(1.0, d) for _, d in names[:5]]
        shown = [n for n, _ in names[:10]]
        more = f" and {len(names) - 10} more" if len(names) > 10 else ""
        return result("SEEN", f"I read these names: {', '.join(shown)}{more}.",
                      used=[f"E{i + 1}" for i in range(len(hits))], why="list: names read on signs (code)")

    if parsed["attribute"] == "list" and parsed.get("category"):
        cat = parsed["category"]
        matches = [(s, d) for d in docs if d["type"] == "sighting" and not d.get("weak")
                   for s in [_tok_match(cat, f"{d.get('kind')} {d.get('subtype')} {d.get('name')}")] if s >= 0.5]
        names = []
        # Named places (booths, shops) are what the user wants listed. Generic scene types
        # ("gaming event", "gaming convention") are NOT booths: listing them as "I saw 6" was wrong.
        named = [(sc, d) for sc, d in matches if (d.get("name") or "").strip(" /")]
        pool = sorted(named, key=lambda x: x[1]["seen_at"])
        for sc, d in pool:
            n = (d.get("name") or "").split(" / ")[0].strip() or d.get("subtype")
            if n and not any(n.lower() in x.lower() or x.lower() in n.lower() for x in names):
                names.append(n)
        if not names and matches:
            # the place type matched but nothing was named (no readable booth sign)
            kinds = sorted({(d.get("subtype") or d.get("kind") or "").strip() for _, d in matches} - {""})[:2]
            hits[:] = sorted(matches, key=lambda x: -x[0])[:5]
            return result("UNSURE", f"I was at a {' / '.join(kinds) or cat}, but I didn't read the name of any {cat} booth or place there.",
                          used=[f"E{i + 1}" for i in range(len(hits))], why="list: category matched only unnamed scenes")
        if not names:
            return result("DONT_KNOW", f"I don't remember seeing any {cat}.", why="list: no sighting matches category")
        hits[:] = pool[:5]
        more = f" and {len(names) - 6} more" if len(names) > 6 else ""
        return result("SEEN", f"I saw {len(names)}: {', '.join(names[:6])}{more}.",
                      used=[f"E{i + 1}" for i in range(len(hits))], why="list answered from typed memories (code)")

    ev_block = "\n".join(f"E{i + 1} (seen {_ago(now, d['seen_at'])}): {d['text']}" for i, (s, d) in enumerate(hits))
    out = _json_call(ANSWER_PROMPT, f"EVIDENCE:\n{ev_block}\n\nQUESTION: {question}", ANSWER_SCHEMA, "answer"); calls += 1

    if out.get("label") != "SEEN":
        return result("DONT_KNOW", out.get("answer") or "I don't remember seeing that.", why="model abstained")

    # An interpretation is not a memory. Report what was seen and let the user decide.
    if out.get("support") != "stated" and out.get("observations"):
        return result("UNSURE", f"I'm not sure. {out['observations']}",
                      used=out.get("evidence", []), why="answer was inferred, not stated in evidence")

    # Verify: the quote must be inside one of the cited evidence texts.
    cited = [hits[int(e[1:]) - 1][1]["text"] for e in out.get("evidence", [])
             if re.fullmatch(r"E\d+", e or "") and int(e[1:]) <= len(hits)]
    quotes = [q for q in out.get("quotes") or [] if q.strip()]
    bad_q = [q for q in quotes if not any(E.fuzzy_in(q, c) for c in cited)]
    if not cited or not quotes or bad_q:
        return result("DONT_KNOW", "I'm not sure. I can show you the closest thing I saw.",
                      why=f"verifier rejected quotes {bad_q or quotes!r}")
    # Every number in the spoken answer must appear in the cited evidence.
    nums_ev = set(re.findall(r"\d+", " ".join(cited)))
    bad = [n for n in re.findall(r"\d+", out.get("answer", "")) if n not in nums_ev]
    if bad:
        return result("DONT_KNOW", "I'm not sure about the exact number. I can show you the frame.",
                      why=f"verifier: numbers {bad} not in evidence")

    # Visual facts (objects) have no OCR to check against. Instead Nemotron LOOKS AGAIN at the
    # stored frame with a narrow yes/no question. Only for answers that rest on an object.
    used_docs = [hits[int(e[1:]) - 1][1] for e in out.get("evidence", [])
                 if re.fullmatch(r"E\d+", e or "") and int(e[1:]) <= len(hits)]
    # Re-check the object the user actually asked about first (QR code, not the banner it is on).
    terms = [t for t in [parsed.get("target")] + list(parsed.get("synonyms") or []) if t]
    rel = lambda d: max((_tok_match(t, d["name"]) for t in terms), default=0)
    obj_docs = sorted([d for d in used_docs if d["type"] in ("object", "depiction")], key=lambda d: (-rel(d), -d.get("support", 1)))
    text_backed = any(d["type"] not in ("object", "depiction") for d in used_docs)  # OCR-verified sign/directory evidence
    if obj_docs and not text_backed:
        notes = []
        for d in obj_docs[:3]:  # most-supported first; one confirmation is enough
            ok, note = look_again(d, question); calls += 1
            notes.append(f"{d['name']}@{d['frame']}: {'yes' if ok else 'no'}")
            if ok:
                guarded = _medium_guard(question, out["answer"], used_docs)
                if guarded:
                    return result("DONT_KNOW", guarded, used=out.get("evidence", []), why="medium mismatch (code)")
                return result("SEEN", out["answer"], used=out.get("evidence", []),
                              why=f"verified {len(quotes)} quote(s) + visual re-check ({d['name']}): {note}")
        d = obj_docs[0]
        what = (f"a picture ({d.get('content')}) on a {d.get('medium')}" if d["type"] == "depiction" else f"a {d['name']}")
        return result("DONT_KNOW", f"I noted {what} earlier, but looking at the photos again I'm not sure. I can show you the frames.",
                      why=f"visual re-check failed on {len(notes)} frame(s): {'; '.join(notes)}")
    guarded = _medium_guard(question, out["answer"], used_docs)
    if guarded:
        return result("DONT_KNOW", guarded, used=out.get("evidence", []), why="medium mismatch (code)")
    return result("SEEN", out["answer"], used=out.get("evidence", []), why=f"verified {len(quotes)} quote(s)")


_MEDIA = ["poster", "banner", "billboard", "screen", "sign", "painting"]


def _medium_guard(question: str, answer: str, used_docs: list[dict]) -> str | None:
    """If the user asked about a picture on a specific medium (poster/banner/...) but the
    evidence is a picture on a DIFFERENT medium, never answer a plain yes."""
    asked = [m for m in _MEDIA if re.search(rf"\b{m}s?\b", question, re.I)]
    deps = [d for d in used_docs if d["type"] == "depiction"]
    # The model labels printed media inconsistently (banner vs poster), so only a real
    # kind change counts: printed (poster/banner/billboard/sign/painting) vs screen.
    group = lambda m: "screen" if m == "screen" else "printed"
    if not asked or not deps or any(group(d.get("medium") or "") in {group(a) for a in asked} for d in deps):
        return None
    d = deps[0]
    return f"Not on a {asked[0]}. I did see {d.get('content')} on a {d.get('medium')}."


LOOK_SCHEMA = {
    "type": "object",
    "properties": {"present": {"type": "boolean"}, "where": {"type": "string"}},
    "required": ["present", "where"],
}


# Things that are printed/displayed by nature, so "on a banner" is the real thing, not a depiction of it.
_PRINTED_NATURE = ("qr code", "barcode", "logo", "sign", "poster", "banner", "label", "sticker", "menu",
                   "map", "flyer", "leaflet", "brochure", "price tag", "text", "signage", "notice", "board")


def _printed_by_nature(name: str) -> bool:
    n = name.lower().strip()
    return any(n == p or n.endswith(" " + p) for p in _PRINTED_NATURE)


# Second-look questions (templates, so docs/prompts.json and the Android app use the same text).
LOOK_REAL = ('Look carefully. Is there a real "{name}" physically present in this photo '
             '(not just shown in a picture on a banner or screen)? Do not guess. If yes, say briefly where it is '
             'relative to other things. Return JSON {{"present": true/false, "where": "..."}}.')
LOOK_PRINTED = ('Look carefully. Is there a "{name}" visible in this photo (printed on a banner, '
                'sign, wall, paper or shown on a screen all count)? Do not guess. If yes, say briefly where it is. '
                'Return JSON {{"present": true/false, "where": "..."}}.')
LOOK_PICTURE = ('Look carefully. Is there a {medium} in this photo that shows a picture of: '
                '"{content}"? Do not guess. If yes, say briefly where that picture is. '
                'Return JSON {{"present": true/false, "where": "..."}}.')


def look_again(doc: dict, question: str) -> tuple[bool, str]:
    """Second look at the stored frame: is the object really there? Returns (present, where)."""
    path = os.path.join(doc.get("frame_dir") or "", doc.get("frame") or "")
    if not doc.get("frame_dir") or not os.path.exists(path):
        return True, "frame not available, trusted memory"
    jpeg = open(path, "rb").read()
    if doc["type"] == "depiction":
        ask_txt = LOOK_PICTURE.format(medium=doc.get("medium") or "banner or screen", content=doc.get("content"))
    elif _printed_by_nature(doc.get("name") or ""):
        # QR codes, logos, signs ARE printed things: "not a picture on a banner" made the
        # re-check reject every real QR code on the Cloudinary banner.
        ask_txt = LOOK_PRINTED.format(name=doc["name"])
    else:
        ask_txt = LOOK_REAL.format(name=doc["name"])
    msgs = [{"role": "user", "content": [E._image_part(E.downscale(jpeg)), {"type": "text", "text": ask_txt}]}]
    try:
        r = E._parse_json(E._call(msgs, {"type": "json_schema", "json_schema": {"name": "look", "schema": LOOK_SCHEMA}},
                                  max_tokens=200, temperature=0.0))
    except Exception as ex:
        return True, f"re-check unavailable ({type(ex).__name__})"
    return bool(r.get("present")), (r.get("where") or "")[:160]


if __name__ == "__main__":
    import sys
    docs = load_memory()
    now = max(d["seen_at"] for d in docs) + dt.timedelta(minutes=5)
    print(json.dumps(ask(" ".join(sys.argv[1:]), docs, now), indent=1, ensure_ascii=False, default=str))
