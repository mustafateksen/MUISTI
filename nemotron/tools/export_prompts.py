"""Regenerate docs/PROMPTS.md and docs/prompts.json from the code (run after any prompt change).

Usage (from nemotron/): python tools/export_prompts.py
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import ask  # noqa: E402
import extract as E  # noqa: E402

P = {
    "OCR_PROMPT": E.OCR_PROMPT,
    "EXTRACTION_SYSTEM": E.SYSTEM_PROMPT,
    "EXTRACTION_FEW_SHOTS": [{"user": u, "assistant": a} for u, a in E.FEW_SHOTS],
    "RECORD_SCHEMA": E.RECORD_SCHEMA,
    "PARSE_PROMPT": ask.PARSE_PROMPT, "PARSE_SCHEMA": ask.PARSE_SCHEMA,
    "ANSWER_PROMPT": ask.ANSWER_PROMPT, "ANSWER_SCHEMA": ask.ANSWER_SCHEMA,
    "LOOK_SCHEMA": ask.LOOK_SCHEMA,
    # templates: {name} / {medium} / {content} are filled in by the caller; {{ }} are literal braces
    "LOOK_REAL": ask.LOOK_REAL, "LOOK_PRINTED": ask.LOOK_PRINTED, "LOOK_PICTURE": ask.LOOK_PICTURE,
    "SUMMARY_PROMPT": ask.SUMMARY_PROMPT, "SUMMARY_SCHEMA": ask.SUMMARY_SCHEMA,
    "AGENT_PROMPT": ask.AGENT_PROMPT, "AGENT_TOOLS": ask.AGENT_TOOLS,
}
json.dump(P, open(os.path.join(ROOT, "docs", "prompts.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)


def fence(x, lang=""):
    t = x if isinstance(x, str) else json.dumps(x, indent=2, ensure_ascii=False)
    return f"```{lang}\n{t}\n```\n"


shots = "".join(f"**Örnek {i}: user mesajı**\n" + fence(s["user"]) + f"**Örnek {i}: assistant cevabı**\n" + fence(s["assistant"], "json")
                for i, s in enumerate(P["EXTRACTION_FEW_SHOTS"], 1))
head = open(os.path.join(ROOT, "tools", "_prompts_header.md"), encoding="utf-8").read()
body = f"""## 1. Extraction: system prompt
{fence(P["EXTRACTION_SYSTEM"])}
## 2. Extraction: few-shot örnekleri
{"Yok. v17'den itibaren örnek gönderilmiyor (bkz. eval/ITERATIONS.md, v15–v17). Format, system prompt'un sonundaki FORMAT NOTES ile öğretiliyor." if not shots else "Her biri system'den sonra bir user/assistant çifti olarak eklenir." + chr(10) + chr(10) + shots}
## 3. Extraction: JSON şeması
{fence(P["RECORD_SCHEMA"], "json")}
## 4. Soru ayrıştırma: system prompt
User mesajı sadece sorunun kendisi.
{fence(P["PARSE_PROMPT"])}
Şema:
{fence(P["PARSE_SCHEMA"], "json")}
## 5. Cevap: system prompt
User mesajı:
```
EVIDENCE:
E1 (seen 3 minutes ago): <kayıt metni>
...

QUESTION: <soru>
```
Kayıt metinleri etiketli olmalı (`Name on sign:`, `Other text on sign:`, `Seen object:`, `PICTURE (not a real object):` …).
{fence(P["ANSWER_PROMPT"])}
Şema:
{fence(P["ANSWER_SCHEMA"], "json")}
## 6. Görsel tekrar bakma (LOOK)
Gerçek nesne için:
```
Look carefully. Is there a real "<object name>" physically present in this photo (not just shown in a picture on a banner or screen)? Do not guess. If yes, say briefly where it is relative to other things. Return JSON {{"present": true/false, "where": "..."}}.
```
Resim içeriği için:
```
Look carefully. Is there a <medium> in this photo that shows a picture of: "<content>"? Do not guess. If yes, say briefly where that picture is. Return JSON {{"present": true/false, "where": "..."}}.
```
Şema:
{fence(P["LOOK_SCHEMA"], "json")}
## 7. Geçici metin okuma (sadece Emir'in OCR'ı yokken, offline test için)
{fence(P["OCR_PROMPT"])}
"""
open(os.path.join(ROOT, "docs", "PROMPTS.md"), "w", encoding="utf-8").write(head + body)
print("docs/PROMPTS.md and docs/prompts.json regenerated")
