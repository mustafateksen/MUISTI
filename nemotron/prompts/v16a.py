"""v16a = v14 with the wayfinding few-shot made neutral (only change).

Why: without few-shots (v15a/b) the Espoo sign was read "P + METRO left" (correct); with the v14
shot ("CITY CENTRE straight ahead, P + METRO right") it came back "P + METRO straight ahead".
The shot's own words leaked into the real sign. New shot uses destinations that rarely appear on
real signs and different directions.
"""
import copy
import json

import extract as E

SYSTEM_PROMPT = E.SYSTEM_PROMPT
_u, _a = E.FEW_SHOTS_V14[2]
_a = copy.deepcopy(_a)
_u = "OCR_LINES:\nL01 OLD LIGHTHOUSE\nL02 BOTANIC GARDEN"
_a["other_text"] = "OLD LIGHTHOUSE / BOTANIC GARDEN"
_a["objects"][0]["details"] = "arrows: OLD LIGHTHOUSE left, BOTANIC GARDEN straight ahead"
_a["caption"] = ("A dark road junction with a direction sign (old lighthouse to the left, botanic garden straight "
                 "ahead), four lit street lamps and a crossing.")
FEW_SHOTS = [E.FEW_SHOTS_V14[0], E.FEW_SHOTS_V14[1], (_u, _a)]
MAX_TOKENS = 2500
assert "METRO" not in json.dumps(FEW_SHOTS)
