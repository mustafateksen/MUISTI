"""Replay a recorded glasses video into the server, like the phone would.

Same frame selection as process_video (sharpest per window, blur + duplicate drop),
then POST /ingest with a realistic seen_at timestamp per frame.

Usage:
  python tools/replay_video.py <video.mp4> [--server http://localhost:8000] [--start 2026-11-13T22:03:00]
                               [--fps 2] [--ocr-json vision.json] [--workers 4]
--ocr-json: Apple Vision output from tools/vision_ocr.swift (keys = frame file names);
            without it the server uses Nemotron as stand-in OCR.
"""
import argparse
import base64
import datetime as dt
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import cv2
import httpx

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from process_video import select_frames  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--server", default="http://localhost:8000")
    ap.add_argument("--start", help="ISO time the recording started (default: file mtime - duration)")
    ap.add_argument("--fps", type=float, default=2)
    ap.add_argument("--ocr-json")
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()

    kept, stats = select_frames(a.video, a.fps)
    cap = cv2.VideoCapture(a.video)
    dur = cap.get(cv2.CAP_PROP_FRAME_COUNT) / (cap.get(cv2.CAP_PROP_FPS) or 30)
    start = dt.datetime.fromisoformat(a.start) if a.start else \
        dt.datetime.fromtimestamp(os.path.getmtime(a.video)) - dt.timedelta(seconds=dur)
    vision = json.load(open(a.ocr_json, encoding="utf-8")) if a.ocr_json else {}
    print(f"selection: {stats} | start {start:%H:%M:%S}")

    def send(k):
        ok, buf = cv2.imencode(".jpg", k["frame"], [cv2.IMWRITE_JPEG_QUALITY, 90])
        body = {"frame_jpeg_b64": base64.b64encode(buf.tobytes()).decode(),
                "seen_at": (start + dt.timedelta(seconds=k["t"])).isoformat()}
        obs = vision.get(f"f{k['index']:05d}.jpg")
        if obs is not None:
            body["ocr_observations"] = obs
        for attempt in range(3):
            try:
                return k["t"], httpx.post(f"{a.server}/ingest", json=body, timeout=180).json()
            except Exception as ex:  # server busy / restarting
                err = ex
                time.sleep(2)
        return k["t"], {"stored": False, "reason": f"error {err}"}

    t0, stored = time.time(), 0
    with ThreadPoolExecutor(a.workers) as pool:
        for t, r in sorted(pool.map(send, kept)):
            if r.get("stored"):
                stored += 1
                rec = r["record"]
                print(f"{t:>6.1f}s  STORED  {rec.get('kind')}/{rec.get('subtype')}  {rec.get('name')}")
    print(f"done: {len(kept)} frames sent, {stored} stored, {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
