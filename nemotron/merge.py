"""Merge per-frame records of the same sign into one 'sighting'.

Walking past a booth gives 3-10 frames of it, each read slightly differently
('ARDUINO' vs 'AROUND'). We group consecutive useful records that are close in time
and share OCR words or name, then keep the best-evidenced values from the group.
"""
import re
from collections import Counter
from difflib import SequenceMatcher


def _words(rec: dict) -> set:
    text = " ".join((rec.get("ocr_lines") or {}).values()) + " " + (rec.get("name") or "")
    return {w for w in re.findall(r"[A-Z0-9]{3,}", text.upper())}


GENERIC_OBJECTS = {"screen", "door", "table", "chair", "light", "plant", "poster", "banner", "ceiling", "floor",
                   "wall", "window", "sign", "truss", "curtain", "booth", "ceiling light", "lighting truss",
                   "doorway", "pillar", "box", "backpack", "lanyard", "bottle", "laptop"}


def _names_conflict(name: str, group: list[dict]) -> bool:
    """A named frame must not join a group that already carries a clearly different name."""
    names = {(x["record"].get("name") or "").lower() for x in group} - {""}
    if not name or not names:
        return False
    n = name.lower()
    return not any(n in m or m in n or SequenceMatcher(None, n, m).ratio() >= 0.6 for m in names)


def _same_sign(fa: dict, fb: dict) -> bool:
    """fa/fb are frame rows: {'t', 'dhash', 'record'}."""
    a, b = fa["record"], fb["record"]
    na, nb = (a.get("name") or "").lower(), (b.get("name") or "").lower()
    if na and nb and (na in nb or nb in na or SequenceMatcher(None, na, nb).ratio() >= 0.6):
        return True  # 'AfterQuery' vs 'AfterQuests'
    wa, wb = _words(a), _words(b)
    if wa and wb and len(wa & wb) / len(wa | wb) >= 0.3:
        return True
    # Frames <1.5 s apart that look alike are the same view, whatever OCR made of it
    # ('AfterQuery' vs 'AltoBerry').
    ha, hb = fa.get("dhash"), fb.get("dhash")
    if (ha is not None and hb is not None and abs(fa["t"] - fb["t"]) <= 1.5
            and bin(ha ^ hb).count("1") <= 20):
        return True
    # Text-less frames of the same spot: close in time, same kind of place, mostly the same
    # DISTINCTIVE objects (screens/doors/tables are everywhere in a hall and prove nothing).
    oa = {o["name"] for o in a.get("objects") or []} - GENERIC_OBJECTS
    ob = {o["name"] for o in b.get("objects") or []} - GENERIC_OBJECTS
    pa, pb = (a.get("scene") or {}).get("place_type"), (b.get("scene") or {}).get("place_type")
    return (abs(fa["t"] - fb["t"]) <= 2.5 and pa == pb and len(oa) >= 2 and len(ob) >= 2
            and len(oa & ob) / len(oa | ob) >= 0.5)


def _score(rec: dict) -> float:
    filled = sum(1 for f in ("name", "phone", "hours", "other_text") if rec.get(f))
    return filled * 2 + len(rec.get("items") or []) * 1.5 + (rec.get("confidence") or 0) \
        + len(rec.get("objects") or []) * 0.2 - len(rec.get("rejected") or []) * 0.5


def _merge_objects(group: list[dict]) -> tuple[list[dict], list[dict]]:
    """Union of objects/relations over the frames of one sighting, with how many frames
    showed each one ('support'): something seen in 3 frames is far more trustworthy
    than something one frame mentioned."""
    objs: dict[str, dict] = {}
    for fr in group:
        for o in fr["record"].get("objects") or []:
            cur = objs.get(o["name"])
            if cur is None:
                objs[o["name"]] = {**o, "support": 1, "frame": fr["file"], "count": o.get("count", 1)}
            else:
                cur["support"] += 1
                # count = most seen at once in any single frame (frames overlap, so never sum)
                cur["count"] = max(cur.get("count", 1), o.get("count", 1))
                if len(o.get("details") or "") > len(cur.get("details") or ""):
                    cur.update(details=o["details"], position=o["position"], distance=o["distance"], frame=fr["file"])
    rels: dict[tuple, dict] = {}
    for fr in group:
        for r in fr["record"].get("relations") or []:
            key = (r["subject"], r["relation"], r["object"])
            if key in rels:
                rels[key]["support"] += 1
            else:
                rels[key] = {**r, "support": 1, "frame": fr["file"]}
    order = sorted(objs.values(), key=lambda o: -o["support"])
    return order, sorted(rels.values(), key=lambda r: -r["support"])


