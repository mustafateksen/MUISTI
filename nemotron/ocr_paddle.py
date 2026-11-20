"""Text reading on a computer with PaddleOCR (stand-in for the phone's Apple Vision in tests).

Why: tests used Nemotron as the text reader, which reads the same frame differently from run to
run ("ARDUINO" one time, "ANDROID" the next). PaddleOCR is deterministic, free and runs locally.
In the product the phone still reads text (Apple Vision / ML Kit) and sends the lines to /ingest.

Output = the same OCR lines the rest of the pipeline uses: one string per visual row, rows top to
bottom, side-by-side boxes joined on one row (via ocr_adapter.vision_to_lines).

Usage:  python ocr_paddle.py image.jpg [image2.jpg ...]
"""
import sys
import threading

import cv2
import numpy as np

from ocr_adapter import vision_to_lines

_engine = None
_lock = threading.Lock()  # PaddleOCR is not safe to call from several threads at once


def _get():
    global _engine
    if _engine is None:
        import os
        os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")
        from paddleocr import PaddleOCR
        try:  # PaddleOCR 3.x. oneDNN is off: on Windows CPU Paddle 3.3 fails with
            # "ConvertPirAttribute2RuntimeAttribute not support" when it is on.
            _engine = PaddleOCR(lang="en", use_doc_orientation_classify=False, use_doc_unwarping=False,
                                use_textline_orientation=False, enable_mkldnn=False)
        except TypeError:  # PaddleOCR 2.x
            _engine = PaddleOCR(lang="en", use_angle_cls=False, show_log=False)
    return _engine


def observations(img: np.ndarray, min_conf: float = 0.5) -> list[dict]:
    """[{text, conf, box=[x, y, w, h]}] normalised 0..1, origin top-left (same shape as Apple Vision input)."""
    h, w = img.shape[:2]
    out = []
    with _lock:
        eng = _get()
        if hasattr(eng, "predict"):  # 3.x
            res = eng.predict(img)
            for r in res:
                r = r.json.get("res", r.json) if hasattr(r, "json") else r
                for text, score, poly in zip(r["rec_texts"], r["rec_scores"], r["rec_polys"]):
                    out.append((text, float(score), np.asarray(poly, dtype=float)))
        else:  # 2.x
            for line in (eng.ocr(img, cls=False) or [[]])[0] or []:
                poly, (text, score) = line
                out.append((text, float(score), np.asarray(poly, dtype=float)))
    obs = []
    for text, score, poly in out:
        if not text.strip() or score < min_conf:
            continue
        x0, y0 = poly[:, 0].min(), poly[:, 1].min()
        x1, y1 = poly[:, 0].max(), poly[:, 1].max()
        obs.append({"text": text.strip(), "conf": score, "box": [x0 / w, y0 / h, (x1 - x0) / w, (y1 - y0) / h]})
    return obs


def read_lines(jpeg_or_img) -> list[str]:
    img = jpeg_or_img
    if isinstance(jpeg_or_img, (bytes, bytearray)):
        img = cv2.imdecode(np.frombuffer(jpeg_or_img, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return []
    return vision_to_lines(observations(img))


if __name__ == "__main__":
    for path in sys.argv[1:]:
        print("==", path)
        for line in read_lines(cv2.imread(path)):
            print("  ", line)
