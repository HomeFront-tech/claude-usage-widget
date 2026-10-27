# Voice ("okay Buddy" and spoken lines) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Buddy listens for "okay Buddy", takes a hands-free chat turn, and speaks his
answers (and, by a slider, his own lines) with his mouth in sync with the audio.

**Architecture:** A small Swift helper (`ear/buddy-ear`, built on the owner's Mac) owns the
mic and the speaker. It splits speech into utterances by pauses, transcribes them live
with Apple's on-device `DictationTranscriber`, and plays speech through the same
`AVAudioEngine` with voice processing on while it plays, so Buddy never hears himself.
It talks JSON lines over stdin/stdout to `voice.lua`, which runs the wake/turn rules
and the speaking rules. `speech.lua` turns text into audio files.

**Tech Stack:** Hammerspoon Lua, Swift 6 (AVFoundation, Speech, CoreAudio), macOS 26+, `say`.

**Spec:** `docs/superpowers/specs/2026-10-26-buddy-voice-design.md`

## What the spike proved (2026-10-26, on the owner's Mac; code was throwaway)
- Started by Hammerspoon (`hs.task`), the helper gets the mic with no new prompt, and
  SpeechAnalyzer needs no speech-recognition permission.
- Voice processing removes Buddy's own voice from the mic completely, and it also removes
  any other audio the Mac plays. The owner talking over Buddy was still heard.
- `SpeechTranscriber` heard "okay Bobby". `DictationTranscriber` with contextual strings
  `["okay Buddy", "OK Buddy", "Buddy"]` heard "Okay Buddy" 6 out of 6 times, with the
  phrase showing up 0.4 to 0.6 s after it was said.
- `DictationTranscriber` never ends a result on its own (a whole minute came back as one
  result), and CPU climbed from 7% to 17% as that result grew. So the helper must find
  utterances itself, feed the analyzer only while someone is talking, and call
  `finalize` at each utterance's end.
- Voice processing fails to start (-10875) unless `engine.outputNode` and
  `engine.mainMixerNode` are touched before `setVoiceProcessingEnabled(true)`. With it on,
  the input has 3 channels: take channel 0 (`converter.channelMap = [0]`).
- Ducking setting used: `AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)`.
- Several AVAudioEngine calls are deprecated on macOS 27 but still work. Warnings are fine.

## Global Constraints
- Public repo: no personal names, phone numbers, addresses or business details in code,
  tests, docs or screenshots. Write "the owner".
- Off by default: with no voice settings saved, Buddy behaves exactly as today, and no
  helper process runs.
- Settings live in `hs.settings` key `claudeBuddy.voice`:
  `{ listen = false, answers = false, outLoud = 0, voice = { engine = "system", name = nil }, phrase = "okay Buddy" }`.
  Turning `listen` on for the first time also sets `answers = true`.
- `config.lua` may hold `voice = { gap = 1.0, timeout = 6, phrase = "okay Buddy" }`
  (defaults when the settings have no value). Document it in `config.example.lua`.
- Everything about hearing and speech stays on the Mac. No audio is written to disk
  except the temporary speech files, which are deleted after playing.
- macOS older than 26, or no `swiftc`: the Voice menu and wizard step say what's missing
  ("Voice needs macOS 26 or later." / "Voice needs Apple's Command Line Tools:
  xcode-select --install") and nothing else changes.
- Never pick a remote-desktop app's virtual audio devices. The helper uses the system's
  default input and output.
- A batch release is on: work only in `.claude/worktrees/voice-wake` (branch
  `voice-wake`), stage by explicit path, never merge, push, tag, bump VERSION or run
  `tools/release`.
- Lua specs: `/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests`. Python:
  `/usr/bin/python3 -m unittest discover -s tests -v`.

## Review Focus
1. The USB mic is unplugged, replugged, or the default input changes while listening:
   the helper rebuilds its engine and keeps listening, with no crash loop (Task 2 test).
2. "okay Buddy" while the chat panel is already open with typed text that hasn't been
   sent: the typed text stays, the spoken words go after it, and sending sends both
   (Task 6 test).
3. An answer that's all code, a link or a list: nothing is spoken, his mouth doesn't move,
   and nothing errors (Task 4 test).
4. The chosen voice disappears (wrapper deleted, system voice removed): it falls back to
   the default system voice, and if that fails too he shows the line silently with one
   bubble saying his voice isn't working (Task 4 test).
5. A Hammerspoon reload while listening or speaking: the old helper is gone afterwards,
   there's never more than one `buddy-ear` process, and no orphan holds the mic (Task 5 test).

---

### Task 1: The helper hears utterances

**Files:**
- Create: `ear/ear.swift`, `ear/Info.plist`, `ear/build.sh`
- Modify: `.gitignore` (add `ear/buddy-ear`, `ear/buddy-ear.hash`)
- Test: `tests/test_ear.py`

**Interfaces:**
- Produces: `ear/build.sh` builds `ear/buddy-ear` and writes `ear/buddy-ear.hash` (the
  `shasum -a 256` of `ear.swift` + `Info.plist`, first field). It exits 3 with "no swiftc"
  when there's no toolchain. Compile with
  `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`. The
  plist carries `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- Produces the CLI `buddy-ear [--gap SECS] [--file PATH]`. `--file` reads audio from a file
  instead of the mic (for tests) and prints `{"ev":"eof"}` when the file is done.
- Produces stdout events, one JSON object per line:
  `{"ev":"ready"}`, `{"ev":"error","why":S,"fatal":B}`, `{"ev":"start","utt":N}`,
  `{"ev":"words","utt":N,"text":S}`, `{"ev":"end","utt":N,"text":S}`.
- Produces stdin commands, one JSON object per line: `{"cmd":"listen","on":B}` (the
  default is on) and `{"cmd":"quit"}`.

- [ ] **Step 1: Write the failing tests** in `tests/test_ear.py`. Skip the class unless
  `platform.mac_ver()` ≥ 26 and `ear/build.sh` succeeds. Make the audio with `say -o`. The
  pause uses say's `[[slnc 2000]]`.
  - `test_two_utterances`: audio "Okay Buddy, what's the weather? [[slnc 2000]] Tell me a
    joke." gives exactly 2 `start` and 2 `end` events. The first `end` text, lowercased
    with punctuation stripped, starts with `okay buddy`. The second contains `joke`.
    `words` events come before their `end`.
  - `test_silence_feeds_nothing`: 5 s of `[[slnc 5000]]` gives 0 `start` events and then `eof`.
  - `test_build_hash`: after a build, `ear/buddy-ear.hash` equals the hash of the sources.
- [ ] **Step 2: Run** `/usr/bin/python3 -m unittest tests.test_ear -v`. Expected: FAIL (no `ear/`).
- [ ] **Step 3: Implement `ear/ear.swift`.**
  - Recognizer: `DictationTranscriber(locale: en-US equivalent, contentHints: [.shortForm], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])`,
    contextual strings as in the spike, assets via `AssetInventory`.
  - Pause detection runs on the audio timeline, not the wall clock, so file mode is
    deterministic. Speech starts when the 20 ms peak goes over
    `max(0.02, 4 × noise floor)`. It ends after `--gap` seconds (default 1.0) below that.
  - Keep a 0.5 s pre-roll ring buffer and feed it at speech start. Feed the analyzer only
    between start and end. At end, call `finalize(through:)` and emit `end` with the
    final text.
  - Convert to the analyzer's format with `AVAudioConverter` (`channelMap = [0]` when
    there's more than one channel).
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Check idle cost live.** Start it through Hammerspoon
  (`hs -c "T = hs.task.new('<abs>/ear/buddy-ear', nil, function() return true end, {}); T:start()"`).
  After 20 s of a quiet room, `ps -o %cpu= -p <pid>` is under 3. Record the number in
  the commit message.
- [ ] **Step 6: Commit** `ear/ear.swift ear/Info.plist ear/build.sh .gitignore tests/test_ear.py`.

### Task 2: The helper speaks, without hearing itself

**Files:**
- Modify: `ear/ear.swift`
- Create: `tools/voice-check`
- Test: `tests/test_ear.py`

**Interfaces:**
- Consumes: Task 1 CLI and events.
- Produces commands `{"cmd":"speak","id":N,"file":PATH}` and `{"cmd":"stop"}`.
- Produces events `{"ev":"speaking","id":N,"secs":F}` when the audio starts (`secs` is the
  file's length), `{"ev":"spoken","id":N,"cut":B}` when it ends or is stopped (`cut` is
  true when stopped), and `{"ev":"busy","on":B,"app":S}`.
- Voice processing: it's on from just before playing until 0.3 s after the audio ends.
  Turning it on or off means stop the engine, set it, rebuild the converter for the new
  input format, then start again. Touch `outputNode` and `mainMixerNode` before
  enabling (spike).
- Mic busy: every 2 s, read CoreAudio's process list
  (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`,
  `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`). It's busy when a process
  other than itself is running input and that PID is a regular app
  (`NSRunningApplication(processIdentifier:)?.activationPolicy == .regular`). Emit `busy`
  only when the state changes.
