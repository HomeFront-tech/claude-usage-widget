---
name: changing-buddy-voice
description: Use when changing Buddy's voice feature ("okay Buddy", spoken answers, the talk out loud slider), its Swift helper ear/buddy-ear, voice.lua or speech.lua, or when buddy-ear won't start, hears itself, never ends an utterance, mishears "Buddy", eats CPU, or grok_ask_spec starts failing after a change.
---

# Changing Buddy's voice

## Overview
`ear/buddy-ear` (Swift, built on the user's Mac by `ear/build.sh --if-stale`) owns the mic
and the speaker. `voice.lua` runs it over JSON lines (protocol in `ear/ear.swift`'s header)
and holds the wake, turn and speaking rules. `speech.lua` turns text into an audio file.
`buddy.lua` and `chat.lua` wire it in. Design and plan: `docs/superpowers/{specs,plans}/2026-10-26-buddy-voice*`.

| Piece | Files | Tests |
|---|---|---|
| Helper | `ear/ear.swift`, `ear/build.sh` | `tests/test_ear.py` (file mode, speak/stop), `tools/voice-check` (live) |
| Rules, lifecycle | `voice.lua` (`V.turns`, `V.decide` are pure) | `tests/voice_spec.lua`, `tests/fakes/fake-ear` |
| Text to audio | `speech.lua` | `tests/speech_spec.lua` |
| Wiring | `buddy.lua` (`say`, `M.startVoice`, `SUB.voice`), `chat.lua`, `chat.html` | `tests/buddy_voice_spec.lua`, `tests/chat_voice_spec.lua` |
| Settings | `hs.settings` key `claudeBuddy.voice`; `config.lua` `voice = { gap, timeout, phrase }` | `tests/setup_spec.lua` |

## Apple audio and speech facts (macOS 26–27)
- `DictationTranscriber` with `AnalysisContext` contextual strings hears "okay Buddy". `SpeechTranscriber` heard "okay Bobby".
- The transcriber never ends a result at a pause, and CPU grows with the result. The helper finds pauses itself (80 ms blocks, threshold `max(0.02, 4 × noise floor)`, two loud blocks start, `--gap` seconds of quiet end), feeds the analyzer only while someone talks (plus a 0.5 s pre-roll), then calls `finalize(through:)`.
- `finalize(through:)` doesn't return until audio past that point arrives. Keep feeding a short tail (`TAIL`) after each utterance.
- After a finalize, the recognizer counts that tail as the start of the next result. A result belongs to the first utterance whose `through` is after the result's start, not to the last utterance that started before it.
- Voice processing (echo cancellation): touch `engine.outputNode` and `engine.mainMixerNode` before `setVoiceProcessingEnabled(true)`, or start fails with -10875 (kAUInitialize). Its input has 3 channels: set `converter.channelMap = [0]`. It cancels everything the Mac plays, not only our audio, and ducks other apps' audio, so it's on only while speech plays.
- Started by `hs.task`, the helper uses Hammerspoon's microphone permission, and SpeechAnalyzer asked for no speech permission. From a terminal it asks for the terminal's. Live checks go through Hammerspoon, as `tools/voice-check` does.
- The helper quits when its stdin closes. A Hammerspoon reload kills it. `V.start` also kills the PID saved in `claudeBuddy.voicePid`.

## Hammerspoon rules
- Never block the main thread. `say -v '?'` takes about 0.4 s, so look voices up with `hs.task` (see `SUB.voice`). Never call `hs.execute(cmd, true)`: it starts a login shell.
- `buddy.lua` is at Lua's 200-local limit. New state goes on `M` (for example `M.heardAt`), not in new top-level locals.
- The buddy sandboxes (`tests/buddy_sandbox.lua`, `tests/buddy_frame_spec.lua`) load `voice.lua` and `speech.lua` for real. A spec's `opts.stubs` wins.
- Specs that write `claudeBuddy.voice` must restore it (setting nil clears it). A leaked `answers = true` makes sandbox specs reach `hs.task` and fail with "sandbox: hs.task".
- A sandbox's fake `hs.settings.get` must not pass any `claudeBuddy.voice*` key through, `claudeBuddy.voicePid` included: `V.start` kills the helper whose PID it reads there (the running buddy's ears; it did, once per sandbox, 2026-10-28). `voice.lua` also keeps a registry of live helpers (`ClaudeBuddyVoiceHelpers`) so a second instance never kills one (`tests/voice_owned_spec.lua`). That kill only matches a command name of `buddy-ear` or `fake-ear`, and `ps -o comm=` names a shell script's interpreter, so `tests/fakes/fake-ear` can't stand in for it; the spec copies `/bin/cat` under that name.

## Testing
1. `/usr/bin/python3 -m unittest tests.test_ear -v` (no mic).
2. `/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests`.
3. `tools/voice-check`: it speaks through the speakers and fails only if Buddy's own words come back. It also prints the helper's idle CPU, which should stay under 3%.
- `grok_ask_spec` is the canary. Its timers only run after every later spec's synchronous part, and it waits 6 s. If it fails only on your branch, something after it blocks for about 5 s. Time each spec's synchronous call to find it.
- Count fake helpers from this run only: `voice_spec` copies `fake-ear` into the run's temp folder and searches for that path.
- Auto mode won't edit `~/.hammerspoon/init.lua` to load a worktree. Preview a worktree's wizard with `hs -c "W = dofile('<worktree>/setup.lua'); W.open{ dir = '<worktree>', config = {} }"`, then close it without saving. The full live test comes after the orchestrator merges into local main.

## Splitting the work with another coding agent
What worked:
- One write-enabled run in the worktree per plan task for pure Lua work: `speech.lua`, the rules, the lifecycle, the wizard.
- Each brief gave the plan task, the exact files the agent may change, "don't stage or commit; another worker is editing X", and "you can't run the Lua specs" (they need the live Hammerspoon).
- The main session kept the Swift helper, which needs the real mic and speakers, and the `buddy.lua` wiring.
- The main session ran every spec and read every diff. The agent's misses were login-shell `hs.execute`, a synchronous `say` in a menu, a pattern that skipped long voice names, and counting helper processes across the whole Mac.

## Long messages: the chunk pipeline (`speech.chunks`, `V.speak`)
`speakable` keeps every safe sentence (no length cap). `V.speak` splits it into pieces (short first one) and plays them back to back through the normal `V.pending` / `deliverPending` path. Rules that review caught:
- Every piece carries the **whole message** as its echo `text`, not just its own words: an echo of piece 1 can end after piece 2 starts.
- One message object (`V.msg`) owns the queue. `V.speaking()` is true while it is open, so a click or a line of his own in the gap between pieces cuts or waits instead of slipping in.
- Held lines run only after the **last** piece (or a cut), never between pieces.
- Exactly one of `onSkip` / `onEnd` reaches the caller, through `V.finish`. A cut, a new answer, `V.interrupt`, `V.stop`, a helper exit and a failed piece all flush the queue (`V.flushQueue`) and bump `renderSerial`.
- A failed piece clears `renderKind`; pieces already made still play, then the message ends.
- Panel close and any pause except `dictate` call `V.interrupt()` so a long answer isn't read to an empty room.
- Split only at whitespace, or `,;:` followed by a space (never inside `12,500` or `10:30`), and never inside a UTF-8 character.
- The fake-helper spec renders synchronously; defer a render (`holdText`) to test the gap paths.
