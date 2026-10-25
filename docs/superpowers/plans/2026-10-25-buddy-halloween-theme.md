# Buddy Halloween theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Buddy's corner into a small spooky pixel world from Oct 24 to Oct 31: the witch costume, a web with a spider, a candy pail, Halloween lines and brain, and 41 data-driven skits, all shipped tonight.

**Architecture:** `skits.lua` is a pure-Lua engine. It compiles sprite and skit JSON and answers "what's drawn at time t, and which cues fired". `halloween.lua` is the theme. It owns the dates, the dress-up, the world art, scheduling, lines, the menu and the persona sentence, and it draws through `add`/`px` callbacks that `buddy.lua` passes in from `frame()`. `buddy.lua` and `brain.lua` only get small call sites. A Python checker validates every skit file. A browser gallery, mirroring the engine in JS, plays every skit for review. A sandboxed hidden Buddy runs specs and renders PNG contact sheets of each skit without touching the running copy.

**Tech Stack:** Hammerspoon Lua (`hs.canvas`, `hs.json`, `hs.fs`, `hs.settings`), Python 3 standard library, plain HTML/JS canvas.

**Spec:** `docs/superpowers/specs/2026-10-24-buddy-halloween-theme-design.md`. Read it with this plan. Where they differ, this plan's "My calls" section says why.

**Execution:** one orchestrating session plans and verifies. Parallel builders implement the code-from-spec tasks and the skit batches, and a separate reviewer gives a second opinion on the engine, the theme and each skit batch. The orchestrator writes the `buddy.lua` call sites itself (Task 6), runs every test, and reviews the PNG contact sheets. Builders never commit; the orchestrator commits each task after its tests pass. Branch `halloween-theme`, in its own worktree.

## Global Constraints

- Hammerspoon Lua, no build step. Canvas 200×170, `S = 5`, `BODY_TOP = 98`, `GROUND = BODY_TOP + 12*S`, body grid 14×12, home `ox = 65`. `frame()` runs at 12 fps and calls `replaceElements` only when its signature changes.
- `skits.lua` makes no `hs.*` calls. Everything platform-specific is passed in.
- One `Skins` instance, `ClaudeBuddy.skins`. The theme never loads its own copy. Call `Skins.wear` on theme start and stop only.
- Off means no drawing, no extra timers and no skit file loading, only the date check once a second.
- Skit lines use `say(text, true, true)`. They go in the bubble, stay out of the chat transcript, and respect the mute.
- Nothing faster than 3 Hz blinks (the checker enforces this for sprite animations that change how much is lit).
- No character names or movie titles in ids, skit `name`s, sprite names, menu labels or the README. Spoken lines may quote briefly ("Beetlejuice…" is allowed).
- Lines are at most 40 characters: skit `say`, and the idle, sleepy, morning and click pools. Jokes are at most 80 (see My calls).
- No personal data or business details in the repo. Docs say "the owner".
- Specs never reassign globals (`print`, `hs`, …); they pass a logger in. Specs and the sandbox Buddy never write `hs.settings`: the sandbox keeps its settings in memory.
- The running copy `~/.hammerspoon/claude-usage-widget` is never touched. `hs -c` may run specs and the sandbox only.
- Match the repo's style: two-space Lua indentation, a comment above each non-obvious block in the same short plain-English voice, `local function` helpers, no new dependencies.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. No commits to `main`, no `tools/release`, no push.

## My calls (not in the spec, or settling something it left open)

