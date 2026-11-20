"""Re-merge Ahmet's zoom run with a stricter rule (no re-run on the Mac needed).

Full-frame readings come from ocr_<k>.json (same settings, deterministic), zoomed readings from
ocr_zoom_<k>.json (src == "zoom"). A zoomed reading:
  - is ADDED if it overlaps no full reading (new text),
  - REPLACES overlapping full readings only if it covers each of them (>= 80% of its area)
    and is about as confident - a zoom that read only part of a line ("ARDUINO HARDWAR")
    never replaces the complete line,
  - is otherwise dropped.
Writes results/apple_vision/ocr_zoomfix_<k>.json
"""
import json, os
A = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results", "apple_vision")

def inter(a, b):
    ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    return ix * iy

def merge(full, zoom):
    out = [dict(o, src="full") for o in full]
    for z in zoom:
        za = z["box"][2] * z["box"][3]
        hit = [o for o in out if o["src"] == "full" and inter(o["box"], z["box"]) > 0.3 * min(za, o["box"][2] * o["box"][3])]
        if not hit:
            if not any(inter(o["box"], z["box"]) > 0.3 * za for o in out):
                out.append(z)
        elif all(inter(o["box"], z["box"]) >= 0.8 * o["box"][2] * o["box"][3] for o in hit) and \
                z["conf"] >= max(o["conf"] for o in hit) - 0.1:
            out = [o for o in out if o not in hit] + [z]
    return out

if __name__ == "__main__":
    for k in ("tune", "video1", "video2"):
        full = json.load(open(os.path.join(A, f"ocr_{k}.json"), encoding="utf-8"))
        zr = json.load(open(os.path.join(A, f"ocr_zoom_{k}.json"), encoding="utf-8"))
        res = {f: merge(full.get(f, []), [o for o in zr.get(f, []) if o.get("src") == "zoom"]) for f in full}
        json.dump(res, open(os.path.join(A, f"ocr_zoomfix_{k}.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
        rep = [(f, o["text"]) for f, v in res.items() for o in v if o["src"] == "zoom"]
        print(k, "zoom readings kept:", len(rep))
        for f, t in rep: print("   ", f, t[:50])
