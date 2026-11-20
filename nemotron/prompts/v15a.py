"""v15a = v14 (production) WITHOUT few-shot examples; code rules on.

Why: Mustafa's iOS port (main 7b8af7f, Extraction.swift) dropped all few-shots because they
steered the model ("a restaurant frame came back with the dentist example's caption") and lets the
JSON schema fix the output shape. We neutralised the shots in v13 but never measured "no shots".
"""
import extract as E

_DISCLAIMER = """

The examples only show the JSON format. They are different places: never add an object because it appeared in an
example. Describe only what is in THIS photo."""

SYSTEM_PROMPT = E.SYSTEM_PROMPT.replace(_DISCLAIMER, "")
FEW_SHOTS = []
MAX_TOKENS = 2500
