"""v13b = v13a + rules for the glasses/night errors.

- Wayfinding: direction signs keep each destination WITH its arrow direction; a direction sign is not
  the place it points to (v12 classified the Espoo road sign as a "metro station" named Kiviruukki).
- Elevator only when its doors AND buttons / floor indicator are clearly visible (3 invented elevators).
- Vocabulary for things v12 misnamed: drink cooler / fridge, wet floor sign, traffic signs, floor label.
- Count repeated things (v12: "street lamp x1" with ~8 lamps). Dark scenes: still list what is lit.
"""
import prompts.v13a as a

SYSTEM_PROMPT = a.SYSTEM_PROMPT.replace(
    "  Rare or striking things (aquarium,",
    "  Direction / wayfinding signs: name it \"direction sign\" and put every destination WITH its arrow direction in details\n"
    "  (e.g. \"arrows: P + METRO left, CENTRE straight ahead\"). A direction sign is not the place it points to: do not use\n"
    "  its destinations as kind, subtype or name.\n"
    "  Large numbers or codes painted on walls or pillars (B2, 05, L3) are floor labels: name \"sign\", details \"floor label B2\".\n"
    "  Elevator only if you clearly see elevator doors AND call buttons or a floor indicator; a plain wall or door is not one.\n"
    "  Use these names when they fit: drink cooler (glass-front fridge with drinks), wet floor sign (yellow warning stand),\n"
    "  traffic sign (yield, no entry, crossing, roundabout), traffic light, doormat.\n"
    "  count: repeated things are counted (8 street lamps = one object with count 8).\n"
    "  In dark or night scenes still list what you can see: lit lamps, lit signs, windows, vehicles with lights, silhouettes.\n"
    "  Rare or striking things (aquarium,")
FEW_SHOTS = a.FEW_SHOTS
MAX_TOKENS = 2500
