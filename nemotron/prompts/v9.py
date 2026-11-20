"""v9 = v8 + fixes for the errors v8 still made on train+test.

1. Costumed performer listed as "statue" (Times Square Statue-of-Liberty performer).
2. Lit / neon signs still named "screen" although details said "neon sign" -> fixed in CODE
   (postprocess), because the model's own details contradict its label.
3. Missed: kiosk (street snack booth), shop fronts in busy views, goods on night stalls (fish).
4. Invented rare landmark: blue mosaic band reported as an "aquarium with fish".
"""
import re

import prompts.v8 as v8

SYSTEM_PROMPT = v8.SYSTEM_PROMPT.replace(
    "  Only list things you can actually see. People (even costumed performers) are never objects.\n",
    "  Only list things you can actually see.\n"
    "  People are never objects - including costumed performers, mascots and 'living statues' (a person dressed as the\n"
    "  Statue of Liberty is a person, not a statue). A real statue is stone or metal on a pedestal.\n"
    "  Every shop front you can see counts as a store (put what it sells in details). A small street booth selling\n"
    "  snacks, drinks or newspapers is a kiosk. Name the goods on stalls and in windows (fish, flowers, hats, shoes).\n"
    "  Rare or striking things (aquarium, fountain, statue, slide, stage) only if you are certain: a blue wall, tiles\n"
    "  or a screen showing water is not an aquarium.\n")
MAX_TOKENS = v8.MAX_TOKENS

_SIGNLIKE = re.compile(r"\b(neon|lit sign|illuminated sign|light[- ]?box|logo|lettering|letters|store sign|shop sign|"
                       r"signboard|name sign)\b", re.I)
_VIDEO = re.compile(r"\b(video|showing|displaying|image|images|footage|game|ad |advert|animation|moving)\b", re.I)


def postprocess(rec: dict) -> dict:
    """The model's details often say 'neon sign' while the label says 'screen'. Trust the details."""
    for o in rec.get("objects") or []:
        d = o.get("details") or ""
        if o.get("name") == "screen" and _SIGNLIKE.search(d) and not _VIDEO.search(d):
            o["name"] = "sign"
    return rec
