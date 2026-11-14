"""v16c = v16a + a counter-example shot: a plain corridor with only a door and a wall, no pictures,
no text. Teaches that not every scene has an elevator / screen / sign next to a door."""
import prompts.v16a as a

SYSTEM_PROMPT = a.SYSTEM_PROMPT
FEW_SHOTS = a.FEW_SHOTS + [(
    "OCR_LINES:\n(none)",
    {"useful": True, "kind": "indoor_space", "subtype": "corridor",
     "name": None, "name_line": None, "phone": None, "phone_line": None, "hours": None, "hours_line": None,
     "items": [], "other_text": None,
     "scene": {"place_type": "corridor", "indoor": True, "lighting": "bright"},
     "objects": [
         {"name": "door", "category": "navigation", "position": "center", "distance": "mid", "details": "plain white door, closed", "count": 1},
         {"name": "wall", "category": "building", "position": "left", "distance": "near", "details": "bare painted wall", "count": 1}],
     "relations": [{"subject": "door", "relation": "in front of", "object": "wall"}],
     "depictions": [],
     "caption": "An empty corridor with a closed white door. Nothing else is visible.",
     "confidence": 0.8})]
MAX_TOKENS = 2500
