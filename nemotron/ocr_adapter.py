"""Turn Apple Vision observations into the OCR lines extract.py expects.

Vision returns one observation per text block, in no guaranteed order. Signs need
reading order, and label/value pairs that sit side by side ('7TH FLOOR   SAUNA AND POOL')
must end up on ONE line, because the verifier only accepts items from a single line.

Input observation: {"text": str, "conf": float, "box": [x, y, w, h]}  (normalized, top-left origin)
This is the same shape the iPhone app should send in POST /ingest.
"""


def vision_to_lines(observations: list[dict], min_conf: float = 0.3,
                    row_overlap: float = 0.5) -> list[str]:
    obs = [o for o in observations if o.get("text", "").strip() and o.get("conf", 1) >= min_conf]
    obs.sort(key=lambda o: (o["box"][1], o["box"][0]))

    rows: list[list[dict]] = []
    for o in obs:
        y, h = o["box"][1], o["box"][3]
        for row in rows:
            ry = min(r["box"][1] for r in row)
            rb = max(r["box"][1] + r["box"][3] for r in row)
            overlap = min(y + h, rb) - max(y, ry)
            if overlap >= row_overlap * min(h, rb - ry):
                row.append(o)
                break
        else:
            rows.append([o])

    return ["  ".join(o["text"].strip() for o in sorted(row, key=lambda o: o["box"][0])) for row in rows]


if __name__ == "__main__":
    demo = [
        {"text": "SAUNA AND POOL", "conf": 0.95, "box": [0.40, 0.300, 0.30, 0.04]},
        {"text": "7TH FLOOR", "conf": 0.97, "box": [0.10, 0.302, 0.20, 0.04]},
        {"text": "5TH FLOOR", "conf": 0.99, "box": [0.20, 0.100, 0.50, 0.08]},
        {"text": "ARDUINO HARDWARE LAB", "conf": 0.90, "box": [0.40, 0.360, 0.35, 0.04]},
        {"text": "5TH FLOOR", "conf": 0.96, "box": [0.10, 0.362, 0.20, 0.04]},
        {"text": "zz", "conf": 0.1, "box": [0.9, 0.9, 0.05, 0.02]},
    ]
    for line in vision_to_lines(demo):
        print(line)
