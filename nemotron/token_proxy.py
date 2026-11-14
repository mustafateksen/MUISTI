"""Token proxy: the Verda key stays on this server, the phone app never ships it.

Flow
  1. Pair once: the user types the pairing code shown by the server (env MUISTI_PAIR_CODE) into the app.
     POST /proxy/pair {"device_id", "code"} -> {"device_secret"}   (HMAC of the device id; stored on the phone)
  2. Short-lived token: POST /proxy/token {"device_id", "device_secret"} -> {"token", "expires_in"} (default 1 h)
  3. Calls: the app uses the proxy as its base URL with "Authorization: Bearer <token>":
       POST /proxy/llm/v1/chat/completions   -> muisti-nemotron
       POST /proxy/retrieval/v2/embed        -> muisti-retrieval
       POST /proxy/retrieval/classify        -> muisti-retrieval
     The body is forwarded unchanged; the server adds the real key. Nothing is stored (no memories, no images).

Env
  VERDA_INFERENCE_KEY   the real key (required for forwarding)
  MUISTI_PAIR_CODE      pairing code (if unset, pairing is disabled)
  MUISTI_TOKEN_SECRET   HMAC secret for device secrets and tokens (required; keep it stable across restarts)
  MUISTI_TOKEN_TTL      token lifetime in seconds (default 3600)
  MUISTI_REVOKED        comma-separated device ids that may no longer get tokens
"""
import base64
import hashlib
import hmac
import json
import os
import time

import httpx
from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel

LLM_BASE = os.environ.get("MUISTI_LLM_BASE", "https://containers.datacrunch.io/muisti-nemotron")
RETRIEVAL_BASE = os.environ.get("MUISTI_RETRIEVAL_BASE", "https://containers.datacrunch.io/muisti-retrieval")
ALLOWED = {
    ("llm", "v1/chat/completions"), ("llm", "v1/models"),
    ("retrieval", "v2/embed"), ("retrieval", "classify"), ("retrieval", "v1/models"),
}

router = APIRouter(prefix="/proxy")
_client: httpx.AsyncClient | None = None   # one shared client (HTTP/2 not required here)


def _secret() -> bytes:
    s = os.environ.get("MUISTI_TOKEN_SECRET", "")
    if len(s) < 16:
        raise HTTPException(503, "proxy not configured (MUISTI_TOKEN_SECRET)")
    return s.encode()


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def device_secret(device_id: str) -> str:
    return _b64(hmac.new(_secret(), b"device:" + device_id.encode(), hashlib.sha256).digest())


def make_token(device_id: str, now: float | None = None, ttl: int | None = None) -> str:
    exp = int((now or time.time()) + (ttl or int(os.environ.get("MUISTI_TOKEN_TTL", "3600"))))
    payload = _b64(json.dumps({"d": device_id, "e": exp}, separators=(",", ":")).encode())
    sig = _b64(hmac.new(_secret(), b"token:" + payload.encode(), hashlib.sha256).digest())
    return f"{payload}.{sig}"


def check_token(token: str, now: float | None = None) -> str:
    """Returns the device id, or raises 401."""
    try:
        payload, sig = token.split(".")
        good = _b64(hmac.new(_secret(), b"token:" + payload.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, good):
            raise ValueError("signature")
        d = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(401, "bad token")
    if d["e"] < (now or time.time()):
        raise HTTPException(401, "token expired")
    if d["d"] in _revoked():
        raise HTTPException(401, "device revoked")
    return d["d"]


def _revoked() -> set[str]:
    return {x.strip() for x in os.environ.get("MUISTI_REVOKED", "").split(",") if x.strip()}


class PairIn(BaseModel):
    device_id: str
    code: str


class TokenIn(BaseModel):
    device_id: str
    device_secret: str


@router.post("/pair")
def pair(body: PairIn):
    code = os.environ.get("MUISTI_PAIR_CODE", "")
    if not code:
        raise HTTPException(403, "pairing disabled")
    if not (4 <= len(body.device_id) <= 128) or not hmac.compare_digest(body.code.strip(), code):
        raise HTTPException(401, "wrong pairing code")
    return {"device_secret": device_secret(body.device_id)}


@router.post("/token")
def token(body: TokenIn):
    if body.device_id in _revoked() or not hmac.compare_digest(body.device_secret, device_secret(body.device_id)):
        raise HTTPException(401, "unknown device")
    ttl = int(os.environ.get("MUISTI_TOKEN_TTL", "3600"))
    return {"token": make_token(body.device_id, ttl=ttl), "expires_in": ttl}


@router.api_route("/{target}/{path:path}", methods=["GET", "POST"])
async def forward(target: str, path: str, request: Request):
    if (target, path) not in ALLOWED:
        raise HTTPException(404, "not proxied")
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise HTTPException(401, "missing token")
    check_token(auth[7:].strip())
    key = os.environ.get("VERDA_INFERENCE_KEY", "")
    if not key:
        raise HTTPException(503, "proxy has no upstream key")
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=httpx.Timeout(120, connect=20))
    base = LLM_BASE if target == "llm" else RETRIEVAL_BASE
    up = await _client.request(request.method, f"{base}/{path}", content=await request.body(),
                               headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    return Response(up.content, status_code=up.status_code, media_type=up.headers.get("content-type", "application/json"))
