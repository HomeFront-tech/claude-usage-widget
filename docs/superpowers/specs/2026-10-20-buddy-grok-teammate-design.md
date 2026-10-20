# Buddy and Grok Bot as teammates: design

Date: 2026-10-20. Status: draft for the owner's approval. Builds on v1.3.0 (44a4a9f).

## Intent

The owner runs two AI helpers. **Buddy**, the pixel Claude in this widget, lives on the
Mac and is the persona of that computer. **Grok Bot** is a cloud agent; through the Grok
Bot desktop app it can also run commands on this Mac, but it is not "the computer". The
owner wants them to work as a team:

1. **Owner → Buddy → Grok.** The owner asks Buddy, in Buddy's chat, to ask Grok something
   or to work something out with Grok. Buddy passes it on and brings the answer back in
   its own voice.
2. **Grok → Buddy → Opus 5.5.** When Grok needs Claude Opus 5.5, it asks Buddy, and Buddy
   runs Opus here on the Mac through Claude Code.

Buddy stays the face and voice of the Mac: when work passes through it, Buddy shows it.

## Goals

- "Ask Grok…" from Buddy's chat (typed, or dictated by holding space) reaches the bot
  named **Grok Bot** and the reply comes back to the chat and the speech bubble.
- Grok can borrow Opus 5.5 through a Buddy-owned command under the trust rules below.
- The owner can see the teamwork: Buddy shows when it is waiting on Grok, when Grok asked
  for Opus, and when Opus needs the owner's OK.
- Buddy's personality treats Grok as a teammate it teases, not a rival it roasts.
- Everything is opt-in through `config.lua`; without it the widget behaves exactly as v1.3.0.

## Trust rules (decided by the owner)

- Grok may have Opus **read and think** without asking: answer a question, review a plan,
  read files on the Mac, search the web.
- Anything that **changes or sends** (editing or writing files, running commands, any tool
  that sends something out) makes Buddy pop up **Approve / Deny** and wait for the owner.
- A **daily cap** on Grok-requested Opus runs. Over the cap, Buddy tells Grok no and tells
  the owner.

## Owner ruling on sending (2026-10-20)

The draft `2026-10-20-buddy-haiku-agent-design.md` (another session) sets the hard rule
"Buddy never sends anything to anyone". The owner ruled that Grok's and Buddy's actions
are different: Buddy passing the owner's own words to Grok Bot when the owner says
"ask Grok…" is allowed, and neither Grok nor Buddy (nor Opus running for Grok) may send
anything out without the owner's approval. Both designs follow this.

## Calls made in the conversation (owner heard and did not object)

- Target is the single bot named exactly "Grok Bot". No other bots or rooms.
- If the Grok Bot app is closed when Buddy needs it, Buddy opens it in the background.
- Approval popups unanswered for **10 minutes** count as **Deny**, and Grok is told.
- Daily cap default **10** runs, changeable in config.
- Buddy sends Grok **only the owner's words** (plus a short header), never screenshots,
  Buddy's chat history or Buddy's memory notes.
- Buddy's local brain (Ollama) keeps doing the chatting and jokes; Opus runs only for real
  Grok requests.
- No iMessage or other notifications come out of this feature. Another system owns those.

## Non-goals

- Using gbot's built-in Claude Code channel (`gbot claude send` into a session started with
  `--dangerously-load-development-channels`). It is a research preview, needs a terminal
  session kept open with a development flag, and gives up after 120 seconds.
- A hard lock on Grok's access to the Mac. Grok can run shell commands here, so it could
  call `claude` itself. Routing Opus through Buddy is a rule given to Grok, not enforced.
- A setup-wizard step. v1 is configured by hand in `config.lua`.
- Narrating everything Grok does on the Mac. The Grok app's local log
  (`~/.grokbot/local-exec-daemon.log`) records only connection state, not commands, so
  Buddy can only show what passes through Buddy.
- Streaming or partial answers.

## Anti-goals (failure even if it technically works)

- Opus spend the owner can't see, any path around the daily cap, or Buddy's small talk
  reaching Opus.
- An approval that is granted by default, on timeout, or by anything other than the
  owner's click.
- Resending a message to Grok after an ambiguous send. Duplicate tasks are worse than a
  missed one.
- Any change to other people's installed copies of this public widget.
- Secrets or tokens in `config.lua`, the repo, logs or messages.
- Freezing Hammerspoon while waiting on Grok or Opus. All waits are asynchronous.

## Facts found on the owner's Mac (2026-10-20)

