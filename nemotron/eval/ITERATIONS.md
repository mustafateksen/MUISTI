# Nemotron iteration log

Model: `nemotron-3.5-super-vl` (Verda endpoint), thinking off, temperature 0.2.
Test set: `gt_whatsapp_video_1.json`, an 88 s glasses walk at Junction 2026 (480×640 WhatsApp copy).
It contains 2 booths, a floor directory with 6 floor→room pairs, and 2 traps (an unreadable booth banner and a small Finnish note).
OCR in these runs comes from Nemotron itself, standing in for Apple Vision.

## v1 → v2 (2026-11-13)

| Metric | v1 | v2 |
|---|---|---|
| Records stored | 11 | **6** (merged sightings) |
| Entity recall (Cloudinary, Arduino, directory) | 3/3 | 3/3 |
| Correct floor→room pairs | 6/6 | 6/6 |
| **Wrong floor→room pairs** | **5** (6 mentions) | **0** |
| Junk items in final memory | n/a | 0 |
| Fields rejected by code verifier | 0 (only phone/hours checked) | 7 |
| Extra real booths found | n/a | NVIDIA, Achronix* |
| Nemotron calls / wall time | 168 / 34.0 s | 175 / 38.8 s |

\* Achronix is plausible but not verifiable at 480p.

Run-to-run variance: on a first v1 run the "forbidden word" check fired 3 times ("Astronomy" invented for the unreadable booth, and a Finnish note described as "Thai text"). On the run in the table above it fired 0 times.
In v2, "Astronomy" still appears once in the stand-in OCR output, but it never reaches a record (`useful=false`).

### What changed in v2
1. **OCR lines get IDs (L01…), and every field must cite one line.** Code then checks name, phone, hours and every list item against the cited line, not only phone and hours. Numbers must match exactly, so "5TH" never fuzzy-matches "7TH".
2. **List items (label→value) are only allowed when both sit on the same OCR line.** This alone removed all 5 wrong floor pairs; the model had been pairing floors and rooms from separate lines.
3. **Stand-in OCR prompt keeps same-row text on one line.** This preserves layout for the rule above.
4. **`kind` is a fixed enum and the detail moves to `subtype`.** v1 produced free-form values such as "office directory", "building directory" and "event".
5. **Frames of the same sign merge into one sighting.** Rows are clustered by value similarity and decided by majority vote, with ties going to the best-evidenced frame. One-frame OCR misreads lose: "6TH FLOOR → ANDROID … MEETING SPACE" lost to "5TH FLOOR → ARDUINO … HACKING SPACE", and "1F FLOOR → EXIT" lost to "M FLOOR → EXIT".
6. **The caption may not mention languages or unreadable text.** This targets the "Thai text" fabrication.

### Observed model behaviour worth reporting
- On the synthetic test with the phone missing from OCR, the model still wrote the phone number it saw in the image, against an explicit instruction. Only the code verifier stopped it.
- In v1 the model invented floor→room pairs from list-shaped OCR. In v2 the same-line rule prevents this structurally, rather than asking the model nicely.

## v2 → v3 (2026-11-13, second video)

New test video `gt_whatsapp_video_2.json`: a 67 s walk through the hall, 576×768.
10 booths have a name that is clearly readable in at least one frame.

| Metric | v2 | v3 |
|---|---|---|
| Video 2: booths found | 6/10 | **8/10** |
| Video 2: stored sightings | 17 | 16 |
| Video 2: fields rejected by verifier | 16 | 5 |
| Video 1: wrong floor pairs | 0 | 0 (still 6/6 correct, 3/3 entities) |

### What changed in v3
1. **Names may wrap over up to 3 consecutive OCR lines** ("ARDUINO" / "HARDWARE LAB", "EPIC" / "GAMES"). v2 rejected these true names as unsupported, which made Arduino Hardware Lab, Epic Games and Wendy disappear. The verifier was too strict, and lowering the reject count from 16 to 5 recovered real booths. Phone, hours and items still have to sit on a single line.
2. **Sighting merge tolerates misreads.** Two names merge if they are at least 60% similar. Frames less than 1.5 s apart that look alike (image hash) also merge, whatever OCR read: "AfterQuery", "AfterQues" and "AlloBerry" are now one booth, and so are "Cloudinary" and "Clarity".
3. **A name-vote tie goes to the best-evidenced frame.** v2 stored "elevn" for the Aiven booth; v3 stores "aiven".