- Device change: on `AVAudioEngineConfigurationChange`, rebuild the engine and keep the
  listen state.

- [ ] **Step 1: Write the failing tests.**
  - `test_speak_events`: speak a 1.5 s `say` file. You get `speaking` (secs within 0.1 of
    the file's length) and then `spoken` with `cut` false, between 1.3 and 3 s later.
  - `test_stop_cuts`: speak a 5 s file, send `stop` after 1 s. You get `spoken` with `cut`
    true within 0.5 s of the stop.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement speak, stop, the voice-processing toggle, busy and device change** in `ear/ear.swift`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Write `tools/voice-check`** (POSIX sh). It starts the helper through
  `hs -c` and `hs.task` (so the mic permission is Hammerspoon's). It speaks a 6 s `say`
  sentence. It prints `PASS` when no `start` event arrives during playback, otherwise
  `FAIL` with the words heard. It also prints the helper's idle CPU after 20 s. Run it
  on the owner's Mac. Expected: `PASS`, CPU under 3.
- [ ] **Step 6: Review Focus 1 test, by hand.** With the helper running, unplug and
  replug the USB mic, then speak. `start` and `end` events still arrive, and the
  process is still the same PID. Note the result in the commit.
- [ ] **Step 7: Commit** `ear/ear.swift tools/voice-check tests/test_ear.py`.

### Task 3: Turning text into speech (`speech.lua`)

**Files:**
- Create: `speech.lua`
- Test: `tests/speech_spec.lua`

**Interfaces:**
- Produces `S.speakable(text) -> string|nil`. It removes fenced and inline code, URLs,
  file paths, markdown list and heading lines, and emoji. It drops any sentence with an
  email address, a phone number (`%d%d%d[-. ]%d%d%d[-. ]%d%d%d%d`), a dollar amount
  (`%$%s*%d`) or a street address (a number followed by up to three words and then
  St/Ave/Rd/Dr/Blvd/Way/Cres/Crt). It keeps the first 2 sentences, and returns nil when
  nothing is left.
- Produces `S.parseVoices(sayOutput) -> { {name=S, lang=S}... }` from `say -v '?'` output.
  English comes first, and names with "(Premium)" or "(Enhanced)" sort ahead of the rest.
- Produces `S.engines(home) -> { {id, name, url, setup, installed=B}... }` for the known
  engines `kokoro` (https://github.com/hexgrad/kokoro) and `piper`
  (https://github.com/OHF-Voice/piper1-gpl). Check both links are live before you
  commit. `installed` is true when the wrapper
  `~/Library/Application Support/claude-usage-widget/voices/<id>` is executable. The
  wrapper contract: `<wrapper> --voices` prints one voice per line, and
  `<wrapper> IN.txt OUT.wav [voice]` writes a wav and exits 0. `setup` is the task text
  in Task 7.
- Produces `S.render(text, choice, done)`, where `choice = {engine="system"|id, name=S|nil}`.
  It writes the text to a temp file and runs `/usr/bin/say [-v name] -f IN -o OUT.aiff`,
  or the wrapper. Then `done(path)` or `done(nil, why)`.

- [ ] **Step 1: Write the failing specs** in `tests/speech_spec.lua`:
  - `speakable("Done. I opened it.\n```lua\nx=1\n```\nSee https://a.b/c")` → `"Done. I opened it."`
  - `speakable("```\nonly code\n```")` → nil (Review Focus 3).
  - `speakable("Call 555-555-0100 today. It's sunny.")` → `"It's sunny."`
  - `speakable("One. Two. Three. Four.")` → `"One. Two."`
  - `parseVoices` on a fixture with "Ava (Premium)  en_US", "Albert  en_US" and
    "Amélie  fr_CA" puts Ava first and Amélie last.
  - `engines` with a temp home holding an executable `voices/kokoro` marks kokoro
    installed and piper not.
  - `render` with a fake wrapper script (writes its args to a file) is called as
    `IN OUT voice`, and `done` gets OUT. With the wrapper missing, `done` gets nil plus a
    reason (Review Focus 4, part 1).
- [ ] **Step 2: Run** `/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests`. Expected: the new specs FAIL.
- [ ] **Step 3: Implement `speech.lua`.**
- [ ] **Step 4: Run the specs.** Expected: PASS, everything else unchanged.
- [ ] **Step 5: Commit** `speech.lua tests/speech_spec.lua`.

### Task 4: Wake, turn and speaking rules (`voice.lua`, pure parts)

**Files:**
- Create: `voice.lua`
- Test: `tests/voice_spec.lua`

**Interfaces:**
- Produces `V.matchWake(text, phrase) -> rest|nil`. Both sides are normalized: lowercase,
  punctuation removed, spaces collapsed, `ok` read as `okay`. It matches only at the
  start of the text. `rest` is the trimmed text after the phrase (it can be "").
- Produces `V.turns(opts)`, where `opts = {phrase=S, timeout=N}`. It returns an object with
  `:event(ev, t) -> actions` and `:tick(t) -> actions`. `ev` is a decoded helper event.
  `actions` is a list of `{"wake", rest=S}`, `{"words", text=S}`, `{"send", text=S}`,
  `{"nothing"}` and `{"stop"}`. Rules:
  - Idle: the first `words` of an utterance that `matchWake`s gives `wake` (plus `stop`
    first when `speaking`), once per utterance. Later in that same utterance, the words
    become `words` with the rest.
  - Turn: at the end of the wake utterance, a non-empty rest gives `send`. An empty rest
    waits for the next utterance, whose `words` and `end` give `words` and then `send`.
    No `start` within `timeout` seconds gives `nothing`.
  - While `busy` is on, there's no `wake`.
  - `speaking` and `spoken` events keep `obj.speaking` up to date.
- Produces `V.decide(kind, s) -> bool`, where `kind` is `"answer"` or `"line"` and
  `s = {answers, outLoud, muted, busy, voiceTurn, roll}`. Busy gives false. An answer
  gives `answers and (not muted or voiceTurn)`. A line gives `not muted and roll < outLoud/100`.
- Produces `V.settings() -> table` (the `claudeBuddy.voice` settings over the config
  defaults) and `V.set(key, value)` (persists, and turning `listen` on the first time
  also sets `answers = true`). Task 5 adds starting and stopping the helper to `set`.
- Produces `V.command(text) -> answer|nil` for "talk out loud 40 percent" or "talk out
  loud 40%" (also "out loud 40"). It clamps to 0–100, saves the setting with `V.set`, and
  returns "Talk out loud: 40%.".

- [ ] **Step 1: Write the failing specs** in `tests/voice_spec.lua`:
  - `matchWake("OK, Buddy. What's the weather?", "okay Buddy")` → `"what's the weather"`.
    `matchWake("thank you buddy", ...)` → nil. `matchWake("Okay Buddy", ...)` → `""`.
  - Turns, one breath: `start 1`, `words 1 "Okay Buddy what's"`, `words 1 "Okay Buddy what's the weather"`,
    `end 1` gives `wake("what's")`, then `words("what's the weather")`, then `send("what's the weather")`.
  - Turns, pause after the phrase: `end 1 "Okay Buddy"`, then `start 2` /
    `words 2 "tell me a joke"` / `end 2` gives `wake("")` … `send("tell me a joke")`.
  - Turns, timeout: wake with an empty rest, then `tick(t+6.1)` with no `start` gives `nothing`.
  - Mid-sentence: `words 1 "thank you buddy"` gives no actions.
  - Barge-in: with `speaking` on, a wake utterance gives `{"stop"}` and then `wake`.
  - Busy: with `busy on`, a wake utterance gives no actions.
  - `decide`: the rows above, including muted with voiceTurn true → true for an answer,
    and outLoud 0 → false for a line.
  - `command("talk out loud 140 percent")` → "Talk out loud: 100%.". The setting is 100.
- [ ] **Step 2: Run the specs.** Expected: FAIL.
- [ ] **Step 3: Implement the pure parts of `voice.lua`.**
- [ ] **Step 4: Run the specs.** Expected: PASS.
- [ ] **Step 5: Commit** `voice.lua tests/voice_spec.lua`.

### Task 5: The helper's lifecycle and the speech queue (`voice.lua`, live parts)

**Files:**
- Modify: `voice.lua`
- Test: `tests/voice_spec.lua` (with a fake helper script under `tests/fakes/`)

**Interfaces:**
- Consumes: Task 1–2 protocol, Task 3 `S.render`/`S.speakable`, Task 4 `V.turns`/`V.decide`.
- Produces `V.start(opts)`, where `opts = {dir, cfg, onWake(rest), onWords(text),
  onSend(text), onNothing(), onTrouble(msg)}`. It builds when the hash is stale (runs
  `ear/build.sh` in the background) and starts the helper with `hs.task`, kept on
  `V.task`. It restarts after 2 s, 10 s and 60 s, and after 3 exits in 5 minutes it
  calls `onTrouble`. `V.start` first kills any earlier `buddy-ear` it started (the PID is
  stored in `hs.settings` key `claudeBuddy.voicePid`).
- Produces `V.stop()` (helper quits, mic freed) and `V.pause(reason)`/`V.resume(reason)`
  (listen off while any reason is active). `V.set("listen", ...)` now also starts or
  stops the helper.
- Produces `V.speak(text, kind, cb)`, where `cb = {onStart(secs), onEnd(cut), onSkip()}` and
  kind is `"answer"` or `"line"`, plus `V.speaking()`, `V.hold(fn)`, `V.stopSpeech()` and
  `V.voiceTurn` (true from a `send` until that turn's answer has been spoken).
  `speak` calls `onSkip` when `decide` says no or `speakable` returns nil. It renders
  with the chosen voice, falling back once to the system default, and the first time
  both fail it calls `onTrouble("My voice isn't working: <why>")`. Then it sends
  `speak`, calls `onStart` on `speaking` and `onEnd` on `spoken`, and deletes the file.
  An answer while speaking stops the current audio first. `hold(fn)` keeps only the
  newest fn and runs it after `spoken`.

- [ ] **Step 1: Write the failing specs** using `tests/fakes/fake-ear` (a sh script that
  echoes `{"ev":"ready"}`, then answers each `speak` with `speaking` and, 0.2 s later,
  `spoken`, and logs its commands to a file named in an env var):
  - `speak("Hello there.", "answer", cb)` with answers on calls `onStart(secs)` and then
    `onEnd(false)`, and the temp file is gone afterwards.
  - With `outLoud = 0`, a line calls `onSkip` and sends no `speak`.
  - `hold` while speaking: two held fns, and only the second runs after `spoken`.
  - Review Focus 4, part 2: with a broken choice and a broken system voice (the
    renderer stubbed to fail), `onSkip` runs and `onTrouble` is called exactly once
    over two calls.
  - Review Focus 5: calling `V.start` twice leaves one fake-ear process
    (`pgrep -f fake-ear` count is 1), and `V.stop()` leaves none.
- [ ] **Step 2: Run the specs.** Expected: FAIL.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run the specs.** Expected: PASS.
- [ ] **Step 5: Commit** `voice.lua tests/voice_spec.lua tests/fakes/fake-ear`.

### Task 6: Wire it into Buddy and the chat

**Files:**
- Modify: `buddy.lua` (`say` ~L463, `openChat` ~L737, `onMouseDown` ~L1826, away
  changes ~L1283, `M.start` ~L2405 sleep watcher), `chat.lua` (`C.open` ~L163, the send
  path), `chat.html` (dictation block ~L126), `brain.lua` (where `Brain.chat` builds its
  context)
- Test: `tests/chat_voice_spec.lua`, plus `tests/buddy_frame_spec.lua` or a new buddy sandbox spec

**Interfaces:**
- Consumes: Task 5 `V.*`.
- `chat.lua`: `C.open(opts)` with `opts.noFocus` skips `bringToFront(true)` and
  `hs.focus()` (if it's already open, it only `:show()`s). `C.voice(state, text)` calls
  `window.voice({state, text})`, where state is `"listening"` or `"off"`.
  `C.sendVoice(text)` takes the same path as a typed send (factor out
  `local function send(text, meta)`), adds the user line to the page, and calls
  `opts.ask(history, reply, {voice = true})`. `reply` calls `opts.onReply(text, meta)`.
- `chat.html`: `window.voice` shows "Listening…" with the mic style while listening. It
  puts the live words after any typed text (remembering where the typed text ended) and
  clears the voice part on "off" or after a send.
- `brain.lua`: when `ctx.voice` is true, add to the request: "They're talking to you out
  loud and will hear your answer read aloud: answer in one or two short spoken sentences,
  with no lists, links or code."
- `buddy.lua`:
  - `say()`: kind is `"answer"` when `force == "user"`, otherwise `"line"`. When
    `V.speaking()` and kind is `"line"`, call `V.hold(function() say(text, force, quiet) end)`
    and return. Otherwise show the bubble as today, set `talkUntil = 0`, and call
    `V.speak`: `onStart(secs)` sets `talkUntil = now()+secs` and
    `bubbleUntil = max(bubbleUntil, now()+secs+0.8)`, `onEnd` sets `talkUntil = now()`,
    and `onSkip` keeps today's timing.
  - Chat answers: `onReply(text, meta)` speaks `text` as an answer (`voiceTurn` from
    `meta.voice`) with the same mouth sync, instead of `doAction("talk", 2.5)` when it's
    spoken.
  - Wake: `doAction("startle", 0.6)`, `hs.sound.getByName("Pop")` at volume 0.3,
    `openChat({quiet = true, noFocus = true})`, `Chat.voice("listening", rest)`.
    `onWords` gives `Chat.voice("listening", text)`, and `onSend` gives `Chat.sendVoice(text)`.
    `onNothing` gives `Chat.voice("off")` and closes the panel if this wake opened it.
  - Click: in `onMouseDown`, a plain click while `V.speaking()` calls `V.stopSpeech()` and
    returns.
  - Pauses: `screensDidLock`, `screensDidSleep` and `away == "asleep"` call
    `V.pause("screen"|"asleep")`, and the matching wake or unlock or `"active"` calls `resume`.
  - Command: the chat's `command` tries `V.command(text)` before `Brain.command`.
  - Start: `V.start{...}` only when `V.settings().listen` or `outLoud > 0` or `answers`.
    `onTrouble` posts the message once with `say(msg, "user")`.

- [ ] **Step 1: Write the failing specs** (`tests/chat_voice_spec.lua`, using the chat
  archive spec's temp-settings pattern):
  - `C.open{noFocus=true,...}` doesn't call `hs.focus` (stub it and count the calls).
  - `C.sendVoice("hi")` calls `opts.ask` with meta.voice true and appends a user entry
    with the content "hi".
  - Review Focus 2: in the page, with "typed " in the box, `window.voice({state:"listening",text:"spoken"})`
    gives the box value "typed spoken". Evaluate it in the web view and read back
    `document.getElementById("text").value`.
  - In the buddy sandbox (`tests/buddy_sandbox.lua`) with a fake V: a spoken line keeps
    the mouth still until `onStart(2)`, then talking lasts 2 s and the bubble lasts at
    least 2.8 s. A held line runs only after `onEnd`.
- [ ] **Step 2: Run the specs.** Expected: FAIL.
- [ ] **Step 3: Implement the wiring.**
- [ ] **Step 4: Run all specs.** Expected: PASS, and the existing chat, buddy and dictation specs still pass.
- [ ] **Step 5: Commit** the modified files and the specs by explicit path.

### Task 7: Menu, setup wizard, docs

**Files:**
- Modify: `buddy.lua` (`showMenu` ~L1040), `setup.html`, `setup.lua`, `theme.css`,
  `tasks.lua` (`K.start`), `config.example.lua`, `README.md`
- Test: `tests/setup_spec.lua`, `tests/voice_spec.lua`

**Interfaces:**
- Right-click menu, after "Quiet for an hour": a "Voice" submenu with:
  - "Listen for “okay Buddy”" (checkmark)
  - "Speak answers" (checkmark)
  - "Talk out loud" submenu: 0/25/50/75/100%, with the current one checked; a value in
    between shows as its own checked row
  - "Voice" submenu: system voices from `S.parseVoices`, plus the installed engines' voices
  - "Set up a voice…" (opens the wizard on the Voice step)
  When voice can't run, the submenu shows the reason as one disabled item.
- `theme.css`: a shared slider style `.tars` (a label on the left, a percent readout on
  the right, as in "Talk out loud 40%"). The personality-sliders stream reuses this
  class. Tell that session the class name in the handoff.
- Setup wizard: a new `<section data-mood="wave" data-step="voice">` with:
  - the listen and answers switches
  - a `.tars` slider for talk out loud (step 5)
  - the voice picker with a Test button (posts `{type="voiceTest", choice}`, which
    speaks "Hi, I'm Buddy. This is my voice.")
  - the wake phrase field
  - one row per `S.engines()`: name, a Download link (opens `url`), and "Have Buddy set
    it up" (posts `{type="voiceSetup", id}`)
  Saving writes `claudeBuddy.voice` through `V.set`.
- `tasks.lua`: `K.start` uses `p.model or cfg.model` and `p.effort or cfg.effort`.
  "Have Buddy set it up" calls `TK.lib.start({task = engine.setup, name = "voice-" .. id, folder = HOME, model = "opus"}, "chat", done)`.
  When task sessions are off, the button is disabled and says "Needs task sessions".
- Engine setup text (`S.engines` `setup`), with the engine's name and URL filled in:
  "Set up the <name> text-to-speech engine (<url>) on this Mac for Claude Buddy. Install it
  in its own folder under ~/Library/Application Support/claude-usage-widget/voices/<id>-engine,
  then create an executable script at ~/Library/Application Support/claude-usage-widget/voices/<id>.
  With --voices it prints the available voice names, one per line. With <input.txt> <output.wav> [voice]
  it reads the text file, writes the speech to the wav file and exits 0. Test it on one sentence
  and play the result with afplay. Don't change anything in the claude-usage-widget folder."

- [ ] **Step 1: Write the failing specs.**
  - `setup_spec`: a fake wizard post `{type="save", voice={listen=true, outLoud=40}}`
    gives `claudeBuddy.voice.listen == true`, `outLoud == 40` and `answers == true`
    (first time on).
  - `voice_spec`: the menu builder's Voice items, given settings `{listen=true, outLoud=30}`,
    include a checked "30%" row and a checked listen row. With trouble "Voice needs macOS
    26 or later.", there's exactly one disabled item.
  - `K.start` with `p.model = "opus"` and `cfg.model = "sonnet"` passes `"opus"` to
    `buddy-task` (use the claude fake's arg log).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement the menu, the wizard step, the `.tars` style and the `K.start` override.**
- [ ] **Step 4: Docs.** In `config.example.lua`, add the `voice` block with comments. In
  `README.md`, add a "Voice" section: what it does, macOS 26 and the Command Line Tools,
  the orange mic dot, that it's off by default, privacy, and the `tools/voice-check`
  command.
- [ ] **Step 5: Run all specs and the Python tests.** Expected: PASS.
- [ ] **Step 6: Screenshot the wizard step and the menu** (testing-hammerspoon-widgets
  skill) and read the PNGs. Check that no personal data shows.
- [ ] **Step 7: Commit** by explicit path.

### Task 8: Live check on the owner's Mac, then hand off

**Files:**
- Modify: the stream's session log (handoff block)

- [ ] **Step 1:** Point a test Hammerspoon load at the worktree only if no other session
  is reloading main. Otherwise run the live checks with the worktree's `voice.lua` and
  `ear/` loaded by hand through `hs -c`. Never reload the live Buddy onto the branch
  without telling the owner.
- [ ] **Step 2:** Run `tools/voice-check`. Expected: `PASS`, idle CPU under 3% (helper) and
  coreaudiod not above its idle level by more than 2 points.
- [ ] **Step 3: Owner run** (on-screen cues like the spike):
  - "okay Buddy, what's the weather" from the chair: the perk-up and sound come within
    0.6 s, the panel opens without taking focus, the words show, and it sends after the
    pause.
  - The answer is spoken, with his mouth moving exactly as long as the audio.
  - "okay Buddy" while he answers stops him and starts a turn.
  - A click stops him.
  - With the slider at 0%, no quips are spoken. At 100%, every quip is.
  - During a FaceTime call, there's no wake and nothing spoken.
- [ ] **Step 4: False wakes.** Leave listening on for at least an hour of normal desk time
  (including a call and a YouTube video). Count wakes from the console. Target: at most 1
  false wake.
- [ ] **Step 5:** Write the handoff block (coordinating-buddy-releases) in the session log.
