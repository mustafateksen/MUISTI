"""v16e = v16b (no example scenes) + a rule against scene stereotypes.

Why: v16b's longer lists (8.9 objects/frame) included things that are typical for the kind of place
but not visible: a taxi, trash bin and railing in a Times Square close-up, a "pink vending machine" at
Shibuya, red chairs and an escalator at the far end of a mall corridor.
"""
import prompts.v16b as b

SYSTEM_PROMPT = b.SYSTEM_PROMPT + """
- Do not add things just because they are typical for this kind of place (a street usually has bins and taxis, a mall
  usually has escalators). Each object needs its own clearly visible evidence in THIS photo; small or far things you
  cannot actually make out are left out."""
FEW_SHOTS = []
MAX_TOKENS = 2500
