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
