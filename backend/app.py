import logging
import os
from time import perf_counter
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
from .embedding import vector

from .evidence import choose_floor, format_sources, read_choice


@asynccontextmanager
async def lifespan(app):
    headers = {"Authorization": "Bearer " + os.environ["NVIDIA_EMBED_API_KEY"]}
    with httpx.Client(headers=headers, timeout=30) as client:
        app.state.embedding_client = client
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
    embedding = vector(app.state.embedding_client, raw, "passage")
    with app.state.pool.connection() as conn:
        row = conn.execute(
            "INSERT INTO memories (capture_id, seen_at, lat, lon, heading, street, ocr_text, "
            "lines, nemotron_35_1b_embedding, thumbnail) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s::vector,%s) "
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
    start = perf_counter()
    ids = []
    selected = None
    outcome = "embedding_error"
    try:
        embedding = vector(app.state.embedding_client, q.question, "query")
        outcome = "retrieval_error"
        with app.state.pool.connection() as conn:
            rows = conn.execute(
                "SELECT memory_id, seen_at, lines FROM memories WHERE seen_at > %s AND seen_at <= %s "
                "ORDER BY nemotron_35_1b_embedding <=> %s::vector LIMIT 5",
                (q.now - timedelta(minutes=q.window_minutes), q.now, embedding),
            ).fetchall()
        ids = [row[0] for row in rows]
        sources = format_sources(rows)
        if not sources:
            outcome = "no_candidates"
            return unknown
        choice = choose_floor(q.question, sources)
        outcome = "rule_selected"
        if choice is None:
            if not (os.getenv("NVIDIA_MODEL") and os.getenv("NVIDIA_API_KEY")):
                outcome = "model_unconfigured"
                return unknown
            try:
                choice = read_choice(q.question, sources)
            except httpx.TimeoutException:
                outcome = "model_timeout"
                return unknown
            except httpx.HTTPStatusError as exc:
                outcome = f"model_http_{exc.response.status_code}"
                return unknown
            except httpx.HTTPError:
                outcome = "model_connection_error"
                return unknown
            except (ValueError, KeyError, IndexError, TypeError, AttributeError):
                outcome = "invalid_model_response"
                return unknown
            if choice is None:
                outcome = "model_no_evidence"
                return unknown
            outcome = "model_selected"
        src = sources[choice]
        selected = src["memory_id"]
        return {"answer": src["text"], "label": "GORDUM", "sources": [], "evidence": [src]}
    finally:
        logging.getLogger("uvicorn.error").info(
            "ask outcome=%s candidates=%s selected=%s elapsed_ms=%.1f",
            outcome, ids, selected, (perf_counter() - start) * 1000,
        )
