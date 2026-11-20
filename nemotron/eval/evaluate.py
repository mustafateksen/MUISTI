"""Score a process_video run against a hand-labelled ground-truth file.

Usage: python eval/evaluate.py <results.json> <gt.json>
Prints a metrics dict; also importable (score()).
"""
import json
import re
import sys

FLOOR_RE = re.compile(r"\b(\d+|M)\s*(?:ST|ND|RD|TH)?\s*FLOOR\b")


def record_text(rec: dict) -> str:
    parts = [rec.get("name") or "", rec.get("other_text") or ""]
    for it in rec.get("items") or []:
        parts.append(f"{it.get('label', '')} {it.get('value', '')}")
    return " ; ".join(p for p in parts if p).upper()


def pairs_in(text: str, pairs: dict) -> tuple[set, set]:
    """For each room keyword, find the nearest floor token before it (same item/line).
    Returns (correct_pairs, wrong_pairs)."""
    correct, wrong = set(), set()
    for segment in re.split(r"[;\n]|,(?=\s*\d|\s*M\s*FLOOR)", text):
        for room, floor in pairs.items():
            pos = segment.find(room)
            if pos < 0:
                continue
            floors = list(FLOOR_RE.finditer(segment[:pos]))
            if not floors:
                continue
            got = floors[-1].group(1)
            (correct if got == floor else wrong).add(f"{got}->{room}")
    return correct, wrong


def score(results: dict, gt: dict) -> dict:
    records = results.get("records")
    if records is None:  # raw per-frame run (v1): every useful frame is a record
        records = [dict(r["record"], t=r["t"]) for r in results["rows"]
                   if (r.get("record") or {}).get("useful")]

    found = set()
    for ent in gt["entities"]:
        for rec in records:
            name = (rec.get("name") or "").lower()
            text = record_text(rec).lower()
            if any(n in name or n in text for n in ent["names"]):
                found.add(ent["id"])

    all_correct, all_wrong, wrong_mentions = set(), set(), 0
    for rec in records:
        c, w = pairs_in(record_text(rec), gt["pairs"])
        all_correct |= c
        all_wrong |= w
        wrong_mentions += len(w)

    forbidden = 0
    for row in results.get("rows", []):
        blob = json.dumps(row.get("record") or {}).lower() + " " + (row.get("ocr") or "").lower()
        forbidden += sum(1 for wd in gt["forbidden_words"] if wd in blob)
    for rec in records:
        blob = json.dumps(rec).lower()
        forbidden += sum(1 for wd in gt["forbidden_words"] if wd in blob)

    known = [n for e in gt["entities"] for n in e["names"]]
    unknown_names = sorted({rec["name"] for rec in records
                            if rec.get("name") and not any(k in rec["name"].lower() for k in known)})

    # Floor items whose room is not a real room on the screen (e.g. OCR's 'ANDROID ... MEETING SPACE').
    rooms = list(gt["pairs"])
    junk_items = sorted({f"{it.get('label')} -> {it.get('value')}" for rec in records
                         for it in rec.get("items") or []
                         if "FLOOR" in (it.get("label") or "").upper()
                         and not any(rm in (it.get("value") or "").upper() for rm in rooms)})

    stats = results.get("stats", {})
    return {
        "junk_items": junk_items,
        "records": len(records),
        "entity_recall": f"{len(found)}/{len(gt['entities'])}",
        "correct_floor_pairs": f"{len(all_correct)}/{len(gt['pairs'])}",
        "wrong_floor_pairs_unique": len(all_wrong),
        "wrong_floor_pair_mentions": wrong_mentions,
        "forbidden_word_hits": forbidden,
        "unknown_names": unknown_names,
        "rejected_by_verifier": stats.get("rejected_by_verifier", 0),
        "nemotron_calls": stats.get("calls"),
        "seconds": stats.get("seconds"),
    }


if __name__ == "__main__":
    res = json.load(open(sys.argv[1], encoding="utf-8"))
    gt = json.load(open(sys.argv[2], encoding="utf-8"))
    print(json.dumps(score(res, gt), indent=1, ensure_ascii=False))