### Still wrong in v3
- **Pankki was lost.** It got merged into a group with "PARKING" and "GAMING" text and named "VIER AS". The image-similarity merge is too eager while walking past several booths quickly.
- **Xbox was missed.** The name was rejected because the model wrote "Xbox BETA".
- **Some fragments look like noise:** "eVe", "BY ME", "ESPOR ESBO", "Q Gaming", "E2e Agent". With the stand-in OCR at this resolution, short or odd names are often misreads. A minimum-evidence rule (seen in 2 or more frames, or confidence of at least X) is the next thing to try.
- **Run-to-run variance:** Achronix appeared in the v2 run of video 1 but not in v3.

## v4 extraction + first /ask (2026-11-13)

### Extraction v4
`other_text` is now actually filled (slogans, taglines, websites). v3's few-shots always had it null, so the model learned to skip it, and the Cloudinary slogan never reached memory. Each " / " part of `other_text` is verified against the full OCR text.

### /ask (`ask.py`), test set `eval/ask_tests.json`
The test set has 14 questions: 8 answerable and 6 traps (never seen, attribute never seen, room not on the directory).

| Metric | first run | after fixes |
|---|---|---|
| Accuracy | 11/14 | **12/14** |
| Answerable correct | 5/8 | 6/8 |
| **Traps correctly abstained** | 6/6 | **6/6** |
| **Hallucinated answers** | 0 | **0** |
| Answered but wrong | 0 | 0 |
| Avg latency / Nemotron calls | 0.19 s / 1.5 | 0.22 s / 1.57 |

The design uses at most 2 calls per question, as follows.
1. Nemotron parses the question.
2. Lexical and fuzzy search runs, with time as a soft factor.
3. Gates answer DONT_KNOW without calling the model when nothing is relevant, or when the asked phone or hours was never stored.
4. Nemotron answers from evidence E1..E5 and must give one exact quote per evidence item it uses.
5. A code verifier checks every quote, and requires every number in the spoken answer to appear in the cited evidence.

Fixes between the two runs:
- **Label the evidence fields** ("Name on sign:", "Other text on sign:"). With unlabelled fields the model did not treat the slogan as banner text and abstained.
- **Search name variants from the merge** (e.g. aiven/alven/"DATA AI").
- **Drop generic query words** ("booth", "banner") so they no longer match every memory.
- **Allow one quote per evidence item.** A single quote merged across items failed verification.

Both remaining misses are honest abstentions, not wrong answers:
- **Arduino lab floor.** In this run's stand-in OCR the directory row was read as "6TH FLOOR ANDROID ... MEETING SPACE" more often than the correct reading. So the memory itself is wrong, and the answer model correctly refused to equate "Android" with "Arduino". The cause is OCR run-to-run variance; the same video gave 6/6 floor pairs in v2 and v3 and 5/6 in v4.
- **Aiven slogan.** The memory holds "DATA & AI / CLOUD / BUILDERS", but the model did not treat that as a slogan.

## Server, end-to-end, and v5 /ask fixes (2026-11-13, autonomous run)

Both videos were replayed into the FastAPI server through `POST /ingest`, the way the phone would send them. The server blurred faces, ran the stand-in OCR and extraction, and stored the results in SQLite: 245 frames sent, 70 stored, 24 sightings. `/ask` was then tested over HTTP with 15 questions, 8 answerable and 7 traps; the trap "Which dentists did I pass today?" was added.

| Metric | server run 1 | after fixes (2 runs) |
|---|---|---|
| Accuracy | 13/15 | **15/15, 15/15** |
| Traps abstained | 7/7 | **7/7** |
| **Answered but wrong** | **1** | **0** |
| Avg latency / calls | 0.19 s / 1.57 | 0.14–0.23 s / 1.47 |

The one wrong answer was "Which gaming booths did I see?" → "NVIDIA, Achronix and Cloudinary at the GAMERGY gaming expo". Every quote in it was genuinely in its evidence, but the *inference* that these were gaming booths was false. A quote check cannot catch that kind of error.

Fixes:
- **List questions are now answered by code, not the model.** A sighting counts only if the category appears in its own kind, subtype or name. That makes this error impossible by construction.
- **Tiny stemmer.** "gaming", "games" and "game" now match each other, and "booths" counts as the generic word "booth".
- **Items with no letters are dropped.** OCR noise such as "2 → 11" no longer becomes an item.
- **New rule in the answer prompt:** the glasses are worn by the user, so "seen" means "you walked past it". The model had answered "I saw the booth but not you walking past it".
- **Answer calls run at temperature 0.**

## Extraction ablations (OCR held fixed)

`eval/ablation.py` reuses the saved v4 OCR lines and changes only the Nemotron extraction settings, then merges and scores both videos. Each variant is a single run, so small differences are noise.

