#!/usr/bin/env python3
"""Stand-in for Kişi 3's FastAPI server, standard library only.

    python3 ios/tools/mock_server.py --port 8000 [--out /tmp/muisti-ingest]

POST /ingest  -> {"memory_id": n}, saves the JPEG + JSON (without base64) to --out
POST /ask     -> canned BILMIYORUM answer pointing at the last ingested frame
GET  /        -> {"ok": true, "ingested": n}
Set the app's server address to http://<this Mac's IP>:8000 (Simulator: http://127.0.0.1:8000).
"""
import argparse, base64, json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
state = {"n": 0, "last": None}


class Handler(BaseHTTPRequestHandler):
    out = None

    def _json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._json(200, {"ok": True, "ingested": state["n"]})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "bad json"})
        if self.path == "/ingest":
            if "frame_jpeg_b64" not in body or "seen_at" not in body:
                return self._json(422, {"error": "missing fields"})
            with lock:
                state["n"] += 1
                n = state["n"]
                meta = {k: v for k, v in body.items() if k != "frame_jpeg_b64"}
                state["last"] = {"memory_id": n, **meta}
            jpeg = base64.b64decode(body["frame_jpeg_b64"])
            if self.out:
                with open(os.path.join(self.out, f"{n:06d}.jpg"), "wb") as f:
                    f.write(jpeg)
                with open(os.path.join(self.out, f"{n:06d}.json"), "w") as f:
                    json.dump(meta, f, ensure_ascii=False)
            print(f"ingest #{n} {meta.get('seen_at')} lat={meta.get('lat')} lon={meta.get('lon')} {len(jpeg)} B", flush=True)
            return self._json(200, {"memory_id": n})
        if self.path == "/ask":
            last = state["last"]
            evidence = [] if not last else [{
                "memory_id": last["memory_id"], "frame_url": None, "seen_at": last.get("seen_at"),
                "lat": last.get("lat"), "lon": last.get("lon")}]
            return self._json(200, {"answer": "Bunu net görmedim (sahte sunucu).", "label": "BILMIYORUM",
                                    "evidence": evidence, "sources": []})
        self._json(404, {"error": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--out", default=None)
    a = p.parse_args()
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    Handler.out = a.out
    print(f"mock server on :{a.port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()
