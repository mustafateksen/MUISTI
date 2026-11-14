# MUISTI Android — checklist
Last updated: 2026-11-14 · branch omer/android-app · HEAD (see git log)

## Status legend
DONE = built, tested, wired into the app, verified (on device if it touches device features)
PARTIAL = works with a documented limitation or fallback
IN PROGRESS · TODO · BLOCKED (reason + what would unblock it)

Session constraint: **no phone was attached** (`adb devices` empty) and `nemotron/results/` (the video test memories)
is absent. Tasks whose "Done when" needs the device or those memories cannot be DONE in this session.

## Regression gate (latest run)
| metric | baseline | now |
|---|---|---|
| agent accuracy /31 (video set) | BLOCKED (no results/) | BLOCKED |
| fixture accuracy /20 | 20/20 | 20/20 (end of Phase 1) |
| traps abstained, hallucinations (fixture) | 10/10, 0 | 10/10, 0 |
| avg latency s / calls per question (fixture) | 1.3 / 2.4 | 1.6 / 2.2 (end of Phase 1) |
| cold start | BLOCKED (no device) | BLOCKED |
| Nemotron req/min (recording, 2 min) | BLOCKED (no device) | BLOCKED |
| unit tests | 6 pass / 3 skip / 0 fail | 34 pass / 2 skip / 0 fail (36, live tests on; end of Phase 1) |

## iOS reference (origin/main, behaviour in one line each)
- InterventionPolicy: silent < notification < chime < spoken; safety always spoken; 5-min topic pause; 40 spoken/day; 2-min gap; quiet hours 22–07 → notification; driving holds notices.
- AgentCenter: 15 s tick; home/place/calendar (0–15 min)/review/digest cues; snooze 30 min.
- Notice: one tool-calling call; quotes and numbers must appear in the prompt.
- Places/Navigator: Maps lookup ≤ 400 m, relative directions, arrival ≤ 35 m.
- CalendarReader: next 24 h, ≤ 12 events, re-read ≤ 1/min.
- BackgroundRuntime: significant-change + ≤ 18 region monitors (≥ 100 m).
- Safety: user rules + 3 auto hazard alerts (left home / idle hazard / immediate, 10 min cooldown); 20 calls/min cap; text match first, image check only on hits.
- AdaptiveScheduler: still/walking/fast intervals (refresh 3 s still, 1.5 s moving), factor ×1.5–3 for battery/heat, hold on critical heat, head turn ≥ 25° → capture.
- Memory: hybrid RRF k=60 (FTS, text vector, image vector, fuzzy 0.8, recency 0.5); episodes = ≤ 10 min gap AND ≤ 300 m; summaries after 90 s settled.
- HeadBlur: faces + pose + upper body, plates padded 25 %, pixellate then blur; failure → frame dropped.
- Voice: Siri AskIntent; media-key double tap = push-to-talk; glasses mic 16 kHz; wake word "Muisti"; barge-in after 3 words.
- KeychainStore: keys in the Keychain (this device only).

