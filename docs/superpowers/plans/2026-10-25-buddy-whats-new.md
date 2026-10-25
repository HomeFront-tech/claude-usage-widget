# Buddy What's New Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A window that greets people after an update with a live Buddy, a slide tour of what's new, a Help-shape-Buddy page that emails feedback to the owner, and full patch notes.

**Architecture:** Content lives in `whatsnew/releases.json`, checked and version-stamped by `tools/whatsnew` (called from `tools/release`). `whatsnew.lua` picks the releases to show, inlines the page (`whatsnew.html` + `buddy_draw.js` + skin JSON + images) into an `hs.webview`, and handles the page's messages; feedback is POSTed to a Cloudflare Worker (`worker/feedback/`) that emails it, with a public GitHub-issue fallback while no URL is set.

**Tech Stack:** Hammerspoon Lua, plain HTML/JS in a WebKit webview, Python 3 (stdlib) for tools and tests, Cloudflare Worker (ES module JS) tested with `node --test`.

**Spec:** `docs/superpowers/specs/2026-10-25-buddy-whats-new-design.md`

## Global Constraints

- No email addresses, tokens, secrets or personal/business details in the repo, docs or commit messages; say "the owner".
- Lua specs only through `/usr/bin/lockf -k /tmp/buddy-hs.lock timeout 600 tests/lua-tests`; no other `hs -c`; specs never load `hs.webview`, `hs.http`, `hs.sharing` or `hs.pasteboard` (inject fakes).
- Python tests: `/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py'`. Worker tests: `node --test worker/feedback/test`.
- `buddy.lua` and `updater.lua` get small call sites only.
- Limits: title ≤ 40, summary ≤ 140, slide text ≤ 220, ≤ 8 slides/release, ≤ 12 notes/group, idea ≤ 2000, reply email ≤ 200, macOS ≤ 40, Worker body ≤ 16 KB, image ≤ 600 KB, 5 sends/day, queue ≤ 5 items, queue items dropped after 3 days, Worker 3 req/60 s per IP.
- Settings keys: `claudeWidget.whatsNewFrom`, `claudeWidget.feedbackDay` (`{ day = "YYYY-MM-DD", n = N }`), `claudeWidget.feedbackQueue`.
- Never deploy the Worker, send real email, push, run `tools/release`, or reload Hammerspoon.

## Review Focus

1. **A release file that's missing, empty or malformed JSON** → Buddy starts normally, no window, the old bubble line; `W.load` returns `{}` plus an error string. Test in Task 4.
2. **Someone who skipped releases (1.5.0 → 1.8.0)** → slides from 1.8.0 then 1.7.0, notes for both, hero from 1.8.0; 1.5.0 and anything newer than VERSION excluded. Test in Task 4.
3. **A skin named in a scene that isn't installed** (user deleted it, or a newer file) → that skin is left out of a `skins` grid, a `buddy` scene falls back to Classic, the Wear button hides. Test in Task 4 (`W.pageData`).
4. **Typed text with quotes, `</script>`, emoji or newlines** → shows literally in the issue body / email, never breaks the page init JSON. Tests in Tasks 3 and 4.
5. **Offline Send, then Hammerspoon reloads** → the item survives in the queue and goes out on the next flush; a 4xx is dropped, not retried forever. Test in Task 4.

---

### Task 1: Release content and `tools/whatsnew`

**Files:**
- Create: `whatsnew/releases.json`, `tools/whatsnew` (executable, `#!/usr/bin/env python3`, stdlib only)
- Test: `tests/test_whatsnew.py`

