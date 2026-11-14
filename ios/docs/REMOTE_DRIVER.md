# Muisti remote driver: a guide for the agent that will use it

You (a coding agent on a Mac) can drive the Muisti app like a person wearing the glasses: show it a recorded video or photos as if the glasses saw them, ask it questions, and read what it answered and what it said on its own. This is for preparing a demo video and for trying whole scenarios without wearing the glasses.

You do not need Xcode, and you do not build or change the app. The app is already installed on the phone (a DEBUG build, installed by cable from the owner's Mac). You only send HTTP requests to it over Wi-Fi with the tool in this repository.

## What you need

- The iPhone with Muisti installed, unlocked, with **Muisti open in front** the whole time (a phone that locks or shows another app stops answering).
- The Mac and the phone on the **same Wi-Fi network**.
- `python3` (comes with macOS) and the file `ios/tools/muisti-drive` from this repository. Nothing to install.

## Switching the driver on (on the phone)

1. In Muisti: Settings › turn on "Developer options" › open the Developer screen.
2. Turn on **Remote driver**.
3. The screen now shows an **Address** (like `http://192.168.1.23:8765`) and a **Token**. Ask the person holding the phone to read both to you, or to send them to the Mac.

iOS may ask once whether Muisti may find devices on the local network: the answer must be Allow.

On the Mac, in the shell you run commands from:

```bash
export MUISTI_DRIVER_URL="http://192.168.1.23:8765"   # the Address from the phone
export MUISTI_DRIVER_TOKEN="…"                         # the Token from the phone
cd <repository>/ios
python3 tools/muisti-drive state
```

`state` printing JSON means you are connected. Do not print the token, do not write it into files in the repository.

## Commands

| Command | What it does |
|---|---|
| `muisti-drive state` | What Muisti holds now: number of memories, frames still being processed, open reminders, destination and route, named places, safety rules, pending yes/no question, and the notes text the model sees |
| `muisti-drive video clip.mp4 [--step 1.0] [--speed 4] [--motion walking] [--track track.json]` | Plays a video as the glasses' view. One frame is taken every `--step` seconds of the video and fed `--speed` times faster than real time (`0` = as fast as they can be processed). The file is uploaded to the phone. Returns at once; the video keeps playing |
| `muisti-drive wait [--timeout 180]` | Waits until the video is fed and every frame is read, described and indexed. Always run this before asking about a video |
| `muisti-drive frame photo.jpg [--no-store]` | Shows one photo as what the glasses see right now. It is stored as a memory and becomes the "live view" for questions like "what is this?". `--no-store`: live view only |
| `muisti-drive ask "question"` | Asks like a user (typed, in any language). Prints the answer, its label, the evidence records and how long it took. Add `--trace` for the stage timings. The conversation carries over between asks, as in real use |
| `muisti-drive evidence <record id> out.jpg` | Saves the stored frame (faces already blurred) of an evidence record |
| `muisti-drive events` | Everything Muisti brought up **by itself** since your last `events` call, and everything it decided to keep to itself, with the reason. `--all` prints the whole log |
| `muisti-drive reply yes\|no\|not_now` | Answers a yes/no question Muisti is waiting on (see `state`) |
| `muisti-drive location <lat> <lon> [--course DEG] [--speed M/S]` | Tells Muisti where the user is now |
| `muisti-drive motion walking\|stationary\|automotive\|…` | Tells Muisti how the user is moving |
| `muisti-drive tick [--review]` | Lets the agent check the clock and position right now (it also does this by itself every 15 s). `--review`: also its own look at how the day is going, at once |
| `muisti-drive log <object> <value> [--at "yyyy-MM-dd HH:mm"] [--kind action\|state]` | Adds an entry to the safety log (`log medicine taken --at "2026-11-13 08:15"`): earlier days for the habits demo |
| `muisti-drive habits` | What Muisti counts as the user's habits from the log, and whether each happened today |
| `muisti-drive chat` / `chat-clear` | The conversation as the app's Ask tab shows it; start a new one |
| `muisti-drive memories [--limit 30]` | The newest memories (id, time, title, street) |
| `muisti-drive delete-memory <id>` / `forget <minutes>` | Delete one memory; forget the last N minutes |
| `muisti-drive intent <id> done\|remove` | Finish or remove a reminder (ids are in `state`) |
| `muisti-drive rule <id> on\|off\|delete` | A safety rule (ids are in `state`) |
| `muisti-drive settings [key=value …]` | The assistant's switches and limits (run without arguments to see them) |
| `muisti-drive screen ask\|memory\|safety\|notes\|back` | What the phone shows, for a screen recording |
| `muisti-drive reset --yes` | Deletes all memories, rules and notes in the app. Only when a clean start is wanted |

Labels in answers: `GORDUM` = seen, answered from evidence; `EMIN_DEGILIM` = not sure; `BILMIYORUM` = not seen / not known.

Event levels: `spoken` (Muisti would say it aloud through the glasses), `chime` (a short sound and a note on the phone), `notification`, `silent` (it decided to say nothing; the reason is given).

## A first session

```bash
D="python3 tools/muisti-drive"
$D reset --yes                                   # only if a clean start is wanted
$D video ~/Movies/walk.mp4 --step 1 --speed 4 --motion walking
$D wait --timeout 300
$D state                                         # how many memories were kept
$D ask "What did I see?"
$D ask "What was the phone number on the sign?"
$D ask "And where was it?"                       # follow-up: the conversation is remembered
$D events                                        # anything Muisti brought up on its own
```

Sample photos are in `ios/tools/samples/` (credits in `CREDITS.txt`):

```bash
$D frame tools/samples/board_equation.jpg --no-store
$D ask "Can you solve this?"
$D frame tools/samples/price_tag.jpg --no-store
$D ask "How much do I pay?"
$D frame tools/samples/medicine.jpg              # no question: Muisti should ask by itself
$D wait; $D events                               # e.g. "I see your medicine … Have you taken it today?"
```

## Scenarios worth recording

Muisti is an agent: much of what matters is what it says **without being asked**. After every video or frame, run `wait` and then `events`.

- **Remembering:** play a walk past signs and shops; ask what was seen, where, what a sign said, what came before or after something. Check the evidence frame with `evidence`.
- **Reminders on sight:** `ask "Tell me when you see a pharmacy, I need to pick up my prescription"`, then play a video that passes a pharmacy. `events` should show the reminder at the pharmacy and silence elsewhere.
- **Reminders at a time or place:** `ask "Remind me to call the dentist at 15:30"`; `ask "Remind me to buy milk"` and then `location` near a grocery store.
- **Its own initiative:** show medicine, a lit stove, keys left on a table without asking anything. It may ask "have you taken it today?".
- **Directions:** `location` first, then `ask "I'm going to <a real place nearby>"`. `state` shows the route. Send `location` points along the way: `events` shows each turn; walk the wrong way and a new route comes.
- **Safety rules:** `ask "Warn me if I leave the stove on when I go out"`, `reply yes`, show `stove_on.jpg` twice a few seconds apart, then `ask "I'm leaving"`.
- **Working things out:** a board with an equation, a price tag with a discount, a menu to translate: `frame … --no-store` and ask.
- **Forgetting:** `ask "Forget the last 10 minutes"`.
- **Places:** give frames positions (`location` before `frame`/`video`), then ask about a place: `ask "Did I see a pharmacy in Istanbul?"` answers plainly that nothing was seen there, without showing something from elsewhere; `ask "Did I see one here?"` searches only around the current `location`.
- **Habits:** `log medicine taken --at "<yesterday> 08:15"` for the last four or five days, then (after the usual hour today) `tick --review`; `events` shows Muisti asking about the medicine by itself. Add `log medicine taken` for today and the next review stays silent.
- **Did I do it?:** with a safety rule or automatic watching on, play a clip at `--step 1` in which a door is locked or a stove turned off (hands in view), then `ask "Did I lock the door?"`: the answer comes with the frames of that moment (`safety_frames` in the result), and says so honestly when the frames show the door but not the locking.

For the demo recording itself, the person holds the phone and screen-records it while you drive, or records the terminal: what you see in `ask` and `events` is exactly what the app shows and would say.

## Doing things while a video plays

`video` returns at once and the video keeps playing in the app. While it plays you can run any other command — `ask`, `events`, `location`, `screen` — exactly as a person would talk to Muisti while walking. For a demo, play the clip at `--speed 1` (real time), start the screen recording on the phone, and send your questions at the moments the script calls for.

## Giving a video a position

A video file has no GPS. Without a position, place and direction features stay off. Two ways:

- one position for the whole clip: `muisti-drive location 60.1719 24.9414` before `video`;
- a track: a JSON file `[{"t": 0, "lat": 60.1719, "lon": 24.9414}, {"t": 12, "lat": 60.1722, "lon": 24.9409}, …]` (`t` = seconds into the video) passed with `--track`.

## What this does not test

- **Voice.** Questions go in as text and answers come back as text. The microphone, speech recognition and the glasses' speaker are not involved. (Muisti is muted while the driver is on.)
- **The real camera path.** Frames are taken from the file at fixed steps; the glasses' own frame picking (by head and body movement) is not involved. Everything after that is the real path: text reading, blurring, memory, enrichment, safety, agent.
- **Action detection across frames** (did the user turn the stove off) depends on frames a few seconds apart with hands in view: use `--step 1` or less for such clips. It has not been measured yet.
- **Background behaviour.** Muisti must stay open in front.

## Things to know

- Faces and number plates are blurred on the phone before anything is stored or sent. A frame showing a bathroom, toilet or shower is withheld entirely (`frame` answers `"withheld": true`), and so is every frame of the 20 seconds after it (`settings private_pause=0` switches that wait off for tests that show unrelated photos one after another).
- An answer that something was not seen comes without evidence frames; nothing "closest" is shown in its place.
- Frames that are blurry, or the same as the one before, are dropped on purpose: `"kept": false` is normal for many frames of a video.
- Each kept frame is described by the model after it is stored (1–3 s each). Until `wait` returns, answers may miss the newest frames.
- A video of a few minutes at `--step 1` is a few hundred frames: allow several minutes. Keep clips under ~200 MB (the upload is held in the phone's memory).
- The token gives full access to Muisti's memory, including deleting it. Switch the driver off on the phone when you are done.
- If a command says it cannot reach the app: is Muisti in front and the phone unlocked, are both on the same Wi-Fi, is the address still the one on the screen (it can change when the phone reconnects)?

## For the owner of the app (not needed for driving)

- The driver exists only in DEBUG builds (`Muisti/Debug/RemoteDriver.swift`, `#if DEBUG`). It is off until switched on in the Developer screen, or started with the launch argument `--remote-driver=<port>|<token>` (add `--remote-driver-speak` to keep the voice on).
- On a Mac with Xcode the same tool works against the simulator: launch with the argument, leave `MUISTI_DRIVER_URL` unset (`http://127.0.0.1:8765`).
- New versions of the app have to be installed by cable from the owner's Mac; with a free Apple developer account an installed build stops opening after 7 days.
- The model key travels inside the installed app (from the git-ignored `Muisti/Resources/Secrets.plist`); it is never needed on the driving side.
