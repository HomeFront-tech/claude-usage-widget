---
name: testing-hammerspoon-widgets
description: Use when trying out, reloading, screenshotting or debugging the usage card, buddy, chart, chat or setup wizard in this repo, or when `hs -c` hangs, a widget vanishes after a reload, clicks do nothing, or a change doesn't show up.
---

# Testing the Hammerspoon widgets

## Overview
The clone is the live install: `~/.hammerspoon/init.lua` loads these files straight from
the repo, so a reload runs whatever is on disk, for everyone working in the folder.
Check the syntax before reloading, look at the result, and read the console.

## The loop
```sh
R="$(git rev-parse --show-toplevel)"; OUT="$(mktemp -d)"   # OUT: where pictures go
# 1. Syntax-check every .lua file you changed, without running it (luac usually isn't installed)
for f in buddy.lua events.lua; do timeout 10 hs -c "local _, e = loadfile('$R/$f'); return e or '$f ok'"; done
# 2. Reload
timeout 10 hs -c 'hs.reload()' >/dev/null 2>&1; sleep 6
# 3. Errors since then
timeout 10 hs -c 'return hs.console.getConsole():sub(-3000)' | grep -iE 'error|traceback|\.lua:[0-9]'
# 4. Preview
timeout 10 hs -c 'ClaudeBuddy.test("design", 15)'          # a mood for 15 s (3rd arg: an action)
timeout 10 hs -c 'ClaudeBuddy.event("download", "a.fig")'   # an event
timeout 10 hs -c 'ClaudeUsage.chart(true)'                 # the chart with demo data
```
Always wrap `hs` in `timeout`. A call can hang for good (a killed IPC call, a modal
dialog), and a hung `hs` blocks your shell.

Specs: `tests/lua-tests` runs every `tests/*_spec.lua` inside Hammerspoon (plus a load check
of each top-level `.lua`) and exits non-zero on failure; `hs -c` itself always exits 0.
Python helpers: `/usr/bin/python3 -m unittest discover -s tests -v`. Specs use temp folders
and fakes in `tests/fakes/`, never the live state.

Then try the real trigger: bring the app to the front, or create a test file in the
watched folder (`touch ~/Downloads/zz-test.fig`) and delete only that file afterwards.
Events have cooldowns (20–60 s), so wait or use a new name before trying again.

## Look at it
Take the picture through Hammerspoon, which has Screen Recording; your terminal may not.
`OUT` is any scratch folder.
```sh
timeout 15 hs -c "local f = ClaudeBuddy.canvas:frame(); local s = hs.screen.find(f); local ff = s:fullFrame()
  s:snapshot(hs.geometry.rect(f.x - ff.x, f.y - ff.y, f.w, f.h)):saveToFile('$OUT/buddy.png')"
```
Then read the PNG. The same works for `ClaudeUsage.canvas` and for web views
(`ClaudeUsage.chartWin.wv`, the wizard, the chat panel). Drive a web view with
`wv:evaluateJavaScript("...")` to switch tabs or fake a hover before the snapshot.
Animations move, so pin the mood with `test()` for long enough and snap twice if needed.
The snapshot shows whatever is on top at that spot: if a window covers the widget, you
get the window, so check the picture before trusting it. Close any window you opened.

## Check it's cheap
`top -l 4 -s 2 -pid $(pgrep -x Hammerspoon) -stats cpu`: the buddy at 12 fps should
stay around 2–4%.

## Gotchas
| Symptom | Cause and fix |
|---|---|
| A widget disappears a while after a reload | Garbage collection: keep timers, watchers and canvases on the module table (`M.timer = …`) and the module in a global in init.lua |
| Clicks on the card or buddy do nothing | Finder's desktop window shares the `desktopIcon` level; draw at `desktopIcon + 1` |
| Dragging or an event tap does nothing | No Accessibility permission: poll `hs.mouse.absolutePosition()` and `hs.eventtap.checkMouseButtons()` |
| Window titles are empty | Screen Recording is off; app-level rules still work |
| `os.date` errors on `%-I` | Lua 5.4 rejects `%-`; strip the leading zero yourself |
| The card says "Usage API busy" | Anthropic rate-limits that endpoint. Don't reload in a loop; the card reuses numbers under 60 s old |
| A brand-new GitHub release isn't seen | macOS cached the earlier 404; send `Cache-Control: no-cache` |
| `hs.task` silently fails | It needs absolute paths (`/usr/bin/nice`, the full python3 path) |
| A drag test with `hs.eventtap.event.newMouseEvent(...):post()` hangs `hs -c` or doesn't move anything | Posted clicks don't reliably show up in `checkMouseButtons()`, and the CLI call loses its reply and never returns. Test drags and clicks by hand; `pkill -f '^hs -c'` clears stuck calls |
| `hs -c` from a script hangs until its timeout | hs reads stdin when it isn't a terminal. Give it `/dev/null` (`stdin=subprocess.DEVNULL`), above all inside an MCP server, whose stdin stays open |
| `hs -c` output fails to parse as JSON | The first touch of an extension prints `-- Loading extension: …` first. Drop those lines |
| `hs.window.allWindows()` or `app:allWindows()` hangs `hs -c` | They ask every app over Accessibility and a busy app (a game, remote play) stalls them. Keep your own windows on the module table and use those |
| `hs.eventtap.keyStrokes` never reaches the chat box | A borderless web view takes typing only after a real click. Drive it with `wv:evaluateJavaScript` on a web view you keep on the module table |
| A saved spot on an unplugged screen still "finds" a screen | `hs.screen.find(point)` returns the nearest screen, never nil. Loop `hs.screen.allScreens()` and test each `frame()` |

## Another session in the same folder
Another Claude session may be editing and reloading this folder too, and every reload
loads your half-finished file. Make each save leave the file loadable (one complete
write, or edits that are each valid on their own) and syntax-check big changes first.
`ListAgents` shows who's busy; message them before touching their files.
