"""v16b = no example scenes at all; the format is taught by written rules instead.

Why: v15a (no shots) lost half the pictures (6-9/14 found) and precision (91% -> 82-87%), because
the shots were what taught the depictions field and restraint. v16b keeps zero invented content but
spells out those two lessons in the instructions.
"""
import extract as E

_DISCLAIMER = """

The examples only show the JSON format. They are different places: never add an object because it appeared in an
example. Describe only what is in THIS photo."""

SYSTEM_PROMPT = E.SYSTEM_PROMPT.replace(_DISCLAIMER, "") + """

FORMAT NOTES (there are no examples):
- depictions: every banner, poster, screen or billboard that shows a PICTURE (photo, drawing, video, map, logo artwork)
  gets one depictions item. Busy shop, event and street frames usually have 1-4. Leave it empty only if no picture is
  visible. Text-only signs are not depictions.
- objects: list what you are sure is physically there. A shorter correct list is better than a long list with guesses.
  Do not add belongings carried by people (bags, backpacks, phones) and do not guess hidden rooms or buildings.
- details: 3-12 words; relations: only between objects you listed."""
FEW_SHOTS = []
MAX_TOKENS = 2500
