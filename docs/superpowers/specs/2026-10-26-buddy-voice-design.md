# Voice: "okay Buddy" and a Buddy that talks out loud

## Why
The owner sits at the Mac and wants to talk to Buddy without touching anything: say
"okay Buddy", the chat panel pops up and starts taking their words, and Buddy answers out
loud, like Hey Siri. Today the chat needs a click, then holding space to dictate, and
every answer is text only. The owner also wants Buddy's own quips said out loud when they
choose, with a TARS-style slider (Interstellar's "humour setting") for how often, and the
voice in step with his animations.

This is a desktop feature. Telegram already has its own voice notes and stays as it is.

Success: the owner leaves it on. They said they'd turn it off if it was annoying,
disruptive or not useful, so those three are the anti-goals below.

## What the owner decided
- The wake phrase is "okay Buddy". It's the only trigger.
- After the wake phrase, the chat panel opens and speech-to-text starts at once.
- Buddy's answers are spoken out loud.
- His own lines (quips, notices, reactions) are spoken only as often as a slider says.
  The slider is in the setup wizard and reachable from the right-click menu.
- The voice and the animation are in sync: his mouth moves while the audio plays.
- The default voice is the Mac's built-in voice. Other voices are picked in the
  right-click menu or the setup wizard. Each has a link to download it and a "Have Buddy
  set it up" button, which opens a Claude Code session (Opus) to install it.
- Clicking Buddy, or saying "okay Buddy" while he's talking, cuts him off.
- His own voice must never count as input. Echo cancellation (below) handles that, so
  the mic can stay on while he talks.

## Approved guesses (the owner said "it looks really good")
- Every chat answer is spoken while voice is on, whether the question was typed or said.
- After he answers, he goes back to waiting for "okay Buddy". He doesn't listen for a
  follow-up.
- About a second of silence after you stop talking sends your words. No Enter.
- Your words show in the chat box live, as you talk.
- A small perk-up animation and a soft sound the moment he hears "okay Buddy".
- The chat panel opens without taking the keyboard from the app you're typing in.
- The spoken answer is short (a sentence or two). The full answer is in the chat panel.
- "Quiet for an hour" silences his voice too.
- He only wakes when "okay Buddy" starts what you're saying, not mid-sentence.
- The wake phrase can be changed if it fires too often.
- While a call or meeting app is using the mic, he ignores the wake phrase and doesn't
  speak his own lines.
- A "Stop listening" switch in the right-click menu. The orange mic dot in the menu bar
  shows the whole time he listens. That's macOS and can't be hidden.
- Apple's echo cancellation is on only while Buddy is talking, set to duck other audio
  as little as Apple allows, because macOS turns other apps' audio down while it runs.
- Everything to do with hearing and speech runs on the Mac. Nothing is recorded or kept.

## Goals
1. **Wake.** Always listening for "okay Buddy" on this Mac. Within about half a second of
   the phrase: perk-up and sound, the panel opens (or comes forward) without taking
   focus, listening starts. Words after the phrase in the same breath belong to the
   request (see "Calls made by Claude").
2. **Hands-free turn.** Live words in the box; about one second of silence sends. A turn
   that hears nothing closes quietly after a few seconds. Sending works exactly like a
   typed message, so commands, tasks and tools behave as they do today.
3. **Spoken answers.** Every chat answer is spoken while voice is on. Speak the first
   sentence or two. Never read out code, lists, links, file paths or anything persona()
   already forbids (phone numbers, addresses, emails, passwords, dollar amounts). When a
   turn came in by voice, the brain is told the owner is talking out loud, so it keeps
   the answer short.
4. **Spoken lines and the slider.** "Talk out loud: N%". N is the share of Buddy's own
   lines that are spoken. 0% means none (the default), 100% means every line. The
   percentage is the promise. The chatter level still decides how often he says anything
   at all, so it also spaces out the spoken ones. This is the one slider this stream
   owns.
5. **Sync.** While audio plays, his mouth moves for exactly as long as it lasts, and the
   bubble stays up until it ends. The next line waits for the current one to finish.
   Lines that aren't spoken keep today's timing.
6. **Interrupt.** Clicking Buddy, or "okay Buddy" while he talks, stops the audio at once.
   Saying it also starts a new turn.
7. **No self-hearing.** His voice never wakes him or lands in the transcript. That holds
   with open speakers, not only headphones.
8. **Voices.** The built-in Mac voice by default, with a picker for the system voices
   installed (the Enhanced and Premium ones sound much better). Plus a short list of
   local voice engines (Kokoro, for one). Each has a download link and a "Have Buddy set
   it up" button. Once it's installed, it shows up in the picker. A voice engine is
   named the same way `telegram.tts` names one today: a command with `{in}`/`{out}`.
9. **Controls.** The right-click menu gets a "Voice" submenu: listening on or off,
   talk-out-loud steps (0/25/50/75/100%), the voice picker, and "Set up a voice…". The
   setup wizard gets a Voice step: listening on or off, the real slider, the voice
   picker with a "Test" button, the wake phrase, and the voice list with download and
   set-up buttons.
10. **Off by default.** New installs and existing installs behave exactly as today until
    the owner turns voice on. Turning it off stops the helper and frees the mic.

## Anti-goals: what would get it switched off
- **Annoying:** waking when nobody called him (TV, YouTube, a phone call, saying "okay
  buddy" to a person), or talking too much.
- **Disruptive:** stealing keyboard focus, talking over a call, music staying quiet,
  noticeable CPU load or fan noise.
- **Not useful:** slow to react, long rambling spoken answers, or words heard wrong so
  often you have to type anyway.

## Constraints
- Buddy is Hammerspoon Lua with webview panels. Specs run with `tests/lua-tests` under
  `/usr/bin/lockf -k /tmp/buddy-hs.lock` (see `.claude/skills/testing-hammerspoon-widgets`).
- Public repo, and installed copies update themselves. No personal data in code, docs,
  tests or screenshots. A batch release is on: build in `.claude/worktrees/voice-wake`
  on branch `voice-wake`, commit by explicit path, never release. Finish with the
  handoff block from `coordinating-buddy-releases` in the vault session log.
- The owner's Mac runs macOS 27 with Swift 6.4 and the Command Line Tools. Input is a USB
  desk mic. It's the default input, and loud speech clipped in a test today. Output is
  the Mac mini's own speakers. The virtual "Jump Desktop" audio devices must never be
  picked. Other installs may run older macOS or have no Swift: there the feature says
  plainly what it needs and stays off. It must not break.
- Hammerspoon already has the microphone permission (hold-space dictation uses ffmpeg).
- Keep hold-space dictation (`dictate.lua`, whisper.cpp) and Telegram voice notes
  working unchanged.
- `chat.lua`'s `C.open` calls `bringToFront(true)` and `hs.focus()`. The wake path needs
  a way to open without either.
- A parallel stream, **personality sliders** (another Claude session; its vault session
  log is `2026-10-26-buddy-personality-sliders*.md` or similar), adds TARS-style
  personality sliders to the setup wizard and shapes `persona()` in `brain.lua`. Both
  streams change `setup.html` and `setup.lua`. The sliders must look and behave the same
  (a percent readout). Whichever lands first sets the slider style, and the other reuses
  it. Spoken lines inherit whatever personality the persona gives them.
- Claude Code sessions for "Have Buddy set it up" go through the existing task sessions
  (`tasks.lua`, `bin/buddy-task`) with model Opus.

## How it works (the shape; details are the builder's)
- **One small native helper** (Swift, built on the owner's Mac) owns the mic and the
  speaker. It listens for the wake phrase, streams live words while a turn is open,
  decides when the turn is over, and plays Buddy's speech. It plays through the same
  audio engine it listens with, so Apple's built-in echo cancellation (voice processing
  on the input node) removes Buddy's voice from what the mic hears. That's why
  listening and speaking live in one program.
- **Hammerspoon talks to it** over its stdin/stdout, a line of JSON per message, for
  example `wake`, `partial`, `final`, `silence`, `speaking-started` (with duration),
  `speaking-ended`, `interrupted`. A new `voice.lua` module starts and stops it and turns
  those messages into chat and buddy actions. `buddy.lua`'s `say()` asks `voice.lua`
  whether a line is spoken, and uses the real start and end for the mouth and bubble.
- **Recognition:** Claude's call is Apple's on-device speech recognition built into
  macOS (SpeechAnalyzer on macOS 26 and later), for both the wake check and the live
  words. It needs no download, sends nothing off the Mac, and gives live partial text.
  The wake check is done on the live text with the "starts what you're saying" rule.
- **Speech:** text becomes a file with `say` (or the chosen engine's command), and the
  helper plays it. Long answers can start playing after the first sentence is ready.
- **Call detection:** the builder's choice. One option on recent macOS is CoreAudio's
  per-process input state, which tells which processes are using the mic, excluding
  the helper itself.

## Calls made by Claude (the owner should check these)
- **No pause needed after "okay Buddy".** "okay Buddy, what's the weather" in one breath
  works, and the words after the phrase become the request. It still has to start what
  you're saying. Earlier I said "and you pause after it". I loosened that because Hey
  Siri works this way and a forced pause feels slow. The start-of-speech rule is what
  stops false wakes.
- **Voice command for the slider:** "okay Buddy, talk out loud 40 percent" sets it, TARS
  style, through the chat's existing command hook. The builder may cut it if it costs
  more than a small change.
- **Default for new installs:** listening off, talk-out-loud 0%, spoken answers on once
  listening is turned on. Turning listening on asks for speech permission.
- **No listening while the screen is locked, the display is asleep, or Buddy is asleep.**
  It saves power and it's more private.
- **The slider's percentage wins over "never two in a row".** An earlier guess said he
  never says two spoken lines in a row. That rule can't coexist with 75%: never two in a
  row caps the share at 50%. I dropped it, because the owner asked for a slider that
  sets how often he speaks. The chatter level already spaces his lines out.
- **Echo cancellation runs only while Buddy is talking,** so other apps' audio isn't
  turned down all day. If switching it on and off mid-stream causes clicks or gaps, the
  builder may keep it on during a whole turn instead. It must never stay on while
  idle.

## Left to the builder
- How the helper is packaged and permitted: a Swift command-line tool with an embedded
  Info.plist, or a tiny `.app`. Plus how setup builds it. Speech recognition needs a
  usage string, and macOS may credit the permission to Hammerspoon. Prove this first.
- The fallback if Apple's recognizer can't do the wake check well enough (false wakes,
  permissions, older macOS): a dedicated small wake-word model (openWakeWord, for one),
  with the live words from Apple's recognizer or whisper.
- Silence timing, the no-speech timeout, how answers are trimmed for speaking, how
  the start-of-speech rule is measured.
- Exact layout of the menu and the wizard step, within the decisions above and the
  shared slider style.
- Which local voice engines to list, and the download links (check they're current).

## First: prove the risky parts on the owner's Mac
Before building the rest, a throwaway spike should show:
1. With the helper playing `say` through the Mac mini speakers, the desk mic hears the
   owner talking over Buddy and not Buddy himself.
2. The helper, started by Hammerspoon, gets mic and speech permission without crashing.
3. Wake check: about an hour of normal desk time, including a phone call and a YouTube
   video, gives at most one false wake. Saying "okay Buddy" from the chair works at
   least 9 times out of 10.
4. Idle CPU stays low enough that nobody notices: well under 10% of one core, and the
   fans don't spin up.
If 2 or 3 fails, switch to the fallback above before going further.

## Done looks like
- From the chair, "okay Buddy" brings the perk-up and sound within about half a second.
  The panel opens without stealing focus, words appear as you talk, and a short pause
  sends them.
- The answer is spoken, short, with his mouth moving exactly as long as the audio plays.
- A click or "okay Buddy" mid-answer stops him at once.
- His own voice never wakes him and never shows up in the transcript, with open speakers.
- At 0% his own lines are silent. At 100% every line is spoken. In between, roughly
  that share of his lines.
- No wake and no spoken lines while another app is on a call.
- With voice off, Buddy behaves exactly as before, and the helper isn't running.
- Lua specs (and any helper tests) pass. The handoff block is in the vault session log.
