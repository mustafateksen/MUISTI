"""v13d = v13c + panel-arrow rule for direction signs.

Why: on the Espoo night photo every variant wrote "P + METRO straight ahead, ESPOONLAHDEN ... right",
but one LEFT arrow on the panel covers both KIVIRUUKKI/STENBRUKET and P + METRO; the separate small
right-turn sign has no text. The model assigned one arrow per text line and guessed the rest.
"""
import prompts.v13c as c

SYSTEM_PROMPT = c.SYSTEM_PROMPT.replace(
    "  its destinations as kind, subtype or name.\n",
    "  its destinations as kind, subtype or name.\n"
    "  One arrow on a sign panel applies to EVERY destination printed on that same panel. Give each destination the arrow\n"
    "  of its own panel. If you cannot see which arrow belongs to a destination, write \"direction unclear\" - never guess.\n"
    "  A small separate arrow sign without text is its own sign (e.g. \"separate right-turn arrow sign\").\n")
FEW_SHOTS = c.FEW_SHOTS
MAX_TOKENS = 2500
postprocess = c.postprocess
