# Claude Usage Widget + Buddy

A macOS desktop widget that shows your Claude plan usage, plus a little pixel Claude
that reacts to whatever app you're in. Runs on [Hammerspoon](https://www.hammerspoon.org).
There's no AI inside: the buddy runs on plain rules.

![Usage card and buddy](docs/screenshot.png)

## What you get

**The usage card** shows the same numbers as Claude Code's `/usage`:

- The current 5-hour session, your weekly limits (all models and per model), any
  credits, and extra usage if you've turned it on, each with a reset countdown
- A refresh every 2 minutes, after your Mac wakes, and whenever you click the card
- Bars that turn amber at 70% and red at 90%
- Drag it anywhere; it remembers the spot

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

It also follows your mouse with its eyes, blinks and fidgets, gets bored after
3 minutes away, falls asleep after 10 (and jumps when you come back), drinks coffee in
the morning, gets sleepy late at night, and sweats when your session is 80% used.
Click it for a hello. Drag it to move it. Option-click it for the setup wizard.

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
3. **Your apps**: everything installed, with your most-used apps first. Pick how the
   buddy reacts to each one.
4. **Your stuff**: your company or websites (it gets proud) and work tools (glasses on).
5. **Behaviour**: desktop or always on top, how chatty, and when it naps.

It saves your answers to `config.lua` and restarts. **Option-click the buddy** to open
the wizard again at any time.

![Setup wizard](docs/setup.png)

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
```

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
- `usage_widget.lua` runs the script every 2 minutes and draws the card.
- `buddy.lua` reads the front app, its window title, your mouse position and idle time,
  then picks a mood from the rules. It animates at 12 fps, uses about 2–4% CPU, and
  pauses when your screens sleep.
- The per-app time tally is stored in Hammerspoon's settings on your Mac and never
  leaves it. Only app IDs and seconds are kept, never window titles.
- `setup.lua` and `setup.html` are the wizard: a small Hammerspoon web view that writes
  `config.lua`.

## Troubleshooting

- **"No Claude Code login found"**: run `claude` and log in with `/login`.
- **"Login expired · open Claude Code"**: open any Claude Code session and it refreshes.
- **Nothing shows up**: check the Hammerspoon console (menu bar icon → Console) for errors.

## Not affiliated with Anthropic

This is an unofficial fan project. Claude is a trademark of Anthropic.

## License

[MIT](LICENSE)
