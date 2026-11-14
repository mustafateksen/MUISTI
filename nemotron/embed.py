"""Semantic vectors with NVIDIA Nemotron Embed (same model as Emir's backend and the iOS app).

- Model: nvidia/nemotron-3.5-embed-1b on integrate.api.nvidia.com (key: NVIDIA_EMBED_API_KEY).
- input_type: "passage" for memories, "query" for questions (asymmetric model; mixing them hurts).
- Batches of 32 (measured: 32 texts in ~0.8 s).
- Disk cache keyed by (kind, text) hash, so re-running tests does not re-embed the same memory.
- No key or API error -> returns None and search falls back to words only.
"""
import hashlib
import os
import pickle
import threading

import numpy as np

import extract  # noqa: F401  (loads .env)

MODEL = "nvidia/nemotron-3.5-embed-1b"
URL = "https://integrate.api.nvidia.com/v1/embeddings"
CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "embed_cache.pkl")
_cache: dict | None = None
_lock = threading.Lock()


def available() -> bool:
    return bool(os.environ.get("NVIDIA_EMBED_API_KEY"))


def _load() -> dict:
    global _cache
    if _cache is None:
        try:
            _cache = pickle.load(open(CACHE_PATH, "rb"))
        except (OSError, EOFError, pickle.UnpicklingError):
            _cache = {}
    return _cache


def _save() -> None:
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    tmp = CACHE_PATH + ".tmp"
    pickle.dump(_cache, open(tmp, "wb"))
    os.replace(tmp, CACHE_PATH)


def _key(kind: str, text: str) -> str:
    return hashlib.sha1(f"{kind}\n{text}".encode("utf-8")).hexdigest()


def embed(texts: list[str], kind: str = "passage") -> list[np.ndarray] | None:
    """Unit-normalised float32 vectors, one per text (cached). None if embeddings are unavailable."""
    if not available() or not texts:
        return None
    import httpx

    with _lock:
        cache = _load()
        missing = [t for t in dict.fromkeys(texts) if _key(kind, t) not in cache]
        headers = {"Authorization": "Bearer " + os.environ["NVIDIA_EMBED_API_KEY"]}
        try:
            for i in range(0, len(missing), 32):
                batch = missing[i:i + 32]
                r = httpx.post(URL, headers=headers, timeout=60,
                               json={"model": MODEL, "input": batch, "input_type": kind,
                                     "encoding_format": "float", "truncate": "END"})
                r.raise_for_status()
                for t, item in zip(batch, sorted(r.json()["data"], key=lambda x: x["index"])):
                    v = np.asarray(item["embedding"], dtype=np.float32)
                    cache[_key(kind, t)] = v / max(float(np.linalg.norm(v)), 1e-8)
        except Exception:
            if missing:
                return None
        finally:
            if missing:
                _save()
        return [cache[_key(kind, t)] for t in texts]
