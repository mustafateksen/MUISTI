"""Apply ocr_repair to PaddleOCR test text, then re-extract ONLY frames whose text changed.

- results/tune/ocr_paddle_fix.json
- results/<video>/v19r/results.json  (from v19p: unchanged frames keep their record, changed ones re-extracted)
"""
import json, os, shutil, sys, time
from concurrent.futures import ThreadPoolExecutor
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import extract as E  # noqa: E402
import ocr_repair as R  # noqa: E402
from merge import merge_sightings  # noqa: E402

arg = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
# defaults = PaddleOCR; Apple Vision: --tune ocr_vision --base v19v --out v19vr
TUNE_IN, BASE, OUT = arg("--tune", "ocr_paddle"), arg("--base", "v19p"), arg("--out", "v19r")
tune = os.path.join(ROOT, "results", "tune")
t = json.load(open(os.path.join(tune, f"{TUNE_IN}.json"), encoding="utf-8"))
vt = R.build_vocab(l for ls in t.values() for l in ls)
json.dump({k: R.repair(v, vt) for k, v in t.items()}, open(os.path.join(tune, f"{TUNE_IN}_fix.json"), "w", encoding="utf-8"),
          indent=1, ensure_ascii=False)

vids = [v for v in sorted(os.listdir(os.path.join(ROOT, "results")))
        if os.path.exists(os.path.join(ROOT, "results", v, BASE, "results.json"))]
runs = {v: json.load(open(os.path.join(ROOT, "results", v, BASE, "results.json"), encoding="utf-8")) for v in vids}
vocab = R.build_vocab(l for d in runs.values() for r in d["rows"] for l in (r.get("ocr") or "").splitlines())
for vid, d in runs.items():
    src, dst = os.path.join(ROOT, "results", vid, BASE), os.path.join(ROOT, "results", vid, OUT)
    if not os.path.exists(os.path.join(dst, "frames")):
        shutil.copytree(os.path.join(src, "frames"), os.path.join(dst, "frames"))
    t0, changed = time.time(), []
    for r in d["rows"]:
        new = "\n".join(R.repair((r.get("ocr") or "").splitlines(), vocab))
        if new != (r.get("ocr") or ""):
            r["ocr"] = new
            changed.append(r)

    def one(r):
        jpeg = open(os.path.join(src, "frames", r["file"]), "rb").read()
        r["record"] = E.extract(jpeg, r["ocr"].splitlines())

    with ThreadPoolExecutor(8) as pool:
        list(pool.map(one, changed))
    rows = sorted(d["rows"], key=lambda r: r["t"])
    d["records"] = merge_sightings(rows)
    d["stats"].update(ocr_source=d["stats"].get("ocr_source", "?") + "+repair", sightings=len(d["records"]))
    json.dump(d, open(os.path.join(dst, "results.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(vid, f"re-extracted {len(changed)} frames in {time.time() - t0:.0f}s", flush=True)
