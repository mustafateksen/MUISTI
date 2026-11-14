"""Build test memory from Ahmet's Apple Vision output exactly like the server does at /ingest:
vision_to_lines (row grouping + wrapped-value join) -> ocr_repair. Only frames whose lines differ
from --base are re-extracted.

  results/tune/ocr_vision_fix.json
  results/<video>/<out>/results.json
Usage: python eval/vision_sets.py --base v19v --out v20v
"""
import json, glob, os, shutil, sys, time
from concurrent.futures import ThreadPoolExecutor
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import extract as E  # noqa: E402
import ocr_repair as R  # noqa: E402
from ocr_adapter import vision_to_lines  # noqa: E402
from merge import merge_sightings  # noqa: E402

arg = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
BASE, OUT = arg("--base", "v19v"), arg("--out", "v20v")
PREFIX = arg("--prefix", "ocr_")            # ocr_zoomfix_ -> Ahmet's zoom run (eval/zoom_merge.py)
TUNE_OUT = arg("--tune-out", "ocr_vision_fix.json")
AV = os.path.join(ROOT, "results", "apple_vision")

def lines_for(raw: dict) -> dict:
    ls = {k: vision_to_lines(v) for k, v in raw.items()}
    vocab = R.build_vocab(l for v in ls.values() for l in v)
    return {k: R.repair(v, vocab) for k, v in ls.items()}

tune_raw = json.load(open(os.path.join(AV, f"{PREFIX}tune.json"), encoding="utf-8"))
json.dump(lines_for(tune_raw), open(os.path.join(ROOT, "results", "tune", TUNE_OUT), "w", encoding="utf-8"),
          indent=1, ensure_ascii=False)

raw = {}
for key in ("video1", "video2"):
    raw.update(json.load(open(os.path.join(AV, f"{PREFIX}{key}.json"), encoding="utf-8")))
new_lines = lines_for(raw)  # both videos share one vocab, like one user's server
for src in glob.glob(os.path.join(ROOT, "results", "*", BASE)):
    dst = os.path.join(os.path.dirname(src), OUT)
    if not os.path.exists(os.path.join(dst, "frames")):
        shutil.copytree(os.path.join(src, "frames"), os.path.join(dst, "frames"))
    d = json.load(open(os.path.join(src, "results.json"), encoding="utf-8"))
    t0, changed = time.time(), []
    for r in d["rows"]:
        new = "\n".join(new_lines.get(r["file"], []))
        if new != (r.get("ocr") or ""):
            r["ocr"] = new
            changed.append(r)

    def one(r):
        r["record"] = E.extract(open(os.path.join(src, "frames", r["file"]), "rb").read(), r["ocr"].splitlines())

    with ThreadPoolExecutor(8) as pool:
        list(pool.map(one, changed))
    d["records"] = merge_sightings(sorted(d["rows"], key=lambda r: r["t"]))
    d["stats"].update(ocr_source=f"apple_vision({PREFIX})+join+repair", sightings=len(d["records"]))
    json.dump(d, open(os.path.join(dst, "results.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(os.path.basename(os.path.dirname(src))[-12:], f"re-extracted {len(changed)} frames in {time.time() - t0:.0f}s", flush=True)
