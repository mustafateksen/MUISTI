"""Cheap clean-up of computer OCR lines (PaddleOCR in tests).

PaddleOCR glues words when letter gaps are small ("STHFLOOR", "ARDUINOHARDWARELAB") and swaps
look-alike characters in ordinals (S<->5). Two fixes, no invented words:
1. ordinals glued to FLOOR/FL are split and their digit fixed: "STHFLOOR" -> "5TH FLOOR"
2. a long glued token is split into words that were read cleanly elsewhere in the SAME video
   (the vocab argument), e.g. "ARDUINOHARDWARELAB" -> "ARDUINO HARDWARE LAB" when ARDUINO,
   HARDWARE and LAB were each read on their own somewhere.
"""
import re

_DIGIT = {"S": "5", "O": "0", "I": "1", "l": "1", "B": "8", "Z": "2", "G": "6"}
_ORD_GLUED = re.compile(r"\b([0-9SOIlBZG])(TH|ST|ND|RD)\s*(FLOOR|FL)\b", re.I)
_TOKEN = re.compile(r"[A-Za-z]{3,}")


def build_vocab(all_lines) -> dict[str, int]:
    """Upper-cased words (3+ letters) -> how many times they were read as a separate token."""
    vocab: dict[str, int] = {}
    for line in all_lines:
        for w in re.split(r"[^A-Za-z]+", line):
            if len(w) >= 3:
                vocab[w.upper()] = vocab.get(w.upper(), 0) + 1
    return vocab


def _split(token: str, vocab: dict[str, int]):
    """Split token into >=2 vocab words (each 3+ letters), fewest pieces; None if impossible."""
    up, n = token.upper(), len(token)
    best = [None] * (n + 1)
    best[0] = []
    for i in range(n):
        if best[i] is None:
            continue
        for j in range(i + 3, n + 1):
            if vocab.get(up[i:j], 0) >= 2 and (best[j] is None or len(best[i]) + 1 < len(best[j])):
                best[j] = best[i] + [token[i:j]]
    parts = best[n]
    return parts if parts and len(parts) >= 2 else None


_SUFFIX_DIGIT = {"ST": "1", "ND": "2", "RD": "3"}  # only one digit fits these suffixes


def _ordinal(m) -> str:
    ch, suf = m.group(1), m.group(2).upper()
    if not ch.isdigit():
        ch = _SUFFIX_DIGIT.get(suf) or _DIGIT.get(ch, ch)
    return ch + suf + " " + m.group(3)


def repair_line(line: str, vocab: dict[str, int]) -> str:
    line = _ORD_GLUED.sub(_ordinal, line)

    def fix(m):
        tok = m.group(0)
        if len(tok) < 7:
            return tok
        up = tok.upper()
        # a cut-off read of a longer known word ("Cloudinar" of CLOUDINARY) is not a glued pair
        if any(up in w and w != up for w, c in vocab.items() if c >= 2):
            return tok
        parts = _split(tok, vocab)
        # a real word read often on its own (e.g. HARDWARE) is never split; a glued token is rarer than its parts
        if not parts or vocab.get(tok.upper(), 0) >= min(vocab[p.upper()] for p in parts):
            return tok
        return " ".join(parts)

    return _TOKEN.sub(fix, line)


def repair(lines: list[str], vocab: dict[str, int]) -> list[str]:
    return [repair_line(l, vocab) for l in lines]
