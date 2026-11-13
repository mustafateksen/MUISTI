"""Run eval/ask_tests.json through ask.py and print the scoreboard.

Usage: python eval/run_ask_tests.py [--out eval/ask_results.json]
"""
import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import ask  # noqa: E402

spec = json.load(open("eval/ask_tests.json", encoding="utf-8"))
now = dt.datetime.fromisoformat(spec["now"])
SERVER = sys.argv[sys.argv.index("--server") + 1] if "--server" in sys.argv else None
docs = None if SERVER else ask.load_memory()


def run(q, q_now=None):
    now_ = dt.datetime.fromisoformat(q_now) if q_now else now
    if not SERVER:
        return ask.ask(q, docs, now_)
    import httpx
    r = httpx.post(f"{SERVER}/ask", json={"question": q, "now": now_.isoformat()}, timeout=120).json()
    return {"label": r["label"], "answer": r["answer"], "why": r.get("why", ""), "calls": r.get("calls", 0),
            "latency_s": r.get("latency_s", 0), "evidence": r.get("evidence", [])}


rows, ok_n = [], 0
answerable = [x for x in spec["questions"] if x["expect_label"] == "SEEN"]
traps = [x for x in spec["questions"] if x["expect_label"] == "DONT_KNOW"]
for t in spec["questions"]:
    r = run(t["q"], t.get("now"))
    r["question"] = t["q"]
    accept = t.get("accept_labels") or [t["expect_label"]]
    has = lambda s: any(alt in r["answer"].lower() for alt in s.lower().split("|"))
    ok = (r["label"] in accept
          and (r["label"] != "SEEN" or all(has(s) for s in t.get("must_contain", [])))
          and not (r["label"] == "SEEN" and any(has(s) for s in t.get("must_not_contain", []))))
    ok_n += ok
    r["expected"], r["ok"] = t["expect_label"], ok
    rows.append(r)
    print(f"{'OK ' if ok else 'XX '} [{r['label']:9}] {r['latency_s']:>5}s c={r['calls']}  {t['q']}\n      -> {r['answer']}   ({r['why']})")

seen_ok = sum(r["ok"] for r in rows if r["expected"] == "SEEN")
trap_ok = sum(r["ok"] for r in rows if r["expected"] == "DONT_KNOW")
halluc = sum(1 for r in rows if r["expected"] == "DONT_KNOW" and r["label"] == "SEEN")
wrong_seen = sum(1 for r in rows if r["expected"] != "DONT_KNOW" and r["label"] == "SEEN" and not r["ok"])
summary = {
    "accuracy": f"{ok_n}/{len(rows)}",
    "answerable_correct": f"{seen_ok}/{len(answerable)}",
    "traps_abstained": f"{trap_ok}/{len(traps)}",
    "hallucinated_on_traps": halluc,
    "answered_but_wrong": wrong_seen,
    "avg_latency_s": round(sum(r["latency_s"] for r in rows) / len(rows), 2),
    "avg_calls": round(sum(r["calls"] for r in rows) / len(rows), 2),
}
print(json.dumps(summary, indent=1))
out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "eval/ask_results.json"
json.dump({"summary": summary, "rows": rows}, open(out, "w", encoding="utf-8"), indent=1, ensure_ascii=False, default=str)
