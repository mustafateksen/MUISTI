"""Re-read all test frames with PaddleOCR (deterministic) instead of the Nemotron stand-in.

- results/tune/ocr_paddle.json          : text lines for the 53 tuning frames
- results/<video>/v6p/results.json       : copy of the v6 run with every frame's text replaced
  (frames folder copied too), so `eval/reextract.py --base v6p` re-runs extraction on it.
"""
import json
import os
import shutil
import sys
import time

import cv2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import ocr_paddle as P  # noqa: E402

t0 = time.time()
tune = os.path.join(ROOT, "results", "tune")
meta = json.load(open(os.path.join(tune, "frames.json"), encoding="utf-8"))
out = {}
for m in meta:
    out[m["file"]] = P.read_lines(cv2.imread(os.path.join(tune, "frames", m["file"])))
json.dump(out, open(os.path.join(tune, "ocr_paddle.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print(f"tune frames: {len(out)} in {time.time() - t0:.0f}s", flush=True)

for vid in sorted(os.listdir(os.path.join(ROOT, "results"))):
    src = os.path.join(ROOT, "results", vid, "v6")
    if not os.path.exists(os.path.join(src, "results.json")):
        continue
    dst = os.path.join(ROOT, "results", vid, "v6p")
    if not os.path.exists(os.path.join(dst, "frames")):
        shutil.copytree(os.path.join(src, "frames"), os.path.join(dst, "frames"))
    d = json.load(open(os.path.join(src, "results.json"), encoding="utf-8"))
    for r in d["rows"]:
        r["ocr"] = "\n".join(P.read_lines(cv2.imread(os.path.join(src, "frames", r["file"]))))
        r["record"] = None
    d["records"] = []
    d["stats"]["ocr_source"] = "paddleocr"
    json.dump(d, open(os.path.join(dst, "results.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"{vid}: {len(d['rows'])} frames, {sum(1 for r in d['rows'] if r['ocr'])} with text, {time.time() - t0:.0f}s",
          flush=True)
