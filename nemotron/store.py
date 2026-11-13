"""Memory store. SQLite now; Aiven PostgreSQL later behind the same interface.

Only frames that produced a useful record are stored (plus their blurred JPEG on disk).
Sightings are derived from frames by merge.merge_sightings (cached until next write),
so the Aiven version can keep the same 'frames' table and compute sightings in SQL or here.

Aiven swap: implement the same 5 methods (add_frame, frames, sightings, forget, stats)
with psycopg + pgvector; nothing else in the server changes.
"""
import datetime as dt
import json
import os
import sqlite3
import threading

from merge import merge_sightings

SCHEMA = """
CREATE TABLE IF NOT EXISTS frames (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  seen_at     TEXT NOT NULL,          -- ISO 8601
  lat         REAL, lon REAL, heading REAL, street TEXT,
  ocr_lines   TEXT,                   -- JSON list
  record      TEXT NOT NULL,          -- JSON extraction record (verified)
  frame_path  TEXT,                   -- blurred JPEG on disk
  dhash       TEXT
);
CREATE INDEX IF NOT EXISTS frames_seen_at ON frames(seen_at);
"""


class SqliteStore:
    def __init__(self, path: str = "data/muisti.db", frame_dir: str = "data/frames"):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        os.makedirs(frame_dir, exist_ok=True)
        self.frame_dir = frame_dir
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()
        self._cache = None

    def add_frame(self, seen_at: dt.datetime, record: dict, ocr_lines: list[str], jpeg: bytes,
                  dhash: int | None = None, lat=None, lon=None, heading=None, street=None) -> int:
        with self.lock:
            cur = self.db.execute(
                "INSERT INTO frames(seen_at, lat, lon, heading, street, ocr_lines, record, dhash) VALUES (?,?,?,?,?,?,?,?)",
                (seen_at.isoformat(), lat, lon, heading, street, json.dumps(ocr_lines),
                 json.dumps(record, ensure_ascii=False), None if dhash is None else str(dhash)))
            fid = cur.lastrowid
            path = os.path.join(self.frame_dir, f"{fid}.jpg")
            with open(path, "wb") as f:
                f.write(jpeg)
            self.db.execute("UPDATE frames SET frame_path=? WHERE id=?", (path, fid))
            self.db.commit()
            self._cache = None
            return fid

    def frames(self) -> list[dict]:
        rows = self.db.execute(
            "SELECT id, seen_at, lat, lon, street, record, dhash FROM frames ORDER BY seen_at").fetchall()
        out = []
        for fid, seen, lat, lon, street, rec, dh in rows:
            t = dt.datetime.fromisoformat(seen)
            out.append({"id": fid, "file": f"{fid}.jpg", "seen_at": t, "t": t.timestamp(),
                        "lat": lat, "lon": lon, "street": street,
                        "record": json.loads(rec), "dhash": int(dh) if dh else None})
        return out

    def sightings(self) -> list[dict]:
        if self._cache is None:
            frames = self.frames()
            by_file = {f["file"]: f for f in frames}
            out = []
            for i, s in enumerate(merge_sightings(frames)):
                first = by_file[s["frames"][0]]
                s.update(id=i + 1, seen_at=first["seen_at"], lat=first["lat"], lon=first["lon"],
                         street=first["street"], source="live", frame_dir=self.frame_dir)
                out.append(s)
            self._cache = out
        return self._cache

    def forget(self, since: dt.datetime) -> int:
        """Delete everything seen at or after `since` (the 'forget the last N minutes' command)."""
        with self.lock:
            rows = self.db.execute("SELECT id, frame_path FROM frames WHERE seen_at >= ?",
                                   (since.isoformat(),)).fetchall()
            for _, p in rows:
                if p and os.path.exists(p):
                    os.remove(p)
            self.db.execute("DELETE FROM frames WHERE seen_at >= ?", (since.isoformat(),))
            self.db.commit()
            self._cache = None
            return len(rows)

    def latest_time(self) -> dt.datetime | None:
        r = self.db.execute("SELECT MAX(seen_at) FROM frames").fetchone()[0]
        return dt.datetime.fromisoformat(r) if r else None

    def stats(self) -> dict:
        n = self.db.execute("SELECT COUNT(*) FROM frames").fetchone()[0]
        return {"frames": n, "sightings": len(self.sightings())}