**Interfaces:**
- Produces: `check(data: dict, root: Path) -> list[str]` (error strings, empty = ok); `stamp(data: dict, version: str) -> tuple[dict, bool]` (new data, whether it changed; raises `ValueError` if version invalid or both `"next"` and `version` exist). CLI: `tools/whatsnew check [file]` (exit 1 and one error per line on failure), `tools/whatsnew stamp <version> [file]` (rewrites the file with `json.dumps(indent=2, ensure_ascii=False)` + newline only when changed; prints `stamped "next" as v<version>` or nothing). Default file: `<repo>/whatsnew/releases.json`.
- Scene kinds: `buddy {skin, wave, lines}`, `skins {skins[2..8]}`, `bubble {line}`, `phone {messages[{from: "you"|"buddy", text}]}`, `card {rows[{label, value, sub?}]}`, `image {file}`. Unknown kinds pass `check` (a newer file must not fail an older checker).

- [ ] **Step 1: Write failing tests** in `tests/test_whatsnew.py` (load `tools/whatsnew` like `test_skins.py` loads `check-skins`): `test_shipped_file_is_valid` (real file → `check == []`); `test_title_too_long` (41-char title → one error mentioning `title`); `test_unknown_skin` (`hero.skin = "nope"` → error naming `nope`); `test_two_next_entries`; `test_duplicate_versions`; `test_bad_version_string` (`"1.7"`); `test_too_many_slides` (9); `test_missing_image` (`image` scene, file absent); `test_unknown_scene_kind_ok`; `test_stamp_next` (`stamp(data,"1.7.0")` → entry version `"1.7.0"`, changed True); `test_stamp_without_next_is_noop` (changed False, data equal); `test_stamp_conflict_raises` (`"next"` + `"1.7.0"` present); `test_stamp_rejects_bad_version`; `test_cli_stamp_rewrites_file` (temp file, run via `subprocess` with `/usr/bin/python3 tools/whatsnew stamp 1.7.0 <tmp>` → file holds `"1.7.0"`, exit 0).
- [ ] **Step 2:** Run `/usr/bin/python3 -m unittest tests.test_whatsnew -v` → FAIL (module missing).
- [ ] **Step 3: Implement `tools/whatsnew`** and write `whatsnew/releases.json` with one `"next"` entry: title "The Halloween Update", hero vampire waving with lines "Happy Halloween!", "I got updated!", "Fangs for updating!", "Come see what's new!"; slides per the spec's "First content" 1–4 (skins grid ids: witch, vampire, pumpkin, ghost, franken, winter, hardhat, pirate; action "Wear the Witch now"/witch; bubble line "Fangs for stopping by."; phone: you "How's my usage?", buddy a short usage answer with example numbers, you "Nice, thanks Buddy", buddy a quip; card rows: `API value · This week` `$412`, `6.4× your plan`, `🍕 That's 71 large pepperoni pizzas` with sub "Example numbers"); notes New/Better/Fixed for v1.6.0 + this window. Plain words, no character names.
- [ ] **Step 4:** Run the tests → PASS.
- [ ] **Step 5: Commit** `What's New: release content and its checker`.

### Task 2: `tools/release` stamps the draft inside the release commit

**Files:**
- Modify: `tools/release` (after the dirty-tree and tag checks, before `echo "$version" > VERSION`)
- Test: `tests/test_release.py`

**Interfaces:**
- Consumes: Task 1 CLI (`tools/whatsnew check`, `tools/whatsnew stamp <version>`).

