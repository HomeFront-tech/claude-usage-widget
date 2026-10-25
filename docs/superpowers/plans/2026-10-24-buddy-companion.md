# Buddy Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Buddy into a learning, candid, health-minded sidekick that runs on any Claude model (Auto routing by default), with privacy controls and a view of Buddy's own usage.

**Architecture:** New Lua modules (`privacy.lua`, `facts.lua`, `learn.lua`, `health.lua`, `usage_report.lua`) hold the new behaviour and their own state; `buddy.lua`, `brain.lua`, `setup.*` and `usage_widget.lua` get small call sites. Model choice and routing live in `bin/buddy-agent`; Buddy's per-model ledger is tallied by `bin/claude-tokens` into `tokens.json["buddy"]` and reported by a new `bin/buddy-usage`.

**Tech Stack:** Hammerspoon Lua (no build step), Python 3 standard library, `claude -p` (Claude Code CLI 2.1.x), Lua specs run inside Hammerspoon, Python `unittest`.

**Spec:** `docs/superpowers/specs/2026-10-24-buddy-companion-design.md` (read it first; this plan argues from it).

## Global Constraints

- Work only in the `companion` worktree (`.claude/worktrees/companion`). Never reload Hammerspoon or point the live copy at this branch.
- Public repo: no personal data, names, business details or real usage numbers in code, tests, docs or commits.
- Lua style matches the files around it: module header comment, sparse comments, `local` tables on the module for anything that must survive garbage collection. Python matches `bin/buddy-agent` (type hints, stdlib only).
- Every module must load without side effects (no timers, no file writes) so `tests/run.lua` can `dofile` it.
- Specs use `t.tmpdir()` and fakes; any spec that touches an `hs.settings` key saves and restores it.
- Claude model choices are Claude Code aliases, exactly: `auto`, `haiku`, `sonnet`, `opus`, `fable`.
- Auto routing, exactly: `quip`, `note`, `learn`, `ping` → `haiku` at effort `low`; `chat`, `job` → `opus`; `chat` with a research signal → `opus` plus helper subagents on `sonnet`.
- A named model is used for every kind, helpers included.
- Buddy can find, read and open things, never send, change or delete. Helpers get no more tools than chat has.
- Questions: at most 3 a day. Never during calls, meetings, full-screen windows, games, quiet time or "Quiet for an hour". Questions, health nudges and fact lines are all skipped when chattiness is "Only when clicked" (`QUIET_FOR < 0`) or Buddy is muted.
- Every screenshot Buddy takes shows the `ponder` action while it's out, including learning looks.
- Health defaults: sitting nudge after 60 min of activity, reset after 5 min away; meal windows breakfast 8–10, lunch 12–14, dinner 17–19.
- `tokens.json["buddy"]` has the same per-hour, per-model shape as `tokens.json["hours"]`: `{ "<hour epoch>": { "m": { "<model>": [input, output, cache_write, cache_read, replies, dollars] }, "k": { "<kind>": [tokens, dollars] } } }`. Dollars come only from `PRICES` / `price_for()` in `bin/claude-tokens`.
- Before editing `usage_widget.lua` `render()` or `bin/claude-tokens`, check with the dollar-row work (SendMessage); after committing a change to either, send it the changed functions and line ranges.
- Watching off or paused: no screenshots, no learning, no on-screen questions, no food/fitness spotting, and no window titles, counts, facts or habits in any model prompt.
- Existing configs (no `watch`, `auto_reactions` or `health` keys) keep today's behaviour: nothing new turns on until the wizard is run.

## Review Focus

1. **The chosen model isn't on the user's plan** (or Claude Code is signed out): Auto quietly falls back down the chain and keeps working; a named model gives a plain message naming the model and how to switch. Tests in Task 1.
2. **Corrupt or missing state files** (`facts.json`, `learn.json`, `health.json`, a half-written ledger line): the module starts fresh or skips the line, and Buddy never errors. Tests in Tasks 3, 6, 7, 8.
3. **Midnight and sleep**: "today" counts, meal windows and the sitting timer behave across local midnight and after the Mac sleeps (a long idle is a break). Tests in Tasks 6 and 8.
4. **Watching turned off while a request is in flight**: a learning result or question that comes back after a pause is dropped, not stored or asked. Test in Task 7.
5. **Updating from v1.5 with an old `config.lua`**: `ai = { engine = "claude", model = "haiku" }` still works as named Haiku, the wizard shows Haiku selected, and no learning or health starts until the wizard saves. Tests in Tasks 5 and 9.

---

### Task 1: Any Claude model and Auto routing in the agent

**Files:**
- Modify: `bin/buddy-agent` (argv building, timeouts, `run`)
- Modify: `agent.lua` (`A.configure` keeps any alias; new `A.setModel`)
- Modify: `tests/fakes/claude` (per-model failure)
- Test: `tests/test_buddy_agent.py`, `tests/brain_claude_spec.lua`

**Interfaces:**
- Produces: `route(kind: str, req: dict, cfg: dict, unavailable: set) -> dict` with keys `model: str`, `effort: str | None`, `helpers: bool`, `helper_model: str | None`, `timeout: float`.
- Produces: `research_signal(prompt: str) -> bool` (checks only the last `Them:` line).
- Produces: request kinds `learn` (one turn, no tools, like `quip`) and `ping` (one turn, no tools; honours `req["model"]`, the only kind that may).
- Produces: `agent/models.json` = `{ "<alias>": { "ok": bool, "at": epoch } }`; an `ok: false` entry under a day old makes Auto skip that alias.
- Produces: `A.setModel(model: string)` rewrites `config.json`'s `model` (next run uses it; no reload).
- Produces: every response dict gains `model` (the alias actually used).

