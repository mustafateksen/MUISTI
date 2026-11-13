import os
from contextlib import asynccontextmanager
from datetime import timedelta
from uuid import UUID, uuid5, NAMESPACE_URL
from hashlib import sha256
from datetime import timezone

import httpx
from fastapi import FastAPI, HTTPException, Response
from pydantic import AwareDatetime, Base64Bytes, BaseModel, Field, AliasChoices
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool
from sentence_transformers import SentenceTransformer

from .evidence import choose_floor, format_sources, read_choice


@asynccontextmanager
async def lifespan(app):
    app.state.encoder = SentenceTransformer("intfloat/multilingual-e5-small")
    with ConnectionPool(os.environ["DATABASE_URL"], min_size=1, max_size=4) as pool:
        pool.wait()
        app.state.pool = pool
        yield


app = FastAPI(lifespan=lifespan)


class Line(BaseModel):
    text: str = Field(min_length=1, max_length=2048)
    confidence: float = Field(ge=0, le=1)
    box: tuple[float, float, float, float]


class Capture(BaseModel):
    capture_id: UUID | None = None
    seen_at: AwareDatetime
    lat: float | None = None
    lon: float | None = None
    heading: float | None = None
    street: str | None = None
    ocr_text: str = ""
    lines: list[Line] = Field(default_factory=list, max_length=256)
    frame_jpeg_b64: Base64Bytes = Field(validation_alias=AliasChoices(
        "frame_jpeg_b64", "blurred_thumbnail_jpeg_b64"))


class Question(BaseModel):
    question: str = Field(min_length=1, max_length=1000)
    now: AwareDatetime
    window_minutes: int = Field(default=15, ge=1, le=1440)


def vector(text):
    values = app.state.encoder.encode(text, normalize_embeddings=True)
    return "[" + ",".join(str(float(v)) for v in values) + "]"


@app.post("/ingest")
def ingest(capture: Capture):
    lines = [line.model_dump() for line in capture.lines]
    raw = capture.ocr_text or "\n".join(line.text for line in capture.lines)
    if not raw.strip():
        raise HTTPException(422, "No OCR text in capture")
    if not lines:
        lines = [{"text": text.strip()} for text in raw.splitlines() if text.strip()]
    thumb = capture.frame_jpeg_b64
    if not thumb.startswith(b"\xff\xd8"):
        raise HTTPException(422, "Expected a redacted JPEG")
    instant = capture.seen_at.astimezone(timezone.utc).isoformat()
    key = capture.capture_id or uuid5(NAMESPACE_URL, instant + sha256(thumb).hexdigest())
    with app.state.pool.connection() as conn:
        prior = conn.execute("SELECT memory_id FROM memories WHERE capture_id=%s", (key,)).fetchone()
    if prior:
        return {"memory_id": prior[0]}
    embedding = vector("passage: " + raw)
    with app.state.pool.connection() as conn:
        row = conn.execute(
            "INSERT INTO memories (capture_id, seen_at, lat, lon, heading, street, ocr_text, "
            "lines, embedding, thumbnail) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s::vector,%s) "
            "ON CONFLICT (capture_id) DO NOTHING RETURNING memory_id",
            (key, capture.seen_at, capture.lat, capture.lon, capture.heading, capture.street,
             raw, Jsonb(lines), embedding, thumb),
        ).fetchone()
        if row is None:
            row = conn.execute("SELECT memory_id FROM memories WHERE capture_id=%s", (key,)).fetchone()
    return {"memory_id": row[0]}


@app.get("/frames/{key}")
def frame(key: int):
    with app.state.pool.connection() as conn:
        row = conn.execute("SELECT thumbnail FROM memories WHERE memory_id=%s", (key,)).fetchone()
    if not row:
        raise HTTPException(404)
    return Response(bytes(row[0]), media_type="image/jpeg")


@app.post("/ask")
def ask(q: Question):
    unknown = {"answer": "I couldn't verify that from the signs.", "label": "BILMIYORUM", "sources": [], "evidence": []}
    embedding = vector("query: " + q.question)
    with app.state.pool.connection() as conn:
        rows = conn.execute(
            "SELECT memory_id, seen_at, lines FROM memories WHERE seen_at > %s AND seen_at <= %s "
            "ORDER BY embedding <=> %s::vector LIMIT 5",
            (q.now - timedelta(minutes=q.window_minutes), q.now, embedding),
        ).fetchall()
    sources = format_sources(rows)
    if not sources:
        return unknown
    choice = choose_floor(q.question, sources)
    if choice is None and os.getenv("NVIDIA_MODEL") and os.getenv("NVIDIA_API_KEY"):
        try:
            choice = read_choice(q.question, sources)
        except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError):
            return unknown
    if choice is None:
        return unknown
    src = sources[choice]
    return {"answer": src["text"], "label": "GORDUM", "sources": [], "evidence": [src]}
