"""MUISTI - Nemotron extraction step.

Frame (blurred JPEG) + on-device OCR text  ->  structured memory record (JSON).
Verbatim facts (phone, hours) are re-checked against the OCR text in code;
the model's word is never trusted on its own.
"""
import base64
import io
import json
import os
import random
import re
import time

from openai import (APIConnectionError, BadRequestError, InternalServerError,
                    OpenAI, RateLimitError)
from PIL import Image  # pip install openai pillow

def _load_dotenv(path: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")) -> None:
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.strip().split("=", 1)
                os.environ.setdefault(k, v)


_load_dotenv()

# Hackathon endpoint (Verda/DataCrunch vLLM container). Falls back to NVIDIA's public API.
BASE_URL = os.environ.get("LLM_BASE_URL", "https://integrate.api.nvidia.com/v1")
MODEL = os.environ.get("LLM_MODEL", "nvidia/nemotron-3.5-super-vl-120b-a12b")
API_KEY = os.environ.get("VERDA_INFERENCE_KEY") or os.environ["NVIDIA_API_KEY"]

RECORD_SCHEMA = {
    "type": "object",
    "properties": {
        "useful": {"type": "boolean"},
        "kind": {"type": ["string", "null"]},
        "name": {"type": ["string", "null"]},
        "phone": {"type": ["string", "null"]},
        "hours": {"type": ["string", "null"]},
        "other_text": {"type": ["string", "null"]},
        "caption": {"type": "string"},
        "confidence": {"type": "number"},
    },
    "required": ["useful", "kind", "name", "phone", "hours", "other_text", "caption", "confidence"],
}

client = OpenAI(base_url=BASE_URL, api_key=API_KEY, max_retries=0, timeout=120)

SYSTEM_PROMPT = """You extract memory records from photos taken by smart glasses.
The photo usually shows a street sign, shop front, poster or event booth. Text is in English.

You get:
1. The image.
2. OCR_TEXT: text read from the image by a separate OCR engine. It may contain errors.

Rules:
- Only report what is VISIBLE in the image. Never guess or use outside knowledge.
- For phone, hours and price: copy them exactly as they appear in OCR_TEXT. If they are not in OCR_TEXT, use null, even if you think you can read them in the image.
- If you are unsure about any field, use null.
- Never describe people, faces, clothing or license plates. Never guess anyone's identity.
- If the image has no useful text or business information, set "useful" to false.
- Write all fields in English.

Return ONLY one JSON object, no other text:
{
  "useful": true | false,
  "kind": "short category in English, e.g. dentist, cafe, plumber, event, booth, bus stop",
  "name": "business or event name, or null",
  "phone": "as written in OCR_TEXT, or null",
  "hours": "as written in OCR_TEXT, or null",
  "other_text": "other important visible text (website, address, date, price), or null",
  "caption": "one short English sentence describing what was seen",
  "confidence": 0.0 to 1.0
}"""

FEW_SHOT_USER = """OCR_TEXT:
DENTAL CLINIC
Bright Smile Dental
Tel. 040 123 4567
Mon-Fri 8-18"""

FEW_SHOT_ASSISTANT = json.dumps({
    "useful": True,
    "kind": "dentist",
    "name": "Bright Smile Dental",
    "phone": "040 123 4567",
    "hours": "Mon-Fri 8-18",
    "other_text": None,
    "caption": "A dentist sign for Bright Smile Dental with a phone number and weekday hours.",
    "confidence": 0.9,
})


def _image_part(jpeg_bytes: bytes) -> dict:
    b64 = base64.b64encode(jpeg_bytes).decode()
    return {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}


def _parse_json(text: str) -> dict:
    """Models sometimes wrap JSON in ``` fences or add a sentence; grab the object."""
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"no JSON in model output: {text[:200]}")
    return json.loads(match.group(0))


# --- verification: the evidence rule lives here, not in the prompt -------------

_OCR_FIX = str.maketrans({"O": "0", "o": "0", "l": "1", "I": "1", "S": "5", "B": "8"})


def _digits(s: str) -> str:
    return re.sub(r"\D", "", s.translate(_OCR_FIX))


def phone_supported(phone: str | None, ocr_text: str) -> bool:
    """True if the phone's digit sequence appears in the OCR text (after fixing common OCR confusions)."""
    if not phone:
        return False
    want = _digits(phone)
    if len(want) < 6:
        return False
    # compare against each OCR line and the whole text, ignoring spaces/dashes
    candidates = [_digits(line) for line in ocr_text.splitlines()] + [_digits(ocr_text)]
    return any(want in c for c in candidates)


def text_supported(value: str | None, ocr_text: str) -> bool:
    if not value:
        return False
    norm = lambda s: re.sub(r"\s+", " ", s).strip().lower()
    return norm(value) in norm(ocr_text)


def downscale(jpeg_bytes: bytes, long_side: int = 1536) -> bytes:
    """12 MP photos are wasteful: model tiles images into 512x512 (256 tokens each)."""
    img = Image.open(io.BytesIO(jpeg_bytes)).convert("RGB")
    img.thumbnail((long_side, long_side))
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=85)
    return out.getvalue()


def _call(messages: list, response_format: dict) -> str:
    """One request with backoff on 429/5xx (free tier is ~40 req/min, unofficial)."""
    for attempt in range(5):
        try:
            resp = client.chat.completions.create(
                model=MODEL,
                messages=messages,
                temperature=0.2,  # NVIDIA suggests 0.6 for vision; extraction wants low. Compare in evals.
                top_p=0.95,
                max_tokens=600,
                response_format=response_format,
                # Reasoning is ON by default and shares max_tokens -> empty content. Turn it off.
                extra_body={"chat_template_kwargs": {"enable_thinking": False}},
            )
            choice = resp.choices[0]
            if not choice.message.content:
                raise ValueError(f"empty content, finish_reason={choice.finish_reason}")
            return choice.message.content
        except (RateLimitError, InternalServerError, APIConnectionError):
            time.sleep(min(30, 2 ** attempt) + random.random())
    raise RuntimeError("Nemotron unavailable after retries")


def extract(jpeg_bytes: bytes, ocr_text: str) -> dict:
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": FEW_SHOT_USER},
        {"role": "assistant", "content": FEW_SHOT_ASSISTANT},
        {"role": "user", "content": [
            # OCR text BEFORE the image/instruction tends to help text-VQA.
            {"type": "text", "text": f"OCR_TEXT:\n{ocr_text or '(none)'}"},
            _image_part(downscale(jpeg_bytes)),
        ]},
    ]
    try:
        content = _call(messages, {"type": "json_schema",
                                   "json_schema": {"name": "memory", "schema": RECORD_SCHEMA}})
    except BadRequestError:
        # Hosted endpoint may reject json_schema; json_object still guarantees valid JSON.
        content = _call(messages, {"type": "json_object"})
    record = _parse_json(content)

    # Enforce the evidence rule in code. Keep what the model said, but mark it.
    record["phone_verified"] = phone_supported(record.get("phone"), ocr_text)
    record["hours_verified"] = text_supported(record.get("hours"), ocr_text)
    if not record["phone_verified"]:
        record["phone_unverified"] = record.pop("phone", None)
        record["phone"] = None
    if not record["hours_verified"]:
        record["hours_unverified"] = record.pop("hours", None)
        record["hours"] = None
    return record


if __name__ == "__main__":
    import sys

    img_path, ocr_path = sys.argv[1], sys.argv[2]
    with open(img_path, "rb") as f, open(ocr_path, encoding="utf-8") as g:
        print(json.dumps(extract(f.read(), g.read()), ensure_ascii=False, indent=2))
