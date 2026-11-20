"""v8: coverage + naming + brevity.

Why (v7 on 20 train frames): recall_must 61% (buildings, stores, cranes, cars, chandelier,
umbrella, railing, column, bin missed; 4.8 objects/frame); "screen" used for lit/neon signs;
one frame returned truncated JSON (very long picture descriptions on Times Square).
"""
import extract as E

# Historical: written against the v7 prompt. After later versions were adopted into extract.py this
# rebuilds only an approximation; it must still import.
_OBJECTS_V7 = E.SYSTEM_PROMPT[E.SYSTEM_PROMPT.index("- objects:"):E.SYSTEM_PROMPT.index("- relations")]

_OBJECTS_V8 = """- objects: describe the scene so that ANY clearly visible thing can be found again later. List 8-15 objects.
  Go through these groups and include what is clearly visible from each (largest / most useful first):
    1. ways to move: stairs, escalator, elevator, door, entrance, exit, crosswalk, ramp, bridge
    2. structures and landmarks: building (say what kind in details: mall, office tower, shop front), store, statue,
       crane, scaffolding, column, arch, fountain, aquarium, slide, stage
    3. vehicles: car, taxi, bus, bicycle, pedicab, scooter, truck
    4. furniture and amenities: bench, chair, table, sofa, counter, trash bin, ashtray, umbrella, chandelier, lamp,
       street lamp, railing, kiosk, vending machine, ATM
    5. signs and media: sign, screen, billboard, poster, banner, flag, traffic light, QR code
    6. nature: tree, plant, flower, water
    7. goods on display: mannequin, clothing rack, display case, hat, shoe, fish
  Use these words exactly when they fit:
    screen = an electronic display showing video or changing images (TV, LED wall, monitor, digital billboard).
    sign = fixed lettering or a logo, lit or not (shop sign, neon sign, store name). A lit sign is NOT a screen.
    billboard = a large printed or digital advertisement panel on a building or pole.
    poster = a printed picture or advert on a wall, window or stand. banner = hanging fabric/vinyl.
  For each: name (simple English noun, singular), category, position in the frame (left/center/right), distance (near/mid/far),
  details (at most 8 words: colour, material, kind, state), count (how many of this thing are visible in THIS frame).
  Numbers on plaques, indicators and screens: say in details what the number MEANS only if it is clear
  (e.g. "elevator position indicator showing 4", "floor label 5TH FLOOR at top of directory").
  If you cannot tell what a number means, write "unlabeled number 4". Never decide which floor the viewer is on.
  Only list things you can actually see. People (even costumed performers) are never objects.
"""

SYSTEM_PROMPT = E.SYSTEM_PROMPT.replace(_OBJECTS_V7, _OBJECTS_V8).replace(
    "content (one sentence: what the picture shows,",
    "content (at most 15 words: what the picture shows,").replace(
    "- For each picture you can make out, add one depictions item:",
    "- For each picture you can make out (max 4, largest first), add one depictions item:").replace(
    "- relations: spatial facts", "- relations (max 6): spatial facts")

MAX_TOKENS = 2500
