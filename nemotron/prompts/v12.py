"""v12: QR codes as own objects + details up to 12 words (on top of v9 + v10 code rules).

Why: glasses Q&A regression 31/31 -> 28/31 after v9. The 8-word details limit cut
"... banner with white text and QR code" to "... banner with white text", so QR codes
vanished from memory. v9 never listed a QR code as its own object either.
Adopted into extract.py; this module now just reuses the production prompt.
"""
import extract as E

SYSTEM_PROMPT = E.SYSTEM_PROMPT
