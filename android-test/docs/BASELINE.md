# MUISTI Android — baseline (measured 2026-11-14, HEAD db6513c + test fixes)

Machine: Windows 11, JDK 21, Gradle wrapper, AGP 8.7.3. **No phone was attached to adb** during this session
(`adb devices` empty), so every on-device number below is BLOCKED, not guessed.

| Metric | Value | How |
|---|---|---|
| Build time `assembleDebug` (fresh app outputs, warm Gradle cache) | 30 s | `time ./gradlew assembleDebug` |
| Debug APK size | 191.6 MB (191 591 826 B) | `app/build/outputs/apk/debug/app-debug.apk` |
| Cold start (`Displayed com.muisti…`) | BLOCKED: no device | the last commit message says 1.4 s (not re-measured) |
| Unit tests | 6 passed, 0 failed, 3 skipped (before the fix: 2 crashed with NPE) | `./gradlew testDebugUnitTest` |
| Agent regression, 31 video questions (`ParityTest.askTestsLikePython`) | BLOCKED: `nemotron/results/` (processed videos) is not in git and not on this machine | |
| Agent regression, fixture day (20 q: 10 answerable, 10 traps) | **20/20**, answerable 10/10, traps 10/10, hallucinations 0, wrong 0, avg 1.3 s, 2.4 calls/question | `./gradlew testDebugUnitTest --tests "com.muisti.engine.FixtureRegressionTest" -Dmuisti.fixture=1` → `app/build/fixture_agent.{txt,json}` |
| Nemotron req/min while recording (2 min, phone camera) | BLOCKED: no device | `MuistiRate` log |
| Privacy check time per frame | BLOCKED: no device (`PrivacyGuard.Scores.ms`) | `MuistiPrivacy` log |

Endpoint smoke test (curl, the new Verda key from `local.properties`): chat with `nemotron-3.5-super-vl` → 200;
`/v2/embed` with `nemotron-3.5-embed` → 200, 2048-d vector.

Notes
- The old Embedder called `integrate.api.nvidia.com` with an NVIDIA key that does not exist on this machine, so semantic
  search was silently off. It now calls the Verda `/v2/embed` deployment (same key) with a new cache file.
- The fixture is a synthetic, committed memory (`app/src/test/resources/fixture_memory.json`). It is easier than the
  video set: use it to catch regressions between commits, not as an absolute quality number.