- `eveningWeight` (optional, skits): the weight used from 17:00 to 23:59. It's for `trick-or-treat` ("more often in the evening").
- `next.after` may be a number or `[lo, hi]` seconds. `pail-heist` uses `[40, 60]`. Its upper bound is at most 150, so it falls inside the 3-minute chain window.
- The chain deadline is the end of the first skit + 180 s. While a chain is waiting, no other skit starts.
- No repeats until 8 others have played. If every eligible skit is among the last 8, pick from them, never the very last one.
- `pail-return` moves into the reference set, since `pail-heist` chains to it and the checker requires chain targets to exist.
- `prop` cues become `doAction("prop:<name>", for)`. The theme registers one action per existing prop (`laptop popcorn controller mug envelope wrench shovel phone`): `{ prop = name, arms = "hold" }`.
- The `run` cue also starts a `trot` action (`{ body = "sway" }`) for its duration, so the legs alternate. An `action` cue at the same `t`, written after it, replaces that action.
- The spider's climb cycle is the mockup's, stretched from 10 s to 30 s. The mockup ran fast on purpose; the extra 20 s go to the hanging part.
- Skit files load from `skits/` and from `~/Library/Application Support/claude-usage-widget/skits/` (a user's own, the same as skins). The library loads once, the first time the theme is on.
- Spooky surprise and `ClaudeBuddy.skit(id)` play right away and ignore the start rules. Spooky surprise still respects `needs`; `skit(id)` doesn't, so chain-only skits can be tested. Both only work while the theme is on.
- The menu toggle counts only in season (Oct 24–31) and only for the year it was set, so an "on" saved in October can't keep the theme on in November.
- The Halloween theme ✓ item is disabled, with "(set in config.lua)" in its title, when config.lua forces the theme.
- `buddy.lua` loads the theme with `pcall`. If `halloween.lua` fails to load, or errors later while drawing, Buddy logs it once and carries on as if the theme were off. This also keeps skins' `buddy_frame_spec.lua` sandbox (which only allows `skins.lua`) passing unchanged.
- Halloween jokes may be up to 80 characters, like the existing `JOKES`. Every other pool keeps the 40 limit.
- `ClaudeBuddy.theme` is exposed for specs and `hs -c` debugging (`Theme.status()`).

## Review Focus

1. **Pail never comes back.** A heist is interrupted by a click, or its `pail-return` chain misses its 3-minute window, or Hammerspoon reloads while the pail's gone. A person expects the pail back in Buddy's hand right away (interrupt, deadline) or on load (it's never saved as gone). Tests: Task 4 `chain deadline brings the pail back`, Task 4 `interrupt restores pail, spider and offset`.
2. **Buddy stuck off to one side.** The screens sleep mid-chase (frames stop, so `behind()` isn't called), or a click lands mid-run. A person expects Buddy home when they come back. Test: Task 4 `tick ends a skit whose frames stopped`.
3. **The user's own skin overridden.** Someone picks Vampire (or Classic) from the menu on Oct 26 and reloads Hammerspoon. A person expects their pick to stick and no witch hat. Test: Task 4 `a menu pick sticks across a reload`.
4. **Theme stuck on in November.** Toggled off and back on in October, then Nov 1 arrives. A person expects it off. Test: Task 4 `menu on in October does not carry into November`.
5. **A theme error freezes Buddy.** A bad skit that passed the loader still throws while drawing. A person expects Buddy to keep animating without the theme. Test: Task 4 `an error while drawing turns the theme off`.

---

## File Structure

| File | Owns |
|---|---|
| `skits.lua` (new) | Pure engine: colours, easing, sprite compile, skit compile/validate, sampling, cues, weighted pick |
| `halloween.lua` (new) | The theme: dates/overrides, dress-up, library loading, scheduling, start/interrupt rules, cue execution, run offset, web/spider/pail/actor drawing, line pools, persona, menu, error guard |
| `skits/sprites.json` (new) | Shared sprites: `bat`, `spider`, `pail`, `candy`, `puff` |
| `skits/<id>.json` (new ×41) | One skit each |
| `tools/check-skits` (new) | Python validator for `skits/` |
| `tests/test_skits.py` (new) | Checker tests |
| `tests/skits_spec.lua` (new) | Engine specs, plus checks over every shipped file |
| `tests/halloween_spec.lua` (new) | Theme specs with a fake Skins, settings, clock and hooks |
| `tests/buddy_sandbox.lua` (new) | Hidden test Buddy: `buddy.lua` loaded with a stand-in `hs`, in-memory settings, the real skins/theme/skits |
| `tests/halloween_buddy_spec.lua` (new) | `buddy.lua` + theme through the sandbox |
| `tools/skit-snapshots` (new) | Renders PNG contact sheets of skits through the sandbox |
| `tools/skits.html`, `tools/skits-gallery` (new) | Browser gallery on 127.0.0.1:8743 |
| `buddy.lua`, `brain.lua` (modify) | Call sites only |
| `README.md`, `config.example.lua` (modify) | Halloween section, `halloween` option |

---

### Task 1: Skit engine (`skits.lua`)

**Files:**
- Create: `skits.lua`
- Test: `tests/skits_spec.lua`

**Interfaces:**
- Produces (all on the module table `K`, returned by `dofile("skits.lua")`):
  - `K.GROUPS = { "bats", "spider", "visitors", "movies" }`, `K.ANCHORS = { "top", "head", "face", "hand", "feet", "web", "spider" }`
  - `K.hex(s) -> { red, green, blue, alpha } | nil` for `#rrggbb` / `#rrggbbaa`
  - `K.ease(kind, p) -> number`. kind is `linear|in|out|inout`; p is clamped to 0..1. `in` = p², `out` = 1−(1−p)², `inout` = smoothstep 3p²−2p³.
  - `K.sprites(defs, color, warn) -> lib`. defs is `{ name = spriteDef }`. color(s) returns a colour table or nil. warn(msg) is called for each skipped sprite. lib[name] = `{ pixel, default = animName, anims = { [name] = { fps, frames = { { w, h, runs = { { x, y, n, color } } } } } } }`. Runs are maximal same-colour horizontal spans, 0-based x/y.
  - `K.compile(def, lib, color) -> skit | nil, why`. Local `def.sprites` compile over lib (local wins). Returns `{ id, name, group, length, weight (default 2), eveningWeight (nil), needs = { pail = true, … }, next = { skit, after = { lo, hi }, chance (default 1) } | nil, actors = { { sprite, layer, keys, bob, thread } }, cues = { sorted by t, stable } }`.
  - `K.sample(skit, time, anchors) -> items`. anchors[name] = `{ x, y }`. Each item is `{ layer, x, y, pixel, frame, flip, thread, key }`: x, y is the integer top-left; frame is a compiled frame; thread is `{ x1, y1, x2, y2 } | nil`; key is a short string for the frame signature.
  - `K.cues(skit, from, to) -> list` of the cues with `from < cue.t <= to`, in order.
  - `K.pick(skits, state, random) -> skit | nil`. state = `{ pail = bool, evening = bool, recent = { id, … } }`, oldest first, at most 8.

- [ ] **Step 1: Write the failing spec `tests/skits_spec.lua`**

It returns `function(t, dir)` and loads `dofile(dir .. "/skits.lua")`. The colour function is `function(s) return K.hex(s) or ({ dark = "DARK", eye = "EYE" })[s] end`. Fixtures are literal tables. Assertions:

```lua
local warnings = {}
local function warnf(m) warnings[#warnings + 1] = m end
local A = { top = { x = 100, y = 58 }, head = { x = 100, y = 98 }, face = { x = 100, y = 123 }, hand = { x = 150, y = 118 },
  feet = { x = 100, y = 158 }, web = { x = 39, y = 39 }, spider = { x = 39, y = 108 } }
-- colours and easing
t.eq(K.hex("#ff0000").red, 1, "hex red"); t.eq(K.hex("#00000080").alpha, 128 / 255, "hex alpha")
t.eq(K.hex("red"), nil, "names aren't hex")
t.eq(K.ease("linear", 0.5), 0.5, "linear"); t.eq(K.ease("in", 0.5), 0.25, "in")
t.eq(K.ease("out", 0.5), 0.75, "out"); t.eq(K.ease("inout", 0.5), 0.5, "inout mid")
t.eq(K.ease("in", 2), 1, "clamped")

-- sprite runs: "XX.e" -> two runs on row 0
local lib = K.sprites({ s = { pixel = 3, colors = { X = "dark", e = "eye" },
  anims = { a = { fps = 2, frames = { { "XX.e", "...." } , { "X..e", "...." } } }, b = { frames = { { "eeee", "...." } } } } } }, color, warnf)
local f1 = lib.s.anims.a.frames[1]
t.eq(#f1.runs, 2, "runs merge same-colour spans"); t.eq(f1.runs[1].n, 2, "first run is 2 wide")
t.eq(f1.w .. "x" .. f1.h, "4x2", "frame size")
-- a sprite with an unknown colour char, or uneven rows, or 25 rows, is skipped with a warning
t.eq(lib.bad, nil, "bad sprite skipped"); t.ok(#warnings >= 1, "and warned")

-- sampling: bottom-centre positions, easing, step fields, appear/disappear
local sk = assert(K.compile({ id = "x", name = "X", group = "bats", length = 4, actors = {
  { sprite = "s", layer = "front", keys = {
    { t = 1, x = 100, y = 50, anim = "a" },
    { t = 3, x = 140, y = 50, ease = "in", flip = true },
    { t = 3.5, at = "head", dy = -2, anim = "b" } } } },
  buddy = { { t = 0, say = "hi" }, { t = 2, action = "hop", ["for"] = 1 }, { t = 2, say = { "a", "b" } } } }, lib, color))
t.eq(#K.sample(sk, 0.5, A), 0, "hidden before its first key")
local it = K.sample(sk, 1, A)[1]
t.eq(it.x .. "," .. it.y, (100 - 6) .. "," .. (50 - 6), "bottom-centre to top-left (4x2 sprite, pixel 3)")
t.eq(K.sample(sk, 2, A)[1].x, math.floor(100 + 40 * 0.25 - 6 + 0.5), "eases with the arriving key's ease")
t.eq(K.sample(sk, 2, A)[1].flip, false, "flip waits for its key"); t.eq(K.sample(sk, 3.2, A)[1].flip, true, "then holds")
t.eq(K.sample(sk, 3.5, A)[1].frame, lib.s.anims.b.frames[1], "anim switches at its key")
t.eq(K.sample(sk, 3.6, A)[1], nil, "gone after its last key")
-- anchors are live: moving head moves the actor
A.head = { x = 120, y = 90 }; local a1 = K.sample(sk, 3.5, A)[1].x
A.head = { x = 130, y = 90 }; t.eq(K.sample(sk, 3.5, A)[1].x, a1 + 10, "anchor follows Buddy")
-- bob and thread
local bt = assert(K.compile({ id = "z", name = "Z", group = "spider", length = 2, actors = {
  { sprite = "s", layer = "behind", bob = { amp = 3, hz = 0.25 }, thread = "web", keys = { { t = 0, x = 50, y = 80, anim = "a" } , { t = 2 } } } } }, lib, color))
t.eq(K.sample(bt, 0, A)[1].y - K.sample(bt, 1, A)[1].y, 3, "bob: a quarter cycle in, 3 pt higher")
local th = K.sample(bt, 0, A)[1].thread
t.eq(th.x1 .. "," .. th.y1 .. "," .. th.x2 .. "," .. th.y2, "39,39,50,74", "thread from the web to the top centre")

-- cues: once each, in order, a slow frame skipping past several still fires them all
t.eq(#K.cues(sk, -1, 0), 1, "t = 0 cue fires on the first step")
t.eq(#K.cues(sk, 0, 1.9), 0, "nothing in between")
local c = K.cues(sk, 1.9, 2.5); t.eq(#c, 2, "both t = 2 cues"); t.eq(c[1].action, "hop", "in file order")
t.eq(#K.cues(sk, -1, 4), 3, "a 4 s frame fires all three once")

-- compile rejects, with a reason: unknown sprite, unknown anchor, keys out of order, t past length,
-- unknown group, length > 30, a cue with two kinds
t.ok(select(2, K.compile({ id = "y", name = "Y", group = "bats", length = 40, actors = {} }, lib, color)), "length > 30 rejected")

-- pick: weights, needs, no repeats, chain-only, evening weight
local P = { { id = "a", weight = 1, needs = {} }, { id = "b", weight = 0, needs = {} },
  { id = "c", weight = 5, needs = { pail = true } }, { id = "d", weight = 1, eveningWeight = 9, needs = {} } }
t.eq(K.pick(P, { pail = false, recent = { "d" } }, function() return 0 end).id, "a", "skips chain-only, unmet needs, recent")
t.eq(K.pick(P, { pail = true, recent = {} }, function() return 0.3 end).id, "c", "weighted (1, 5, 1 -> 0.3 lands on c)")
t.eq(K.pick(P, { pail = false, evening = true, recent = { "a" } }, function() return 0.99 end).id, "d", "evening weight")
t.eq(K.pick(P, { pail = false, recent = { "d", "a" } }, function() return 0 end).id, "d", "all recent: any but the very last")
```

Also: `shipped skits` checks, which skip with a note when `skits/` has no files yet. Every `skits/*.json` and `skits/sprites.json` compiles with no warnings (read with `io.open` + `hs.json.decode` in the spec, never in `skits.lua`). Every `next.skit` names a shipped skit. **No skit covers the face**: sample each skit every 0.1 s with home anchors (`ox = 65, oy = 98, cx = 100`, witch `topRows = 8`). The face box is `x 75..125, y 108..143`. No run of samples longer than 1.5 s may have front-layer item boxes covering more than half of it.

- [ ] **Step 2: Run it and see it fail**

Run: `tests/lua-tests`
Expected: FAIL. `skits_spec.lua` errors with "cannot open …/skits.lua".

- [ ] **Step 3: Implement `skits.lua`**

Pure Lua. The header comment is in the style of `skins.lua` (what it is, the format pointer). Rules the signatures don't settle:
- A key with no `x`/`y`/`at` keeps the previous key's position, resolved at sample time.
- Before the first key, or after the last key's `t`, the actor isn't drawn.
- Step fields (`anim`, `flip`, `hide`) come from the latest key with `t <= time`. The default anim is the first key's anim, else the alphabetically first.
- The animation frame is `floor(time * fps) % #frames + 1`, with fps defaulting to 6.
- Bob adds `-amp * sin(2π·hz·time)` to y.
- `flip` mirrors the run x: `w - x - n`.
- All output coordinates are `math.floor(v + 0.5)`.
- `key` = `sprite .. anim .. frameIndex .. "@" .. x .. "," .. y .. (flip and "f" or "")`.

Validation lives in `K.compile` and mirrors the checker's structural rules (Task 2). It returns `nil, "why"` instead of throwing; a `pcall` around the body turns an unexpected error into a `why`.

- [ ] **Step 4: Run it and see it pass**

Run: `tests/lua-tests`
Expected: the `skits_spec.lua` lines pass. The "shipped skits" checks note that none are shipped yet. The total is `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add skits.lua tests/skits_spec.lua
git -C <worktree> commit -m "Skits: the engine (sprites, keys, anchors, cues, pick)"
```

---

### Task 2: Skit checker (`tools/check-skits`)

**Files:**
- Create: `tools/check-skits` (executable, `#!/usr/bin/env python3`, stdlib only; same shape as `tools/check-skins`: `check_file(path) -> [errors]`, `check_all(paths) -> {path: [errors]}`, `main(argv)`)
- Test: `tests/test_skits.py` (same loader pattern as `tests/test_skins.py`)

**Interfaces:**
- Produces: `tools/check-skits [files…]`. With no arguments it checks `skits/sprites.json` plus every `skits/*.json`. It prints `path: problem` lines and `N skits OK`, and exits 1 on any problem. Builders and the release captain run it.

Rules (each one is a test in `tests/test_skits.py`, named `test_<rule>`):
- Readable JSON, with no NaN or Infinity.
- Sprites (library or local):
  - `pixel` is an int 1–8.
  - `colors` maps single characters (not `.` or space) to `#rrggbb[aa]` or a base name (`body shade shine eye white grey dark red yellow gold brown blue pink`).
  - `anims` is non-empty. Each anim has `fps` 1–12 (default 6) and non-empty `frames`.
  - Every frame has equal-length rows, at most 24×24, and every lit character appears in `colors`.
  - **Anti-flash:** if two frames of one anim differ in lit-pixel count by more than half of the larger count, that anim's `fps` must be at most 3.
- Skit top level:
  - `id` matches the filename stem.
  - `name` is a string of 1–30 characters.
  - `group` is in the four groups.
  - `length` is in (0, 30].
  - `weight` and `eveningWeight` are ≥ 0.
  - `needs` is a subset of `pail` and `evening`.
  - `next` is `{ skit, after, chance }`: `skit` names an existing file in the same folder; `after` is a number or `[lo, hi]` with 0 ≤ lo ≤ hi ≤ 150; `chance` is in (0, 1].
  - Unknown keys are errors.
- Actors:
  - `sprite` exists, local or in the library.
  - `layer` is `front` or `behind`.
  - There is at least one key. Key `t` values are strictly ascending and within `[0, length]`.
  - A position is `x`+`y`, or `at` (an anchor) with optional `dx`/`dy`, never both. The first key needs a position.
  - `ease` is one of the four kinds. `anim` exists in the sprite, and the first key sets `anim` when the sprite has more than one. `flip` and `hide` are bools.
  - `bob` is `{ amp 0–20, hz 0–3 }`. `thread` is `"web"`.
- Buddy cues:
  - `t` values are ascending (equal allowed) and within the skit's length.
  - Each cue has exactly one of `action say look run prop pail spider emit`.
  - `action` is in `joy startle hop wave look stretch dance blush ponder talk shaken dizzy grumpy duck flee eat lookUp trot`.
  - `for` is in (0, length] and is required for `action look run prop`.
  - `say` is a string, or a non-empty list of strings, each 1–40 characters.
  - `look` is an anchor or `[x, y]`.
  - `run` is in −200..200.
  - `prop` is in the eight props.
  - `pail` is `gone` or `back`. `spider` is `away` or `home`.
  - `emit` is `{ glyphs: non-empty list of strings, color, count 1–12, from head|side|sky|hand }`.
- End state:
  - If a skit has `run` cues, the last one has `run: 0` and finishes (`t + for`) by `length`.
  - A skit that sends the pail `gone` without a later `back` must have `next`.
- Names:
  - `id`, `name` and sprite names may not contain a word from a denylist of horror character names and titles: `beetlejuice pennywise voorhees jason freddy krueger chucky ghostface scream poltergeist frankenstein dracula thriller ghostbusters scooby shining psycho myers exorcist samara`, matched case-insensitively as words.
  - `say` lines are exempt.

- [ ] **Step 1: Write `tests/test_skits.py`.** It has a minimal valid skit fixture (one actor, one cue), and each test breaks one rule and asserts that an error mentions it. It also has `test_shipped_files_pass`: when `skits/` holds files, `check_all` returns no errors. The tests write fixtures plus a `sprites.json` into a temp folder, since chain targets and library sprites resolve against the checked file's folder.
- [ ] **Step 2: Run it and see it fail.** `/usr/bin/python3 -m unittest tests.test_skits -v` → errors, since `tools/check-skits` doesn't exist yet.
- [ ] **Step 3: Implement `tools/check-skits`.** Copy the docstring style from `tools/check-skins`, pointing at the design doc's "Skit format".
- [ ] **Step 4: Run it and see it pass.** The same command, all OK.
- [ ] **Step 5: Commit.** `Skits: tools/check-skits and its tests`

---

### Task 3: Sprite library and reference skits

**Files:**
- Create: `skits/sprites.json`, `skits/fly-by.json`, `skits/hat-perch.json`, `skits/pail-heist.json`, `skits/pail-return.json`

**Interfaces:**
- Consumes: the format (Tasks 1–2).
- Produces: library sprites that later skits use by name:
  - `bat` (anims `fly` at 9 fps, `perch`, `hang`)
  - `spider` (anims `hang` at 2 fps, `climb` at 8 fps)
  - `pail` (pixel 5, anim `idle`)
  - `candy` (pixel 3, a 3×2 wrapped sweet)
  - `puff` (pixel 3, a 3-frame smoke puff at 6 fps; frames grow, so lit-count changes stay under half)

  These files are the worked examples the builder batches copy from.

Art, copied exactly from the approved mockup (`halloween-scene.html` in the main checkout's `.superpowers/brainstorm/96122-1792904181/content/`):

```json
"bat":    { "pixel": 3, "colors": { "X": "#0d0b12", "e": "#f5c542" },
            "anims": { "fly": { "fps": 9, "frames": [
              ["X...X.X...X", "XX..XXX..XX", "XXXXeXeXXXX", ".XX.XXX.XX.", "....X.X...."],
              ["....X.X....", "...XeXeX...", ".XXXXXXXXX.", "XX..XXX..XX", "X.........X"]] },
              "perch": { "frames": [["...X.X...", "..XeXeX..", ".XXXXXXX.", ".XX.X.XX.", "...X.X..."]] },
              "hang":  { "frames": [["...X.X...", ".XX.X.XX.", ".XXXXXXX.", "..XeXeX..", "...X.X..."]] } } },
"spider": { "pixel": 3, "colors": { "X": "#0d0b12", "r": "#e04646" },
            "anims": { "hang":  { "fps": 2, "frames": [
              [".X.XXX.X.", "X.XrXrX.X", "XX.XXX.XX", "........."],
              ["...XXX...", ".XXrXrXX.", "X..XXX..X", "X.......X"]] },
              "climb": { "fps": 8, "frames": "<same two frames>" } } },
"pail":   { "pixel": 5, "colors": { "g": "#8a8f99", "p": "#f26ca7", "b": "#5bc0eb", "y": "#f5c542",
                                    "O": "#f59a23", "e": "#1a1414", "s": "#c76a12" },
            "anims": { "idle": { "frames": [[".ggg.", "gpbyg", "OOOOO", "OeOeO", "OeOeO", "sssss"]] } } }
```

(In JSON, `climb` repeats the two `hang` frames. The bat's 2×2 mockup eyes become one 3-point pixel. Held at the hand, the pail's top-left is `(ox + 15·S, oy + 4·S)`. As an actor, `at: "hand", dx: 2, dy: 30` puts it exactly where the held pail is.)

Skits:
- `fly-by` (bats, w6, 5 s): one bat crosses right to left at about 70 pt/s, with a bob of amp 5 and hz 0.8. y is between 10 and 60. No lines.
- `hat-perch`: the spec's example, verbatim.
- `pail-heist` (bats, needs pail, w2, about 7 s):
  - A bat swoops in to `hand`, and the pail goes `gone`.
  - A `pail` actor follows the bat off to the right.
  - Buddy: `startle`, then "Hey! My candy!", then `grumpy`.
  - `next`: `{ skit: "pail-return", after: [40, 60] }`.
- `pail-return` (bats, w0, about 6 s):
  - A bat carries the `pail` actor in from the left and drops it at `hand`.
  - Then `pail: back`, Buddy `joy`, then "…One's missing."

- [ ] **Step 1: Write the five files.**
- [ ] **Step 2: Run the checker.** `tools/check-skits` → `5 skits OK` (the sprite library counts as one file).
- [ ] **Step 3: Run the Lua specs.** `tests/lua-tests` → the "shipped skits" checks now run and pass, including "no skit covers the face".
- [ ] **Step 4: Commit.** `Skits: sprite library and the reference skits`

---

### Task 4: The theme's rules (`halloween.lua`, without drawing)

**Files:**
- Create: `halloween.lua`
- Test: `tests/halloween_spec.lua`

**Interfaces:**
- Consumes: `skits.lua` (Task 1) via `dofile(dir .. "/skits.lua")`. Skins: `current() -> { id, name, group }`, `wear(id|nil)`, `topRows()`.
- Produces:
  - `H.active(d, cfg, saved) -> bool`. d is an `os.date("*t")` table and saved is the settings value `{ year, on }`.
  - `H.configure(opts) -> Theme`. opts:
    - `cfg`: config.lua's table
    - `skins`
    - `palette`: buddy's `C`
    - `dirs`: the skit folders
    - `S` and `ground`
    - `settings = { get(k), set(k, v) }`
    - `now()`: seconds
    - `date(fmt)`: like `os.date`
    - `random()`: 0..1
    - `log(msg)`
    - `hooks = { say(text), act(name|nil, secs), look(x, y, secs), burst(e, n, ox, oy, cx) }`. The hook coordinates are canvas points.
  - Theme:
    - `on() -> bool`
    - `busy() -> bool`
    - `tick(t, state)`, with state `{ away, idle, mood, event, action, dragging }`
    - `interrupt()`
    - `skit(id) -> bool`
    - `set(on|nil)`: the session override
    - `line(kind) -> string|nil`
    - `persona() -> string|nil`
    - `menu() -> item|nil`
    - `offset() -> int`
    - `status() -> { on, playing, pail, spider, offset, chain, nextIn }`
    - `actions`: the table `buddy.lua` merges into `ACTIONS`
  - Drawing (`behind`, `pail`, `front`) is Task 5. Here they're stubs. `behind(add, ox, oy, cx, at)` only advances the skit clock and fires cues. `pail(add, ox, oy)` records that the pail showed this frame and returns `not gone`. `front` does nothing.
  - A `run` tween starts at the cue's scheduled time (`start + cue.t`), not the time the frame fired it, so a slow frame doesn't shift it.

Values the spec pins (put them in the code as named locals):
- Dates: `d.month == 10 and d.day >= 24`.
- Order: session `set()` first, then `cfg.halloween` (a bool), then the in-season saved toggle `{ year == d.year, on }`, then the dates.
- Keys: `claudeBuddy.halloween` = `{ year, on }` and `claudeBuddy.halloweenDressed` = `{ year, declined = true }`.
- Gaps by `cfg.chatter` (default `"chatty"`, the same as buddy.lua): chatty 75–150 s, normal 180–300, quiet 600–900, silent none. Halved on Oct 31.
- Calm moods: `idle browsing generic reading mail watching chat chatting curious music`.
- Start rule: `away == "active"`, `idle < 60`, a calm mood, `not event`, `not action`, `not dragging`, nothing playing, no chain waiting, plus `needs` (pail showing, evening = hour ≥ 17).
- Recent list: 8.
- Chain: `after` is uniform in `[lo, hi]`. The deadline is the first skit's end + 180 s.
- Persona:
  - Oct 24–30: "It's Halloween week and you love it. Now and then, slip in a spooky pun or a nod to a classic horror movie."
  - Oct 31: "Today is Halloween, your favourite day of the year. Now and then, slip in a spooky pun or a nod to a classic horror movie."
- Line pools `idle sleepy morning click joke`, returned when `random() < 0.5`. About 10 lines each, in Buddy's voice: ≤ 40 characters for the pools, ≤ 80 for jokes, with no names.
- `actions`:
  - `duck = { eyes = "closed", arms = "up", body = "duck" }`
  - `flee = { eyes = "wide", mouth = "o", arms = "up", body = "sway" }`
  - `eat = { eyes = "happy", mouth = "talk" }`
  - `lookUp = { eyes = "up" }`
  - `trot = { body = "sway" }`
  - `["prop:" .. p] = { prop = p, arms = "hold" }` for each of the 8 props
- Menu:
  - `{ title = "Halloween", menu = { { title = "Halloween theme", checked = on, fn = toggle }, { title = "Spooky surprise", fn }, { title = "-" }, { title = "Skits", menu = { { title = "Bats", menu = … }, { title = "Spider", … }, { title = "Visitors", … }, { title = "Movie night", … } } } } }`
  - Skits are sorted by name within each group.
  - It returns nil out of season while the theme is off.
- The error guard wraps `tick behind pail front offset` in `pcall`. On the first error it logs `[buddy halloween] switched off after an error: <err>`, sets `broken`, calls `wear(nil)` and clears all state. After that, `on()` is false for the session.
- The library loads lazily, on the first transition to on. Files are read with `io.open` and decoded with `pcall(hs.json.decode)`. A bad file logs `[buddy skits] skipped <path>: <why>`.

- [ ] **Step 1: Write the failing spec `tests/halloween_spec.lua`.**

It uses a fake clock `now`, a fake `date(fmt)` built from a settable `{ year, month, day, hour, min }` (it handles `"*t"` only), a fake Skins (`cur = { id = "classic", group = "classic" }`, `wear` records calls and swaps `cur` to `witch`/`vampire`, and a `pick(id)` helper that clears worn and sets `cur`), in-memory settings, `random` from a fixed list, a `log` that collects messages, and hooks that record calls. Its skit dir is a temp dir with `sprites.json` copied from `skits/` plus small fixture skits written with `t.writeJson`:
- `a`: w2, 4 s, with a `say` at 1, a `run: -60` for 1 at 0.5, and a `run: 0` for 1 at 2.
- `heist`: needs pail, `pail: gone` at 1, `next: { skit = "back", after = 30 }`.
- `back`: w0, `pail: back` at 1.
- `b` and `c`: plain, w2, 2 s.

Tests, by name:
- `date rule`: `H.active` is false on Oct 23 23:59, true on Oct 24 00:00, true on Oct 31 23:59, false on Nov 1 00:00.
- `config wins`: `{ halloween = false }` is off on Oct 26, and `{ halloween = true }` is on in July.
- `menu toggle counts for its year in season`: saved `{ year = 2026, on = false }` turns it off on Oct 26 2026 but not on Oct 26 2027.
- `menu on in October does not carry into November`: saved `{ year = 2026, on = true }` gives `H.active` false on Nov 1 2026.
- `dresses as the witch`: configure on Oct 25 with a Classic skin → `wear("witch")` once.
- `keeps a Halloween skin`: a current `{ id = "vampire", group = "halloween" }` → no `wear`.
- `a menu pick sticks across a reload`: after dressing, `pick("classic")`, then `tick` → the settings hold `halloweenDressed = { year = 2026, declined = true }`. Configure again with the same settings → no `wear`.
- `undresses at the end`: move the date to Nov 1 and `tick` → `wear(nil)`, `on()` false.
- `off costs nothing`: with config off, a `dirs` folder holding a broken file → after configure and 5 ticks, no `[buddy skits]` log lines and `menu()` is nil out of season.
- `persona`: Oct 25 → the week sentence; Oct 31 → the "Today is Halloween" sentence; Nov 1 → nil.
- `brain hook`: `dofile(dir .. "/brain.lua").configure({}, "Sam", false)`, then `B.addPersona(function() return "Boo." end)` → `B.persona()` ends with `" Boo."`, and a hook returning nil leaves it unchanged. (The `brain.lua` change ships in this task, Step 3b.)
- `schedules by chatter`: with chatter normal, after the first tick `status().nextIn` is in 180–300; on Oct 31 it's in 90–150; silent gives nil.
- `start rules`: at the due time, each failing condition (bored, idle 61, mood `coding`, event, action, dragging) blocks the start. All passing → `busy()`.
- `cues fire through behind`: `skit("a")` → driving `behind(add, 65, 98, 100, 0)` at now 0, 1.2, 1.3 → `say` hook called once.
- `run offset returns home`: `skit("a")`, driving `behind` at each time, then `offset()` is −30 at 1.0 (inout midpoint), −60 at 1.5, and 0 at 3.1.
- `loader skips bad files`: with the theme on and a skit dir holding an unreadable JSON file and a skit naming an unknown sprite, there are two `[buddy skits] skipped` log lines and `skit("a")` still plays.
- `tick ends a skit whose frames stopped`: `skit("a")`, then `tick` at now + 10 with no `behind` calls → `busy()` false, `offset()` 0.
- `interrupt restores pail, spider and offset`: during `heist` after `pail: gone`, `interrupt()` → `status().pail` true, `status().chain` nil.
- `chains play their follow-up`: let `heist` end → `status().chain == "back"` and the pail is gone; tick past `after` with the start rules met → `back` plays and then the pail is back.
- `chain deadline brings the pail back`: let `heist` end, then keep `away = "asleep"` until 181 s after it ends → the chain is dropped and the pail is back.
- `events interrupt`: `tick` with `event = true` during a skit → not busy. The same with `away = "asleep"`.
- `no repeats`: with `a`, `b` and `c` eligible (no pail), 30 scheduled starts never play the same id twice in a row.
- `lines`: `line("idle")` is a string when `random()` < 0.5 and nil otherwise. All pool lines are ≤ 40 characters and jokes ≤ 80. `line("idle")` is nil when off.
- `menu`: in season and on → a "Halloween" item with the 4 group submenus. The toggle `fn` saves `{ year, on = false }` and turns it off. With config forcing it, the toggle is disabled.
- `an error while drawing turns the theme off`: a hooks.say that throws, with a skit whose `say` fires → `behind` returns normally, `on()` is false, there's one `switched off` log line, and `wear(nil)` was called.

- [ ] **Step 2: Run it and see it fail.** `tests/lua-tests` → the `halloween_spec.lua` load error.
- [ ] **Step 3: Implement `halloween.lua` (the rules part).** The cue handlers are:
  - `action` → `hooks.act(name, for)`
  - `say` → `hooks.say(pick)`
  - `look` → store `{ target, until }` and re-aim it each `behind` with `hooks.look(x, y, 0.3)`
  - `run` → an offset tween (inout, from the current offset) plus `hooks.act("trot", for)`
  - `prop` → `hooks.act("prop:" .. name, for)`
  - `pail` / `spider` → flags
  - `emit` → `hooks.burst({ glyphs, color = resolved, size = 13, from = (from == "hand" and "mug" or from), vy = -26, spread = 50, life = 1.4 }, count, ox, oy, cx)`

  A finish (natural or interrupted) is idempotent:
  - Actors gone, offset 0, the spider home, the look cleared.
  - The pail back, unless the skit ended naturally with a `next` that rolled `random() < chance`; then the chain is queued.
  - An interrupt also calls `hooks.act(nil, 0)` if a skit action may still be showing.
- [ ] **Step 3b: `brain.lua`.** Above `persona()`, add:
  ```lua
  local extras = {} -- sentences a theme adds (halloween.lua); each returns one or nil
  ```
  After `B.costume`, add `function B.addPersona(fn) extras[#extras + 1] = fn end`. Inside `persona()`, add one `.. themed()` at the end of the chain, where `themed()` joins the non-nil sentences with a leading space.
- [ ] **Step 4: Run it and see it pass.** `tests/lua-tests` → 0 failed, and `persona_spec.lua` still passes.
- [ ] **Step 5: Second-opinion review.** A reviewer that hasn't seen this plan's code is asked to review `halloween.lua` and `skits.lua` against the design doc's "Decided" and "Anti-goals" sections; list bugs only. Fix what's real.
- [ ] **Step 6: Commit.** `Halloween theme: dates, dress-up, scheduling, lines, menu, persona`

---

### Task 5: The theme's drawing (web, spider, pail, actors)

**Files:**
- Modify: `halloween.lua` (`behind`, `pail`, `front`, anchors)
- Test: `tests/halloween_spec.lua` (add tests)

**Interfaces:**
- Consumes: `K.sample` (Task 1). `add(el, key)` appends a canvas element plus a signature string.
- Produces:
  - `behind(add, ox, oy, cx, at)` advances the skit and fires cues, then draws the web, the thread, the resting spider and the `behind` actors.
  - `pail(add, ox, oy) -> bool` draws the held pail unless it's gone.
  - `front(add, ox, oy, cx, at)` draws the `front` actors.

  All three do nothing when off. Anchors are as in the spec, with `top` from `skins.topRows()`.

Values the spec pins:
- Web: centre `(2, 2)`, `R = 62`, spokes at `0 22 45 68 90`°, rings at `k = 0.35 0.6 0.85`.
  - Each ring segment between neighbouring spokes is the quadratic curve with its control point at the mid-angle, radius `0.86·R·k`, converted to the cubic `c1 = p0 + 2/3(q − p0)`, `c2 = p1 + 2/3(q − p1)` for `hs.canvas` `segments`.
  - Stroke `#eaecf4` at alpha 0.85, width 1.2, with a shadow (`withShadow = true`, blur 1.5, black at 0.5, offset 0).
  - Build the elements once and reuse them, with one signature key `"web"`.
- Spider anchor `AX = AY = 2 + cos(45°)·62·0.85` (≈ 39.3).
  - It rests hanging with its top at `y = 96 + 4·sin(1.3·at)`.
  - Every 30 s it climbs, as in the mockup's `spiderY` with its 10 s cycle stretched to 30 s (hang 0–26, climb 26–27.6 to `AY + 6`, rest until 28.4, drop by 28.9, then a bounce).
  - It uses anim `hang`, or `climb` while climbing. It's centred on `AX`.
  - The thread is drawn from `(AX, AY)` to its top centre, `#eaecf4` at alpha 0.7, width 1. It's hidden while `spider: away`.
- Pail: the `pail` sprite, with its top-left at `(ox + 15·S, oy + 4·S)`.
- Sprite rects come from runs. Each is a `rectangle` `fill` element at `(item.x + rx·p, item.y + ry·p, n·p, p)`, mirrored when flipped, with one signature key per item (`item.key`). A thread is a 2-point `segments` stroke.

- [ ] **Step 1: Add the failing tests** with a recording `add`:
  - `web draws 8 elements` (5 spokes + 3 rings), and they're the same table objects from frame to frame.
  - `resting spider bobs` (top y within 92–100 over `at` 0..4) and `climbs` (at `at = 27.6` its top is ≤ `AY + 7`).
  - `pail draws at the hand`: one rect at x 140 is orange `#f59a23`. With `pail: gone`, `pail()` returns false.
  - `actors split by layer`.
  - `top anchor uses the hat`: with `topRows` = 8, a key `at: "top"` puts the bottom at `oy − 40`.
  - `nothing drawn when off`: `add` is never called.
- [ ] **Step 2: Run them and see them fail.** `tests/lua-tests`.
- [ ] **Step 3: Implement the drawing in `halloween.lua`.**
- [ ] **Step 4: Run them and see them pass.** `tests/lua-tests` → 0 failed.
- [ ] **Step 5: Commit.** `Halloween theme: web, spider, pail and skit actors`

---

### Task 6: Call sites in `buddy.lua`, and the hidden test Buddy

**Files:**
- Modify: `buddy.lua` (each edit is below, located by the code it sits next to)
- Create: `tests/buddy_sandbox.lua`, `tests/halloween_buddy_spec.lua`, `tools/skit-snapshots`

**Interfaces:**
- Consumes: the Theme API (Tasks 4–5).
- Produces:
  - `ClaudeBuddy.skit(id) -> bool`, `ClaudeBuddy.halloween(on)`, `ClaudeBuddy.theme`.
  - `tests/buddy_sandbox.lua` returns `function(dir, cfg, opts) -> S`. S has:
    - `M`: the module, started
    - `step(n, dt)`: advances the fake clock by `dt` (default 0.25) per frame and calls `frame`
    - `poll()`
    - `canvas`
    - `said`: what reached `Chat.said`
    - `settings`: the in-memory store, pre-filled from `opts.settings`
    - `mouse(msg)`, `menu`, `errors`, `done()`
  - `tools/skit-snapshots [ids…] [--out dir]` writes `<out>/<id>.png` contact sheets.

`buddy.lua` edits:
1. After `dressBrain()` (the Skins block), add a forward declaration with a one-line comment: `local Theme -- the Halloween theme (halloween.lua), set up below once what it calls exists`.
2. After `spawn()` and before `frame()`:
   ```lua
   -- The Halloween theme: on by itself Oct 24–31 (config.lua `halloween` forces it). A theme
   -- that fails to load or breaks later leaves Buddy as it was.
   do -- a block, so its locals don't count toward the chunk's 200 (it's at 190)
     local ok, why = pcall(function()
       Theme = dofile(DIR .. "/halloween.lua").configure({ cfg = CFG, skins = Skins, palette = C, S = S, ground = GROUND,
         dirs = { DIR .. "/skits", HOME .. "/Library/Application Support/claude-usage-widget/skits" },
         settings = hs.settings, now = now, log = print, hooks = { … } })
     end)
     if not ok then
       print("[buddy] Halloween theme didn't load: " .. tostring(why))
       Theme = setmetatable({ actions = {}, offset = function() return 0 end }, { __index = function() return function() end end })
     end
   end
   for k, v in pairs(Theme.actions) do ACTIONS[k] = ACTIONS[k] or v end
   if Brain then Brain.addPersona(Theme.persona) end
   ```
   The hooks:
   - `say = function(s) say(s, true, true) end`
   - `act = doAction`
   - `look = function(x, y, secs) local tl = M.canvas:topLeft(); lookAt, lookUntil = { x = tl.x + x, y = tl.y + y }, now() + secs end`
   - `burst = function(e, n, ox, oy, cx) for _ = 1, n do spawn(e, ox, oy, cx) end end`
3. In `drawEyes`, add `up = true` to the `open` set. As the first line, add `if kind == "up" then dy = -1 end`.
4. In `bodyOffset`, add `if kind == "duck" then return 0, 4 end`.
5. In `frame()`:
   - `ox` gets `+ Theme.offset()`.
   - After the shadow block, add `local function add(el, key) els[#els + 1] = el; sig[#sig + 1] = key end` and `Theme.behind(add, ox, oy, cx, at)`.
   - In the prop branch, change `layer("hand")` to `if not Theme.pail(add, ox, oy) then layer("hand") end`.
   - Before `-- speech bubble`, add `Theme.front(add, ox, oy, cx, at)`.
6. In `lineFor`, track the pool kind (`"idle"`, `"sleepy"` or `"morning"`) next to `spec`, then `own = (spec == MOODS.idle and skinLine("idle")) or Theme.line(kind)`.
7. Click without a brain (`startDrag`): `skinLine("click") or Theme.line("click") or pick(CLICK_LINES)`. In `tellJoke`, the last line becomes `say(Theme.line("joke") or pick(JOKES), "user")`.
8. Add `Theme.interrupt()` in these places:
   - the first line of `onMouseDown`
   - the top of `react` (after the asleep return)
   - the top of `sessionDone`
   - inside `grokMood`
   - next to the 95% usage warning `say`
9. In `poll()`, before the ambient block:
   ```lua
   Theme.tick(t, { away = away, idle = idle, mood = mood, event = t < eventUntil, action = action, dragging = M.dragTimer ~= nil })
   ```
   Add `and not Theme.busy()` to the tricks condition.
10. In `showMenu()`, after the `Skin` item, add `local spooky = Theme.menu(); if spooky then items[#items + 1] = spooky end`.
11. Exports next to `M.skins`:
    - `M.theme = Theme`
    - `M.skit = function(id) return Theme.skit(id) end`
    - `M.halloween = function(on) Theme.set(on) end`

`tests/buddy_sandbox.lua` starts from the `sandbox()` in `tests/buddy_frame_spec.lua`, with these changes:
- `dofile` loads `skins.lua`, `halloween.lua` and `skits.lua` for real (through `loadfile(p, "t", env)`).
- `settings.get` and `settings.set` use an in-memory table for every key. Nothing is read from or written to the real `hs.settings`.
- `cfg` is passed through.
- `buddy_frame_spec.lua` itself is left alone. Its sandbox doesn't allow `halloween.lua`, so it gets the stand-in theme, which proves the fallback path.

`tests/halloween_buddy_spec.lua` (sandbox with `{ halloween = true }`):
- `wears the witch`: `M.skins.current().id == "witch"` after start.
- `every skit plays through frame()`: for every id in `skits/`, `M.skit(id)`, then step its length + 1 s at dt 0.25 → `#S.errors == 0`, then `not M.theme.busy()` and `M.theme.offset() == 0`.
- `skit lines stay out of the chat`: during `hat-perch`, a canvas text element shows a line, and `#S.said` doesn't change.
- `a click ends a skit`: `M.skit("pail-heist")`, then step 1.5 s, then `S.mouse("mouseDown")` → not busy, `status().pail` true.
- `the menu has Halloween`: a right-click gives a "Halloween" item right after "Skin", and its Skits submenus list every shipped skit once.
- `picking a skin declines the witch`: picking Classic from the Skin menu, then `S.poll()` → `S.settings["claudeBuddy.halloweenDressed"].declined`. A new sandbox with those settings → current is `classic`.
- `halloween(false) clears the world`: after `M.halloween(false)` and one step, no element has the web's stroke colour.

`tools/skit-snapshots` (sh, like `tools/skins-gallery`) runs `hs -c` against the sandbox:
- For each id, it plays the skit and steps at dt 1/12. Every 0.5 s it captures `S.canvas:imageFromCanvas()`.
- It lays the frames out 6 per row on a sheet canvas over a dark `#1d2433` background, then `saveToFile` writes `<out>/<id>.png`.
- The default out is `$TMPDIR/buddy-skit-snapshots`. It prints the paths.

- [ ] **Step 1: Write `tests/buddy_sandbox.lua` and the failing `tests/halloween_buddy_spec.lua`.**
- [ ] **Step 2: Run them and see them fail.** `tests/lua-tests` → it fails (no `M.skit`).
- [ ] **Step 3: Make the 11 `buddy.lua` edits.**
- [ ] **Step 4: Run them and see them pass.** `tests/lua-tests` → 0 failed, including `buddy_frame_spec.lua` and `skins_spec.lua` unchanged.
- [ ] **Step 5: Snapshots.** Run `tools/skit-snapshots fly-by hat-perch pail-heist pail-return` and Read each PNG. Check that the web, spider, pail and witch hat look like the mockup, the bat lands on the hat tip, and the pail leaves and comes back.
- [ ] **Step 6: Commit.** `Buddy: Halloween theme call sites, sandbox Buddy and skit snapshots`

---

### Task 7: Gallery (`tools/skits.html`, `tools/skits-gallery`)

**Files:**
- Create: `tools/skits-gallery` (copy `tools/skins-gallery`: port **8743**, a scratch dir `buddy-skits-gallery` linking `skits/`, `skins/` and `tools/skits.html`, and a `stop` argument), `tools/skits.html`

**Interfaces:**
- Consumes: the file formats only. It's a JS mirror of `K.sample`/`K.cues`/`K.ease` and the anchors, per the design doc's Gallery section.
- Produces: `tools/skits-gallery`, which prints its URL.

What the page must do (the spec's Gallery section, plus):
- List `../skits/` from the `http.server` directory page and fetch `sprites.json` plus every other `*.json`. Re-poll every 3 s, and badge new or changed skits NEW.
- Draw Buddy in the Witch skin from `../skins/witch.json` (its `top` rects and palette), the way `tools/skins.html` draws a skin. Add the web, the resting spider and the pail with the Task 5 values, so the stage matches the Lua render.
- Give each card a real-size 200×170 stage that loops with a 2 s gap, a dark/light wallpaper toggle and a 2× zoom. Show the name, group, weight, eveningWeight, needs, length, chain and every line. Play the cues: bubble, look (eyes shift), run offset, the actions approximated (hop, jitter, sway, duck, eyes for wide/happy/closed/up), pail gone/back, spider away/home, and emit bursts.
- Run the same checks in JS as the rules `K.compile` enforces. An invalid file shows a red card with the reason.
- A "Play all" button. Cards are grouped Bats, Spider, Visitors, Movie night.

- [ ] **Step 1: Build it.** A builder works from this task and the design doc.
- [ ] **Step 2: Verify it.** Run `tools/skits-gallery`, open it in Chrome, and screenshot the four reference cards. Compare them with the Task 6 snapshots (the same positions within a few points), and check that a deliberately broken temp file shows red. Then delete the temp file.
- [ ] **Step 3: Commit.** `Skits: browser gallery`

---

### Tasks 8A–8E: Skit batches (parallel)

**Files:** each batch creates only its own `skits/<id>.json` files. New sprites go in each skit's own `sprites`, never in `sprites.json`.

**Interfaces:**
- Consumes: the format, `skits/sprites.json` (`bat spider pail candy puff`), and the four reference skits as worked examples.
- Produces: the skit files the menu and scheduler pick up by themselves.

Batches (ids and beats from the spec's skit list, where each one's story is given):
- **8A Bats (7):**
  - `bat-chase`
  - `bat-swarm`: w1
  - `bat-nap`: hangs from the brim using `bat` `hang`
  - `web-crash`: uses `spider: away` and its own spider actor with `thread: "web"`
  - `bat-gift`: needs pail
  - `hat-bonk`
  - `bat-vampire`: puff, a tiny vampire, puff
- **8B Spider (8):** `spider-eek`, `candy-thief` (needs pail), `spider-yoyo`, `spider-swing`, `spider-wave`, `web-heart`, `boo-back`, `spider-shower`. Every one uses `spider: away` and back to `home`, and its spider actor has `thread: "web"`.
- **8C Visitors 1 (7):** `pail-ghost` (needs pail), `black-cat`, `broom-witch`, `candy-rain` (needs pail), `candy-snack` (needs pail; `eat`), `monster-mash` (`dance`, bats bob), `skeleton-hand`.
- **8D Visitors 2 (6):**
  - `pumpkin-roll`
  - `full-moon`
  - `zombie-chase`: `run` off one side, then back chasing. `next: { skit: "zombie-dance", after: 8, chance: 0.5 }`
  - `zombie-dance`: w0, name "Zombie dance"
  - `trick-or-treat`: w2, `eveningWeight` 6
  - `greedy-kid`: w1, needs pail, `pail: gone`, `next: { skit: "pail-return", after: [40, 60] }`
- **8E Movie night (9):**
  - `red-balloon`
  - `scary-call`: `prop: phone`
  - `tv-static`
  - `run-lights`: letters at most 3 Hz
  - `say-it-thrice`: name "Say it three times"
  - `its-alive`
  - `hockey-mask`
  - `twins`
  - `ghost-call`: `prop: phone`

Each batch goes to its own builder, all five at once. Each brief contains:
- the design doc's skit format and this batch's lines from the skit list
- the Global Constraints
- the four reference skits' paths
- "write only these files; never edit sprites.json, any .lua or any other skit; don't commit"
- the bars: about 5–15 s per skit, readable at real size, Buddy's face never covered for more than a moment, Buddy home and the pail back by the end (or `next`), lines ≤ 40 characters in Buddy's cheeky voice, homages without names in ids/names/sprites
- "run `tools/check-skits <your files>` until clean"

- [ ] **Step 1: Dispatch all five batches** in the background.
- [ ] **Step 2: As each one lands, check it.** Run `tools/check-skits` (all files), then `tests/lua-tests` (the shipped-skit and face checks, plus every skit through `frame()`), then `tools/skit-snapshots <batch ids>`. Read the PNGs and fix or send back anything off-model.
- [ ] **Step 3: Second-opinion review per batch**, asking for: lines over 40 characters or off-voice, names that slipped into ids/names/sprites, Buddy left off-centre, the pail left gone, a face covered, a blink over 3 Hz. Fix what's real.
- [ ] **Step 4: Commit each batch** as it passes: `Skits: <group> batch`.

---

### Task 9: README and config example

**Files:**
- Modify: `README.md` (a new **Halloween** paragraph after the **Skins** paragraph, plus the right-click row mentions "Halloween skits (Oct 24–31)"), `config.example.lua` (a `halloween` option after `chatter`)

- [ ] **Step 1: Write the copy.** A plain-English paragraph:
  - what happens Oct 24–31: witch hat, web, spider, pail, bats and little skits every few minutes
  - that chatter sets how often
  - that clicks and real events end a skit
  - right-click → Halloween for the toggle, Spooky surprise and every skit
  - `halloween = true` / `false` in config.lua to force it
  - `tools/skits-gallery` to watch every skit
  - how to add one: copy a file in `skits/` (or your own in `~/Library/Application Support/claude-usage-widget/skits/`), then `tools/check-skits`, with the format in the design doc

  It names no characters or titles. In `config.example.lua`, add:
  ```lua
  -- The Halloween theme turns itself on Oct 24–31. true keeps it on all year, false keeps it off.
  -- halloween = true,
  ```
- [ ] **Step 2: Verify.** `rg -n -i "beetlejuice|pennywise|jason|freddy|chucky|ghostbusters|scooby" README.md config.example.lua` → no hits.
- [ ] **Step 3: Commit.** `README: Halloween theme`

---

### Task 10: Final check and handoff

- [ ] **Step 1: Run everything.**
  - `tests/lua-tests` → `N passed, 0 failed`
  - `/usr/bin/python3 -m unittest discover -s tests -p "test_*.py"` → OK
  - `tools/check-skits` → `42 skits OK` (41 skits + sprites.json)
  - `tools/check-skins` → still OK
- [ ] **Step 2: Snapshots of all 41.** `tools/skit-snapshots`. Read every sheet.
- [ ] **Step 3: Owner review.** Run `tools/skits-gallery` and send the owner the URL. They flag skits in chat. Fix what they flag, and drop any flagged skit that isn't fixed by release (delete its file, and any chain pointing at it).
- [ ] **Step 4: Privacy check.**
  - `git diff main --stat` shows only this plan's files plus the skins branch's.
  - The added lines hold no personal names, business details or local paths.
- [ ] **Step 5: Hand off** to whoever merges and releases, with:
  - the branch `halloween-theme` and its head commit
  - the test summaries from Step 1
  - the checker (`tools/check-skits`, `tests/test_skits.py`)
  - the merge notes: rebased on main (v1.6.0, 5b77576 or later); `brain.lua` has `B.addPersona` next to `B.costume`; `buddy_frame_spec.lua` is untouched (it exercises the theme's fallback)
  - the live check still to do once the owner restores the normal copy (spec "Testing", last bullet)
