"""(Historical: built on the v12 production prompt; after v13c was adopted, import v14 instead.)
v13a = v12 with NEUTRAL few-shots (only change).

Why: on the glasses frames v12 invented an elevator next to a floor directory (3 frames) and an
"ashtray" (details: "yellow wet floor sign"). Both pairings are exactly what the v12 few-shots show
(directory screen + elevator + stairs; entrance door + ashtray). Few-shots prime co-occurrences.
New shots: no elevator/ashtray; the third shot teaches a direction sign with arrow directions,
counted street lamps, and that a direction sign is not a place.
"""
import extract as E

SYSTEM_PROMPT = E.SYSTEM_PROMPT.rstrip() + """

The examples only show the JSON format. They are different places: never add an object because it appeared in an
example. Describe only what is in THIS photo."""

FEW_SHOTS = [
    ("""OCR_LINES:
L01 DENTAL CLINIC
L02 Bright Smile Dental
L03 Tel. 040 123 4567
L04 Mon-Fri 8-18
L05 Gentle care for
L06 the whole family""",
     {"useful": True, "kind": "health", "subtype": "dentist",
      "name": "Bright Smile Dental", "name_line": "L02",
      "phone": "040 123 4567", "phone_line": "L03",
      "hours": "Mon-Fri 8-18", "hours_line": "L04",
      "items": [], "other_text": "DENTAL CLINIC / Gentle care for the whole family",
      "scene": {"place_type": "street", "indoor": False, "lighting": "bright"},
      "objects": [
          {"name": "sign", "category": "sign_screen", "position": "center", "distance": "near", "details": "white dentist sign with blue text", "count": 1},
          {"name": "door", "category": "navigation", "position": "left", "distance": "near", "details": "glass entrance door of the clinic", "count": 1},
          {"name": "poster", "category": "sign_screen", "position": "right", "distance": "near", "details": "poster in the clinic window", "count": 1}],
      "relations": [{"subject": "sign", "relation": "above", "object": "door"},
                    {"subject": "poster", "relation": "right of", "object": "door"}],
      "depictions": [{"medium": "poster", "on": "window poster of Bright Smile Dental",
                      "content": "photo of a smiling woman in a dentist chair", "depicted": ["woman", "dentist chair"]}],
      "caption": "A dentist entrance with a sign above a glass door and a poster in the window.",
      "confidence": 0.9}),
    ("""OCR_LINES:
L01 3RD FLOOR
L02 4TH FLOOR CAFE & LOUNGE
L03 3RD FLOOR WORKSHOP ROOM
L04 2ND FLOOR
L05 RECEPTION
L06 CITYHUB""",
     {"useful": True, "kind": "directory", "subtype": "floor directory",
      "name": "CITYHUB", "name_line": "L06",
      "phone": None, "phone_line": None, "hours": None, "hours_line": None,
      "items": [{"label": "4TH FLOOR", "value": "CAFE & LOUNGE", "line": "L02"},
                {"label": "3RD FLOOR", "value": "WORKSHOP ROOM", "line": "L03"}],
      "other_text": None,
      "scene": {"place_type": "corridor", "indoor": True, "lighting": "bright"},
      "objects": [
          {"name": "screen", "category": "sign_screen", "position": "left", "distance": "near", "details": "vertical digital directory screen listing floors", "count": 1},
          {"name": "sign", "category": "sign_screen", "position": "right", "distance": "near", "details": "floor label 3 painted large on the wall", "count": 1},
          {"name": "door", "category": "navigation", "position": "right", "distance": "mid", "details": "grey corridor door, closed", "count": 1}],
      "relations": [{"subject": "screen", "relation": "left of", "object": "door"}],
      "depictions": [],
      "caption": "A corridor with a floor directory screen, a large floor label 3 on the wall and a closed door.",
      "confidence": 0.8}),
    ("""OCR_LINES:
L01 CITY CENTRE
L02 P + METRO""",
     {"useful": True, "kind": "street", "subtype": "road junction",
      "name": None, "name_line": None, "phone": None, "phone_line": None, "hours": None, "hours_line": None,
      "items": [], "other_text": "CITY CENTRE / P + METRO",
      "scene": {"place_type": "street", "indoor": False, "lighting": "dark"},
      "objects": [
          {"name": "direction sign", "category": "navigation", "position": "center", "distance": "mid",
           "details": "arrows: CITY CENTRE straight ahead, P + METRO right", "count": 1},
          {"name": "street lamp", "category": "furniture", "position": "center", "distance": "mid", "details": "lit lamp posts along the road", "count": 4},
          {"name": "crosswalk", "category": "navigation", "position": "left", "distance": "near", "details": "white striped crossing", "count": 1},
          {"name": "bus", "category": "vehicle", "position": "right", "distance": "far", "details": "city bus with lit windows", "count": 1}],
      "relations": [{"subject": "direction sign", "relation": "above", "object": "crosswalk"}],
      "depictions": [],
      "caption": "A dark road junction with a direction sign (city centre ahead, parking and metro to the right), four lit street lamps and a crossing.",
      "confidence": 0.8}),
]
MAX_TOKENS = 2500