- [ ] **Step 1: Write failing tests** in `tests/test_release.py`. Fixture: temp dir with a bare repo `origin.git`, a clone holding copies of `tools/release`, `tools/whatsnew`, `VERSION` ("1.6.0"), `skins/` (copy) and a `whatsnew/releases.json`; `git config user.name/email` set locally; `PATH` starts with a dir holding a fake `gh` (`#!/bin/sh` that appends `$@` to a log file and exits 0). Tests: `test_release_stamps_next_in_release_commit` (run `tools/release 1.7.0 "notes"` → rc 0; `git show HEAD:whatsnew/releases.json` has `"1.7.0"` and no `"next"`; `git show HEAD:VERSION` = `1.7.0`; `git status --porcelain` empty; tag `v1.7.0` exists in origin; gh log has `release create v1.7.0`); `test_fix_only_release_without_next` (releases.json has only `"1.6.0"` → rc 0, file byte-identical before/after, output contains `no What's New entry for v1.6.1`, VERSION committed); `test_invalid_content_stops_before_writing` (title 41 chars → rc ≠ 0, VERSION still `1.6.0`, no new commit, no tag).
- [ ] **Step 2:** Run `/usr/bin/python3 -m unittest tests.test_release -v` → FAIL (no stamp, no note).
- [ ] **Step 3: Edit `tools/release`:** before writing VERSION, `tools/whatsnew check || exit 1`; after writing VERSION, `tools/whatsnew stamp "$version"`; `git add VERSION whatsnew/releases.json`; after the commit, if `grep -q "\"version\": \"$version\"" whatsnew/releases.json` fails, print `Note: no What's New entry for v$version; people get the plain bubble.`. Guard each whatsnew call with `[ -f whatsnew/releases.json ]` so an older checkout still releases. Update the header comment.
- [ ] **Step 4:** Run the tests → PASS.
- [ ] **Step 5: Commit** `tools/release: stamp the What's New draft in the release commit`.

### Task 3: Feedback Worker

**Files:**
- Create: `worker/feedback/src/index.js`, `worker/feedback/wrangler.jsonc`, `worker/feedback/package.json` (`"type": "module"`, no dependencies), `worker/feedback/README.md`
- Test: `worker/feedback/test/index.test.js`

**Interfaces:**
- Produces: `POST /feedback` with JSON `{rating, idea, reply_to, version, macos}` → `200 {"ok":true}`; `400/404/405/413/429/502 {"ok":false,"error":"…"}`. Exports for tests: `default { fetch(request, env) }`, `validate(body) -> {ok, value|error}`, `formatEmail(value, receivedISO) -> {subject, text}`.
- env: `EMAIL` (send_email binding), `LIMITER` (ratelimits binding), `FEEDBACK_TO`, `FEEDBACK_FROM` (secrets).

