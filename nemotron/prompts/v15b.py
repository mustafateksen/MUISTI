"""v15b = v15a with the detail code rules OFF (closest to Mustafa's iOS config:
no few-shots, no screen->sign / costume / name-details rules; prompt definitions only)."""
import prompts.v15a as a

SYSTEM_PROMPT = a.SYSTEM_PROMPT
FEW_SHOTS = []
MAX_TOKENS = 2500
DETAIL_RULES = False
