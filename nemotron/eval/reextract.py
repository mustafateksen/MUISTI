"""Re-run extraction on a saved run's frames, reusing its OCR lines, into a new version folder.

Isolates extraction changes from stand-in-OCR run-to-run variance.
Usage: python eval/reextract.py --base v6 --out v7 [--workers 8]
"""
import json
import os
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import extract as E  # noqa: E402
from merge import merge_sightings  # noqa: E402

arg = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
base, out, workers = arg("--base", "v6"), arg("--out", "v7"), int(arg("--workers", "8"))

for vid in sorted(os.listdir(os.path.join(ROOT, "results"))):
    src = os.path.join(ROOT, "results", vid, base)
    if not os.path.exists(os.path.join(src, "results.json")):
        continue
    dst = os.path.join(ROOT, "results", vid, out)
    os.makedirs(dst, exist_ok=True)
    if not os.path.exists(os.path.join(dst, "frames")):
        shutil.copytree(os.path.join(src, "frames"), os.path.join(dst, "frames"))
    saved = json.load(open(os.path.join(src, "results.json"), encoding="utf-8"))
    t0 = time.time()

    def one(r):
        jpeg = open(os.path.join(src, "frames", r["file"]), "rb").read()
        try:
            rec = E.extract(jpeg, (r.get("ocr") or "").splitlines())
        except Exception as ex:
            rec = {"useful": False, "error": str(ex)[:200], "rejected": [], "objects": [], "depictions": []}
        return {**r, "record": rec}

    with ThreadPoolExecutor(workers) as pool:
        rows = sorted(pool.map(one, saved["rows"]), key=lambda r: r["t"])
    records = merge_sightings(rows)
    stats = {**saved["stats"], "sightings": len(records), "calls": len(rows), "seconds": round(time.time() - t0, 1),
             "useful": sum(1 for r in rows if (r["record"] or {}).get("useful")),
             "depictions": sum(len((r["record"] or {}).get("depictions") or []) for r in rows),
             "errors": sum(1 for r in rows if (r["record"] or {}).get("error"))}
    json.dump({"stats": stats, "rows": rows, "records": records},
              open(os.path.join(dst, "results.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(vid, stats)
