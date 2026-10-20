# Claude Usage Widget + Buddy

A macOS desktop widget that shows your Claude plan usage, plus a little pixel Claude
that reacts to whatever app you're in and knows your Claude Code sessions by name. Runs
on [Hammerspoon](https://www.hammerspoon.org). The buddy runs on plain rules; give it
an optional brain (a small AI model running on your own Mac) and it jokes about what's
on your screen and chats back.

![Usage card and buddy](docs/screenshot.png)

## What you get

**The usage card** shows the same numbers as Claude Code's `/usage`:

- The current 5-hour session, your weekly limits (all models and per model), any
  credits, and extra usage if you've turned it on, each with a reset countdown
- A refresh every 5 minutes and after your Mac wakes. It keeps showing the last
  numbers through restarts and outages
- Bars that turn amber at 70% and red at 90%
- A strip of hourly bars for your last 24 hours of Claude Code tokens, with the day's
  total tokens, replies and what they'd cost at API prices
- Drag it anywhere; it remembers the spot

**The usage chart** opens when you click the card. **Tokens** and **Plan limits** come in
**1D / 5D / 1M / ALL** ranges with a hover readout; **History** shows your whole account.

**Tokens** reads the session logs Claude Code already keeps on your Mac, so it shows
your history from day one (as far back as Claude Code has kept logs, about 30 days):

![Tokens chart](docs/tokens.png)

- **All tokens** stacked by type (cache read, output, input, cache write), or
  **Output**, **API value** and **Replies** stacked by model
- Totals for the range: input, output, cache write and read, replies, sessions, the
  busiest hour or day, and the change from the previous period
- A table by model: replies, every token type, share, and API value
- **API value** is what those tokens would cost at Anthropic's API list prices. It's a
  sense of scale; a Pro or Max plan doesn't charge per token

**Plan limits** plots your plan percentages like a stock chart:

![Plan limits chart](docs/chart.png)

- Candlesticks per period (green when usage went up, red when a reset dropped it),
  with a **burn** pane underneath showing how much you used in each period
- Tabs for each limit (session, week, per model)
- A moving average, the current value tagged on the axis, dotted lines where limits
  reset, and a crosshair that reads out each candle
- **At this pace**: where you'll land by the next reset at your current rate, or when
  you'll hit 100% if that comes first

Plan-limit history starts the day you install it: the card saves a point every time it
checks (every 5 minutes while your Mac is awake).

**History** is everything back to your first day, a bar per day with a table by month:

![History chart](docs/history.png)

- **Tokens** and **API value** by model, or **Prompts** typed per day
- A strip under the bars showing when you had a paid plan, with a dot on each payment
- Month by month: plan, what you paid, prompts, sessions, tokens, output, API value,
  and where the numbers came from (logs, Claude Code's daily stats, or an estimate)
- Faded bars are estimates. Claude Code's daily stats keep a total per model, so the
  split into token types (and so the API value) follows that model's lifetime mix. Days
  from before Claude Code kept tokens per day get the rest of its lifetime totals,
  spread by how busy each day was

Claude Code deletes its session logs after about 30 days, but it keeps daily totals for
`/stats` and the time of every prompt you typed. Turn on **older history** in the setup
wizard (or set `import_history = true` in `config.lua`) and the card copies those
numbers in and keeps them for good, even after Claude Code prunes its files. Only
numbers are copied, never what you typed. A month without logs or daily stats says so
in the table instead of looking quiet. Run `/stats` in Claude Code now and then to
keep its daily totals current.

**What you paid** is up to you to add, since the card can't see your receipts. Save a
`billing.json` next to the card's data, in
`~/Library/Application Support/claude-usage-widget/`, with one entry per payment from
your Anthropic receipt emails (`from`/`to` are the billing period on the receipt;
`events` and `ref` are optional):

```json
{
  "currency": "$",
  "charges": [
    { "date": "2026-03-04", "amount": 100.00, "plan": "Max 5x", "from": "2026-03-04", "to": "2026-04-04", "ref": "Receipt 1234-5678" },
    { "date": "2026-04-04", "amount": 100.00, "plan": "Max 5x", "from": "2026-04-04", "to": "2026-05-04" }
  ],
  "events": [{ "date": "2026-04-20", "text": "Cancelled" }]
}
```

To see every view full of made-up data, run `hs -c 'ClaudeUsage.chart(true)'`.

**The buddy** stands next to the card and reacts to the app and window in front:

![Buddy moods](docs/moods.png)

| You're in… | The buddy… |
|---|---|
| Terminal / Ghostty / iTerm | types on a laptop |
| …with Claude Code working | types, with sparkles flying up |
| …with Claude Code waiting on you | hops and waves: "Your turn!" |
| Claude app or claude.ai | heart eyes, bouncing |
| ChatGPT / Grok / Gemini | gives that window the side-eye |
| YouTube, Netflix, Stremio | eats popcorn |
| Gmail / Mail | holds an envelope |
| Sheets, Docs, PDFs, Obsidian | puts on glasses |
| Weather or snow forecast | grabs a shovel while it snows |
| Finder | looks around with question marks |
| System Settings | twists a wrench |
| Games / PS Remote Play | mashes a controller |
| Music / Spotify | dances to floating notes |
| Anything else | "Ooh, *AppName*!" |

It also follows your mouse with its eyes, blinks, fidgets and dances, gets bored after
3 minutes away, falls asleep after 10 (and jumps when you come back), drinks coffee in
the morning, gets sleepy late at night, sweats when your session is 80% used, and
cheers when it resets. On "chatty" it pipes up by itself every minute or so.

**Your Claude Code sessions.** The buddy reads each session's name from the terminal
title. Click into one and it says something about it ("Bug hunt! Get it!", "*Refactor
the API* is still cooking."). When a session in the background finishes, it waves:
"*Fix the login bug* finished after 12 min!"

**Things happening on your Mac.** It reacts when your Mac wakes or unlocks, a screen or
USB gadget is plugged in, headphones connect, the internet drops or comes back, a drive
mounts, you take a screenshot, a download finishes, or an app crashes. You can add
your own: a log file to watch for a line, or a folder to watch for new files (see
`events` in `config.example.lua`).

| Do this | To |
|---|---|
| Click | chat with it (with a brain), or get a hello |
| Shift-click | have it look at your screen and say something |
| Cmd-click | open a new Claude Code session in Terminal |
| Right-click or Ctrl-click | its menu: chat, a joke, a new Claude Code session in any project folder, how your sessions and usage are doing, quiet for an hour, setup |
| Option-click | the setup wizard |
| Drag | move it |
| Shake it while you hold it | it panics and snows like a snow globe, then reels around seeing stars (shake it too often and it gets grumpy) |

**The brain (optional).** Turn it on in the setup wizard, or add `ai = {}` to
`config.lua`. It needs [Ollama](https://ollama.com) and one model:

```sh
brew install ollama && brew services start ollama
ollama pull gemma3:4b
```

With a brain, the buddy looks at windows it doesn't know (a screenshot of that one
window) and makes a crack about them, riffs on your Claude Code sessions, tells jokes
about what you're doing, and chats in a little panel next to it, looking at your
screen again with each message. Everything runs on your Mac: screenshots go to Ollama
on `localhost` and are never saved. It won't look at windows that look like passwords
or banking. Set `peek_every` for unprompted looks at the screen every few minutes.

The chat and the speech bubble are one conversation: whatever the buddy says out loud
also lands in the chat (live, if the panel is open), and opening the chat shows its last
five lines, so you can answer one. After you chat, it jots down a few short notes about
you (what you're working on, running jokes) and brings them up next time, even days
later. `hs -c 'ClaudeBuddy.forget()'` wipes the conversation and the notes. Drag the
chat by its header to move it; it opens in that spot next to the buddy from then on.

**Talk instead of typing.** In the chat, hold space and talk, then let go, like Claude
Code's voice mode; a quick tap still types a space. The words land in the box for you
to send. It's transcribed on your Mac by [whisper.cpp](https://github.com/ggml-org/whisper.cpp):

```sh
brew install ffmpeg whisper-cpp
mkdir -p ~/.cache/whisper.cpp
curl -L -o ~/.cache/whisper.cpp/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

Hammerspoon asks for the microphone the first time. `base.en` is small and quick;
`large-v3-turbo` is more accurate. It uses the first model it finds in
`~/.cache/whisper.cpp`, or the one you name in `ai.dictation`.

It also learns a little: it keeps a tally of how long you spend in each app, so the
wizard can list your most-used apps first. If you spend a while in an app it doesn't
know, it asks you to teach it.

## Requirements

- macOS and [Hammerspoon](https://www.hammerspoon.org) (free)
- [Claude Code](https://claude.com/claude-code), logged in with a Claude Pro or Max
  plan. The card reads Claude Code's login.
- Python 3 (the one that comes with macOS is fine)

## Install

1. Install Hammerspoon, open it, and tick **Launch Hammerspoon at login** in its Preferences:
   ```sh
   brew install --cask hammerspoon
   ```
2. Clone this repo into your Hammerspoon folder:
   ```sh
   git clone https://github.com/HomeFront-tech/claude-usage-widget.git ~/.hammerspoon/claude-usage-widget
   ```
3. Add these lines to `~/.hammerspoon/init.lua` (Hammerspoon menu → **Open Config**):
   ```lua
   local widget = os.getenv("HOME") .. "/.hammerspoon/claude-usage-widget/"
   ClaudeUsage = dofile(widget .. "usage_widget.lua").start()
   ClaudeBuddy = dofile(widget .. "buddy.lua").start()   -- leave out if you only want the card
   ```
   Keep `ClaudeUsage` and `ClaudeBuddy` global (no `local`). Hammerspoon cleans up
   local objects, and the widgets would disappear.
4. Hammerspoon menu → **Reload Config**. The card shows up at the top-left of your main
   screen with the buddy beside it, and a short setup wizard opens (see below).

### The setup wizard

On first start the buddy opens a setup wizard to get to know you:

1. **Your name**, for greetings.
2. **Checks**: whether the card can reach your Claude login, plus Screen Recording and
   start-at-login, with a button to fix each one.
3. **Older history**: what Claude Code still has on your Mac from before its logs were
   cleaned up (days of daily totals, prompts and since when), and whether to bring it
   into the chart's History tab. Off until you turn it on.
4. **Your apps**: everything installed, with your most-used apps first. Pick how the
   buddy reacts to each one.
5. **Your stuff**: your company or websites (it gets proud) and work tools (glasses on).
6. **Behaviour**: desktop or always on top, how chatty, when it naps, and whether it
   gets a brain.

It saves your answers to `config.lua` and restarts. **Option-click the buddy** to open
the wizard again at any time.

![Setup wizard](docs/setup.png)

### Updates

The widget checks for new releases every 6 hours. When one is out, you get a
notification, the card shows **"↑ v1.2.0 is out · click to update"**, and the buddy
tells you. Click the card to see what's new and hit **Update**: it moves your copy to
the new release and restarts. Your `config.lua` is never touched. If you changed the
code yourself and it can't update cleanly, it tells you and opens the release page.

Don't want update alerts? Turn them off in the setup wizard, or set
`check_updates = false` in `config.lua`.

> Installed before v1.1.0? Run this once to get the updater:
> `git -C ~/.hammerspoon/claude-usage-widget pull`, then reload Hammerspoon.

### Permissions

- **Keychain:** the first time, macOS may ask if `security` can use the
  "Claude Code-credentials" item. Click **Always Allow**.
- **Screen Recording (optional):** System Settings → Privacy & Security → Screen &
  System Audio Recording → turn on Hammerspoon. This lets the buddy read window titles
  (YouTube vs. Gmail tabs, Claude Code working vs. waiting). Without it, the buddy still
  reacts to each app.
- Accessibility permission is **not** needed.

## Customize

The setup wizard covers most of it. Your answers go in `config.lua`, which you can also
edit by hand; `config.example.lua` lists every setting, including some the wizard doesn't
ask about, like your own lines for each mood. `config.lua` is gitignored, so `git pull`
won't overwrite it. For bigger changes, edit `MOODS`, `APPS` and `TITLE_RULES` at the top
of `buddy.lua`.

To preview a mood from the terminal, you need Hammerspoon's `hs` command. Add
`require("hs.ipc")` to `init.lua` and run `hs.ipc.cliInstall()` once in the Hammerspoon
console. Then:

```sh
hs -c 'ClaudeBuddy.test("love")'
hs -c 'ClaudeBuddy.event("crash", "Safari")'   # usb, screenshot, download, offline, wake…
hs -c 'ClaudeBuddy.peek()'                     # with a brain: look at the screen now
hs -c 'ClaudeBuddy.forget()'                   # wipe the chat and what it remembers about you
```

Cmd-click opens Terminal; set `terminal = "iTerm"` for iTerm. The menu's project list
comes from your most recently changed folders in `~/dev`, `~/Projects`, `~/code` or
`~/src`, or from `projects = { "~/work/app", ... }` in `config.lua`.

To see your usage in the terminal, run `bin/claude-usage` (add `--raw` for the full API
response).

## How it works

- `bin/claude-usage` reads Claude Code's login token from the macOS Keychain (or
  `~/.claude/.credentials.json`). It calls `https://api.anthropic.com/api/oauth/usage`,
  the same endpoint Claude Code's `/usage` uses, and prints the result as JSON. The
  token goes only to Anthropic and is never printed or saved. The script never
  refreshes the token; Claude Code does that.
- That endpoint isn't documented, so Anthropic can change it at any time. The script
  handles both response shapes seen so far.
- `usage_widget.lua` runs the script every 5 minutes and draws the card. If the API
  says to slow down, it waits as long as asked and keeps showing the last numbers.
- Each check is appended to `~/Library/Application Support/claude-usage-widget/history.jsonl`
  (time and percentages only; 90 days are kept).
- `bin/claude-tokens` reads Claude Code's logs (`~/.claude*/projects/**/*.jsonl`) and
  keeps only numbers: each reply's time, model, token counts and session. It never
  stores message text. It remembers how far it read in each log, so after the first
  scan it takes a fraction of a second; replies repeated in resumed sessions count
  once; and its hourly tallies (`tokens.json`, same folder) outlive Claude Code's own
  log cleanup. The card runs it every 5 minutes.
- With older history on, it also reads Claude Code's `/stats` cache
  (`~/.claude*/stats-cache.json`: tokens per model per day, message and session counts)
  and prompt history (`~/.claude*/history.jsonl`, of which it keeps only each prompt's
  hour and session). The numbers go into `archive.json` and only ever grow, and each new
  version of the stats cache is copied to `archive/`. `claude-tokens --scan` shows what
  it would bring in without changing anything; the wizard runs that.
- `chart.lua` and `chart.html` draw the chart views in a Hammerspoon web view, with no
  outside libraries. Nothing leaves your Mac.
- `buddy.lua` reads the front app, its window title, your mouse position and idle time,
  then picks a mood from the rules. It animates at 12 fps, uses about 2–4% CPU, and
  pauses when your screens sleep.
- The per-app time tally is stored in Hammerspoon's settings on your Mac and never
  leaves it. Only app IDs and seconds are kept, never window titles.
- `events.lua` uses Hammerspoon's watchers for wake, screens, USB, audio, network and
  drives, watches the screenshot folder, Downloads and crash reports for new files, and
  checks the log files you list every 3 seconds for new lines.
- `brain.lua` is the optional brain. It sends a shrunken screenshot of one window, plus
  the app name and window title, to Ollama's chat API (`ai.url`, `localhost` by
  default) and gets one line back. `chat.lua` and `chat.html` are the chat panel. The
  conversation (its last 80 lines, bubble lines included) and the brain's notes about
  you are kept in Hammerspoon's settings on your Mac and only ever sent to `ai.url`.
- `dictate.lua` is hold-space dictation: ffmpeg records the default microphone only
  while you hold space, whisper.cpp transcribes it locally, and the recording is
  deleted right after.
- `setup.lua` and `setup.html` are the wizard: a small Hammerspoon web view that writes
  `config.lua`.
- `updater.lua` reads the latest release from the public GitHub API (no login, nothing
  sent about you) and compares it with `VERSION`. Updating runs `git fetch` and a
  fast-forward to the release tag.

## Publishing an update (maintainers)

Commit and push your changes as usual. Pushing alone doesn't notify anyone. When it's
ready to go out, run:

```sh
tools/release 1.2.0 "Buddy reacts to Figma
Card shows extra usage in dollars"
```

That bumps `VERSION`, tags `v1.2.0`, pushes, and creates the GitHub release. Its notes
are what people see in the update dialog. Installed copies notice it within 6 hours.
It needs the [GitHub CLI](https://cli.github.com) (`gh`). If you fork this, set
`update_repo = "you/your-fork"` in `config.lua` so your copies check your releases.

## Troubleshooting

- **"No Claude Code login found"**: run `claude` and log in with `/login`.
- **"Login expired · open Claude Code"**: open any Claude Code session and it refreshes.
- **"Usage API busy"**: Anthropic asked the widget to slow down. It waits, then
  tries again by itself.
- **Nothing shows up**: check the Hammerspoon console (menu bar icon → Console) for errors.

## Not affiliated with Anthropic

This is an unofficial fan project. Claude is a trademark of Anthropic.

## License

[MIT](LICENSE)
