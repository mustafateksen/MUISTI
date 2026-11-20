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

    rows = [sorted(row, key=lambda o: o["box"][0]) for row in rows]
    rows = _join_wrapped_values(rows)
    return ["  ".join(o["text"].strip() for o in row) for row in rows]


def _join_wrapped_values(rows: list[list[dict]], x_tol: float = 0.025) -> list[list[dict]]:
    """A value that wraps onto two lines next to ONE label ("5TH FLOOR" centred between
    "ARDUINO HARDWARE LAB" / "& HACKING SPACE") ends up as a lone row + a label row.
    Glue the lone line onto the value it continues when:
      - it is a single box, left-aligned (x within x_tol) with a NON-first box of the neighbour row,
      - the vertical gap between the two value lines is small (< 0.6 x line height),
      - the label is centred on the seam between the two value lines (its middle within
        0.18 x line height of the seam) - a label merely touching the lone line is not enough.
    """
    def top(o): return o["box"][1]
    def bot(o): return o["box"][1] + o["box"][3]

    out = [list(r) for r in rows]
    i = 0
    while i < len(out):
        row = out[i]
        if len(row) == 1:
            lone, h = row[0], row[0]["box"][3]
            for j, below in ((i + 1, True), (i - 1, False)):
                if not 0 <= j < len(out) or len(out[j]) < 2:
                    continue
                nb = out[j]
                label = nb[0]
                for k, val in enumerate(nb[1:], 1):
                    if abs(val["box"][0] - lone["box"][0]) > x_tol:
                        continue
                    gap = top(val) - bot(lone) if below else top(lone) - bot(val)
                    seam = (bot(lone) + top(val)) / 2 if below else (bot(val) + top(lone)) / 2
                    centred = abs((top(label) + bot(label)) / 2 - seam) < 0.18 * h
                    if -0.5 * h < gap < 0.6 * h and centred:
                        text = (lone["text"].strip() + " " + val["text"].strip()) if below else \
                               (val["text"].strip() + " " + lone["text"].strip())
                        nb[k] = {**val, "text": text}
                        del out[i]
                        break
                else:
                    continue
                break
            else:
                i += 1
            continue
        i += 1
    return out


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
