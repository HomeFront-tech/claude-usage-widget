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
- A sandbox's fake `hs.settings.get` must not pass any `claudeBuddy.voice*` key through, `claudeBuddy.voicePid` included: `V.start` kills the helper whose PID it reads there (the running buddy's ears; it did, once per sandbox, 2026-10-28). `voice.lua` also keeps a registry of live helpers (`ClaudeBuddyVoiceHelpers`) so a second instance never kills one (`tests/voice_owned_spec.lua`). That kill only matches a command name of `buddy-ear` or `fake-ear`, and `ps -o comm=` names a shell script's interpreter, so `tests/fakes/fake-ear` can't stand in for it; the spec symlinks `/bin/cat` under that name (a copy would be killed).

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

## One line for everything said out loud (`V.waiting`, `V.pump`)
Since 2026-11-02 every spoken message (bubble lines, chat answers, task-session updates)
waits in one FIFO line. A message is made and played to its end before the next starts; a
new answer no longer cuts the one playing. Rules (tests: `tests/voice_queue_spec.lua`):
- `V.pump` starts the next message only when `V.msg`, `V.currentId` and `V.pending` are all
  empty. It runs after every `spoken` event and at the end of `V.flushQueue`.
- Stops empty the line: `V.stopSpeech` (click, wake word), `V.interrupt`, `V.stop`, a helper
  exit. Each waiting caller gets `onSkip(true)` ("dropped, show nothing").
- `onSkip(false)` means its turn came but it isn't said; buddy.lua shows the bubble then.
  `onTurn` fires when a spoken message starts being made; `say()` shows the bubble and the
  chat line there, so they match the audio.
- Duplicate words (waiting or playing) drop the newcomer; `opts.key` replaces the waiting
  one (buddy.lua's chatter); `opts.first` jumps the waiting (chat replies); `opts.maxWait`
  (chatter 20 s, default `V.maxWait` 180 s); more than `V.maxWaiting` (8) drops his own
  lines first. A waiting message is re-checked at its turn (mute, another app on the mic).
- Lines that won't be spoken still wait while he talks, so a bubble never covers his words.
- `V.checkStuck` (on the 0.5 s tick): a speech past its length + `V.stuckAfter` with no
  `spoken` counts as over, and a render running over `V.renderLimit` (180 s) with nothing
  playing drops its message, so the line can't stall. A message that errors while starting
  is flushed too.
- `speech.lua` lets one render run at a time per home (`ClaudeBuddySpeechGates`); a render
  that finds one running waits (`S.renders()`), and `S.cancel` on a waiting one removes it.
- `MacinTalkAUSP` crash reports are not overlap: RunningBoard kills Apple's MacinTalk
  extension (0xDEAD10CC, "suspended while holding a shared file lock" on its
  `regex_cache.db`) after a single `say` ends. Seen with lone renders seconds apart.

## Long messages: the chunk pipeline (`speech.chunks`, `V.speak`)
`speakable` keeps every safe sentence (no length cap). `V.speak` splits it into pieces (short first one) and plays them back to back through the normal `V.pending` / `deliverPending` path. Rules that review caught:
- Every piece carries the **whole message** as its echo `text`, not just its own words: an echo of piece 1 can end after piece 2 starts.
- One message object (`V.msg`) owns its pieces (`msg.queue`). `V.speaking()` is true while it is open, so a click or a line of his own in the gap between pieces cuts or waits instead of slipping in.
- Held lines run only after the **last** piece (or a cut), never between pieces.
- Exactly one of `onSkip` / `onEnd` reaches the caller, through `V.finish`. A cut, `V.interrupt`, `V.stop`, a helper exit and a failed piece all flush the queue (`V.flushQueue`) and bump `renderSerial`.
- A failed piece clears `renderKind`; pieces already made still play, then the message ends.
- Panel close and any pause except `dictate` call `V.interrupt()` so a long answer isn't read to an empty room.
- Split only at whitespace, or `,;:` followed by a space (never inside `12,500` or `10:30`), and never inside a UTF-8 character.
- The fake-helper spec renders synchronously; defer a render (`holdText`) to test the gap paths.

## Long talking and brain dumps (2026-11-09)
Design: `docs/superpowers/specs/2026-11-09-voice-brain-dump.md`. Tests: `tests/voice_dump_spec.lua`,
`tests/test_ear.py` `test_long_brain_dump` (four minutes of `say` through the real helper, replayed
through `V.turns` by `tests/fakes/dump_replay.lua` in standalone Lua), `tests/test_chat_page.py`
`PageBehaviour` (chat.html in node with a stub DOM).
- The helper splits long talking: after `SOFT_UTTERANCE` (20 s) a 0.24 s dip ends the utterance,
  `MAX_UTTERANCE` (30 s) is the hard limit, and both mark the end `"split": true`. A soft split is
  finalized in the middle of the dip (`finish(split:back:)`): finalized at the dip's end, the soft
  start of the next word ("and", "then") straddled the cut and the final result dropped it.
- Outside a dump a split end isn't a message: `turn.carry` joins it to the next utterance, and
  `tick` sends it alone after `carryWait` (gap + 1 s). The one-shot mode does the same with `carry`.
- Without the "brain dump" contextual string, dictation hears "braindom"; both are in `DUMP_STRIP`.
- `turn.dump` collects a dump; `V.dumpStart` / `V.dumpFinish` are pure. A finishing phrase at the end
  of a longer utterance must name Buddy ("...okay Buddy, send it"): "...and then I send it" is common.
- Lua gotcha that broke every live send while building this: `{ nil, "x" }` has length 0 in Lua 5.5,
  so `join` takes varargs (`select("#", ...)`), never a table built from maybe-nil values.
- `V.endLive` hands `onLiveEnd(why, draft)` the unsent words; `V.stop` calls it before clearing `V.turn`.
  chat.lua keeps the draft in `claudeBuddy.chatDraft` until a send or an emptied box.
- During a dump `V.speak` drops his own lines and shows answers silently; `M.awake` holds
  `hs.caffeinate` `displayIdle` (the sandbox stubs `caffeinate.set`, or a spec keeps the real Mac awake).
