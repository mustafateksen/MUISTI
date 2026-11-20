"""v16d = v16a, but the wayfinding shot shows ONE panel with ONE arrow covering both destinations.

Why: with v16a the Espoo sign still came back "P + METRO straight ahead, ESPOONLAHDEN right" 3/3,
while no-shot variants read "P + METRO left" 3/3. The v16a shot gives every text line its own
direction (left / straight ahead), and the model copied that pattern onto a panel whose single left
arrow covers several lines.
"""
import copy

import prompts.v16a as a

SYSTEM_PROMPT = a.SYSTEM_PROMPT
_u, _a = a.FEW_SHOTS[2]
_a = copy.deepcopy(_a)
_a["objects"][0]["details"] = "one panel, one left arrow for both: OLD LIGHTHOUSE and BOTANIC GARDEN left"
_a["caption"] = ("A dark road junction with a direction sign (one left arrow for the old lighthouse and the botanic "
                 "garden), four lit street lamps and a crossing.")
FEW_SHOTS = [a.FEW_SHOTS[0], a.FEW_SHOTS[1], (_u, _a)]
MAX_TOKENS = 2500