- [ ] **Step 1: Extend the fake.** `FAKE_CLAUDE_FAIL_MODEL=<alias>`: when argv's `--model` value equals it, print `{"type":"result","is_error":true,"result":"Model not available on your plan"}` and exit 1. `FAKE_CLAUDE_MODEL_USAGE=<json>`: include it as `modelUsage` in the result line.

- [ ] **Step 2: Write the failing tests** in `tests/test_buddy_agent.py`:

```python
def test_auto_routes_by_kind(self):
    for kind, model, effort in (("quip", "haiku", "low"), ("note", "haiku", "low"),
                                ("learn", "haiku", "low"), ("chat", "opus", None), ("job", "opus", None)):
        r = route(kind, {"prompt": "Them: hi"}, {"model": "auto"}, set())
        self.assertEqual((r["model"], r["effort"], r["helpers"]), (model, effort, False))

def test_auto_research_gets_sonnet_helpers(self):
    r = route("chat", {"prompt": "You: hey\nThem: can you research standing desks"}, {"model": "auto"}, set())
    self.assertEqual((r["model"], r["helpers"], r["helper_model"]), ("opus", True, "sonnet"))

def test_research_signal_only_reads_latest_turn(self):
    self.assertFalse(research_signal("Them: research this\nYou: done\nThem: thanks"))

def test_named_model_used_for_everything(self):
    for kind in ("quip", "note", "learn", "chat", "job"):
        self.assertEqual(route(kind, {"prompt": "Them: research x"}, {"model": "sonnet"}, set())["model"], "sonnet")
    self.assertEqual(route("chat", {"prompt": "Them: research x"}, {"model": "fable"}, set())["helper_model"], "fable")

def test_legacy_config_is_haiku(self):
    self.assertEqual(route("chat", {"prompt": "Them: hi"}, {}, set())["model"], "haiku")

def test_timeouts(self):
    self.assertEqual(route("quip", {"prompt": ""}, {"model": "auto"}, set())["timeout"], 45)
    self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "haiku"}, set())["timeout"], 180)
    self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "auto"}, set())["timeout"], 300)
    self.assertEqual(route("chat", {"prompt": "Them: research x"}, {"model": "auto"}, set())["timeout"], 600)

def test_auto_skips_unavailable(self):
    self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "auto"}, {"opus"})["model"], "sonnet")
    self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "auto"}, {"opus", "sonnet"})["model"], "haiku")

def test_helpers_argv_keeps_tools_read_only(self):   # run_cli with kind=chat, research prompt
    argv = self.argv()
    agents = json.loads(argv[argv.index("--agents") + 1])
    self.assertNotIn("Bash", json.dumps(agents)); self.assertNotIn("Write", json.dumps(agents))
    self.assertIn("Agent", argv[argv.index("--allowedTools") + 1])

def test_auto_falls_back_when_model_missing(self):   # FAKE_CLAUDE_FAIL_MODEL=opus, kind=chat
    out = self.run_cli(kind="chat")
    self.assertTrue(out["ok"]); self.assertEqual(out["model"], "sonnet")
    self.assertFalse(json.loads((self.agent / "models.json").read_text())["opus"]["ok"])

def test_named_model_missing_says_so(self):          # config model=opus, FAKE_CLAUDE_FAIL_MODEL=opus
    out = self.run_cli(kind="chat")
    self.assertFalse(out["ok"]); self.assertIn("Opus isn't on your plan", out["error"])

def test_ping_uses_requested_model(self):
    self.run_cli(kind="ping", model="fable")
    self.assertEqual(self.argv()[self.argv().index("--model") + 1], "fable")
```

- [ ] **Step 3: Run them and see them fail.** Run: `/usr/bin/python3 -m unittest tests.test_buddy_agent -v`. Expected: the new tests fail (no `route`, unknown kinds).

- [ ] **Step 4: Implement `route` and `research_signal`, use them in `build_argv` and `run`.**
  - `RESEARCH_WORDS = ("research", "look into", "find out", "compare", "investigate", "deep dive", "pros and cons", "workout plan", "diet plan", "meal plan", "plan for")`.
  - Timeouts: quip/note 45, learn 60, ping 30; chat 180 on haiku/sonnet, 300 on opus/fable, 600 with helpers; job 150 on haiku/sonnet, 300 on opus/fable.
  - Auto fallback chain for chat/job: `opus → sonnet → haiku`. A result whose error text contains "model" and one of "not available", "not found", "access", "invalid" marks that alias `ok: false` in `models.json` and retries once down the chain (Auto only). A named model failing that way returns `"<Name> isn't on your plan. Right-click me → Brain to pick another."`. A successful run marks its alias `ok: true`.
  - Helpers: `--agents '{"helper": {"description": "Digs into research questions and reports back what it found.", "prompt": <Buddy's assistant rules + "Report findings plainly; never send, change or delete anything.">, "model": <helper_model>, "tools": ["mcp__buddy__find_files", "mcp__buddy__list_folder", "mcp__buddy__read_file", "mcp__buddy__read_source", "WebSearch"]}}'`; add `Agent` to `--tools` and `--allowedTools`.
  - `agent.lua`: `A.configure` passes `ai.model` through when it is one of the five choices or a full `claude-…` name, and uses `"haiku"` otherwise (an Ollama name like `gemma3:4b` still maps to `"haiku"`).

- [ ] **Step 5: Run the tests and see them pass.** Run: `/usr/bin/python3 -m unittest tests.test_buddy_agent -v`. Expected: all pass, older tests included.

