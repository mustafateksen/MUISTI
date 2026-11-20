"""TextVQA as a memory test: 100 unseen public photos are 'seen' one per minute, then the
dataset's own questions are asked against that memory.

Text: Apple Vision (+zoom) run on a Mac -> vision_to_lines -> ocr_repair, exactly like /ingest.
Score per question:
  correct   = SEEN/UNSURE answer contains an answer given by >= 2 of the 10 annotators
  abstained = DONT_KNOW
  wrong     = anything else
  right_photo = the top evidence came from the question's own photo (retrieval check)
Usage: python eval/textvqa_run.py [--ocr results/textvqa/ocr_textvqa.json] [--workers 4] [--skip-build]
"""
import collections, datetime as dt, json, os, re, shutil, sys, time
from concurrent.futures import ThreadPoolExecutor
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
import ask as A  # noqa: E402
import extract as E  # noqa: E402
import ocr_repair as R  # noqa: E402
from merge import merge_sightings  # noqa: E402
from ocr_adapter import vision_to_lines  # noqa: E402

arg = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
OCR, WORKERS = arg("--ocr", "results/textvqa/ocr_textvqa.json"), int(arg("--workers", "1"))
TV = "results/textvqa"
MEM = os.path.join(TV, "day", "mem")
qs = json.load(open(os.path.join(TV, "questions.json"), encoding="utf-8"))
images = sorted({q["image"] for q in qs})
t0 = time.time()

if "--skip-build" not in sys.argv:
    raw = json.load(open(OCR, encoding="utf-8"))
    lines = {f: vision_to_lines(raw.get(f, [])) for f in images}
    vocab = R.build_vocab(l for v in lines.values() for l in v)
    lines = {f: R.repair(v, vocab) for f, v in lines.items()}
    os.makedirs(os.path.join(MEM, "frames"), exist_ok=True)
    for f in images:
        shutil.copy(os.path.join(TV, "images", f), os.path.join(MEM, "frames", f))

    def one(i_f):
        i, f = i_f
        jpeg = open(os.path.join(TV, "images", f), "rb").read()
        try:
            rec = E.extract(jpeg, lines[f])
        except Exception as ex:
            rec = {"useful": False, "error": str(ex)[:200], "rejected": [], "objects": [], "depictions": []}
        return {"file": f, "t": 60.0 * i, "ocr": "\n".join(lines[f]), "record": rec, "dhash": None}

    with ThreadPoolExecutor(8) as pool:
        rows = list(pool.map(one, enumerate(images)))
    records = merge_sightings(rows)
    json.dump({"stats": {"ocr_source": "apple_vision_zoom+join+repair", "frames": len(rows), "sightings": len(records),
                         "with_text": sum(1 for r in rows if r["ocr"]),
                         "errors": sum(1 for r in rows if (r["record"] or {}).get("error"))},
               "rows": rows, "records": records},
              open(os.path.join(MEM, "results.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"memory: {len(rows)} photos, {len(records)} sightings, {time.time() - t0:.0f}s", flush=True)

docs = A.load_memory(os.path.join(MEM, "results.json"))
now = max(d["seen_at"] for d in docs) + dt.timedelta(minutes=5)

def norm(s):
    return re.sub(r"[^a-z0-9 ]", " ", s.lower()).split()

def contains(answer, gold):
    a, g = " " + " ".join(norm(answer)) + " ", " ".join(norm(gold))
    return bool(g) and f" {g} " in a

PER_PHOTO = "--per-photo" in sys.argv  # memory = only the question's own photo ("what am I looking at")

def run(q):
    try:
        mem = [d for d in docs if d.get("frame") == q["image"]] if PER_PHOTO else docs
        r = A.ask(q["question"], mem, now) if mem else {"label": "DONT_KNOW", "answer": "nothing stored for this photo",
                                                         "evidence": [], "why": "photo not in memory"}
    except Exception as ex:
        r = {"label": "ERROR", "answer": str(ex)[:200], "evidence": [], "why": "exception"}
    golds = [a for a, c in collections.Counter(x.lower().strip() for x in q["answers"]).items() if c >= 2]
    ok = r["label"] in ("SEEN", "UNSURE") and any(contains(r["answer"], g) for g in golds)
    verdict = "correct" if ok else ("abstained" if r["label"] == "DONT_KNOW" else "wrong")
    top = (r.get("evidence") or [{}])[0].get("frame")
    return {**q, "label": r["label"], "answer": r["answer"], "why": r.get("why"), "verdict": verdict,
            "golds": golds, "right_photo": top == q["image"], "unsure": r["label"] == "UNSURE"}

# first question alone: libraries (httpx, embeddings client) import lazily and are not safe to
# import from several threads at once ("partially initialized module 'httpx'")
res = [run(qs[0])]
with ThreadPoolExecutor(WORKERS) as pool:
    res += list(pool.map(run, qs[1:]))
c = collections.Counter(r["verdict"] for r in res)
answerable = [r for r in res if r["golds"]]
summary = {"questions": len(res), "correct": c["correct"], "abstained": c["abstained"], "wrong": c["wrong"],
           "accuracy": f"{c['correct'] / len(res):.0%}",
           "precision_when_answering": f"{c['correct'] / max(1, c['correct'] + c['wrong']):.0%}",
           "right_photo_top1": f"{sum(r['right_photo'] for r in res) / len(res):.0%}",
           "no_gold_agreement": len(res) - len(answerable), "seconds": round(time.time() - t0)}
json.dump({"summary": summary, "results": res}, open(os.path.join(TV, "results_vision_perphoto.json" if PER_PHOTO else "results_vision.json"), "w", encoding="utf-8"),
          indent=1, ensure_ascii=False)
print(json.dumps(summary, indent=1))
