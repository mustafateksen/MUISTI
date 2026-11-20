"""MUISTI - offline video test.

video -> sample frames -> drop blurry / duplicate -> Nemotron OCR (temporary stand-in
for Apple Vision) -> extract.py -> results/<video>/report.html

Usage: python process_video.py <video.mp4> [--fps 2]
"""
import argparse
import html
import json
import os
import time

import cv2
import numpy as np

import extract as E2
import extract_v1 as E1
from merge import merge_sightings

E = E1  # helpers (client, downscale, _image_part) are identical in both

OCR_PROMPT = """Transcribe ALL readable text in this image, line by line, exactly as written.
Do not translate, correct or guess. Skip text you cannot read clearly.
If there is no readable text, reply with exactly: NO_TEXT"""


def sharpness(gray: np.ndarray) -> float:
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def dhash(gray: np.ndarray) -> int:
    small = cv2.resize(gray, (9, 8), interpolation=cv2.INTER_AREA)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    return int("".join("1" if b else "0" for b in bits), 2)


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def select_frames(path: str, fps: float, dup_dist: int = 8, blur_ratio: float = 0.5):
    """Keep the sharpest frame in each 1/fps window, then drop blurry and near-duplicate ones."""
    cap = cv2.VideoCapture(path)
    vfps = cap.get(cv2.CAP_PROP_FPS) or 30
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    window = max(1, int(round(vfps / fps)))
    candidates, best, idx = [], None, 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        s = sharpness(gray)
        if best is None or s > best[0]:
            best = (s, idx, frame, gray)
        idx += 1
        if idx % window == 0:
            candidates.append(best)
            best = None
    if best:
        candidates.append(best)
    cap.release()

    median = float(np.median([c[0] for c in candidates])) if candidates else 0
    kept, last_hash, stats = [], None, {"total_frames": total, "sampled": len(candidates),
                                         "blurry": 0, "duplicate": 0}
    for s, i, frame, gray in candidates:
        if s < blur_ratio * median:
            stats["blurry"] += 1
            continue
        h = dhash(gray)
        if last_hash is not None and hamming(h, last_hash) <= dup_dist:
            stats["duplicate"] += 1
            continue
        last_hash = h
        kept.append({"index": i, "t": round(i / vfps, 2), "sharpness": round(s, 1), "frame": frame})
    stats["kept"] = len(kept)
    stats["median_sharpness"] = round(median, 1)
    return kept, stats


def nemotron_ocr(jpeg: bytes) -> str:
    resp = E.client.chat.completions.create(
        model=E.MODEL,
        temperature=0,
        max_tokens=500,
        messages=[{"role": "user", "content": [E._image_part(E.downscale(jpeg)),
                                                {"type": "text", "text": OCR_PROMPT}]}],
        extra_body={"chat_template_kwargs": {"enable_thinking": False}},
    )
    text = (resp.choices[0].message.content or "").strip()
    return "" if text.upper().startswith("NO_TEXT") else text


def sightings_html(records) -> str:
    if not records:
        return ""
    def c(v):
        return "" if v is None else html.escape(str(v))
    rows = "".join(f"""<tr class=useful><td><img src="frames/{s['evidence_frame']}"><div class=t>{s['t']}–{s['t_end']}s · {len(s['frames'])} frames</div></td>
<td><b>{c(s.get('kind'))}</b> / {c(s.get('subtype'))}<br><b>{c(s.get('name'))}</b><br>{c(s.get('phone'))} {c(s.get('hours'))}
<br>{'<br>'.join(c(i['label']) + ' → ' + c(i['value']) for i in s.get('items') or [])}<br><small>{c(s.get('caption'))}</small></td></tr>""" for s in records)
    return f"<h3>Merged sightings ({len(records)})</h3><table>{rows}</table>"


