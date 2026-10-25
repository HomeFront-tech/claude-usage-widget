# Buddy skins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-selectable Buddy skins, stored as JSON data files, with per-skin themed reactions and lines; a live Chrome gallery; about 62 skins shipped tonight.

**Architecture:** Skins are JSON in `skins/` (plus the user's own folder). `skins.lua` loads and validates them and answers the drawing code's questions: colours, layer rects, particles, lines, hat height. `buddy.lua` gets small call sites in `frame()`, the particle code, the lines, and the menu. A stdlib-Python checker and a browser gallery read the same files, so parallel skin builders never touch Lua.

**Tech Stack:** Hammerspoon Lua (hs.canvas, hs.json, hs.settings), Python 3 stdlib, a plain HTML/JS canvas page served by `python3 -m http.server`.

**Spec:** `docs/superpowers/specs/2026-10-24-buddy-skins-design.md`

## Global Constraints

- Skin file = `skins/<id>.json`, `id` = filename. Required fields: `id`, `name`, `group`.
- Groups, in menu order: `classic` "Classic & colours", `outfits` "Outfits", `memes` "Memes", `heroes` "Heroes", `games` "Games & anime", `screen` "Movies & TV", `halloween` "Halloween".
- Rect `[col, row, w, h, color]`: ints. Cols −6..20, rows −9..12 (the rect's whole extent). Colour = palette name | base name (`body shade shine eye white grey dark red yellow gold brown blue pink`) | `#rrggbb` | `#rrggbbaa`.
- Layer = rect array | `{ "fps": n>0, "frames": [ [rects], … ] }` (at least 1 frame).
- Layers: `behind legs body face hand top`. `legs` may also be `false` (no legs).
- Reaction keys: actions/moods `shaken dizzy joy dance love blush ponder worried money call sleep morning claudeWork proud music curious snow wave hop grumpy startle stretch` and emitters `heart spark note z snow steam question coin bang stars`. Reaction fields: `glyphs color size rate vy vx spread life from grow` (`from` ∈ `head side sky mug`).
- Lines: `click` and `idle`, 2–6 each, ≤ 40 characters.
- Settings key `claudeBuddy.skin`. User folder `~/Library/Application Support/claude-usage-widget/skins/`; a user skin with the same id replaces the repo's.
- Pop-culture skins: Claude-themed homage names, plain stable ids, no copied logos (spec "Batch 2 skins").
- Drawing constants (from buddy.lua): S = 5, canvas 200×170, grid origin x = 65, BODY_TOP = 98, FPS 12.
- No personal data or business details anywhere in the repo.
- Never commit to `main`; never run `tools/release`. One combined release at the end of the night.

## Review Focus

1. A user's homemade skin has a JSON syntax error or a bad rect → it's skipped with a console line, and every other skin still loads. (Task 3: `skips broken file`)
2. The saved skin was deleted or renamed → Buddy shows Classic and the menu still works. (Task 3: `unknown saved id falls back to classic`)
3. The user folder doesn't exist (every fresh install) → no error. (Task 3: `missing user dir is fine`)
4. The theme calls `wear` with an id that doesn't exist → ignored, current skin unchanged. (Task 3: `wear unknown id is ignored`)
5. An animated layer has `fps` 0 or empty `frames` → the checker rejects it, and the loader treats it as empty instead of erroring mid-frame. (Task 1 and Task 3: `bad animated layer`)

---

### Task 1: Checker and the Classic skin

**Files:**
- Create: `tools/check-skins` (Python 3, executable, stdlib only)
- Create: `skins/classic.json` (`{"id":"classic","name":"Classic","group":"classic"}` plus 2+ click/idle lines and default-looking reactions are optional)
- Test: `tests/test_skins.py` (unittest, same style as `tests/test_claude_usage.py`; run `/usr/bin/python3 -m unittest tests.test_skins -v`)

**Interfaces:**
- Produces: `check_file(path) -> list[str]` (error strings, empty = clean); `check_all(paths) -> dict[str, list[str]]` (adds a duplicate-id check across files). CLI: `tools/check-skins [files…]`, defaulting to `skins/*.json`; prints `path: error` per problem and `N skins OK`; exit 0 clean, 1 otherwise. Import it in tests with `importlib.machinery.SourceFileLoader`.

- [ ] **Step 1: Write failing tests** in `tests/test_skins.py`, each writing a temp JSON and asserting on `check_file`: `test_classic_is_clean` (no errors), `test_id_must_match_filename`, `test_unknown_group`, `test_unknown_color_name`, `test_hex_colors_ok` (`#a1b2c3` and `#a1b2c3cc` pass), `test_rect_must_be_ints`, `test_rect_out_of_bounds` (`[-7,0,1,1,"eye"]` and `[18,0,4,1,"eye"]` fail, since 18+4−1 = 21 > 20), `test_bad_animated_layer` (`fps` 0 fails, `frames: []` fails), `test_legs_false_ok`, `test_unknown_reaction_key`, `test_unknown_reaction_field`, `test_line_too_long` (41 chars fails), `test_duplicate_ids` (two files, same id → `check_all` reports it), `test_repo_skins_are_clean` (every `skins/*.json` clean).
- [ ] **Step 2: Run them, expect failures** (`No such file … check-skins`).
- [ ] **Step 3: Implement `tools/check-skins`** to the Global Constraints.
- [ ] **Step 4: Run them, expect PASS.** Also run `tools/check-skins`, expect `1 skins OK`.
- [ ] **Step 5: Commit** `tools/check-skins skins/classic.json tests/test_skins.py`, message "Skins: file checker and the Classic skin".

### Task 2: Live gallery

**Files:**
- Create: `tools/skins.html` (self-contained page: inline CSS and JS)
- Create: `tools/skins-gallery` (sh: serve the repo root with `python3 -m http.server 8742 --bind 127.0.0.1` if the port is free, then `open -a "Google Chrome" http://127.0.0.1:8742/tools/skins.html`)

**Interfaces:**
- Consumes: the skin format (Global Constraints); the base palette `C`, `EMIT` defaults and draw order copied from `buddy.lua` (port the renderer in `.superpowers/brainstorm/70514-1792901697/content/skins-v2.html`, main checkout).
- Produces: a page that fetches `/skins/` (the directory listing), loads every `*.json` link, and re-polls every 3 s. New ids get a NEW badge and scroll into view. Cards are grouped by `group` in menu order and show the name, id, an animated canvas at 1× and 2× (breathe, blink, frames animate at their fps, hand layer shown), buttons `shake joy dizzy love dance sleep` that play the reaction particles (using the skin's override or the EMIT default, with emoji allowed), and the skin's lines. A file that fails to parse, or breaks a Global Constraint the page can check cheaply, shows as a red card with the reason.

- [ ] **Step 1: Build both files.**
- [ ] **Step 2: Verify headless:** start the server, then `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1300,900 --screenshot=<scratch>/g.png http://127.0.0.1:8742/tools/skins.html`. Read the PNG: the Classic card renders like today's Buddy.
- [ ] **Step 3: Verify live reload:** copy `classic.json` to `skins/zz-test.json` with id `zz-test`, wait 4 s, take another screenshot, and confirm a NEW card appeared. Delete the file.
- [ ] **Step 4: Commit** `tools/skins.html tools/skins-gallery`, message "Skins: live gallery".

### Task 3: `skins.lua`

**Files:**
- Create: `skins.lua`
- Test: `tests/skins_spec.lua` (runs in Hammerspoon: `timeout 20 hs -c "return dofile('$R/tests/run.lua')('$R')"`)

**Interfaces:**
- Consumes: hs.json, hs.fs, hs.settings.
- Produces: `dofile(DIR .. "/skins.lua").new(opts)`, where opts = `{ dirs = { repoDir, userDir }, key = "claudeBuddy.skin", base = C }` (later dirs override earlier ones by id). The returned object `K` has:
  - `K.current() -> skin` (the wear override, else the saved pick, else `classic`; a skin table always comes back, a built-in empty Classic if even classic.json is missing)
  - `K.pick(id) -> boolean` (saves; clears the wear override; false for an unknown id)
  - `K.wear(id|nil)` (unknown id ignored)
  - `K.list() -> { {id, name, group}, … }` (sorted by group menu order, then name; `classic` first)
  - `K.groups() -> { {group, label}, … }` (menu order)
  - `K.colors() -> table` (copy of `base` with the current skin's `colors` overrides as hs colour tables)
  - `K.layer(name, t) -> { {c, r, w, h, color}, … } | nil | false` (frame chosen by `math.floor(t * fps) % #frames`; colour resolved palette → base → hex; `false` only for `legs: false`)
  - `K.topRows() -> int` (how far the `top` layer reaches above row 0, counted from its rects across all frames; 0 if none)
  - `K.float() -> number`, `K.shadow() -> number` (defaults 0 and 36)
  - `K.particle(emit, emitName, actionName, moodName) -> table|nil` (base = `emit[emitName]`; override = `reactions[actionName] or reactions[moodName] or reactions[emitName]`; returns base fields merged with override fields, with `color` resolved to an hs colour table; with no base but an override, defaults `rate 2, size 13, from "head", vy -24, spread 50, life 1.2`)
  - `K.lines(kind) -> list|nil`
  - `K.name() -> string`
  - Each skipped file prints one `[buddy skins] skipped <path>: <reason>` line.

- [ ] **Step 1: Write failing spec** `tests/skins_spec.lua`, using `t.tmpdir()` and `t.writeJson` fixtures and a unique settings key per run (clear it at the end). Checks: loads two skins and `list()` puts classic first; `skips broken file` (a file containing `{nope` is skipped, the others load); `unknown saved id falls back to classic`; `missing user dir is fine`; `pick saves and survives a new instance`; `wear overrides and wear(nil) restores`; `pick clears wear`; `wear unknown id is ignored`; `user dir overrides repo id`; `colors override body only`; `layer resolves palette, base and hex colours`; `animated layer picks frame by time` (fps 2, t = 0.6 → frame 2); `bad animated layer` (fps 0 → `layer()` returns an empty list); `topRows of a witch hat is 8`; `particle prefers action, then mood, then emitter`; `particle for an action with no emitter uses the defaults`.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement `skins.lua`.** Validate defensively (types, ints, frames); never error at draw time.
- [ ] **Step 4: Run the full Lua suite, expect all PASS** (176 existing plus the new checks).
- [ ] **Step 5: Commit** `skins.lua tests/skins_spec.lua`, message "Skins: load, pick and wear skins".

### Task 4: Wire skins into Buddy

**Files:**
- Modify: `buddy.lua`: module setup near the other `dofile`s (~line 70); `currentSpec` also returns the mood name; `frame()` ~1050–1160; `lineFor` ~358; the brainless click line ~1247; `showMenu` ~765; the `M.skins` export near `M.say` ~1428; the header comment (mention skins and the menu).
- Modify: `brain.lua`: add `B.costume(name|nil)`; `persona()` appends `" You're dressed as " .. name .. " right now."` when a costume is set.

**Interfaces:**
- Consumes: Task 3's `K` API.
- Produces: `ClaudeBuddy.skins` (= `M.skins` = `K`) for the theme. `K.pick`/`K.wear` callers expect the next frame to show the change.

- [ ] **Step 1: Load skins** with `dirs = { DIR .. "/skins", HOME .. "/Library/Application Support/claude-usage-widget/skins" }`, `key = "claudeBuddy.skin"`, `base = C`. Set `M.skins`. When there's a brain, call `Brain.costume(...)` with the skin name (nil for classic) at start and whenever the worn skin changes (compare ids once per frame).
- [ ] **Step 2: Draw** in the spec's order. Per frame `local P = Skins.colors()` replaces `C.body/shade/shine/eye` for the body, legs, arms and eyes. `oy` gets `- Skins.float()`; the ground shadow uses `Skins.shadow()` in place of 36. The `hand` layer draws only when `spec.prop` is nil and `spec.arms` is `rest` or `hold`. Bubble: `byp = math.max(2, BODY_TOP - Skins.topRows() * S - bh - 22)`.
- [ ] **Step 3: Particles:** `local e = Skins.particle(EMIT, spec.emit, action, moodName)`. The emit-change reset keys on the merged emitter's identity (`spec.emit .. action`). Emoji fade: builder's call, per the spec.
- [ ] **Step 4: Lines:** in `lineFor`, for plain idle (not sleepy or morning), use a skin idle line one time in three when there is one. The same applies to the brainless click line.
- [ ] **Step 5: Menu:** add a "Skin" item before "Setup…", with one submenu per group from `K.groups()` (only groups that have skins), `checked` on the worn skin, and a "Surprise me" item at the top. Picking calls `K.pick(id)`, does `doAction("joy", 1.6)`, and says the new skin's first click line, or "Ta-da!" (forced "user").
- [ ] **Step 6: Verify:** the full Lua suite passes; `hs -c "return loadfile('$PWD/buddy.lua') and 'ok'"` prints ok; `tools/check-skins` is clean. A live visual check happens after the end-of-night merge, because the live copy is the fresh-install test.
- [ ] **Step 7: Commit** `buddy.lua brain.lua`, message "Buddy: wear skins, themed reactions and lines, Skin menu".

### Task 5: Batch 1 skins

**Files:** Create `skins/{witch,vampire,pumpkin,ghost,franken,winter,hardhat,midnight,mint}.json`.

**Interfaces:** Consumes the format. Port the art from the mockup page (Task 2 notes where it is). Winter: red toque with pompom, plus a white Santa beard framing the mouth (rows 6–11, mouth cells at cols 6–7 rows 7–8 left clear), scarf dropped. Hard hat: hat, plus a `hand` hammer (brown handle, grey head) animated with 2 frames at fps 3, tapping. Every skin gets `shaken`, `dizzy`, `joy` reactions and 3+ click and idle lines in its theme. Ghost: `float` 8, `shadow` 24, `legs` replaced by the hem.

- [ ] **Step 1: Write the 9 files.**
- [ ] **Step 2: Run `tools/check-skins`, expect `10 skins OK`.** Look at each in the gallery (headless screenshot), and fix anything off-grid.
- [ ] **Step 3: Commit** `skins/`, message "Skins: Halloween five, Winter, Hard hat, Midnight, Mint".

### Task 6: Batch 2 skins (5 parallel Sonnet agents, JSON only)

**Files:** Create `skins/<id>.json` per the spec's "Batch 2 skins" list, one agent per group: memes (8), outfits (10), heroes (10), games (14), screen (10).

**Interfaces:** Each agent gets: the spec path, this plan's Global Constraints, `skins/witch.json` and `skins/hardhat.json` as examples, the grid picture (body cols 0–13 rows 0–9, eyes at cols 3–4 and 9–10 rows 3–5, mouth cols 6–7 rows 7–8, legs cols 2, 4, 9, 11 rows 10–11, arms col −1 and col 14 rows 5–6), its list with homage names, and the self-check loop: write, run `tools/check-skins`, take a headless screenshot of the gallery, Read it, fix. Agents only create their own `skins/*.json` files. They don't edit other files and don't commit.

- [ ] **Step 1: Launch the 5 agents in one message** (model `sonnet`).
- [ ] **Step 2: As each one reports,** run `tools/check-skins`, review its cards in the gallery (the owner watches the same page live), fix or ask for fixes, and commit its group: "Skins: <group>".

### Task 7: Docs and branch review

**Files:** Modify `README.md` (Skins section: the menu, Surprise me, the gallery, making your own skin in the user folder, plus a right-click table row); `~/AGENTS.md` `claude-usage-widget` line (mention `skins/` and `tools/skins-gallery`; outside the repo, not committed).

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Whole-branch review** by one fresh Opus reviewer against the spec. Fix the findings.
- [ ] **Step 3: Commit** "Skins: README". Hand over for the end-of-night merge with `bubble-click` and `halloween-theme`.