- [ ] **Step 6: Prove helpers work for real, once, on Haiku.** From a temp folder, run `bin/buddy-agent` with `BUDDY_AGENT_DIR` set to a temp dir whose `config.json` is `{"model": "haiku"}` and the request `{"kind":"chat","system":"You are a test.","prompt":"Them: research which is bigger, a lime or a lemon, using your helper"}`. Expected: `ok: true` and `"Agent"` in `tools`. If `Agent` is not the tool name in this Claude Code version, use the name its `--help`/error reports and update the test.

- [ ] **Step 7: Add `A.setModel` and a spec line** in `tests/brain_claude_spec.lua`: configure with `{ engine = "claude", model = "auto", agent_dir = tmp }`, then `A.setModel("opus")`; `t.eq(t.readJson(tmp .. "/config.json").model, "opus", "setModel rewrites config.json")`, and configure with `model = "gemma3:4b"` gives `"haiku"`. Run `tests/lua-tests`; expected `0 failed`.

- [ ] **Step 8: Commit.** `git add bin/buddy-agent agent.lua tests/fakes/claude tests/test_buddy_agent.py tests/brain_claude_spec.lua && git commit -m "Brain: any Claude model, Auto routing with helpers and fallback"`

### Task 2: Buddy's ledger records models (Claude and Ollama)

