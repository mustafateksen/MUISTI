# MUISTI for Android (test app)

Everything runs on the phone: the camera (phone or Ray-Ban Meta glasses) feeds the sharpest frame
per half second to ML Kit (text, on device) and Nemotron (called directly), and the memory is kept on
the phone. It is a Kotlin port of the Python pipeline in `../nemotron` (extract, merge, ask).

- `app/src/main/java/com/muisti/engine/` - the engine, pure Kotlin (no Android types):
  `Extractor` (extract.py), `Merge` (merge.py), `Asker` (ask.py), `TextLines`/`OcrRepair`
  (ocr_adapter.py / ocr_repair.py), `MemoryStore` + `Embedder` (store.py / embed.py), `Difflib`
  (Python's SequenceMatcher, so fuzzy matching gives the same numbers).
- Prompts are not copied by hand: the build copies `../nemotron/docs/prompts.json` into the app.
- `com/muisti/test/` - the app: camera stream, glasses (`GlassesSource`, Meta Wearables Device Access
  Toolkit 1.0.1, raw I420 frames), live voice chat, small talk when a question is not about memory.

## Build

`local.properties` (git-ignored) needs the SDK path and the keys:

```
sdk.dir=C\:/Users/<you>/AppData/Local/Android/Sdk
muisti.llmBaseUrl=<Verda OpenAI-compatible base URL>
muisti.llmModel=<model id>
muisti.llmKey=<Verda key>
muisti.embedKey=<NVIDIA embed key>
```

Then `./gradlew assembleDebug` (JDK 17+, Android SDK 35). The keys end up inside the APK: do not
share the APK outside the team.

## Glasses

Meta AI app -> Settings -> App Info -> tap the version 5 times -> Developer mode on. In MUISTI tap
"Glasses": it registers with Meta AI, asks for the camera permission there, and streams 720x1280.
If it says the glasses need an update, use the "Update glasses" button, then "Try again".

## What is real today (Nov 14, 2026)

`docs/CHECKLIST.md` is the source of truth (status, evidence, commit per task); `docs/BASELINE.md` has the baseline.
Packages: `engine/` (pure Kotlin), `privacy/`, `capture/`, `ui/`, app code in `test/`.

- Privacy: one fail-closed image exit (`Llm.imagePart` -> `PrivacyGate`); bathroom + nudity locked on; other scene
  classes, sensitive-OCR blocking (default off, team decision) and plate blur (default on) in Settings -> Privacy;
  no-record zones checked before OCR / model / network; resumable old-memory scan (WorkManager).
- Keys: debug builds use `local.properties`; release builds carry no key and pair with the token proxy
  (`nemotron/token_proxy.py` on `omer/nemotron-scene`, not deployed yet).
- Network: offline frames wait on disk and drain one by one after reconnect.
- Capture: adaptive window (motion, GPS speed, battery, heat; pauses when too hot).
- Memory: episodes, verified one-call summaries, Timeline screen, notes ("note it"), visual search (on-phone
  MobileCLIP text encoder; the build downloads 43 MB), hybrid retrieval (RRF + tie-only rerank).
- Agent: confirm-before-acting tools (no-record zone, safety rule), Agent Center (calendar, notes at places,
  closing hours; max one alert per 15 min, quiet hours), safety monitor.
- Not done: voice barge-in / glasses mic, shortcuts and QS tile, glasses photo capture, Phase 3 (except the
  Timeline), integration tests. No on-device check was possible this session (no phone attached).

Tests: `./gradlew testDebugUnitTest` (JVM). Live checks against Nemotron: add `-Dmuisti.fixture=1`.