- [ ] **Step 1: Write failing tests** with `node:test` + `node:assert/strict`, fake env `{ EMAIL: { send: async m => { sent.push(m); return { messageId: "x" } } }, LIMITER: { limit: async () => ({ success: true }) }, FEEDBACK_TO: "to@example.com", FEEDBACK_FROM: "from@example.com" }`: `rating only → subject "Buddy feedback · 😍 5/5 · v1.7.0"`; `idea only → "Buddy feedback · idea · v1.7.0"`; `both → "Buddy feedback · 🙂 4/5 + idea · v1.7.0"`; body lines in order `Rating: 4/5 (Good)`, `Idea:`, idea lines, `Reply to: —`, `Buddy: v1.7.0`, `macOS: 15.1`, `Received: <iso>`; `reply_to given → message.replyTo equals it`; `neither rating nor idea → 400`; `rating 6 or 2.5 → 400`; `idea 2001 chars → 400`; `bad email → 400`; `version "1.7" → 400`; `body over 4096 bytes → 413`; `GET → 405`, `POST /other → 404`; `limiter {success:false} → 429` and nothing sent; `EMAIL.send throws → 502`; `control chars stripped, newlines in idea kept`; `from is {email: FEEDBACK_FROM, name: "Buddy feedback"}`, `to is FEEDBACK_TO`. Faces: 1 😖 Not great, 2 🙁 Meh, 3 😐 Okay, 4 🙂 Good, 5 😍 Love it.
- [ ] **Step 2:** Run `node --test worker/feedback/test` → FAIL.
- [ ] **Step 3: Implement** `index.js` (read body as text, length check before parse; limiter key `CF-Connecting-IP` or `"unknown"`); `wrangler.jsonc` with `name: "buddy-feedback"`, `main: "src/index.js"`, a current `compatibility_date`, `send_email: [{ name: "EMAIL" }]`, `ratelimits: [{ name: "LIMITER", namespace_id: "1001", simple: { limit: 3, period: 60 } }]`, no vars holding addresses; README: what it does, the deploy steps for the owner (enable Email Sending on a domain, `wrangler secret put FEEDBACK_TO` / `FEEDBACK_FROM`, `wrangler deploy`, put the URL in `whatsnew.lua`'s `FEEDBACK_URL`), the curl to test it, and that the binding shapes are unverified until that deploy.
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5: Commit** `Feedback Worker: ratings and ideas from the What's New window, by email`.

### Task 4: `whatsnew.lua` logic

**Files:**
- Create: `whatsnew.lua` (logic half)
- Test: `tests/whatsnew_spec.lua`

**Interfaces:**
- Produces (module table `W`):
  - `W.newer(a, b) -> bool` (numeric dotted compare, as `updater.lua`).
  - `W.load(dir) -> releases, err` — reads `dir/whatsnew/releases.json`, drops entries/slides that break the limits (with `print` lines), returns `{}` + message when missing or bad JSON.
  - `W.pick(releases, from, current) -> list` — numbered entries with `from < v <= current`, newest first.
  - `W.forMenu(releases, current, want) -> list` — `want` given: that entry (or `{}`); else newest numbered `<= current`; else the `"next"` entry; else `{}`.
  - `W.pageData(list, ctx) -> table` — ctx `{ dir, version, from, repoURL, mode = "email"|"github", canWear = bool, skinFile = function(id) -> path|nil }`; returns `{ releases, skins = {id = decoded JSON}, images = {file = dataURI}, wearable = {id = true}, mode, repoURL, version, from }`; drops missing skins from grids, swaps a missing hero/buddy skin for `"classic"`.
  - `W.initJSON(data) -> string` — `hs.json.encode` with `</` escaped as `<\/`.
  - `W.form(b) -> form|nil, err` — from a page message `{rating, idea, reply_to}`: rating integer 1–5 else nil; idea trimmed, ≤ 2000, empty → nil; reply_to kept only if it matches `^[^%s@]+@[^%s@]+%.[^%s@]+$` and ≤ 200; nil + "empty" when no rating and no idea.
  - `W.payload(form, version, macos) -> table` (the five fields, `hs.json.null`-free: absent fields omitted).
  - `W.issueURL(repoURL, form, version, macos) -> string` — `<repoURL>/issues/new?title=…&body=…`; title `Idea: ` + first 60 chars of the idea's first line; body: idea, `Rating: n/5` if any, `Reply to: …` if any, `Buddy v… · macOS …`. Nothing else.
  - `W.allow(store, today) -> bool` and `W.count(store, today)` — 5/day; `store` is `{ get = fn(key), set = fn(key, v) }`.
  - `W.enqueue(store, payload, now)`; `W.flush(store, post, now)` — `post(payload, done(status))`; status 200 → remove; 400–499 → remove; else keep; items older than 3 days removed; queue capped at 5 (oldest dropped).

- [ ] **Step 1: Write failing spec** `tests/whatsnew_spec.lua` (spec style of `skins_spec.lua`; `W = dofile(dir .. "/whatsnew.lua")`; memory store `{ get = function(k) return m[k] end, set = function(k, v) m[k] = v end }`): `pick` 1.5.0→1.8.0 with entries 1.5.0/1.7.0/1.8.0/1.9.0/next and current 1.8.0 → versions `1.8.0,1.7.0`; `pick` with nil releases → `{}`; `forMenu` current 1.6.0 with only next → next; with 1.7.0 & next and current 1.7.0 → 1.7.0; `forMenu(...,"next")` → next; `load` on a temp dir with bad JSON → `{}` and an error; `load` skips a slide whose text is 221 chars and keeps the others; `pageData` with a missing grid skin drops it, a missing hero skin becomes classic, `wearable` lacks missing ids, `canWear=false` → `wearable` empty; `initJSON` of `{ t = "</script>" }` contains `<\/script>`; `form` rating 6 → nil rating; `form` reply_to "nope" dropped; `form` blank → nil, "empty"; `issueURL` decoded body contains the idea and `Buddy v1.7.0 · macOS 15.1` and nothing from a config (assert no `HOME` path, no `config`); quotes/newlines/emoji survive `issueURL` round-trip (decode with a local `%XX` decoder); `allow` true 5 times after `count`, false on the 6th, true again next day; `flush` with post returning 200 empties the queue, 503 keeps it, 400 drops it; `enqueue` 6 items keeps newest 5; item 4 days old is dropped by `flush` without calling `post`.
- [ ] **Step 2:** Run `/usr/bin/lockf -k /tmp/buddy-hs.lock timeout 600 tests/lua-tests` → the new spec FAILS.
- [ ] **Step 3: Implement** the logic half of `whatsnew.lua` (module header comment in the style of `report.lua`/`skins.lua`; `local W = {}`; no `hs.webview`/`hs.http`/`hs.sharing` at load time).
- [ ] **Step 4:** Run the Lua tests → PASS (and everything else still passes).
- [ ] **Step 5: Commit** `What's New: pick releases, check feedback, queue and cap sends`.

### Task 5: The page (`buddy_draw.js`, `whatsnew.html`)

**Files:**
- Create: `buddy_draw.js`, `whatsnew.html`
- Test: `tests/test_whatsnew_page.py`

**Interfaces:**
- Consumes: Task 4 `W.pageData` shape (`window.INIT`), skin JSON format.
- Produces: `buddy_draw.js` defines `window.BuddyDraw = { W, H, prepare(skinJSON), makeBuddy(P, opts), canvas(el, scale) }`, `opts = { script(at) -> {eyes, arms, body, blush}, under(ctx, at), extra(px, at, s), over(ctx, at) }`, buddy `{ draw(ctx), say(text, secs), st }` — ported from `tools/skins.html`'s renderer (keep its "Mirrors buddy.lua" comment), plus the hooks and `st.box` (bubble rect). `whatsnew.html` has `/*__INIT__*/null` and `/*__BUDDY_DRAW__*/` placeholders; posts `{type: "wear", skin}`, `{type: "rate", rating}`, `{type: "send", rating, idea, reply_to}`, `{type: "copy"}`, `{type: "share"}`, `{type: "open", url}`, `{type: "close"}` to `webkit.messageHandlers.buddy`; exposes `window.sent({ok, text})`, `window.copied(text)`.

- [ ] **Step 1: Write failing test** `tests/test_whatsnew_page.py`: `test_placeholders_present` (both placeholders in `whatsnew.html`); `test_script_syntax` (if `node` is on PATH: concatenate `buddy_draw.js` + the page's inline script with a stub INIT and run `node --check`; else skip); `test_message_types` (page source posts exactly the seven types above); `test_no_external_urls` (no `http` URLs in `<script src>`/`<link>`).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement** the page from the approved mock (`.superpowers/brainstorm/89540-1792911854/content/whats-new-flow.html` in the main checkout): same layout, colours and copy; pages built from `INIT.releases` (welcome from the newest; slides from all, newest release first; feedback last; notes per version with "See it on GitHub" link → `open` with `<repoURL>/releases/tag/v<version>`, hidden for `"next"`); scene renderers for the six kinds (unknown → buddy); Halloween web/spider/bats/pail are not needed (no slide uses them yet); one rAF loop that draws only the visible page's scenes at 12 fps; Escape → close; idea-line text per `INIT.mode` (spec wording); a picked face posts `rate`; Send posts `send` and disables until `window.sent`; Wear button only when `INIT.wearable[skin]`.
- [ ] **Step 4:** Run → PASS. Then render it in a browser with a stub `webkit.messageHandlers` and stub INIT (scratch file outside the repo) and click through every page; compare with the mock.
- [ ] **Step 5: Commit** `What's New: the window's page and Buddy's JS renderer`.

### Task 6: Window, messages, sending, and the hooks

**Files:**
- Modify: `whatsnew.lua` (window half), `updater.lua` (first-start branch, ~6 lines), `buddy.lua` (menu item + two functions, ~15 lines), `config.example.lua` (`feedback_url`), `README.md` (Updates section; maintainer section; a "Feedback" note in How it works)
- Test: extend `tests/whatsnew_spec.lua`

**Interfaces:**
- Consumes: Tasks 4–5.
- Produces: `W.init(dir)` (idempotent: reads VERSION + config.lua `feedback_url`, `update_repo`; starts the flush timers only when the queue is non-empty); `W.markFrom(old)` (sets `claudeWidget.whatsNewFrom`); `W.showPending() -> bool` (opens the window and has Buddy say "I got updated! Come see what's new."); `W.open(want) -> bool`; `W.handle(msg, deps)` (the message switch, deps `{ post, openURL, copy, share, wear, close, say }` so the spec can drive it); `FEEDBACK_URL = ""` constant. `buddy.lua`: `M.whatsNew(v)`, `M.wearSkin(id) -> bool` (wraps local `pickSkin`, false if the skin isn't in `Skins.list()`), menu item "What's new" after "Skin". `updater.lua`: in the first-start branch, `whatsNew().markFrom(last)`; the 6 s timer calls `whatsNew().showPending()` and only says the old bubble line when it returns false. Single instance via global `ClaudeWhatsNew = ClaudeWhatsNew or dofile(dir .. "/whatsnew.lua")` at both call sites.

- [ ] **Step 1: Extend the spec:** `handle` with `send` in email mode and allow() true → `deps.post` called with the payload, `sent` reply ok text "Sent. Thanks!"; post 503 → queued, reply "Saved. I'll send it when you're back online."; over cap → no post, reply "That's plenty for today. Thanks!"; github mode → `deps.openURL` called with an `issues/new` URL, reply "Opened on GitHub. Click Submit there to post it."; `rate` then `close` in email mode → one post with only rating; `rate` then `send` then `close` → exactly one post; `open` with a non-repo URL → `openURL` not called; `wear` → `deps.wear(id)`; `showPending` with no `whatsNewFrom` → false.
- [ ] **Step 2:** Run Lua tests → FAIL.
- [ ] **Step 3: Implement** the window half (`hs.webview` built like `setup.lua`: titled+closable, 600×520 centred on the main screen, title "What's new in Buddy", `allowTextEntry(true)`, `deleteOnClose(true)`, `windowCallback` closing → `handle({type = "close"})` once; real deps: `hs.http.asyncPost`, `hs.urlevent.openURL`, `hs.pasteboard.setContents`, share via a `hs.menubar.new(false)` popup with Messages/Mail/AirDrop using `hs.sharing.newShare("com.apple.share.Messages.window" | "com.apple.share.Mail.compose" | "com.apple.share.AirDrop.send"):shareItems({ text, url })`, macOS from `hs.host.operatingSystemVersion()`); then the hooks in `updater.lua`, `buddy.lua`, `config.example.lua`, README.
- [ ] **Step 4:** Run Lua + Python + Node tests → PASS. Syntax check of every module is part of the Lua run.
- [ ] **Step 5: Commit** `What's New: open after an update, from the menu, and send feedback`.

### Task 7: Whole-branch review and hand-off

- [ ] **Step 1:** Independent review of `git diff main...whats-new` (a reviewer that hasn't seen this plan), focused on the Global Constraints and Review Focus; fix what's real.
- [ ] **Step 2:** Re-run all three suites; record counts.
- [ ] **Step 3:** Message the release captain: branch, head, Lua/Python/Node counts, what the owner must do to turn on email (Worker README), and that `releases.json`'s `"next"` copy is theirs to finish last.