def write_report(out_dir: str, name: str, stats: dict, rows: list, records=None) -> str:
    def cell(v):
        return "" if v is None else html.escape(str(v))
    body = []
    for r in rows:
        rec = r.get("record") or {}
        phone = rec.get("phone") or (f"<s>{cell(rec.get('phone_unverified'))}</s>"
                                     if rec.get("phone_unverified") else "")
        body.append(f"""<tr class="{'useful' if rec.get('useful') else 'skip'}">
<td><img src="frames/{r['file']}"><div class=t>{r['t']}s · sharp {r['sharpness']}</div></td>
<td><pre>{cell(r['ocr']) or '<i>no text</i>'}</pre></td>
<td><b>{cell(rec.get('kind'))}</b><br>{cell(rec.get('name'))}<br>{phone}<br>{cell(rec.get('hours'))}
<br>{'<br>'.join(cell(i['label']) + ' → ' + cell(i['value']) for i in rec.get('items') or [])}
<br><small>{cell(rec.get('caption'))}</small><br><small>conf {cell(rec.get('confidence'))} · {r['latency']}s</small>
{''.join('<div class=err>rejected ' + cell(x['field']) + ': ' + cell(x['value']) + '</div>' for x in rec.get('rejected') or [])}
{('<div class=err>' + cell(r['error']) + '</div>') if r.get('error') else ''}</td></tr>""")
    page = f"""<!doctype html><meta charset=utf-8><title>MUISTI video test</title>
<style>
:root{{--bg:#fff;--fg:#111;--mut:#666;--line:#ddd;--ok:#e8f5e9}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151515;--fg:#eee;--mut:#999;--line:#333;--ok:#1d2e1f}}}}
body{{font:14px system-ui;background:var(--bg);color:var(--fg);margin:16px}}
table{{border-collapse:collapse;width:100%}} td{{border-top:1px solid var(--line);padding:8px;vertical-align:top}}
img{{width:220px;border-radius:6px}} pre{{white-space:pre-wrap;margin:0;font-size:12px}}
.t,small{{color:var(--mut)}} tr.useful{{background:var(--ok)}} .err{{color:#c33}} s{{color:#c33}}
</style>
<h2>{html.escape(name)}</h2>
<p>{stats['total_frames']} frames → sampled {stats['sampled']} → blurry −{stats['blurry']}, duplicate −{stats['duplicate']}
→ <b>{stats['kept']} sent</b> · with text {stats.get('with_text', 0)} · useful records {stats.get('useful', 0)}
· Nemotron calls {stats.get('calls', 0)} · total {stats.get('seconds', 0)}s</p>
<p class=t>Green = useful record. Struck-through phone = model said it but OCR did not contain it (rejected).</p>
{sightings_html(records)}
<h3>Frames</h3>
<table>{''.join(body)}</table>"""
    path = os.path.join(out_dir, "report.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(page)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--fps", type=float, default=2)
    ap.add_argument("--version", default="v2")
    args = ap.parse_args()

    name = os.path.splitext(os.path.basename(args.video))[0]
    out_dir = os.path.join("results", name.replace(" ", "_"), args.version)
    os.makedirs(os.path.join(out_dir, "frames"), exist_ok=True)

    t0 = time.time()
    kept, stats = select_frames(args.video, args.fps)
    print("selection:", stats)

    rows, calls = [], 0
    for k in kept:
        fname = f"f{k['index']:05d}.jpg"
        ok, buf = cv2.imencode(".jpg", k["frame"], [cv2.IMWRITE_JPEG_QUALITY, 90])
        jpeg = buf.tobytes()
        open(os.path.join(out_dir, "frames", fname), "wb").write(jpeg)
        row = {"file": fname, "t": k["t"], "sharpness": k["sharpness"], "ocr": "", "record": None,
               "dhash": dhash(cv2.cvtColor(k["frame"], cv2.COLOR_BGR2GRAY))}
        t = time.time()
        try:
            if args.version == "v1":
                row["ocr"] = nemotron_ocr(jpeg); calls += 1
                if row["ocr"]:
                    row["record"] = E1.extract(jpeg, row["ocr"]); calls += 1
            else:
                lines = E2.ocr(jpeg); calls += 1
                row["ocr"] = "\n".join(lines)
                if lines or E2.SCENE_MODE:  # v6: describe text-less frames too
                    row["record"] = E2.extract(jpeg, lines); calls += 1
        except Exception as ex:
            row["error"] = f"{type(ex).__name__}: {ex}"[:300]
        row["latency"] = round(time.time() - t, 2)
        rows.append(row)
        rec = row["record"] or {}
        print(f"{k['t']:>6}s  text={'Y' if row['ocr'] else '-'}  {rec.get('kind')!s:12} {rec.get('name')!s:30} "
              f"phone={rec.get('phone')} unverified={rec.get('phone_unverified')}")

    records = merge_sightings(rows) if args.version != "v1" else None
    stats.update(rejected_by_verifier=sum(len((r["record"] or {}).get("rejected") or []) for r in rows),
                 sightings=len(records) if records is not None else None)
    stats.update(with_text=sum(1 for r in rows if r["ocr"]),
                 useful=sum(1 for r in rows if (r["record"] or {}).get("useful")),
                 calls=calls, seconds=round(time.time() - t0, 1))
    json.dump({"stats": stats, "rows": rows, **({"records": records} if records is not None else {})}, open(os.path.join(out_dir, "results.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("stats:", stats)
    print("report:", write_report(out_dir, f"{name} [{args.version}]", stats, rows, records))


if __name__ == "__main__":
    main()