def _sim(a: str, b: str) -> float:
    return SequenceMatcher(None, a, b).ratio()


def _vote_items(recs: list[dict], best_rec: dict, same_value: float = 0.6) -> list[dict]:
    """Each frame's items are already verified against its own OCR, but OCR itself can
    misread a row in one frame ('6TH FLOOR ANDROID ...' vs '5TH FLOOR ARDUINO ...').
    Cluster readings of the same row by value similarity, then majority vote;
    ties go to the reading from the best-evidenced frame."""
    best_keys = {(i["label"].upper(), i["value"].upper()) for i in best_rec.get("items") or []}
    votes = Counter()
    for r in recs:
        for it in r.get("items") or []:
            lab, val = it["label"].upper().strip(), it["value"].upper().strip()
            if _sim(lab, val) > 0.8:  # '5TH FLOOR -> 5TH FLOOR' is not a fact
                continue
            if not re.search(r"[A-Z]{2}", val):  # '2 -> 11': OCR noise, no words
                continue
            votes[(lab, val)] += 1

    clusters: list[list[tuple]] = []
    for key in votes:
        for cl in clusters:
            if any(_sim(key[1], other[1]) >= same_value for other in cl):
                cl.append(key)
                break
        else:
            clusters.append([key])

    out = []
    for cl in clusters:
        winner = max(cl, key=lambda k: (votes[k], k in best_keys))
        out.append({"label": winner[0], "value": winner[1], "votes": votes[winner],
                    "alternatives": [f"{k[0]} -> {k[1]}" for k in cl if k != winner]})
    return out


def _merge_depictions(group: list[dict]) -> list[dict]:
    """Pictures on banners/screens: the same picture is described slightly differently per
    frame, so near-duplicate descriptions are merged and counted ('support')."""
    out: list[dict] = []
    for fr in group:
        for d in fr["record"].get("depictions") or []:
            for o in out:
                if o["medium"] == d["medium"] and SequenceMatcher(None, o["content"].lower(), d["content"].lower()).ratio() >= 0.55:
                    o["support"] += 1
                    o["depicted"] = sorted(set(o["depicted"]) | set(d.get("depicted") or []))
                    break
            else:
                out.append({**d, "support": 1, "frame": fr["file"]})
    return sorted(out, key=lambda d: -d["support"])


def merge_sightings(frames: list[dict], max_gap_s: float = 6.0) -> list[dict]:
    """frames: [{'t': seconds, 'file': ..., 'record': {...}}] in time order."""
    groups: list[list[dict]] = []
    for fr in frames:
        rec = fr.get("record") or {}
        if not rec.get("useful"):
            continue
        g = groups[-1] if groups else None
        if (g and fr["t"] - g[-1]["t"] <= max_gap_s and not _names_conflict(rec.get("name"), g)
                and any(_same_sign(fr, x) for x in g[-3:])):
            g.append(fr)
        else:
            groups.append([fr])

    sightings = []
    for g in groups:
        recs = [x["record"] for x in g]
        best_rec = max(recs, key=_score)
        best = dict(best_rec)
        # Majority vote on verified name across frames (fixes one-off misreads);
        # ties go to the best-evidenced frame ('aiven' over 'elevn').
        names = Counter(r["name"] for r in recs if r.get("name"))
        if names:
            best["name"] = max(names, key=lambda n: (names[n], n == best_rec.get("name"),
                                                     (best_rec.get("confidence") or 0) if n == best_rec.get("name") else 0))
        best["name_variants"] = sorted(names)
        # Fill fields the best frame missed from other frames (all already verified).
        for f in ("phone", "hours", "other_text", "subtype"):
            if not best.get(f):
                best[f] = next((r[f] for r in recs if r.get(f)), None)
        best["items"] = _vote_items(recs, best_rec=max(recs, key=_score))
        best["t"] = g[0]["t"]
        best["t_end"] = g[-1]["t"]
        best["frames"] = [x["file"] for x in g]
        best["evidence_frame"] = g[[x["record"] for x in g].index(max(recs, key=_score))]["file"]
        best["rejected"] = [rj for r in recs for rj in r.get("rejected") or []]
        best["objects"], best["relations"] = _merge_objects(g)
        best["depictions"] = _merge_depictions(g)
        # Weak = a NAME seen in one frame only that is short or low-confidence: often an OCR misread.
        name = best.get("name") or ""
        best["weak"] = bool(name) and len(g) == 1 and (len(name) <= 4 or (best.get("confidence") or 0) < 0.7)
        sightings.append(best)
    return sightings