| Variant | Video 1: entities / floor pairs / wrong pairs / junk | Video 2: booths found / sightings | Verifier rejections | Latency per frame |
|---|---|---|---|---|
| temp 0.0, thinking off | 3/3 · 5/6 · 0 · 1 | 8/10 · 20 | 4 | 0.48 s |
| **temp 0.2, thinking off (chosen)** | **3/3 · 6/6 · 0 · 0** | **8/10 · 16** | **2** | **0.44 s** |
| temp 0.6 (NVIDIA's vision default) | 3/3 · 6/6 · 0 · 0 | 9/10 · 15 | 4 | 0.55 s |
| temp 0.2, thinking **ON** | 3/3 · 5/6 · 0 · 1 | 8/10 · 24 | 0 | **6.3 s** |

Takeaways:
- **Thinking ON costs 14× the latency without improving accuracy.** It fragments memories more (24 sightings instead of 16) and still let one junk item through. We keep it off, as the research also suggested: reasoning modes lower abstention.
- **Thinking ON produced 0 verifier rejections.** With reasoning, the model follows the evidence rules better on its own, but the end result is no better because the verifier already catches those cases cheaply.
- **No temperature is a clear winner.** We keep 0.2, the only variant that was clean on every video-1 metric in this run.

## Privacy net
- **Server-side face blur (OpenCV YuNet) runs before Nemotron and before disk.** On small frames it detects on a 2× upscale; before that change, distant faces were missed. On one crowd frame it found 6 faces instead of 2, and booth text stays readable.
- **"Forget the last N minutes / hour" works by voice through `/ask`.** Tested on a copy of the database: "last 5 minutes" deleted 53 frames (the whole second walk) and left the first walk intact.

## v6: remember everything useful, not only text (2026-11-13)

**Goal (from the user):** remember any useful detail, such as an ashtray on the street or "stairs behind the floor directory", not only sign text.

### Extraction
Every kept frame now goes to Nemotron, including frames without text. The schema gains:
- `scene`: place_type, indoor, lighting
- `objects[]`: name, category, position, distance, details. Up to 15 per frame; the prompt lists the kinds of things worth finding again.
- `relations[]`: subject, relation, object, e.g. "directory screen" left of "elevator".

Text fields keep the strict OCR evidence rule. Visual facts cannot be checked against OCR, so the code enforces what it *can* check:
- People are never objects.
- Plurals are normalized to singular.
- A relation is dropped if it refers to an object that was not listed.
- When frames are merged, each object gets a **support** count: how many frames showed it.

### Merge fix
The first v6 merge chained different booths together through generic objects (screen, door, table): one "Modal" sighting swallowed aiven, Pankki and Epic Games. Two fixes:
- **Generic objects no longer count** as evidence that two frames show the same spot.
- **A named frame never joins a group that already has a clearly different name.**

| Video 2 | v4 (text only) | v6 first merge | v6 fixed merge |
|---|---|---|---|
| Clearly visible booths found | 7/10 | 6/10 | **9/10** |

Video 1 stayed at 3/3 entities and 6/6 floor pairs, with 0 wrong pairs.

### /ask for objects
Changes:
- **Object docs:** one memory doc per visible thing, carrying its spatial relations.
- **Synonyms:** the parse call returns them ("somewhere to sit" → chair, sofa, bench), weighted at 70% of the user's own word.
- **Visual re-check:** if an answer rests on an object, Nemotron looks again at the stored frame with a narrow yes/no question, checking the asked object first. If no frame confirms it, the answer becomes DONT_KNOW.
- **Speed:** token and similarity caching cut search time from about 1.5 s to 0.03 s; memory grew to about 1000 docs.

The test set grew to 25 questions. The new ones are 6 object questions answerable from frames I checked by eye (sofa, QR code, elevator next to the directory, basketball hoop, fire extinguisher, "somewhere to sit") and 4 object traps (ashtray, bicycles, vending machine, piano).

| Run | Accuracy | Traps abstained | Hallucinated | Answered wrong | Latency |
|---|---|---|---|---|---|
| v6 first | 23/25 | 11/11 | 0 | 0 | 1.93 s |
| + recheck up to 3 frames, caching | 25/25 | 11/11 | 0 | 0 | 0.37 s |
| + synonyms weighted 70% (run 2) | 25/25 | 11/11 | 0 | 0 | 0.35 s |

Before the fix, both misses were the visual re-check being too strict. It checked only the first evidence frame, where the sofa was not clearly visible, and it was checking the banner rather than the QR code.

### Observed visual hallucinations (why the re-check exists)
Hand-checking the frames behind detected objects showed:
- **Correct:** sofa (both videos), QR code on the Cloudinary banner, elevator next to the floor directory, white counter, fire extinguisher by the exit door.
- **Doubtful:** "stairs, left far" in a crowded hall frame, where no stairs are visible; a "round clock on pillar" that is most likely a hanging lamp.

So visual memory is less precise than OCR-backed memory. Support counts and the answer-time visual re-check are how we keep that from reaching the user.

### Live server (v6 replay: 245 frames sent, 231 stored, 140 sightings)
| Run | Accuracy | Hallucinated / wrong | Latency |
|---|---|---|---|
| first | 23/25 | 0 / 0 | 0.45 s |
| after fix, run 1 | 24/25 | 0 / 0 | 0.39 s |
| after fix, run 2 | 24/25 | 0 / 0 | 0.38 s |

Fix: the visual re-check now runs only when an answer rests **purely** on objects. "Where is the main stage?" was correctly answered from the directory ("MAIN STAGE → 3RD FLOOR"), but it was then rejected because a "stage" object it also cited failed the visual re-check. OCR-verified text evidence does not need a second look.

The remaining server miss is the Arduino-lab floor. In this replay the stand-in OCR read the directory row as "ANDROID HARDWARE LAB & MEETING SPACE → 6TH FLOOR", and the model correctly refused to treat that as the Arduino lab. Apple Vision OCR should remove this variance.

### Crash found and fixed
With 6 parallel `/ingest` requests the server died with 0xC0000005. OpenCV's YuNet face detector was being created and used from several threads at once. Detection is now serialized with a lock, and a stress test with 12 threads blurring 48 frames passes.

## v7: pictures, counts and misreadings (2026-11-14)

The user reported three problems from the live demo.

**1. "Which floor am I on?" → "You're on the 4th floor" (wrong; the user was on the 5th).**
The evidence was a small "4" plaque above the elevator. That plaque shows where the *elevator car* is. The directory screen in the same frame was titled "5TH FLOOR". The number "4" really was in the evidence, so the number check passed. The answer was a misinterpretation, not a fabrication.

Fixes:
- **Extraction:** a number on a plaque, indicator or screen gets its meaning in `details` only if that meaning is clear, e.g. "elevator position indicator showing 4" or "floor label 5TH FLOOR at top of directory". Otherwise it is recorded as "unlabeled number 4", and the model never decides the viewer's floor.
- **Answer:** the model must say whether the answer is `stated` in the evidence or `inferred` from it, and give the raw `observations`. An inferred answer becomes **UNSURE** (EMIN_DEGILIM): the system reports what it saw and draws no conclusion. The prompt also spells out that an elevator indicator never shows the user's floor, while a lobby directory title does.
- **"Where am I now?" questions** use the latest memories (last 3 min) instead of word search.
- **Result:** "You are on the 5th floor", on both runs.

**2. "basketball hoop×4", but there is only one hoop.**
The ×4 meant "seen in 4 frames", but it read as "4 hoops". Fixes:
- **Extraction:** a new per-object `count` field (how many are visible at once). The merge takes the max over frames, never the sum, because frames overlap.
- **UI:** "×N" is gone. A chip shows the real count, the tooltip says how many frames it was seen in, and things seen only once are dashed and faded.
- **Answers:** memory text says explicitly that the frame count is not an object count.

**3. Pictures on banners and screens.** A new `depictions` field: medium, what it is on, what the picture shows, and the things in it. Things inside a picture never enter `objects`. People in pictures may be described generically, while real bystanders still never are. Picture memories are labelled "PICTURE (not a real object)", answers must say "that was a photo on the Cloudinary banner", and the visual re-check asks whether there is a banner or screen showing that picture.

Examples extracted:
- **Cloudinary banner:** "collage of photos of people working with images and videos on screens"
- **ESPOO booth screen:** "aerial photo of a waterfront area with buildings and parked cars"
- **Arduino screen:** "photo of a blue circuit board"

Answers also fixed along the way: "What did the Cloudinary banner say?" had started describing the banner's look instead of its text, so OCR text memories now win for "what did it say" questions.

### Test set: 31 questions
18 answerable and 13 traps. New: 1 interpretation question (current floor), 3 picture questions, and 2 picture traps (a dog photo; a beach poster, where only a sea photo on a *screen* exists).

| Run (offline, v7 memory, same OCR as v6) | Accuracy | Traps | Hallucinated | Wrong |
|---|---|---|---|---|
| first | 30/31 | 13/13 | 0 | 0 |
| final, run 1 | **31/31** | 13/13 | 0 | 0 |
| final, run 2 | **31/31** | 13/13 | 0 | 0 |

## Next ideas to try
- Apple Vision OCR with bounding boxes instead of the Nemotron stand-in, which would also remove the OCR-stage "Astronomy".
- Temperature 0 vs 0.2 vs 0.6.
- Thinking on vs off for extraction (accuracy vs latency).
- Original-resolution video instead of the WhatsApp copy.
- A test video with phone numbers on signs.
