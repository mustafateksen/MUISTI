"""Interactive Windows demo entry point. Run from the project root."""
import getpass
import os
from pathlib import Path

import httpx
import psycopg
import uvicorn

from .embedding import COLUMN, vector


def secret(name, prompt):
    if not os.environ.get(name):
        os.environ[name] = getpass.getpass(prompt).strip()


def main():
    secret("NVIDIA_EMBED_API_KEY", "NVIDIA Build embedding key: ")
    secret("DATABASE_URL", "Aiven Service URI: ")
    secret("NVIDIA_API_KEY", "Verda inference key: ")
    os.environ.setdefault("NVIDIA_MODEL", "nemotron-3.5-super-vl")
    with httpx.Client(headers={"Authorization": "Bearer " + os.environ["NVIDIA_EMBED_API_KEY"]},
                      timeout=30) as client:
        vector(client, "Which floor?", "query")
        with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=10) as db:
            db.execute(Path(__file__).with_name("schema.sql").read_text(encoding="utf-8"))
            db.execute("LOCK TABLE memories IN SHARE ROW EXCLUSIVE MODE")
            db.execute(f"ALTER TABLE memories ADD COLUMN IF NOT EXISTS {COLUMN} vector(2048)")
            # The old column and its values remain available for comparison.
            old = db.execute("SELECT attnotnull FROM pg_attribute WHERE attrelid='memories'::regclass "
                             "AND attname='embedding' AND NOT attisdropped").fetchone()
            if old and old[0]:
                db.execute("ALTER TABLE memories ALTER COLUMN embedding DROP NOT NULL")
            rows = db.execute(f"SELECT memory_id, ocr_text FROM memories WHERE {COLUMN} IS NULL").fetchall()
            for key, text in rows:
                db.execute(f"UPDATE memories SET {COLUMN}=%s::vector WHERE memory_id=%s",
                           (vector(client, text, "passage"), key))
            db.execute(f"ALTER TABLE memories ALTER COLUMN {COLUMN} SET NOT NULL")
    print(f"NVIDIA hazir. Guncellenen kayit: {len(rows)}", flush=True)
    uvicorn.run("backend.app:app", host="127.0.0.1", port=8000)


if __name__ == "__main__":
    main()