- Buddy runs in Hammerspoon. Chat: `chat.lua` + `chat.html`; `brain.lua` talks to Ollama
  (`gemma3:4b`); `dictate.lua` handles hold-space dictation. `buddy.lua` wires them up
  (`Chat.open{ ask = function(history, done) Brain.chat(...) end }`, around line 563).
  The `hs` CLI is at `/opt/homebrew/bin/hs` and reaches the running Hammerspoon.
- `config.lua` is gitignored and written by the setup wizard. `setup.lua` `save()` copies
  every existing key before applying its answers, so a new `grok` table survives the wizard.
- The persona string in `brain.lua` (`persona()`, line 34) lists Grok among rival AIs to
  roast. `buddy.lua` maps Grok windows to the `jealous` mood (lines 221 and 231).
- **gbot** (pinned 0.12.2) is the CLI for messaging Grok Bot. On the owner's Mac the wrapper
  that Codex already uses lives under `~/Documents/Codex/…/Grokbot-Control/gbot` (machine
  specific; find it with `atlas find Grokbot-Control`). The wrapper forces manual reply
  mode on `send`. Useful commands: `gbot send <target> -- <message> --json`,
  `gbot thread <target> --limit N --json`, `gbot bots list --json`.
  - gbot signs in through the running, signed-in Grok Bot desktop app. With the app
    closed it fails (seen: "Could not find a Grok Bot agents directory"). Never read or
    copy its credential files.
  - **It doesn't work right now** (found by the Haiku-design session): with Grok Bot.app
    0.72.0 running and signed in, `gbot doctor` reports "gateway auth: no / Grok Bot app
    session: not found"; the CLI expects a `gateway-descriptor.json` the app doesn't
    write. grok-bot-cli 0.12.4 is on npm. Fixing this gates Part 1, not Part 2.
  - A send can take up to ~100 s. A timeout means delivery is **unknown**: check the thread
    for a unique marker, and never resend automatically. 0.12.2 can report
    `delivery: unknown` even when the message was delivered.
- Grok reaches the Mac through the Grok Bot app's local-exec daemon ("Grok Bot Shell"
  with a machineId). The log shows frequent disconnects and reconnects.
- Claude Code is at `~/.local/bin/claude`. Headless mode (`claude -p`) supports
  `--model claude-opus-5-5`, `--allowedTools`, `--permission-prompt-tool <mcp tool>`
  (an MCP tool decides each permission request) and `--output-format json`.
- Verified by the Haiku-design session: `--setting-sources ""`, `--strict-mcp-config`,
  `--no-session-persistence` and a working directory with no CLAUDE.md keep the owner's
  CLAUDE.md and hooks out of a `claude -p` run on the Max plan. `--bare` can't be used
  (API key only, never the plan sign-in).
- The owner's Claude Code user settings carry many hooks (session logging, iMessage audio,
  a sub-agent guard and others) and a large CLAUDE.md written for interactive sessions.
- The repo is public, and installed copies auto-update from GitHub releases (`tools/release`).

## Design

### Config

```lua
grok = {
  bot = "Grok Bot",          -- exact bot name to message
  gbot = "/path/to/gbot",    -- gbot CLI for this machine
  app = "Grok Bot",          -- macOS app to open in the background when closed
  opus_daily_cap = 10,       -- Grok-requested Opus runs per local day
  approve_timeout = 600,     -- seconds; no answer = Deny
},
```

No `grok` table means the feature is off: no routing, no command, original persona and moods.
`config.example.lua` gets a commented example; README gets a short section.

### Part 1: asking Grok from Buddy's chat

- **Routing.** A chat message goes to Grok when it plainly addresses Grok: it starts with
  "grok," or contains "ask grok", "have grok", "tell grok", "get grok to" (any case). Use a
  plain pattern match, not the local model. Everything else stays with the local brain
  as today.
- **Message.** Send the owner's words unchanged, wrapped in a short header saying it comes
  from Buddy on the owner's Mac, with a unique marker such as `[buddy:<id>]`, and a footer
  telling Grok how to borrow Opus (Part 2).
- **While waiting.** Buddy answers in the chat right away ("Passing it to Grok…") and shows
  a waiting/teamwork pose. Run gbot with `hs.task`, never blocking. If the Grok Bot app is
  closed, open it in the background (`open -g -a`) and allow a bounded wait for gbot to
  work.
