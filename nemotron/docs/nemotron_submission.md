# MUISTI: Best Use of Nemotron (draft submission text)

> Draft. Numbers come from `eval/ITERATIONS.md`, measured on 2026-11-13 with Nemotron itself as stand-in OCR. Re-run and update them once Apple Vision OCR and the final videos are in.

## What we built
MUISTI is a memory for smart glasses. Ray-Ban Meta glasses see signs, booths and directory screens while you walk. Later you ask by voice, for example "Which floor is the sauna on?", and MUISTI answers *only from what the glasses actually saw*, showing the frame as evidence. If it did not see the answer, it says "I don't know".

## Which model, and what it does
**Nemotron 3.5 Super VL** (`nemotron-3.5-super-vl`, reasoning disabled) handles every language and vision step:

1. **Frame → structured memory.** It takes a face-blurred frame plus numbered OCR lines (L01, L02 …) and returns JSON matching a fixed schema: kind (fixed enum), subtype, name, phone, hours, label→value items such as directory rows, other text and a caption. **Every field must cite the OCR line it came from.**
2. **Question → query.** It turns a spoken question into `{target, category, attribute, time, synonyms}`.
   It also describes everything else worth finding later (step 1 adds scene, objects and spatial relations), and
   **re-checks a stored frame** with a narrow yes/no question before any answer that rests only on a visual object.
3. **Evidence → answer.** It writes a short spoken answer from at most five retrieved memories, with an exact quote from each memory it uses.

## Why it matters
Visual memory is only useful if you can trust it. A wrong phone number or floor is worse than "I don't know". So Nemotron is wrapped in **code-level evidence checks**, and we *measured* how often the model breaks the rules without them.

## How we improved the output quality (measured)
We hand-labelled two real walks through the Junction venue (88 s and 67 s of glasses video) and scored every change against them. The full log is in `eval/ITERATIONS.md`.

| Step | Change | Effect |
|---|---|---|
| v1 → v2 | OCR line IDs and per-field citations; directory items only accepted when label and value are on the **same** OCR line; fixed `kind` enum | Wrong floor→room pairings **5 → 0**; 11 noisy records → 6 clean ones |
| v2 | Merge frames of the same sign and vote on each row | One-frame OCR misreads ("6TH FLOOR → ANDROID LAB") lose to the reading seen most |
| v2 → v3 | Allow a sign name to span up to 3 lines (the verifier had been too strict) | Booths found on video 2: **6/10 → 8/10** |
| v4 | Few-shots that actually fill `other_text` | Slogans and taglines reach memory; "What did the Cloudinary banner say?" became answerable |
| /ask v5 | List questions answered by code from typed memories; tiny stemmer; wearer rule in the prompt | Q&A **15/15** on two consecutive runs; **0 hallucinations on 7 trap questions** |
| v6 | Remember *everything useful*, not only text. Every frame yields scene, objects (category, position, details) and spatial relations; people are never objects; relations must connect listed objects; per-object support counts across frames | Video 2 booths **9/10** (best so far); hundreds of findable objects (sofa, QR code, elevator, fire extinguisher…) |
| /ask v6 | One memory doc per object; Nemotron-generated synonyms ("somewhere to sit" → chair, sofa); **visual re-check**: Nemotron looks at the stored frame again before answering from an object-only memory | Q&A **25/25** offline and **24/25** on the live server, including 10 object questions; **0 hallucinations on 11 traps** (ashtray, piano…) |

**Things we observed about Nemotron's behaviour, and how we answered them:**
- **It ignores "only copy from OCR" instructions.** On a sign whose phone number was missing from the OCR text, it still wrote the number it could see in the image. *Prompting alone is not enough*, so the rule is enforced in code: numbers must match the cited line exactly, and text may differ only by small OCR typos.
- **It builds false inferences from true quotes.** It answered "NVIDIA, Achronix and Cloudinary at the GAMERGY gaming expo"; every quote existed, but the conclusion was false. A quote check cannot catch this, so category list questions are now answered deterministically from Nemotron's own typed extraction.
- **Its visual memory is less precise than its text memory.** When we hand-checked object detections, sofas, QR codes and elevators were right, but it also reported "stairs" in a crowded hall frame where none are visible and called a hanging lamp a "clock". So an object-only answer is never trusted directly: Nemotron is asked a narrow yes/no question about the stored frame first, and "not sure" wins if no frame confirms it.
- **Reasoning mode is not worth it here.** With OCR held fixed, thinking ON took **6.3 s instead of 0.44 s** per frame, with no accuracy gain and more fragmented memories.

## Final numbers (stand-in OCR; to be updated)
- **Extraction, video 1:** 3/3 entities and 6/6 floor→room pairs correct, 0 wrong pairs.
- **Extraction, video 2:** 8–9 of 10 clearly visible booths found.
- **Q&A:** 25/25 offline and 24/25 on the live server (14 answerable, 11 traps, 10 of them about objects), **0 hallucinated or wrong answers**. The single miss is an honest "I don't know", caused by stand-in OCR reading "Arduino" as "Android".
- **Speed:** about 0.2 s per answer, with at most 2 Nemotron calls; questions with nothing relevant in memory skip the model entirely.

## Honest limitations
- **Ground truth is two short videos that we labelled ourselves.** Results vary between runs, mainly because of the stand-in OCR.
- **Finnish text is out of scope.** The demo and the prompts are English-only.
- **Category questions need the category word in the sign or in the extracted type.** "Gaming booths" does not include Xbox unless the sign or the type says so.