## Tasks
| ID | Task | Status | Evidence (test / log / screenshot) | Commit | Notes / limits |
|----|------|--------|------------------------------------|--------|----------------|
| S0 | Audit, checklist, baseline | DONE | docs/BASELINE.md, FixtureRegressionTest 20/20 | | on-device baseline BLOCKED (no device) |
| P1.1 | Privacy settings model and screen | PARTIAL | PrivacySettingsTest (defaults, locked classes, restart via store, toggle changes decision) | 6b74a08 | Settings screen (Settings → Privacy settings) wired; on-device P_atm_0.jpg import check BLOCKED: no device |
| P1.2 | Sensitive OCR, tested | PARTIAL | PrivacyTextTest: 19 positive + 19 negative cases, setting gate | 6b74a08 | live + import paths use PrivacyText.check(SceneHint); on-device card-photo import BLOCKED: no device. Default off (team decision) |
| P1.3 | Fail-safe audit of every image exit | DONE | PrivacyGateTest (6): extract/liveLook/lookAgain send 0 requests when gate blocks, throws, or is default; source scan finds no other image builder | 6b74a08 | Llm.gate defaults to CLOSED; PrivacyGuard.gate installed after model load |
| P1.4 | Old-memory scan that survives restarts | PARTIAL | OldMemoryScanTest: killed after 900 of 1100 frames, a new process resumes after id 900; frames 845-852, 915, 1006, 1029 deleted; crash = private | 6b397c2 | WorkManager (battery-not-low + idle; Check now = battery only); progress in Privacy settings. On-device kill/resume and the real toilet frames: BLOCKED (no device) |
| P1.5 | License-plate privacy | PARTIAL | PlateDetectorTest: 13/13 plate strings, 0/24 signs/prices/hours, box aspect + block-size filter | 5df36fb | Wikimedia 10-photo plate set + 10-photo sign set need ML Kit OCR on the phone: BLOCKED (no device). Plate text is also removed from the OCR lines sent to Nemotron |
| P1.6 | API keys out of the APK | PARTIAL | release APK: 0 dex/APK hits for the key prefix (debug/dev mode: 1); TokenClientTest; backend eval/test_token_proxy.py 5/5 (branch omer/nemotron-scene 8f1bc31, not pushed) | 5095c64 | Proxy code + tests done; not deployed (needs a host + MUISTI_TOKEN_SECRET/PAIR_CODE). Dev mode = debug build with local.properties key. Release lint disabled (AGP 8.7 lint crashes on Kotlin 2.2) |
| P1.7 | Network resilience | PARTIAL | PendingQueueTest: survives restart, cap, forget reaches queue; 20 queued frames drain oldest-first one at a time with 1.5 s pauses (max 1 in flight), server-down keeps the frame, privacy-dropped removed | 6a69eff | Offline state from ConnectivityManager (header: Offline · N queued); ingest limited to 3 concurrent (Semaphore) + MuistiRate logs peak concurrent. Airplane-mode run on device: BLOCKED (no device) |
| P1.8 | Retrieval reliability baseline (JSON report) | PARTIAL | RegressionReport writes build/<run>.json with per-question tool traces, used by ParityTest (parity_agent.json) and FixtureRegressionTest (fixture_agent.json, baseline 20/20, 0 halluc., 1.3 s, 2.4 calls) | ebbc859 | 31-question video run BLOCKED: nemotron/results not on this machine |
| D1 | Old-memory scan never finishes | PARTIAL | see P1.4 | 6b397c2 | fixed in code + JVM test; device check BLOCKED |
| D2 | Sentence vectors can go stale | DONE | gradle checkPrivacyPrompts (in preBuild): passes in sync, fails with 'privacy_prompts.json is stale' after a script edit (checked by hand); regenerated json has identical 68 vectors + source_sha256 | ebbc859 | MobileCLIP text model in git-ignored tools/mobileclip/ |
| D3 | Agent regression lost points (30 → 27/31) | BLOCKED | - | 5948ed6 | Needs the 31-question video memories (nemotron/results) to measure. Decision: fix the prompt, not the grader (the grader's must_contain checks the asked object is named, which is what users need). The exported AGENT_PROMPT already says 'name the thing asked about'; re-measure when results/ is available |
| D4 | Speech-correction gap ("not eat") | DONE | NotesTest.speechFix (bare 'not eat'/'knot it'/'not dat' fixed; 6 real sentences untouched; alternatives left to the agent); NoteCommandsLiveTest case 3 | 5948ed6 | engine/SpeechFix, applied in PhoneEngine.ask, original hearing passed to the agent |
| D5 | Glasses: unclear "Waiting…" when the Meta AI channel is stuck | PARTIAL | GlassesHintTest (stuck channel = REGISTERED + empty device list for 10 s; folded/disconnected/doffed/hot/battery/update) | bf8c736 | GlassesSource status now from SDK state only. Real stuck-channel repro needs the glasses: BLOCKED (no device) |
| D6 | "note it" (`engine/Notes.kt`) is not on this branch (never committed) | PARTIAL | NotesTest (store/search/forget, agent calls note via merged tool list); NoteCommandsLiveTest 4/4 NOTED with live Nemotron | 5948ed6 | Re-implemented: engine/Notes.kt (NoteStore + note tool, frames redacted, searchable as type note, forget clears them). Original Notes.kt was never committed, behaviour reconstructed from the prompt. On-device voice check BLOCKED (no device) |
| D7 | ParityTest crashed (NPE) without `nemotron/results` | DONE | ParityTest now skips (JUnit Assume) | | |
| D8 | Embedder called the NVIDIA API with a key that does not exist → semantic search silently off | DONE | curl /v2/embed 200; FixtureRegressionTest 20/20 | | now Verda `/v2/embed`, new cache file |
| P2.1 | Adaptive Capture Scheduler | PARTIAL | CaptureSchedulerTest: policy table, battery/heat factors, thermal >= SEVERE pauses, 60 s still = 15 windows vs walking 60 (-75 %) | 5f4188a | Wired: MotionMeter (linear accel RMS), GPS speed, battery/power-save/PowerManager thermal, glasses battery+thermal from DAT Device; header shows 'Paused · phone is too hot'. DAT SDK 1.0.1 exposes no glasses IMU (javap). On-device MuistiRate still-vs-walk measurement: BLOCKED (no device) |
| P2.2 | No-Record Zones | PARTIAL | ZonesTest (distance, point-in-zone, accuracy cap, clamp); ConfirmTest (create_zone only proposed, yes/no parsing incl. kyllä, no location -> no proposal; live model: 3/3 zone requests -> CONFIRM) | e57134b | Enforced first in considerFrame (fix + geofence), imports refused, Privacy settings list/add/remove, debug 'Simulate here'. On-device mocked-location check: BLOCKED (no device) |
| P2.3 | Memory Episodes | PARTIAL | EpisodesTest: fixture day -> 7 episodes [3,3,3,1,1,1,3], no sighting in two, shuffled input same result, later sighting leaves closed episodes unchanged; move/scene splits; video-memory variant skips (no results/). Fixture regression with episode docs: 3x 20/20 | be9823f | Rules: <=10 min gap AND <=300 m (iOS), scene change after >=5 min when no GPS. episodes.json stored; agent: episode docs in search_memory, recent lists episodes first. Timeline screen (Memories tile). Verifier fixes found by the run: item's own time and whole-hour ':00' accepted (VerifierTest). Device view: BLOCKED (no device) |
| P2.4 | AI Episode Summaries | DONE | EpisodeSummaryTest: uncited phone / invented phone / invented hour removed, inline [Mx] citations accepted and stripped; 1 request per summary, text only (no image_url), cache invalid when members change; live: 14 episodes (fixture x2) -> 14 summaries, 14 calls | next | Runs in the background loop (closed = 10 min without a new sighting, max 2/min); summaries.json; shown in Timeline and used in episode docs |
| P2.5 | Image embeddings and visual search | TODO | | | |
| P2.6 | Advanced hybrid retrieval | TODO | | | |
| P2.7 | Proactive Agent Center | TODO | | | |
| P2.8 | Safety Monitor | TODO | | | |
| P2.9 | Audio and speech | TODO | | | |
| P2.10 | Android shortcuts and assistant integration | TODO | | | |
| P2.11 | High-resolution capture | TODO | | | |
| P3.1 | Evidence-based answers (SEEN/INFERRED/UNKNOWN) | TODO | | | |
| P3.2 | Memory Timeline | TODO | | | |
| P3.3 | Natural-language memory management | TODO | | | |
| P3.4 | Contextual proactive intelligence | TODO | | | |
| P3.5 | People and places memory | TODO | | | |
| P3.6 | Memory insights | TODO | | | |
| P4.1 | UI/UX pass | TODO | | | |
| P4.2 | Battery and performance | TODO | | | |
| P4.3 | Integration tests | TODO | | | |
| P4.4 | Documentation | TODO | | | |

## Privacy truth table (what is actually enforced today)
| Protection | Enforced where | Default | Tested by |
|---|---|---|---|
| Single image exit: every image goes through `Llm.imagePart` → `PrivacyGate.check`; block or exception → nothing sent | `engine/Llm.kt`, `privacy/PrivacyGate.kt` | on; `Llm.gate` = CLOSED until the phone model is loaded | PrivacyGateTest |
| Bathroom / nudity scenes never leave the phone (cannot be switched off) | `PrivacyGuard` (MobileCLIP on the phone) + `SceneRules` + gate | on, locked | PrivacySettingsTest (rules); scene model itself: device only |
| Changing room / medical room (pause) | same, if switched on in Privacy settings | off | PrivacySettingsTest |
| PIN pad / ATM, banking screens, cards, documents (drop) | same, if switched on | off (team decision: may go to Nemotron) | PrivacySettingsTest.togglingAClassChangesTheDecision |
| Sensitive OCR: card (Luhn + issuer, split lines), IBAN (mod 97, split lines), HETU, MRZ, ID words + date/number, PIN words on keypad scenes, password words on document/screen scenes | `privacy/PrivacyRules.kt` `PrivacyText.check`, live + import paths | off (team decision), setting "Block frames with card numbers / IBAN / ID numbers / PINs" | PrivacyTextTest (19+/19−) |
| Head blur before send/store | `VisualRedactor` in live, import, live look | on | none (ML Kit: device only) |
| Plate blur + plate text removed from OCR lines | `PlateDetector` on the phone OCR boxes → `VisualRedactor`, live + import + live look | on (setting "Blur licence plates") | PlateDetectorTest (13 plates, 24 signs); photo set: device only |
| No-record zones (nothing captured: no live frame, no OCR, no privacy model, no network; imports with EXIF inside a zone refused) | per-frame `Zones.inside` on the latest fix (radius + accuracy ≤ 100 m) + Play Services geofences, checked first in `considerFrame` | no zones until the user adds one | ZonesTest; device: BLOCKED |
