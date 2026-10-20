---
name: adding-buddy-reactions
description: Use when adding or changing what the Claude buddy does in this repo, such as a new mood, an app or website reaction, a prop, a particle effect, an action, a Mac event, dialogue lines or a menu item, or when a new mood doesn't show up somewhere it should.
---

# Adding buddy reactions

## Overview
The buddy is data-driven: almost every feature is a row in a table in `buddy.lua` or
`events.lua`. A reaction is finished only when every place that lists moods knows it.
Find tables by name (`grep -n "^local MOODS" buddy.lua`); line numbers drift. The
examples use a made-up `design` mood for Figma.

Before editing, run `git status --short`. If another session has changes in the files
you need, read shipping-widget-releases first.

## Where things live
| Want | Edit | Shape |
|---|---|---|
| App → reaction | `APPS` in buddy.lua (bundle id or app name) | `["com.figma.Desktop"] = "design"` |
| Browser tab → reaction | `TITLE_RULES` (lower-case substring; first match wins, so order matters) | `{ "figma.com", "design" }` |
| How a reaction looks | `MOODS` | `{ eyes, body, arms, prop?, emit?, mouth?, glasses?, blush?, lines }` |
| A short move over any mood | `ACTIONS`; idle fidgets go in `TRICKS` | mood fields, no `lines` |
| Something it holds | `PROPS.name = function(px, f) ... end` | see the grid below |
| Floating particles | `EMIT` | `{ rate, glyphs, color, size, from = "head"/"side"/"sky"/"mug", vy, spread, life }` |
| A Mac or system event | `BUILTIN` in events.lua, plus the watcher that calls `fire(id, spec, extra, cooldown)` | `{ mood, lines }` |
| Claude Code session lines | `SESSION_TOPICS`, `DONE_*`; users add their own with config.lua `session_topics` (checked first) | `{ { "checkout" }, { "%t: careful!" } }`; `%t` session name, `%m` minutes |

Values that exist today (the branches of `drawEyes`, `bodyOffset`, `drawArms` and the
mouth code in `frame()`; check there if one is missing, since a new value needs drawing code):
- eyes: `track` (follows the mouse), `scan`, `down`, `ahead`, `squint`, `happy`, `hearts`,
  `wide`, `sleepy`, `closed`, `dizzy`
- body: `breathe`, `bounce`, `type`, `sway`, `jitter`, `sleep`, `hop`
- arms: `rest` (the default), `up`, `wave`, `type`, `hold`
- mouth: `o`, `flat`, `yawn`, `talk`; `happy` and `hearts` eyes add a smile by themselves
- props: `laptop`, `popcorn`, `controller`, `mug`, `envelope`, `wrench`, `shovel`, `phone`
- colours in `C`: `body`, `shade`, `shine`, `eye`, `pink`, `blush`, `white`, `grey`, `dark`,
  `red`, `yellow`, `gold`, `brown`, `blue`

## Why a reaction doesn't fire
Order of precedence: `config.lua` `apps` > terminal rules (Claude Code's spinner or ✳ in
the title) > browser `TITLE_RULES` > `APPS` > generic. The local `config.lua` can shadow
a built-in, so check it when testing.

## Lines
Placeholders: `{name}` (write it with a leading space: `"Hi {name}!"`), `%s` app name,
`%t` session, `%m` minutes, `%1`… event captures, `%f` file name (events strip the
extension, so name the file type in the line itself). About 27 characters per bubble
line, 4 lines max. The repo is public: no
real people, clients, places or in-jokes about the owner.

## Pixel grid
One pixel is 5 pt (`S`). Body: columns 0–13, rows 0–9. Legs: rows 10–11. Eyes: columns
3–4 and 9–10, rows 3–5. Arms: left column -1, right column 14 (`arms = "hold"` puts the
hand at column 15, rows 6–7). Props usually sit right of the body in columns 15–19; past
column ~26 they leave the 200×170 canvas. `f` counts frames at 6 Hz, so `f % 2` makes a
two-frame wiggle. Colours come from the `C` table; add new ones there.

## A new mood also goes in
1. `MOOD_LABELS` in setup.lua, or the setup wizard can't offer it.
2. The `Moods:` comment at the end of config.example.lua.
3. README.md's "You're in… / The buddy…" table, if users should know about it.
4. The `calm` set in `poll()`, if idle tricks should play during it.
5. The `C` table, for any new colours its prop or particles use.

## Then
**REQUIRED:** use testing-hammerspoon-widgets to syntax-check, reload and look at it.
To publish, use shipping-widget-releases.

## Common mistakes
- The mood exists only in `MOODS`, so the wizard's picker never shows it.
- Two events fire for one thing (a specific download rule and the generic `download`):
  return right after firing the specific one.
- Each `EMIT` entry has one colour. For several, give it `colors = { "red", "gold" }` and
  in `spawn()` use `C[e.colors and pick(e.colors) or e.color]`, so old entries still work.
- Emoji glyphs draw in full colour and ignore `color`.
- An event's `ai` text goes to the local model when a brain is configured; keep private
  content out of it.
