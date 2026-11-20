"""Extraction ablations with OCR held fixed.

Re-runs extract.extract on the frames that had OCR text in a saved run (default v4),
with different Nemotron settings, then merges and scores against both ground truths.
OCR lines are reused from the saved run, so only the extraction step changes.

Usage: python eval/ablation.py [--base v4] [--workers 6]
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "eval"))
import evaluate as ev  # noqa: E402
import extract as E  # noqa: E402
from merge import merge_sightings  # noqa: E402

VIDEOS = [("WhatsApp_Video_2026-11-13_at_10.04.33_PM", "eval/gt_whatsapp_video_1.json"),
          ("WhatsApp_Video_2026-11-13_at_10.39.08_PM", "eval/gt_whatsapp_video_2.json")]
VARIANTS = [
    ("temp 0.0, thinking off", 0.0, False),
    ("temp 0.2, thinking off (default)", 0.2, False),
    ("temp 0.6, thinking off (NVIDIA vision default)", 0.6, False),
    ("temp 0.2, thinking ON", 0.2, True),
]


def run_variant(name, temp, think, base, workers):
    E.EXTRACT_TEMPERATURE, E.EXTRACT_THINKING = temp, think
    out = {"variant": name}
    lat, n_calls, rejected = [], 0, 0
    for vid, gtf in VIDEOS:
        saved = json.load(open(os.path.join(ROOT, "results", vid, base, "results.json"), encoding="utf-8"))
        rows = [r for r in saved["rows"] if r.get("ocr")]

        def one(r):
            jpeg = open(os.path.join(ROOT, "results", vid, base, "frames", r["file"]), "rb").read()
            t = time.time()
            try:
                rec = E.extract(jpeg, r["ocr"].splitlines())
            except Exception as ex:
                rec = {"useful": False, "error": str(ex)[:200], "rejected": []}
            return {**r, "record": rec}, time.time() - t

        with ThreadPoolExecutor(workers) as pool:
            res = list(pool.map(one, rows))
        new_rows = sorted([x[0] for x in res], key=lambda r: r["t"])
        lat += [x[1] for x in res]
        n_calls += len(res)
        rejected += sum(len(r["record"].get("rejected") or []) for r in new_rows)
        records = merge_sightings(new_rows)
        s = ev.score({"rows": new_rows, "records": records, "stats": {}}, json.load(open(os.path.join(ROOT, gtf))))
        out[vid[-14:]] = {k: s[k] for k in ("records", "entity_recall", "correct_floor_pairs",
                                            "wrong_floor_pairs_unique", "junk_items")}
    out["verifier_rejections"] = rejected
    out["avg_latency_s"] = round(sum(lat) / len(lat), 2)
    out["calls"] = n_calls
    return out


if __name__ == "__main__":
    base = sys.argv[sys.argv.index("--base") + 1] if "--base" in sys.argv else "v4"
    workers = int(sys.argv[sys.argv.index("--workers") + 1]) if "--workers" in sys.argv else 6
    results = []
    for name, temp, think in VARIANTS:
        r = run_variant(name, temp, think, base, workers)
        print(json.dumps(r, ensure_ascii=False))
        results.append(r)
    json.dump(results, open(os.path.join(ROOT, "eval", "ablation_results.json"), "w", encoding="utf-8"),
              indent=1, ensure_ascii=False)
