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
| fixture accuracy /20 | 20/20 | 20/20 |
| traps abstained, hallucinations (fixture) | 10/10, 0 | 10/10, 0 |
| avg latency s / calls per question (fixture) | 1.3 / 2.4 | 1.3 / 2.4 |
| cold start | BLOCKED (no device) | BLOCKED |
| Nemotron req/min (recording, 2 min) | BLOCKED (no device) | BLOCKED |
| unit tests | 6 pass / 3 skip / 0 fail | 6 / 3 / 0 |

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
| P1.1 | Privacy settings model and screen | TODO | | | |
| P1.2 | Sensitive OCR, tested | TODO | | | |
| P1.3 | Fail-safe audit of every image exit | TODO | | | |
| P1.4 | Old-memory scan that survives restarts | TODO | | | |
| P1.5 | License-plate privacy | TODO | | | |
| P1.6 | API keys out of the APK | TODO | | | |
| P1.7 | Network resilience | TODO | | | |
| P1.8 | Retrieval reliability baseline (JSON report) | TODO | | | |
| D1 | Old-memory scan never finishes | TODO | | | = P1.4 |
| D2 | Sentence vectors can go stale | TODO | | | |
| D3 | Agent regression lost points (30 → 27/31) | TODO | | | |
| D4 | Speech-correction gap ("not eat") | TODO | | | |
| D5 | Glasses: unclear "Waiting…" when the Meta AI channel is stuck | TODO | | | |
| D6 | "note it" (`engine/Notes.kt`) is not on this branch (never committed) | TODO | `git log --all -- '*Notes.kt'` is empty | | the spec says to preserve it |
| D7 | ParityTest crashed (NPE) without `nemotron/results` | DONE | ParityTest now skips (JUnit Assume) | | |
| D8 | Embedder called the NVIDIA API with a key that does not exist → semantic search silently off | DONE | curl /v2/embed 200; FixtureRegressionTest 20/20 | | now Verda `/v2/embed`, new cache file |
| P2.1 | Adaptive Capture Scheduler | TODO | | | |
| P2.2 | No-Record Zones | TODO | | | |
| P2.3 | Memory Episodes | TODO | | | |
| P2.4 | AI Episode Summaries | TODO | | | |
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
| Bathroom / nudity scenes never leave the phone | `PrivacyGuard.ACTIVE` (MobileCLIP on the phone) + `Llm.imageGuard` | on (hardcoded) | none (device only) |
| Exit guard fail-closed (model missing → private) | `PhoneEngine` sets `imageGuard = { true }` until the model loads | on | none |
| PIN pad / card terminal scenes | scored, but `pin` is not in ACTIVE | off (team decision) | none |
| Sensitive OCR (card Luhn, IBAN, HETU, PIN words) | `PrivacyText.check` in the live and import paths | off (`enabled = false`) | PrivacyTextTest (3 tests) |
| Head blur before send/store | `FaceBlurrer` in live, import, live look | on | none |
| Plate blur | not implemented | — | — |
| No-record zones | not implemented | — | — |