- **Reply.** Poll `gbot thread` until a Grok message newer than the send appears that
  answers it (marker if Grok echoes it, otherwise the first bot message after the send).
  Show a short version in the speech bubble and the full text in the chat, styled as
  coming from Grok.
- **Failure.** No reply within the wait limit, or an unknown delivery: Buddy says it isn't
  sure Grok got it and to check the Grok app. Never resend. If the app isn't signed in or
  gbot is missing, Buddy says so plainly.
- **Transcript.** Grok's lines are stored in the chat transcript but must not confuse the
  local brain: `Brain.chat` builds its prompt from `user`/`assistant` roles, so Grok
  entries need their own role and must be excluded from or labelled in that prompt.

### Part 2: Grok borrowing Opus through Buddy

A new command in `bin/` (working name `buddy-opus`) that Grok runs on the Mac:

- `buddy-opus ask "<request>"` runs Opus 5.5 and prints the answer.
  `buddy-opus status` prints the cap left and whether Buddy is running.
- **Buddy must be present.** The command talks to the running Buddy (for example through
  `hs -c`). If Hammerspoon or Buddy isn't running, or there's no `grok` config, it refuses.
- **Cap.** Count Grok-requested runs per local day. Over the cap: exit non-zero with a clear
  message for Grok, and Buddy says in its bubble that Grok wanted Opus but the day's cap is used.
- **Visible.** Buddy shows "Grok asked me for Opus: <first words>" and a working pose until done.
- **The run.** `claude -p` with model `claude-opus-5-5`. Allowed without asking: read and
  think tools only (Read, Grep, Glob, WebSearch, WebFetch). Every other tool request goes
  through a Buddy-provided `--permission-prompt-tool`, which shows the Approve / Deny popup
  (Part 4) and returns the owner's answer. Opus is told about denials and finishes without
  that action.
- **Isolation.** A Grok run must not set off the owner's interactive hooks (session logs,
  iMessage audio and so on) or run under a CLAUDE.md written for other situations. The
  builder picks the mechanism (for example limiting setting sources) and verifies it.
- **Long jobs.** Grok Bot Shell may cut off long commands. Support an async form
  (`ask --async` returns a job id, `buddy-opus result <id>` fetches it) and pick the default
  after measuring the shell's limit.
- **Log.** One line per run in a local log for the owner: time, first words of the request,
  approvals asked and answered, duration, outcome (answered, denied, capped, failed).

**Telling Grok.** Every Buddy → Grok message carries the one-line footer explaining
`buddy-opus`. A standing instruction on the Grok Bot itself (its profile or a skill)
changes the owner's Grok setup, so the builder drafts it and the owner approves it before
it's applied.

### Part 3: personality and poses

With `grok` configured:

- The persona says Grok Bot is Buddy's teammate in the cloud, and Buddy is the Mac. Buddy
  teases Grok like a work friend and never trashes it. Other rival AIs keep getting roasted.
- Grok windows stop getting the `jealous` side-eye and get a friendly mood instead.
- New states: waiting on Grok, Opus working for Grok, and an attention state when an
  approval is waiting (like the existing "Your turn!" hop).

Without `grok`, all of this is unchanged.

### Part 4: the approval popup

A small panel next to Buddy, like the chat panel, with:

- what Opus wants to do, in full: the tool and its target (file path, the complete
  command), not cut short in a way that hides risk
- Approve and Deny buttons and a visible countdown

Buddy does its attention hop while the panel is up. One popup at a time. Timeout means Deny.

## Left to the builder

- Exact gbot flags, reply matching and polling interval
- How the command and Buddy talk (`hs -c`, files, `hs.ipc`)
- Pose art and names
- Where state, cap counts and logs live
- Async default, after measuring Grok Bot Shell's command limit
- How headless runs are isolated from the owner's hooks and CLAUDE.md
- Whether a busy Grok request queues new asks or Buddy says it's still waiting

## Done means

1. The owner types "ask Grok what's two plus two" and Grok's answer shows in the chat and
   the bubble.
2. Grok runs `buddy-opus ask` and gets Opus's answer. Buddy shows it, and the cap counts it.
3. An Opus request to run a command opens the popup. Deny is respected, and 10 minutes
   without an answer counts as Deny.
4. The 11th run of the day is refused, and both Grok and the owner are told.
5. With the Grok Bot app closed, Buddy opens it or says clearly why it can't reach Grok.
6. With the `grok` table removed, behaviour matches v1.3.0.

Live tests that message the real Grok Bot need the owner present and their OK. Before any
push or release: the owner's OK, plus a check of the public repo for personal data.
