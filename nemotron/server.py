"""MUISTI server.

Run:  uvicorn server:app --host 0.0.0.0 --port 8000
Demo: open http://localhost:8000/

Endpoints (contract from the team plan, section 05):
  POST /ingest   phone -> server: one frame (+ OCR from Apple Vision when available)
  POST /ask      phone -> server: question -> answer + label + evidence
  POST /forget   "forget the last N minutes"
  GET  /memories merged sightings (for the phone's source screen / timeline)
  GET  /frames/{id}.jpg   evidence frame
  GET  /stats

Env:
  STANDIN_OCR=1   if a frame arrives without OCR, use Nemotron as OCR (default 1 until Apple Vision lands)
  DEMO_CLOCK=latest   'now' defaults to (latest memory + 2 min) so replayed videos behave like live
  MUISTI_DB / MUISTI_FRAMES   storage paths
"""
import base64
import datetime as dt
import os
import re
import time

import cv2
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import ask as A
import extract as E
from ocr_adapter import vision_to_lines
from store import SqliteStore

STANDIN_OCR = os.environ.get("STANDIN_OCR", "1") == "1"
DEMO_CLOCK = os.environ.get("DEMO_CLOCK", "latest")
HERE = os.path.dirname(os.path.abspath(__file__))

store = SqliteStore(os.environ.get("MUISTI_DB", "data/muisti.db"),
                    os.environ.get("MUISTI_FRAMES", "data/frames"))
app = FastAPI(title="MUISTI")
LABEL_TR = {"SEEN": "GORDUM", "WEB": "WEBDEN", "DONT_KNOW": "BILMIYORUM", "UNSURE": "EMIN_DEGILIM"}


class Observation(BaseModel):
    text: str
    conf: float = 1.0
    box: list[float] = [0, 0, 0, 0]


class IngestIn(BaseModel):
    frame_jpeg_b64: str
    seen_at: str | None = None
    lat: float | None = None
    lon: float | None = None
    heading: float | None = None
    street: str | None = None
    ocr_text: str | None = None              # plain text, one line per row
    ocr_observations: list[Observation] | None = None   # raw Apple Vision output


class AskIn(BaseModel):
    question: str
    now: str | None = None
    lat: float | None = None
    lon: float | None = None


class ForgetIn(BaseModel):
    minutes: float = 10
    now: str | None = None


def _dhash(jpeg: bytes) -> int | None:
    img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return None
    small = cv2.resize(img, (9, 8), interpolation=cv2.INTER_AREA)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    return int("".join("1" if b else "0" for b in bits), 2)


def _now(s: str | None) -> dt.datetime:
    if s:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).replace(tzinfo=None)
    if DEMO_CLOCK == "latest" and store.latest_time():
        return store.latest_time() + dt.timedelta(minutes=2)
    return dt.datetime.now()


@app.post("/ingest")
def ingest(body: IngestIn):
    t0 = time.time()
    try:
        raw = base64.b64decode(body.frame_jpeg_b64)
    except Exception:
        raise HTTPException(400, "frame_jpeg_b64 is not valid base64")
    # Face blur is done on the phone (teammate). Server stores and sends frames as received.
    jpeg = raw

    if body.ocr_observations:
        lines, ocr_src = vision_to_lines([o.model_dump() for o in body.ocr_observations]), "apple_vision"
    elif body.ocr_text:
        lines, ocr_src = [l for l in body.ocr_text.splitlines() if l.strip()], "client_text"
    elif STANDIN_OCR:
        lines, ocr_src = E.ocr(jpeg), "nemotron_standin"
    else:
        lines, ocr_src = [], "none"

    if not lines and not E.SCENE_MODE:
        return {"stored": False, "reason": "no text in frame", 
                "ocr_source": ocr_src, "latency_s": round(time.time() - t0, 2)}

    record = E.extract(jpeg, lines)
    if not record.get("useful"):
        return {"stored": False, "reason": "no useful information", 
                "ocr_source": ocr_src, "rejected": record.get("rejected"), "latency_s": round(time.time() - t0, 2)}

    seen_at = _now(body.seen_at) if body.seen_at else dt.datetime.now()
    fid = store.add_frame(seen_at, record, lines, jpeg, _dhash(jpeg),
                          body.lat, body.lon, body.heading, body.street)
    return {"stored": True, "memory_id": fid, "ocr_source": ocr_src,
            "record": {k: record.get(k) for k in ("kind", "subtype", "name", "phone", "hours", "items", "other_text",
                                                  "scene", "objects", "relations", "depictions", "caption")},
            "rejected": record.get("rejected"), "latency_s": round(time.time() - t0, 2)}