**Files:**
- Modify: `bin/buddy-agent` (`run`'s log call)
- Modify: `brain.lua` (`post` logs Ollama calls; `dispatch` passes `kind`)
- Test: `tests/test_buddy_agent.py`, new `tests/brain_ledger_spec.lua`

**Interfaces:**
- Consumes: `route()` result (`model`) from Task 1.
- Produces: `models_from(result: dict) -> dict[str, list[int]]` mapping each model id to `[input, output, cache_write, cache_read, cache_write_1h]`. Per-model 1h writes = that model's `cacheCreationInputTokens` × (call `usage.cache_creation.ephemeral_1h_input_tokens` ÷ call `cache_creation_input_tokens`), rounded.
- Produces: ledger line fields added: `engine` ("claude" | "ollama"), `model` (alias or Ollama name), `models` (from `models_from`, or `{"ollama:<name>": [prompt_eval_count, eval_count, 0, 0, 0]}`).
- Produces: `B.ollamaEntry(kind: string, reply: table, now: number) -> table` (pure) and the append to `<agent_dir>/usage.jsonl`; `agent_dir` is `ai.agent_dir` or the default folder, for Ollama too.

- [ ] **Step 1: Write the failing tests.** Python: with `FAKE_CLAUDE_MODEL_USAGE='{"claude-haiku-5-5": {"inputTokens": 2, "outputTokens": 4, "cacheReadInputTokens": 649, "cacheCreationInputTokens": 3044}}'` and a usage block whose `cache_creation.ephemeral_1h_input_tokens` is 3044, the last ledger line has `engine == "claude"`, `model == "haiku"`, `models == {"claude-haiku-5-5": [2, 4, 3044, 649, 3044]}`. A result with no `modelUsage` logs `models == {}`. Lua (`brain_ledger_spec.lua`): `B.ollamaEntry("quip", { prompt_eval_count = 50, eval_count = 9 }, 0)` has `engine = "ollama"`, `kind = "quip"`, `models["ollama:gemma3:4b"][1] == 50` and `[2] == 9`.
- [ ] **Step 2: Run and see them fail.** `/usr/bin/python3 -m unittest tests.test_buddy_agent -v` and `tests/lua-tests`.
- [ ] **Step 3: Implement** `models_from`, the new log fields, `B.ollamaEntry` and the append after a successful Ollama reply (one JSON line, opened in append mode).
- [ ] **Step 4: Run and see them pass.** Same commands; expected all pass.
- [ ] **Step 5: Commit.** `git commit -am "Ledger: record the model behind every Buddy call, Ollama included"` (add the new spec file first).

### Task 3: Tally Buddy's usage and report it

**Files:**
- Modify: `bin/claude-tokens` (read the ledger, `tokens.json["buddy"]`, summary fields)
- Create: `bin/buddy-usage`
- Test: `tests/test_claude_usage.py` (or a new `tests/test_buddy_usage.py`)

**Interfaces:**
- Consumes: ledger lines from Task 2.
- Produces: `tally_buddy(entry: dict, buddy: dict) -> bool` in `bin/claude-tokens`. Lines with a `tool` key, `ok: false` with no tokens, or bad JSON are skipped. Old lines without `models` count under model `"unknown"` with $0. Ollama models count with $0.
- Produces: `tokens-state.json["buddy_offset"]`; the ledger path is `$BUDDY_AGENT_DIR/usage.jsonl` or the default agent folder. When the file is shorter than the offset, rebuild `buddy` from the start.
- Produces: summary JSON fields `buddy24h = {"calls": int, "tokens": int, "cost": float, "models": {model: tokens}}` and `share24h: float` (Buddy tokens ÷ (Claude Code tokens + Buddy tokens), last 24 h, 0 when both are 0).
- Produces: `bin/buddy-usage` prints `{"ok": true, "periods": {"today": P, "week": P, "month": P}}` where `P = {"calls", "tokens", "cost", "local_calls", "models": {model: {"tokens", "cost"}}, "kinds": {kind: {"tokens", "cost"}}}`; today = since local midnight, week = last 7 × 24 h, month = since the 1st, local time.

- [ ] **Step 1: Write the failing tests** using a temp `HOME`/`BUDDY_AGENT_DIR` and a ledger with: one Haiku quip (models as in Task 2), one Opus chat, one Ollama quip, one `{"tool": "read_file", "ok": true}` line, one half-written last line. Assert: `buddy` hour entry `m["claude-haiku-5-5"] == [2, 4, 3044, 649, 1, <price_for cost>]`, `m` has no tool line, Ollama dollars 0, the half line is read on the next run once completed, `k["quip"][0]` equals the quip tokens, a second run adds nothing, truncating the ledger rebuilds. `buddy-usage` on the same data: `periods.today.calls == 3`, `local_calls == 1`, `models` has Haiku and Opus dollars matching `price_for`.
- [ ] **Step 2: Run and see them fail.** `/usr/bin/python3 -m unittest discover -s tests -v`.
- [ ] **Step 3: Implement** `tally_buddy`, the incremental read in `main()` (same pattern as the log files: read from the offset, leave a half-written last line), the summary fields, and `bin/buddy-usage`, which reads the dollars already stored in `tokens.json["buddy"]` and never prices anything itself.
- [ ] **Step 4: Run and see them pass.** Same command; all pass.
- [ ] **Step 5: Commit, then tell the dollar-row work.** `git add bin/claude-tokens bin/buddy-usage tests/... && git commit -m "Tokens: tally Buddy's own calls by model, and a Buddy usage report"`. SendMessage the dollar-row work: the functions changed (`tally_buddy`, `main` summary block) with line ranges.

### Task 4: Switch brains from the menu, and Buddy's usage report

**Files:**
- Modify: `setup.lua` (extract `brainConfig`, new `W.setBrain`, new `W.setOption`)
- Modify: `buddy.lua` (`showMenu`, new `M.setBrain`, `M.buddyUsage`)
- Create: `usage_report.lua`
- Test: `tests/setup_spec.lua`, new `tests/usage_report_spec.lua`

**Interfaces:**
- Consumes: `A.setModel` (Task 1), `bin/buddy-usage` JSON (Task 3).
- Produces: `local function brainConfig(old: table|nil, choice: string|boolean) -> table|nil` in `setup.lua`; `choice` ∈ `"auto" | "haiku" | "sonnet" | "opus" | "fable" | "ollama" | false`, plus legacy `"claude"` (= keep the old Claude model, else `"haiku"`) and `true` (= Ollama). Claude choices set `engine = "claude"` and `model = choice`; other `ai` keys are kept.
- Produces: `W.setBrain(dir: string, cfg: table, choice) -> table` and `W.setOption(dir: string, cfg: table, key: string, value) -> table`: write `config.lua` with only that change and return the new table.
- Produces: `M.setBrain(choice)`: Claude model → Claude model calls `W.setBrain` + `Agent.setModel` with no reload and says "Brain: Opus." (the choice's label); any engine change calls `W.setBrain` then `hs.reload()`.
- Produces: `R.format(report: table) -> string` in `usage_report.lua`; `R.label(model: string) -> string` (`claude-haiku-5-5` → `Haiku 5.5`, `ollama:gemma3:4b` → `gemma3:4b (this Mac)`, `unknown` → `Claude (older)`).
- Produces: `M.buddyUsage()` runs `bin/buddy-usage` with `hs.task`, then `Chat.post("assistant", R.format(report))` and opens the chat quietly; with no brain it shows the text with `hs.dialog.blockAlert("Buddy's usage", text)`.

- [ ] **Step 1: Write the failing specs.** `setup_spec.lua`: `S.setBrain(tmp, { ai = { engine = "claude", model = "haiku", peek_every = 120 } }, "opus")` writes `ai.model == "opus"`, keeps `peek_every`; `"auto"` gives `model == "auto"`; `"ollama"` gives `engine == nil, model == "gemma3:4b"`; `false` gives `ai == nil`; the existing save tests still pass with `brain = "claude"`. `usage_report_spec.lua`: `R.format` of a report with today = 3 calls, $0.01, Haiku 81% / Opus 19% contains `"Today: 3 calls"`, `"Haiku 5.5"`, `"81%"`, `"≈$0.01"` and the `kinds` line; an all-zero report says `"I haven't used any Claude yet."`.
- [ ] **Step 2: Run and see them fail.** `tests/lua-tests`.
- [ ] **Step 3: Implement** the setup functions, `usage_report.lua`, and the menu: a **Brain ▸** submenu (`Auto (recommended)`, `Haiku`, `Sonnet`, `Opus`, `Fable`, `Ollama on this Mac`, `Plain rules`, the current one checked) and **Buddy's usage** after "How's my usage?".
- [ ] **Step 4: Run and see them pass.** `tests/lua-tests`; expected `0 failed`.
- [ ] **Step 5: Commit.** `git commit -m "Brain menu: switch models without a reload; Buddy's own usage report"` (after `git add` of the new files).

### Task 5: Privacy switch, pause, private filter and Forget

**Files:**
- Create: `privacy.lua`
- Modify: `brain.lua` (`PRIVATE` moves out; `B.private` and `B.snapshot` ask Privacy; `B.forget` stays)
- Modify: `buddy.lua` (configure Privacy in `M.start`, `peek` checks it, **Watching ▸** and **Forget what you've learned about me…** in `showMenu`, one-time heads-up)
- Test: new `tests/privacy_spec.lua`, `tests/persona_spec.lua` if it checks `PRIVATE`

**Interfaces:**
- Produces: `P.configure(cfg: table) -> P` (reads `cfg.watch`, `cfg.never_look`, `cfg.ai.private`).
- Produces: `P.watching(now: number?) -> boolean` = `cfg.watch ~= false` and not paused. (Old configs keep today's peeks; new features are separately gated by `auto_reactions` and `health`.)
- Produces: `P.pause(seconds: number)`, `P.pauseUntilMorning(now: number?)` (next local 06:00), `P.resume()`, `P.pausedUntil() -> number|nil`; settings key `claudeBuddy.watchPausedUntil`.
- Produces: `P.private(bid: string?, app: string?, title: string?) -> boolean`: today's `PRIVATE` words + `cfg.ai.private` words + `PRIVATE_APPS` (`com.1password.1password`, `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.lastpass.LastPass`, `com.apple.keychainaccess`, `com.apple.Passwords`, `com.dashlane.dashlanephonefinal`) + `cfg.never_look` bundle ids.
- Produces: `P.forget(parts: table)` where `parts` = `{ brain, chat, stores = { ... } }`; calls `brain.forget()`, `chat.forget()`, `store:wipe()` on each store, and clears `claudeBuddy.appSeconds` and `claudeBuddy.askedToTeach`.
- Produces: `B.private(app, title, bid)` (new third arg; Privacy's own order is `bid, app, title`) and `B.snapshot(winId)` returning nil whenever `P.watching()` is false.
- Produces: `B.scrub(ctx: table) -> table` (pure): with watching off, a copy of `ctx` without `app`, `title`, `winId`, `topic` and `facts`; `B.quip` and `B.chat` run every ctx through it, so prompts say "an app" and session quips name no session.
- Produces: `P.busy(bid: string, title: string, fullScreen: boolean, mood: string) -> boolean`: meeting apps `us.zoom.xos`, `com.microsoft.teams2`, `com.microsoft.teams`, `com.apple.FaceTime`, `com.cisco.webexmeetingsapp`, `com.webex.meetingmanager`; titles containing `meet.google.com`, `google meet`, `zoom meeting`; any full-screen window; moods `gaming`, `call`.

- [ ] **Step 1: Write the failing spec** (`privacy_spec.lua`): `P.busy("us.zoom.xos", "", false, "idle")`, `P.busy("x", "", true, "idle")` and `P.busy("x", "", false, "gaming")` true, `P.busy("x", "Docs", false, "idle")` false; `B.scrub({ app = "Chrome", title = "Bank", topic = "fix login" })` with watching off has no `app`, `title` or `topic`, and with watching on keeps them; `watch = false` → `watching() == false`; no `watch` key → true; `pause(3600)` at `now = 1000` → false at 2000, true at 4601; `pauseUntilMorning` at local 23:00 gives tomorrow 06:00, at 03:00 gives today 06:00; `private("com.bitwarden.desktop", "Bitwarden", "")`, `private(nil, "Chrome", "Chase Bank - Sign in")`, `private("x.y", "X", "")` with `never_look = { "x.y" }` all true; `private("com.apple.Safari", "Safari", "Recipes")` false; `forget` calls each part once and clears both settings keys (save and restore them around the test).
- [ ] **Step 2: Run and see it fail.** `tests/lua-tests`.
- [ ] **Step 3: Implement** `privacy.lua` and the call sites. `peek(kind, byUser)` with watching off says "Watching's off. Right-click me to turn it on." when `byUser`, and does nothing otherwise. Watching ▸ holds `Pause for an hour`, `Pause until morning`, `Resume watching` (only while paused) and `Turn watching off` / `Turn watching on` (`W.setOption(dir, CFG, "watch", …)` then reload). Forget asks first with `hs.dialog.blockAlert("Forget what I've learned about you?", "My notes, app habits, health goals and our chat go. This can't be undone.", "Forget", "Cancel")`. The first time `auto_reactions` or `health` is on and watching is on, Buddy says once (key `claudeBuddy.toldWatching`): "Heads up: I peek at your screen now and then to learn. Right-click me to pause."
- [ ] **Step 4: Run and see it pass.** `tests/lua-tests`; expected `0 failed`.
- [ ] **Step 5: Commit.** `git commit -m "Privacy: watching switch, pause, private apps and words, Forget"`.

### Task 6: Facts and candid lines

**Files:**
- Create: `facts.lua`
- Modify: `brain.lua` (quip kind `fact`; `ctx.facts` in screen quips; candid persona)
- Modify: `buddy.lua` (observe each poll; fact lines on entry)
- Test: new `tests/facts_spec.lua`, `tests/persona_spec.lua`

**Interfaces:**
- Consumes: `P.watching()` (Task 5).
- Produces: `F.keyFor(bid: string, appName: string, title: string, isBrowser: boolean, titleRules: table) -> key: string, label: string`. Apps: `bid`, app name. Browsers: the first matching `TITLE_RULES` pattern (label = pattern with a capital, `youtube` → `YouTube` via a small `LABELS` map), else the text after the last ` - ` or ` — ` in the title (lower-cased key, ≤ 40 chars), else `bid`.
- Produces: `F.new(path: string) -> facts` with `facts:observe(key, label, t)`, `facts:get(key, t) -> { opens, seconds, sinceLast, daypart, streak }`, `facts:describe(key, label, t) -> string`, `facts:line(key, label, t) -> string|nil`, `facts:save()`, `facts:wipe()`. An "open" is entering a key after at least 60 s away from it (quick alt-tabs don't count). Keep 14 days; `daypart` is the part of day (morning 5–12, afternoon 12–17, evening 17–22, night 22–5) holding the most of that key's last-14-days seconds, nil under 30 min total.
- Produces: `facts:observe` returns `true` when the call counted a new open.
- Produces: `B.setKnown(days: number)`; persona adds one sentence by days known (< 3: "You only just met them: friendly and a little cheeky."; 3–29: "You've known them N days: be candid and familiar."; ≥ 30: "You're old friends (N days): blunt, honest and affectionate, and you bring up their habits."). `claudeBuddy.metAt` is set on first start.

- [ ] **Step 1: Write the failing spec** (`facts_spec.lua`): with `t0` = a fixed local 09:00, observe YouTube for 300 s, Mail 120 s, YouTube 300 s, Mail 30 s, YouTube again → opens 2 (the 30 s gap doesn't count); `describe` → `"YouTube: 2nd time today, 10 min so far"`; `line` at 3 opens → `"YouTube for the third time today!"`; an observation at local 00:01 the next day → opens 1 for that day; `streak` counts consecutive days; a garbage `facts.json` → `F.new` starts empty without error; `wipe()` empties and deletes the file. `keyFor("com.google.Chrome", "Chrome", "cats - YouTube", true, {{"youtube","watching"}})` → `"youtube", "YouTube"`; `"Q3 numbers - Google Sheets"` with no rule → `"google sheets"`.
- [ ] **Step 2: Run and see it fail.** `tests/lua-tests`.
- [ ] **Step 3: Implement** `facts.lua` (plain-rule templates: 2 → `"%a again!"`, 3–10 → `"%a for the <ordinal> time today!"`, more → `"%a, round %n today."`, ≥ 120 min today → `"Two hours of %a today!"`), the persona sentence, quip kind `fact` (`"Here's what you know: <facts>. Say one candid line about it, under 15 words, like a friend who's been sitting beside them; <angle>."`), and the poll hook: on a counted open with `opens >= 2`, not muted, not said for that key in 15 min → brain `fact` quip with `facts:describe` when Brain and `P.watching()`, else `say(facts:line(...))`. Facts never reach a prompt when not watching. Save facts every 60 s of polling.
- [ ] **Step 4: Run and see it pass.** `tests/lua-tests`; expected `0 failed`.
- [ ] **Step 5: Commit.** `git commit -m "Facts: count opens and time per app and site; candid lines made from them"`.

### Task 7: Auto reactions that learn

**Files:**
- Create: `learn.lua`
- Modify: `brain.lua` (new `B.classify`)
- Modify: `buddy.lua` (`classify` consults Learn; poll triggers decisions; teach prompt only without Auto)
- Test: new `tests/learn_spec.lua`

**Interfaces:**
- Consumes: `F.keyFor`, `facts:describe` (Task 6); `P.watching`, `P.private`, `P.busy` (Task 5).
- Produces: `L.new(path: string, moods: table) -> learner` where `moods` maps mood key → one-line meaning (all of `setup.lua`'s `MOOD_LABELS` keys except `teammate`, plus `health` and `food`).
- Produces: `learner:observe(key, label, title, t)` (keeps ≤ 8 recent distinct titles ≤ 80 chars, and seconds), `learner:moodFor(key, t) -> string|nil` (daypart mood if set, else the app's mood), `learner:due(key, t) -> boolean` (no profile and ≥ 120 s seen; or ≥ 3600 s new since the last decision and ≥ 24 h since it), `learner:decide(key, label, ctx, brain, privacy, done)`, `learner:canAsk(t) -> boolean` (< 3 asked today), `learner:asked(t)`, `learner:save()`, `learner:wipe()`.
- Produces: `B.classify(req: { label, titles, facts, moods, image? }, done: function(result|nil))` with kind `learn`; `result = { mood: string, dayparts: { morning?, afternoon?, evening?, night? }, question: string|nil }`, validated against `req.moods` (unknown moods → nil).
- Produces: `buddy.lua` `classify(app, title)` order: chat panel → `CFG_APPS` (your picks) → terminal Claude states → Learn (only when `CFG.auto_reactions` and a Brain) → built-ins.

- [ ] **Step 1: Write the failing spec** (`learn_spec.lua`) with a fake brain whose `classify` records the request and calls back with a canned result: `due` false at 60 s, true at 120 s; `decide` stores `"watching"` and `moodFor` returns it; dayparts `{ evening = "watching", morning = "reading" }` return per daypart; an invalid mood is dropped; `decide` while a fake privacy says not watching sends nothing; **watching turned off before the callback → nothing stored, no question** (Review Focus 4); `canAsk` false after 3 `asked` the same day, true the next day; a corrupt `learn.json` loads empty; `wipe()` empties.
- [ ] **Step 2: Run and see it fail.** `tests/lua-tests`.
- [ ] **Step 3: Implement** `learn.lua`, `B.classify` (prompt asks for one JSON object and nothing else; parse the first `{…}`), and the buddy hooks: when Auto is on, watching, Brain not busy, `due`, and ≥ 30 s since the last decision → `decide` with a snapshot when the window isn't private, showing `doAction("ponder", 8)` while it's out. A returned question is said (`say(q, true)`) and recorded in the transcript (`Chat.said(q)`) only when `canAsk`, not `P.busy(...)`, not muted and `QUIET_FOR >= 0`. With Auto on, the "Option-click me to teach me" prompt is skipped.
- [ ] **Step 4: Run and see it pass.** `tests/lua-tests`; expected `0 failed`.
- [ ] **Step 5: Commit.** `git commit -m "Auto reactions: learn each app and site from the screen and your answers"`.

### Task 8: Health sidekick

**Files:**
- Create: `health.lua`
- Modify: `buddy.lua` (`MOODS.health`, `MOODS.food`, `PROPS.dumbbell`, `PROPS.apple`, poll hook, chat opener, chat answers)
- Modify: `setup.lua` (`MOOD_LABELS` gains `{ "health", "💪 Health" }`, `{ "food", "🍎 Food" }`)
- Modify: `bin/buddy-tools` (`health_log`, `health_get`, chat mode only), `bin/buddy-agent` (pass `BUDDY_HEALTH_DIR`)
- Test: new `tests/health_spec.lua`, `tests/test_buddy_tools.py`

**Interfaces:**
- Consumes: `P.watching` (Task 5).
- Produces: `H.new(dir: string, cfg: table) -> health` (`cfg = { sit_minutes = 60, break_minutes = 5, meals = { breakfast = {8,10}, lunch = {12,14}, dinner = {17,19} }, daily_cap = 8 }`, defaults when missing).
- Produces: `health:tick(t, idle, busy) -> event|nil`: `{ kind = "sit", minutes = n }` once the active streak reaches `sit_minutes` (an idle ≥ `break_minutes` resets the streak, so a sleep is a break), then at most every 30 min; `{ kind = "meal", meal = "lunch" }` once per meal per day inside its window when that meal isn't logged, `idle < 60` and not busy. At most `daily_cap` events a day.
- Produces: `health:spot(app, title, t) -> event|nil` → `{ kind = "food" | "fitness", what = title }`, once per kind per 2 h. Food words: `skipthedishes`, `skip the dishes`, `uber eats`, `ubereats`, `doordash`, `grubhub`, `instacart`. Fitness words: `workout`, `fitness`, `yoga`, `hiit`, `push-up`, `pushup`, `exercise`, `strength training`, `stretching`, `running`. The caller checks `P.watching()` first.
- Produces: `health:log(kind, text, t)` (`kind` ∈ `meal`, `workout`, `break`, `goal`, `plan`, `note`), `health:ate(meal, t)`, `health:absorb()` (reads and empties `<dir>/health-new.jsonl`, written by the tools), `health:summary(t) -> string` (goals, latest plan's first line, today's meals and breaks), `health:save()`, `health:wipe()`.
- Consumes: `P.busy` (Task 5) for the `busy` argument of `tick`.
- Produces: tools `health_log(kind, text)` appends `{"kind","text","at"}` to `$BUDDY_HEALTH_DIR/health-new.jsonl`; `health_get()` returns `health.json`'s goals, plans and the last 7 days. Neither is in `JOB_TOOLS`.

- [ ] **Step 1: Write the failing tests.** `health_spec.lua`: 59 min active → nil, 60 → sit event; a 6 min idle resets the streak; a 12 h idle (sleep) resets it; lunch event at 12:30 when not logged, none after `ate("lunch")`, none at 11:59 or 14:01, none while `busy`; a second lunch event the same day never comes; the next day it does; the 9th event of a day is nil; `spot` finds `"Order from Skip The Dishes"` as food once, not again within 2 h; `absorb` folds a tool-written goal into `summary`; corrupt `health.json` loads empty. Python: `health_log` writes one line; `health_log` with kind `"shell"` fails; job mode does not list either tool.
- [ ] **Step 2: Run and see them fail.** `tests/lua-tests` and `/usr/bin/python3 -m unittest tests.test_buddy_tools -v`.
- [ ] **Step 3: Implement** `health.lua`, the tools, the moods and props (follow `.claude/skills/adding-buddy-reactions`: every place that lists moods learns `health` and `food`), and the hooks. Only with `CFG.health`. Sit → `doAction("stretch", 4)` and a line (`"%m minutes straight! Quick walk or ten push-ups?"`, two more variants; a brain `health` quip when there is one). Meal → the question `"Eaten yet? What's for <meal>?"` via `say(…, true)` + `Chat.said`, and a chat message within 30 min marks that meal eaten. Spot → mood `food`/`health` for the event time plus a question (brain quip when watching). Chat: with health on, the system prompt gets `health:summary`, and `absorb()` runs after each reply. The chat opener asks `"Quick one: any health or fitness goals you want me to keep you honest on?"` when no goal is stored (at most once a day, 3 times total).
- [ ] **Step 4: Run and see them pass.** Same commands; expected all pass. The props are only seen at the live test after hand-back (Task 11), so keep every pixel inside the canvas grid (cols −13..26, rows −19..14) by reading the coordinates.
- [ ] **Step 5: Commit.** `git commit -m "Health: move nudges, meal check-ins, goals and plans in chat"`.

### Task 9: The wizard

**Files:**
- Modify: `setup.html` (brain choices, model check, apps Auto and Never look, new "Looking after you" step, summary)
- Modify: `setup.lua` (`W.initial`, `save`, `modelCheck` message, `MOOD_LABELS`)
- Test: `tests/setup_spec.lua`

**Interfaces:**
- Consumes: `brainConfig` (Task 4), `ping` kind (Task 1).
- Produces: wizard state keys `brain` (`"auto" | "haiku" | "sonnet" | "opus" | "fable" | "ollama" | false`), `autoReactions: boolean`, `watch: boolean`, `health: boolean`, `sitMinutes: 45 | 60 | 90`; app rows may carry mood `"auto"` or `"never"`.
- Produces: `config.lua` keys `auto_reactions = true|nil`, `watch = true|false` (always written by the wizard), `health = { sit_minutes = n }|nil`, `never_look = { bundle ids }|nil`; `apps` stores every row that isn't `"auto"` when Auto is on (a pin may equal the built-in), and keeps today's rule when Auto is off.
- Produces: message `{ type = "modelCheck", model = alias }` → runs `bin/buddy-agent` with `{"kind":"ping","model":alias,"system":"Reply with OK.","prompt":"OK?"}` → `js("window.onModelCheck", { model = alias, ok = bool })`; the result is cached for a day in `claudeBuddy.modelChecks`.

- [ ] **Step 1: Write the failing spec** (`setup_spec.lua`): `S.initial({ ai = { engine = "claude", model = "haiku" } }).brain == "haiku"` (Review Focus 5); `model = "auto"` → `"auto"`; Ollama config → `"ollama"`; `save` with `{ brain = "opus", watch = false, health = true, sitMinutes = 90, autoReactions = true, apps = { { id = "a", mood = "auto", default = "coding" }, { id = "b", mood = "coding", default = "coding" }, { id = "c", mood = "never", default = "generic" } } }` writes `ai.model == "opus"`, `watch == false`, `health.sit_minutes == 90`, `auto_reactions == true`, `apps.b == "coding"`, no `apps.a`, `never_look == { "c" }`; the same save with `autoReactions = false` writes no `apps.b`.
- [ ] **Step 2: Run and see it fail.** `tests/lua-tests`.
- [ ] **Step 3: Implement.** Brain buttons: `Auto (recommended): picks the model for each job`, `Haiku`, `Sonnet`, `Opus`, `Fable`, `Ollama on this Mac`, `No, plain rules`; picking a named Claude model shows "Checking…", then "On your plan" or "Not on your plan". Apps step: a seg `Auto: I'll work it out (needs a brain)` / `I'll pick`, rows gain `✨ Auto` (first, default when Auto is on) and `🙈 Never look`. New step "Looking after you" before the summary: "Watch and learn from my screen?" Yes/No with the disclosure paragraph below, "Health check-ins?" Yes/No, "Remind me to move after" 45 / 60 / 90 min. Summary rows: Brain, Reactions (Auto / Your picks), Watching (On / Off), Health check-ins (Every N min / Off), Never look (names). Disclosure copy, verbatim:

  > With a brain, I look at the window you're in now and then to learn what you do and to make up lines about it. With Claude, that picture goes to Anthropic through your Claude Code login, like any Claude Code use. With Ollama, it stays on this Mac. Pictures are never saved. What I learn (app habits, notes about you, your health goals) stays on this Mac. I never look at password managers, banking, windows with your private words in the title, or apps you mark Never look. That filter goes by app names and window titles, so pause me or turn watching off (right-click me) when something private is on screen.

- [ ] **Step 4: Run and see it pass.** `tests/lua-tests`; expected `0 failed`. Open `setup.html` straight in a browser (`INIT` falls back to its default object) and click through every step; the console stays free of errors.
- [ ] **Step 5: Commit.** `git commit -m "Wizard: any Claude model, Auto reactions, Never look, watching and health"`.

### Task 10: The Buddy bar on the usage card

**Files:**
- Modify: `usage_widget.lua` (`render()`, new `buddyRow`, `M.buddyParts`)
- Test: `tests/usage_widget_spec.lua`

**Interfaces:**
- Consumes: summary fields `buddy24h`, `share24h` (Task 3); `R.label` (Task 4).
- Produces: `M.buddyParts(b: table) -> { { family: string, share: number } }`, sorted largest first, families `haiku`, `sonnet`, `opus`, `fable`, `ollama`, `other`, shares summing to 1.
- Produces: `buddyRow(els, y) -> y`: label `Buddy`, figure `"3% of 24h"` (`share24h`), a bar split into family colours (haiku `C.blue`-like, sonnet gold, opus Claude orange, fable pink, ollama and other grey; add these to `C`), sub-line `"Haiku 81% · Opus 19% · ≈$0.42"`. Hidden when Buddy made no calls in 24 h.

- [ ] **Step 1: Check the agreed spot still holds.** Agreed with the dollar-row work: the Buddy bar goes directly under the `24h: … tokens` line, above the limits; its dollar row goes after the credits loop and before "This week:". If its dollar row has landed on `main`, merge `main` into `companion` first. The bar uses the card's 24 h window, like the line above it, rather than "today" (my call, so the card never mixes windows).
- [ ] **Step 2: Write the failing spec**: `M.buddyParts({ models = { ["claude-haiku-5-5"] = 810, ["claude-opus-5-5"] = 190 } })` → `{ {family="haiku", share=0.81}, {family="opus", share=0.19} }`; unknown and `ollama:` models map to `other` and `ollama`; empty models → `{}`.
- [ ] **Step 3: Run and see it fail.** `tests/lua-tests`.
- [ ] **Step 4: Implement** `M.buddyParts` and `buddyRow`, called once from `render()` in a single inserted block.
- [ ] **Step 5: Run and see it pass.** `tests/lua-tests`; expected `0 failed`.
- [ ] **Step 6: Commit, then tell the dollar-row work** the inserted lines. `git commit -am "Usage card: a Buddy bar with his share and model split"`.

### Task 11: Docs, full test run, merge readiness

**Files:**
- Modify: `README.md`, `config.example.lua`, header comments of `buddy.lua` and `brain.lua`

- [ ] **Step 1: README.** Update the right-click row of the controls table (Brain, Watching, Buddy's usage, Forget). Rewrite "The brain" (models, Auto routing, helpers, switching, Ollama). Add "Learning and privacy" (the wizard's disclosure paragraph, Never look, pause, off, Forget, where data lives: `~/Library/Application Support/claude-usage-widget/` and Hammerspoon's settings), "Health check-ins", "Buddy's own usage".
- [ ] **Step 2: `config.example.lua`.** Document `ai.model` (`"auto"` and the four aliases), `watch`, `auto_reactions`, `never_look`, `health = { sit_minutes, meals, daily_cap }`.
- [ ] **Step 3: Full run.** `tests/lua-tests` → first line ends `0 failed`; `/usr/bin/python3 -m unittest discover -s tests -v` → `OK`. Every top-level `.lua` passes the runner's syntax check.
- [ ] **Step 4: Privacy check of the diff.** `git diff main --stat` and a read of the full diff for personal data (follow `auditing-public-repos-for-personal-data` if anything looks off).
- [ ] **Step 5: Commit.** `git commit -am "Docs: brain models, learning and privacy, health, Buddy's usage"`.
- [ ] **Step 6: Stop and hand back.** Do not merge, reload or release. Report to the owner: what's done, test output, and that the live test needs his go-ahead and a release decision per `.claude/skills/shipping-widget-releases`.