_FORGET_RE = re.compile(r"\bforget\b.*?\b(?:last|past)\s+(\d+|a|an|one|ten|five|fifteen|thirty)?\s*(minute|minutes|min|hour|hours)\b", re.I)
_WORDS = {"a": 1, "an": 1, "one": 1, "five": 5, "ten": 10, "fifteen": 15, "thirty": 30}


@app.post("/ask")
def ask_ep(body: AskIn):
    now = _now(body.now)
    m = _FORGET_RE.search(body.question)
    if m:  # voice command: "forget the last 10 minutes"
        n = m.group(1) or "1"
        n = int(n) if n.isdigit() else _WORDS.get(n.lower(), 1)
        minutes = n * (60 if m.group(2).lower().startswith("hour") else 1)
        deleted = store.forget(now - dt.timedelta(minutes=minutes))
        return {"answer": f"Okay, I forgot everything from the last {minutes} minutes.",
                "label": "FORGOT", "label_tr": "UNUTTUM", "deleted_frames": deleted, "evidence": [], "sources": []}

    docs = A.docs_from_sightings(store.sightings())
    if not docs:
        return {"answer": "I haven't seen anything yet.", "label": "DONT_KNOW", "label_tr": "BILMIYORUM",
                "evidence": [], "sources": []}
    r = A.ask(body.question, docs, now)
    by_frame = {s.get("evidence_frame"): s for s in store.sightings()}
    used = set(r["evidence_used"])
    evidence = []
    for e in r["evidence"]:
        s = by_frame.get(e["frame"]) or {}
        evidence.append({"id": e["id"], "used": e["id"] in used, "memory_id": s.get("id"),
                         "frame_url": f"/frames/{e['frame']}", "seen_at": e["seen_at"],
                         "lat": s.get("lat"), "lon": s.get("lon"), "text": e["text"], "score": e["score"]})
    if r["label"] in ("SEEN", "UNSURE"):
        evidence = [e for e in evidence if e["used"]] or evidence[:1]
    return {"answer": r["answer"], "label": r["label"], "label_tr": LABEL_TR[r["label"]],
            "evidence": evidence, "sources": [], "parsed": r["parsed"], "why": r["why"],
            "calls": r["calls"], "latency_s": r["latency_s"], "now": now.isoformat()}


@app.post("/forget")
def forget(body: ForgetIn):
    now = _now(body.now)
    return {"deleted_frames": store.forget(now - dt.timedelta(minutes=body.minutes))}


@app.get("/memories")
def memories():
    out = []
    for s in store.sightings():
        out.append({"id": s["id"], "seen_at": s["seen_at"].isoformat(), "kind": s.get("kind"),
                    "subtype": s.get("subtype"), "name": s.get("name"), "name_variants": s.get("name_variants"),
                    "phone": s.get("phone"), "hours": s.get("hours"), "items": s.get("items"),
                    "other_text": s.get("other_text"), "caption": s.get("caption"), "weak": s.get("weak"),
                    "scene": s.get("scene"), "objects": s.get("objects"), "relations": s.get("relations"),
                    "depictions": s.get("depictions"),
                    "frames": len(s.get("frames") or []), "frame_url": f"/frames/{s.get('evidence_frame')}",
                    "lat": s.get("lat"), "lon": s.get("lon")})
    return out


@app.get("/frames/{name}")
def frame(name: str):
    if not re.fullmatch(r"\d+\.jpg", name):
        raise HTTPException(404)
    path = os.path.join(store.frame_dir, name)
    if not os.path.exists(path):
        raise HTTPException(404)
    return FileResponse(path, media_type="image/jpeg")


@app.get("/stats")
def stats():
    return {**store.stats(), "standin_ocr": STANDIN_OCR, "model": E.MODEL}


@app.get("/")
def index():
    return FileResponse(os.path.join(HERE, "static", "index.html"))


app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")
