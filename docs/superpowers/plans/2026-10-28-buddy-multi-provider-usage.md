# Usage for Every AI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Codex, OpenRouter, xAI credits and a Grok subscription on Buddy's usage card next to Claude, chosen and tuned in the setup wizard, with keys only in the Keychain and no change for Claude-only users.

**Architecture:** A pure Lua registry (`providers.lua`) owns provider facts, config resolution, colour levels, tightest-limit choice and all wording. Python stdlib fetchers (`bin/ai-usage` plus one `bin/usage_<provider>.py` module each) print the same one-line JSON `bin/claude-usage` prints. `usage_poll.lua` runs them on per-provider timers; `usage_widget.lua` draws an "Other AIs" list under the untouched Claude section; `usage_alerts.lua` decides the red alerts; `keys.lua` stores keys; `setup.lua`/`setup.html` gain two steps.

**Tech Stack:** Hammerspoon Lua (`hs.canvas`, `hs.task`, `hs.settings`, `hs.webview`), Python 3 standard library, macOS `security`.

**Spec:** `docs/superpowers/specs/2026-10-28-buddy-multi-provider-usage-design.md`

## Global Constraints

- `bin/claude-usage` is not modified. Claude's fetch loop (`refresh()` in `usage_widget.lua`) keeps its logic.
- No config `usage` table (or `order = { "claude" }` with defaults) gives exactly today's card, `/usage`, chat answer, brain status line and chart.
- Keys never appear in config.lua, logs, argv, env, `hs.settings`, the page's JS state after Save, test fixtures or git. Fetchers read the key from the Keychain or from **stdin** (`--key-stdin`).
- Keychain item: service `claude-buddy-<provider>`, account = `$USER` when it matches `^[A-Za-z0-9._-]+$`, else `buddy` (same as `telegram.lua`). Writes go through `security -i` on stdin.
- Never open `~/.codex/auth.json` or any other app's login files; Codex is reached only through `codex app-server`.
- Defaults: yellow `warn_at = 70`, red `hot_at = 90`, `alert_red = false`; refresh Claude 300 s (min 300), Codex 300, OpenRouter 900, xAI 1800, min 60 for all non-Claude.
- Python 3 stdlib only; no new Lua or Python dependencies.
- Public repo: fixtures use made-up numbers, ids and keys (`sk-or-v1-test…`, `team-test`), never real ones.
- Lua specs: `/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests` (it has its own timeout). No new lazy `hs.*` module loads at spec time.
- Python tests: `/usr/bin/python3 -m unittest tests.<module> -v` from the repo root.
- Commits go on branch `multi-provider-usage` in a worktree. No push, no release, no merge to main without the owner's OK (skills `shipping-widget-releases`, `coordinating-buddy-releases`).

## Review Focus

1. **Codex app-server prints notifications or junk lines before its answer.** The fetcher must skip any line that isn't JSON or has no matching `id`. Test: Task 5 `test_skips_noise_and_notifications`.
2. **Hammerspoon's PATH lacks `~/.local/bin` and `/opt/homebrew/bin`.** Codex must still be found and run. Test: Task 5 `test_finds_codex_without_PATH`. Task 8 also pins the task env PATH.
3. **A pasted key carries spaces, a newline or quotes.** Surrounding whitespace is trimmed. A key with an inner space or quote is refused before it reaches `security -i`, which would split it. Tests: Task 4 `test_key_from_stdin_is_trimmed`, Task 11 `K.valid` cases.
4. **A hand-edited config has bad values** (`warn_at >= hot_at`, a string refresh, an unknown id, `order` that isn't a list, `renews_day = 0`). Each field falls back on its own and nothing crashes. Test: Task 2 "bad config" block.
5. **A result saved by an older build has missing or junk fields** (pct not a number, label missing, a string where a row should be). The card draws without erroring and skips the junk. Tests: Task 2 `visible` junk items, Task 10 "junk saved result renders".

---

### Task 1: Worktree, commit the design, and pin today's Claude card

**Files:**
- Create: `tests/usage_card_spec.lua`
- Modify: `usage_widget.lua:385-453` (split `render`)
- Move in: the spec and this plan (untracked in the main checkout)

**Interfaces:**
- Produces: `M.elements(now) -> els, h`, which builds the element list and height without touching the canvas. `render()` becomes `local els, h = M.elements(); els[1].frame.h = h - 1; canvas:size…; canvas:replaceElements(els)`.
- Produces: `M.inject(state)`, for tests only. It sets any of `state.data`, `state.lastError`, `state.tokens` (→ `M.tokens`). Later tasks extend it with `settings`, `results`, `errors`.

- [ ] **Step 1:** Create the worktree with superpowers:using-git-worktrees: branch `multi-provider-usage` from `main`, at `.claude/worktrees/multi-provider-usage`. Move both docs into it (`docs/superpowers/specs/…-design.md`, `docs/superpowers/plans/…md`) and remove them from the main checkout. Commit `docs: design and plan for usage from every AI`.
- [ ] **Step 2: Write the failing spec** `tests/usage_card_spec.lua`. Use a helper `texts(els)` that collects `e.text:getString()` for every `type == "text"` element.

```lua
local W = dofile(dir .. "/usage_widget.lua")
local now = os.time()
local CLAUDE = { ok = true, plan = "max", fetched_at = now - 30,
  limits = { { label = "Current session", pct = 72, severity = "normal", resets_at = now + 2 * 3600 + 13 * 60 + 30 },
             { label = "Week · all models", pct = 38, severity = "normal" } },
  credits = { { label = "Extra usage", used = 3.2, limit = 20, pct = 16 } },
  breakdown = { { name = "Opus", pct = 30 } } }
W.inject({ data = CLAUDE, lastError = false, tokens = false })
local got = table.concat(texts((W.elements(now))), "|")
t.eq(got, "Claude|Max · just now|Reading Claude Code's logs…|Tokens · 24h|Open chart ›|Current session|72%|"
  .. "Resets in 2 hr 13 min|Week · all models|38%||Extra usage|$3.20 / $20||This week: Opus 30%", "Claude-only card text")
```
(`inject` treats `false` as "set to nil".)

- [ ] **Step 3:** Run `/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests`. Expected: FAIL in `usage_card_spec.lua` (`attempt to call a nil value (field 'elements')`).
- [ ] **Step 4:** Split `render()` into `M.elements(now)` plus a thin `render()`, and add `M.inject`. Thread `now` into the `ageText`, `resetText` and `isStale` calls inside `elements`.
- [ ] **Step 5:** Run the Lua specs. Expected: all pass, including `usage_widget_spec.lua` and `value_flow_spec.lua`.
- [ ] **Step 6:** Commit `usage card: build elements apart from the canvas; pin the Claude-only card`.

### Task 2: providers.lua — registry, settings, levels, tightest, figures

**Files:**
- Create: `providers.lua`, `tests/providers_spec.lua`

**Interfaces:**
- Produces:
  - `P.LIST`: ordered entries `{ id, name, kind = "login"|"key"|"manual", refresh, min_refresh, choices = {seconds…}, fields = {…}, fetch = bool }`.
    - `claude` "Claude": login, refresh 300, min 300, choices {300, 600, 900, 1800}, fetch false. Claude has its own loop.
    - `codex` "Codex": login, 300, fetch true.
    - `openrouter` "OpenRouter": key, 900, fields {"key", "budget"}, fetch true.
    - `xai` "xAI credits": key, 1800, fields {"key", "team_id", "budget"}, fetch true.
    - `grok_plan` "Grok": manual, no refresh, fields {"plan", "renews_day"}, fetch false.
    - Non-Claude choices are {60, 300, 900, 1800, 3600}.
  - `P.byId(id) -> entry|nil`.
  - `P.settings(cfg) -> s` with fields `order`, `lead`, `rest`, `claudeOn`, `claudeOnly`, `warn_at`, `hot_at`, `alert_red`, `providers[id] = { refresh, hide = {[label]=true}, budget, team_id, plan, renews_day }`:
    - `order`: known ids from `cfg.usage.order` with repeats dropped, or `{ "claude" }` when there are none.
    - `lead`: `"claude"` when Claude is on, else `order[1]`.
    - `rest`: `order` without `lead`.
    - `providers`: one entry for every `P.LIST` id.
  - `P.level(pct, severity, s) -> "ok"|"warn"|"hot"`.
  - `P.visible(res, hide) -> items`. Limits then credits, each with `kind = "limit"|"credit"`. Items without a string `label` and numeric `pct`, and hidden labels, are dropped.
  - `P.tightest(res, hide) -> item|nil`.
  - `P.figure(item)` and `P.short(item)`.
  - `P.isStale(fetched_at, refresh, now)`: true when older than `3 * refresh`.
  - `P.args(id, ps, keyOnStdin) -> argv`. It adds `--budget` only for a number > 0 and `--team-id` only for a non-empty string.
- An item is a credit when `used` is a number.

- [ ] **Step 1: Write the failing spec** `tests/providers_spec.lua`:

```lua
local P = dofile(dir .. "/providers.lua")
local function list(t) return table.concat(t, ",") end
local s = P.settings({})
t.eq(list(s.order), "claude", "no usage table: Claude only"); t.ok(s.claudeOnly and s.claudeOn, "Claude-only flags")
t.eq(s.lead, "claude", "Claude leads"); t.eq(#s.rest, 0, "nothing else")
t.eq(s.warn_at .. "/" .. s.hot_at, "70/90", "default levels"); t.eq(s.alert_red, false, "alert off by default")
t.eq(s.providers.claude.refresh, 300, "Claude every 5 min"); t.eq(s.providers.openrouter.refresh, 900, "OpenRouter default")
s = P.settings({ usage = { order = { "codex", "claude", "nope", "codex" }, warn_at = 60, hot_at = 80, providers = {
  claude = { refresh = 60, hide = { "Week · Sonnet" } }, codex = { refresh = 10 }, openrouter = { refresh = "120", budget = -5 },
  grok_plan = { plan = "SuperGrok", renews_day = 14 } } } })
t.eq(list(s.order), "codex,claude", "unknown and repeated ids dropped"); t.eq(s.lead, "claude", "Claude on leads")
t.eq(list(s.rest), "codex", "the rest in order"); t.ok(not s.claudeOnly, "not Claude only")
t.eq(s.providers.claude.refresh, 300, "Claude no faster than 5 min"); t.eq(s.providers.codex.refresh, 60, "nothing faster than 1 min")
t.eq(s.providers.openrouter.refresh, 900, "a non-number refresh is the default"); t.eq(s.providers.openrouter.budget, nil, "bad budget dropped")
t.ok(s.providers.claude.hide["Week · Sonnet"], "hide is a set of labels"); t.eq(s.providers.grok_plan.renews_day, 14, "renewal day")
-- bad config: each field falls back alone
s = P.settings({ usage = { order = "codex", warn_at = 95, hot_at = 80, providers = { grok_plan = { renews_day = 0 } } } })
t.eq(list(s.order), "claude", "order that isn't a list"); t.eq(s.warn_at .. "/" .. s.hot_at, "70/90", "yellow above red falls back")
t.eq(s.providers.grok_plan.renews_day, nil, "day 0 dropped")
t.eq(list(P.settings({ usage = { order = {} } }).order), "claude", "nothing on means Claude")
local off = P.settings({ usage = { order = { "openrouter", "codex" } } })
t.eq(off.lead, "openrouter", "Claude off: first in order leads"); t.eq(list(off.rest), "codex", "rest without lead")
t.ok(not off.claudeOn, "Claude off")
-- levels: API severity wins when higher
local d = P.settings({})
t.eq(P.level(69.9, "normal", d), "ok", "under yellow"); t.eq(P.level(70, nil, d), "warn", "yellow at 70")
t.eq(P.level(90, nil, d), "hot", "red at 90"); t.eq(P.level(10, "critical", d), "hot", "critical is red")
t.eq(P.level(10, "warning", d), "warn", "warning is yellow"); t.eq(P.level(95, "warning", d), "hot", "percent wins when higher")
t.eq(P.level(60, nil, P.settings({ usage = { warn_at = 50, hot_at = 80 } })), "warn", "the user's levels")
-- tightest and visible
local res = { limits = { { label = "5-hour", pct = 20 }, { label = "Week", pct = 41 }, { label = "bad" }, { pct = 99 }, "junk" },
  credits = { { label = "This month", used = 18.4, limit = 50, pct = 36.8 } }, facts = { "12,000 credits left" } }
t.eq(P.tightest(res, {}).label, "Week", "highest percent"); t.eq(P.tightest(res, { Week = true }).label, "This month", "hidden skipped; credits count")
t.eq(#P.visible(res, { Week = true }), 2, "junk and hidden dropped"); t.eq(P.visible(res, {})[3].kind, "credit", "credits after limits")
t.eq(P.tightest({ facts = { "x" } }, {}), nil, "facts are never tightest")
-- figures
t.eq(P.figure({ pct = 41.4 }), "41%", "limit figure"); t.eq(P.figure({ used = 3.2, limit = 20, pct = 16 }), "$3.20 / $20", "credit figure as today")
t.eq(P.figure({ used = 18.4, pct = 0 }), "$18.40", "credit without a cap")
t.eq(P.short({ label = "Week", pct = 41 }), "41% wk", "short week"); t.eq(P.short({ label = "5-hour", pct = 7 }), "7% 5h", "short 5-hour")
t.eq(P.short({ label = "Gizmo", pct = 7 }), "7%", "no suffix"); t.eq(P.short({ used = 18.4, limit = 50, pct = 36.8 }), "$18 / $50", "short dollars")
t.eq(P.short({ used = 3.2, limit = 20, pct = 16 }), "$3.20 / $20", "cents under $10")
-- stale and argv
local now = os.time()
t.ok(P.isStale(now - 901, 300, now) and not P.isStale(now - 899, 300, now), "stale after 3x refresh")
t.eq(list(P.args("codex", {}, false)), "codex", "codex argv")
t.eq(list(P.args("openrouter", { budget = 50 }, true)), "openrouter,--budget,50,--key-stdin", "budget and stdin key")
t.eq(list(P.args("xai", { team_id = "team-test", budget = 12.5 }, false)), "xai,--team-id,team-test,--budget,12.5", "team id")
```

- [ ] **Step 2:** Run the Lua specs. Expected: FAIL (`providers.lua` missing).
- [ ] **Step 3: Implement `providers.lua`.** It is pure Lua with no `hs.*` calls.
  - Settings rules:
    - Levels must satisfy `1 <= warn_at < hot_at <= 100`, or both fall back to the defaults.
    - `refresh` must be a number, clamped to `[min_refresh, 86400]`.
    - `budget` must be a number > 0.
    - `renews_day` must be an integer from 1 to 31.
    - `team_id` and `plan` must be non-empty strings.
  - Short suffixes: `Week`/`This week` → `wk`, `5-hour` → `5h`, `Today` → `today`, `This month` → `mo`.
  - `short` dollars: whole dollars from $10 up, two decimals under $10. Format budgets with `%g`.
- [ ] **Step 4:** Run the Lua specs. Expected: PASS.
- [ ] **Step 5:** Commit `providers.lua: one registry and the rules every AI shares`.

### Task 3: Words for every provider — usage text, Grok renewal, check text

**Files:**
- Modify: `providers.lua`, `buddy.lua:1028-1037` (`M.usageText`), `buddy.lua:786` and `buddy.lua:2241` (status lines)
- Test: `tests/providers_spec.lua`

**Interfaces:**
- Consumes: `P.settings`, `P.tightest`, `P.figure` (Task 2).
- Produces:
  - `P.nextRenewal(day, now) -> epoch`: local midnight of the soonest renewal date on or after today. The day is clamped to the month's last day.
  - `P.grokPlan(ps, now) -> res`: `{ ok = true, provider = "grok_plan", plan, fetched_at = now, limits = {}, credits = {}, facts = { "Renews Nov 14" | "Renews today" } }`, with empty `facts` without a day.
  - `P.summary(name, res, err, hide) -> string`.
  - `P.usageText(claudeData, others, s) -> string`. `others` is a list of `{ id, name, res, err }` for the enabled non-Claude providers, in order.
  - `P.checkText(res, hide) -> string`.
  - `P.statusLabel(s) -> "Claude plan usage: "` when `claudeOnly`, else `"AI usage: "`.

- [ ] **Step 1: Add failing cases** to `tests/providers_spec.lua`:

```lua
local function at(y, m, d, h) return os.time({ year = y, month = m, day = d, hour = h or 12 }) end
local function day(y, m, d) return os.time({ year = y, month = m, day = d, hour = 0 }) end
t.eq(P.nextRenewal(14, at(2026, 10, 28)), day(2026, 11, 14), "next month")
t.eq(P.nextRenewal(28, at(2026, 10, 28, 15)), day(2026, 10, 28), "renews today")
t.eq(P.nextRenewal(31, at(2026, 11, 5)), day(2026, 11, 30), "30-day month")
t.eq(P.nextRenewal(31, at(2027, 2, 1)), day(2027, 2, 28), "February")
t.eq(P.nextRenewal(29, at(2028, 2, 10)), day(2028, 2, 29), "leap year")
t.eq(P.nextRenewal(31, at(2026, 12, 31, 23)), day(2026, 12, 31), "late on the day itself")
local g = P.grokPlan({ plan = "SuperGrok", renews_day = 14 }, at(2026, 10, 28))
t.eq(g.ok and g.plan .. "|" .. g.facts[1], "SuperGrok|Renews Nov 14", "Grok plan facts")
t.eq(P.grokPlan({ renews_day = 28 }, at(2026, 10, 28, 9)).facts[1], "Renews today", "renewal today")
t.eq(#P.grokPlan({}, at(2026, 10, 28)).facts, 0, "no day, no facts")
-- Claude-only text is exactly today's
local only = P.settings({})
local claude = { limits = { { label = "Current session", pct = 55.4 }, { label = "Week · all models", pct = 20 } } }
t.eq(P.usageText(claude, {}, only), "Session 55%, week 20%. Halfway there.", "Claude text unchanged")
t.eq(P.usageText({ limits = { { label = "Current session", pct = 85 } } }, {}, only), "Session 85%. Running hot!", "hot")
t.eq(P.usageText({ limits = { { label = "Current session", pct = 10 } } }, {}, only), "Session 10%. Plenty left!", "plenty")
t.eq(P.usageText(nil, {}, only), "I can't see your usage right now.", "no numbers")
-- several providers
local many = P.settings({ usage = { order = { "claude", "codex", "openrouter", "grok_plan" } } })
local others = { { id = "codex", name = "Codex", res = { ok = true, limits = { { label = "Week", pct = 41 } } } },
  { id = "openrouter", name = "OpenRouter", err = "Key not accepted" },
  { id = "grok_plan", name = "Grok", res = g } }
t.eq(P.usageText(claude, others, many), "Session 55%, week 20%. Halfway there. Codex: Week 41%. OpenRouter: Key not accepted. "
  .. "Grok: SuperGrok, renews Nov 14.", "every provider in order")
t.eq(P.usageText(nil, { others[1] }, P.settings({ usage = { order = { "codex" } } })), "Codex: Week 41%.", "Claude off")
t.eq(P.summary("Codex", { ok = true, blocked = true, limits = {} }, nil, {}), "Codex: blocked right now.", "blocked")
t.eq(P.summary("Codex", nil, nil, {}), "Codex: no numbers yet.", "nothing yet")
t.eq(P.summary("OpenRouter", { ok = true, credits = { { label = "This month", used = 18.4, limit = 50, pct = 36.8 } } }, nil, {}),
  "OpenRouter: This month $18.40 / $50.", "credit summary")
t.eq(P.summary("Codex", { ok = true, limits = { { label = "Week", pct = 41 } } }, nil, { Week = true }), "Codex: no numbers yet.",
  "hidden limits left out")
t.eq(P.checkText({ ok = true, limits = { { label = "Week", pct = 41 } } }, {}), "Working · Week 41%", "check: tightest")
t.eq(P.checkText({ ok = true, facts = { "12,000 credits left" } }, {}), "Working · 12,000 credits left", "check: fact")
t.eq(P.checkText({ ok = false, error = "Key not accepted" }, {}), "Key not accepted", "check: error")
t.eq(P.checkText(nil, {}), "Couldn't run the check", "check: nothing")
t.eq(P.statusLabel(only) .. "|" .. P.statusLabel(many), "Claude plan usage: |AI usage: ", "status label")
```

- [ ] **Step 2:** Run the Lua specs. Expected: FAIL on the new cases.
- [ ] **Step 3: Implement.**
  - Claude part: move today's `M.usageText` body into `providers.lua`. Skip hidden labels and capitalise the first letter of the joined parts, so today's output is unchanged. It applies only when `s.claudeOn`.
  - Summary order:
    1. `blocked` gives "blocked right now".
    2. The tightest visible item gives `label .. " " .. figure`.
    3. Otherwise, plan then facts, joined by ", ", with the first letter of each later part lowercased.
    4. When that leaves nothing (or there is no result), `err`, else "no numbers yet".
  - Sentences are joined with one space.
  - In `buddy.lua`, load `P` once. Then `M.usageText()` returns `P.usageText(usageData(), ClaudeUsage and ClaudeUsage.others and ClaudeUsage.others() or {}, P.settings(CFG))`. Both status lines use `P.statusLabel(...)`.
- [ ] **Step 4:** Run the Lua specs. Expected: PASS, including every existing buddy spec.
- [ ] **Step 5:** Commit `usage text and Grok renewal dates for every provider`.

### Task 4: Fetcher dispatcher, shared helpers and OpenRouter

**Files:**
- Create: `bin/ai-usage`, `bin/usage_common.py`, `bin/usage_openrouter.py`, `tests/test_ai_usage.py`

**Interfaces:**
- Produces, in `usage_common`:
  - `SECURITY = "/usr/bin/security"` and `URLOPEN = urllib.request.urlopen`. These are module attributes that tests patch.
  - `account() -> str`.
  - `keychain_key(provider: str) -> Optional[str]`: runs `security find-generic-password -s claude-buddy-<p> -a <account> -w`.
  - `class Fail(Exception)` with `error: str` and `retry_after: Optional[int]`.
  - `get_json(url, headers, errors: Dict[int, str]) -> dict`: 15 s timeout. Error mapping:
    - 429 → `Fail("Busy · showing last numbers", retry_after=header or 600)`.
    - A code in `errors` → `Fail(errors[code])`.
    - Any other HTTP code → `Fail("HTTP <code>")`.
    - URLError, timeout or OSError → `Fail("Offline")`.
    - Bad JSON → `Fail("Unexpected answer")`.
  - `money(x) -> "$1,284.20"`, from `"${:,.2f}"`.
- Produces, in `bin/ai-usage`: `main(argv, stdin) -> None`. It prints one JSON line with `provider` and `fetched_at`, then exits 0 through `out()`, the `bin/claude-usage` pattern.
  - Usage: `ai-usage <provider> [--key-stdin] [--budget N] [--team-id ID]`.
  - `FETCHERS = {"codex": (usage_codex, False), "openrouter": (usage_openrouter, True), "xai": (usage_xai, True)}`, where the flag says the provider needs a key. Codex and xAI land in Tasks 5–6; import them lazily so this task runs alone.
  - Errors:
    - Unknown provider → `"Unknown provider"`.
    - Bad arguments → `"Bad arguments"`.
    - A provider that needs a key gets none → `"No key saved"`.
    - Any other exception → `"Usage check failed"`.
  - It inserts its own folder on `sys.path` like `bin/buddy-task`.
- Produces: every provider module has `fetch(key: Optional[str], opts: dict) -> dict`, returning `ok`, `plan`, `limits`, `credits`, `facts`, and `blocked` where it applies. It raises `Fail`.
- OpenRouter: `URL = "https://openrouter.ai/api/v1/key"`. `normalize(data: dict, budget: Optional[float]) -> dict` takes the response's `data` object.

- [ ] **Step 1: Write the failing tests.** `tests/test_ai_usage.py` loads `bin/ai-usage` with `SourceFileLoader`, like `tests/test_claude_usage.py`. It points `usage_common.SECURITY` at `tests/fakes/security` with `FAKE_KEYCHAIN`. It patches `usage_common.URLOPEN` with a fake that records each `Request` and returns a canned body or raises `HTTPError`. It captures stdout from `main()`. Tests and their asserts:
  - `test_cap_bar_uses_limit_minus_remaining`: data `{"limit": 50, "limit_remaining": 31.6, "limit_reset": "monthly", "usage_monthly": 18.4, "usage_daily": 1.12}` → `credits == [{"label": "This month", "used": 18.4, "limit": 50, "pct": 36.8, "resets_at": None}]`. Compare `pct` with `assertAlmostEqual`. Also `limits == []` and `facts == []`.
  - `test_cap_labels`: `"daily"` → "Today", `"weekly"` → "This week", `None` → "Spending cap".
  - `test_budget_without_cap`: `{"limit": None, "usage_monthly": 12.5}` with budget 50 → credit `{"label": "This month", "used": 12.5, "limit": 50, "pct": 25.0}`.
  - `test_facts_only_without_cap_or_budget`: `facts == ["Today $1.12 · Month $18.40"]`, `credits == []`.
  - `test_free_tier_fact`: `is_free_tier: True` appends `"Free tier"` to facts.
  - `test_error_mapping`: 401 → "Key not accepted", 402 → "Out of credits or over the key's cap", 500 → "HTTP 500", URLError → "Offline", 429 with `Retry-After: 120` → error "Busy · showing last numbers" and `retry_after` 120. All give `ok: False` and `provider: "openrouter"`.
  - `test_key_from_stdin_is_trimmed`: stdin `"  sk-or-v1-testkey123\n"` → the recorded Authorization header is `"Bearer sk-or-v1-testkey123"`, and the fake `security` was never run (its `FAKE_KEYCHAIN` is empty and the result is still ok).
  - `test_key_from_keychain`: `FAKE_KEYCHAIN` holds service `claude-buddy-openrouter` under the current account. The request carries that key.
  - `test_key_never_printed`: for the 200, 401 and Offline cases, the printed line doesn't contain the key.
  - `test_no_key`: empty Keychain, no stdin → `{"ok": false, "error": "No key saved"}`.
  - `test_unknown_provider`: `main(["nope"])` → "Unknown provider".
- [ ] **Step 2:** Run `/usr/bin/python3 -m unittest tests.test_ai_usage -v`. Expected: errors (files missing).
- [ ] **Step 3: Implement** `usage_common.py`, `usage_openrouter.py` and `bin/ai-usage`.
  - Make `bin/ai-usage` executable.
  - Clamp `pct` to 0–100.
  - Round `used` to 2 decimals.
  - When `limit_remaining` is missing, use the usage field that matches the reset period.
- [ ] **Step 4:** Run the tests. Expected: PASS. Also run `tests.test_claude_usage` to confirm it still passes.
- [ ] **Step 5:** Commit `ai-usage: fetcher dispatcher and OpenRouter`.

### Task 5: Codex through `codex app-server`

**Files:**
- Create: `bin/usage_codex.py`, `tests/fakes/codex` (executable Python), `tests/test_usage_codex.py`

**Interfaces:**
- Consumes: `usage_common.Fail` and the `fetch(key, opts)` contract (Task 4).
- Produces:
  - `CODEX_DIRS`: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`.
  - `find_codex() -> Optional[str]`: searches `CODEX_DIRS` only, never `PATH`.
  - `ask(codex: str, timeout: float = 20) -> dict`: the `account/rateLimits/read` result. It raises `Fail`.
  - `normalize(rate: dict) -> dict`.
  - `label_for(mins: Optional[int], name: Optional[str]) -> str`.
- Protocol, one JSON object per line on stdin and stdout:
  1. Send `{"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "claude-buddy", "version": "1"}}}`.
  2. Send `{"method": "initialized"}`.
  3. Send `{"id": 2, "method": "account/rateLimits/read"}`.
  4. Read lines with `selectors` until there is a line with `"id": 2` or the deadline passes, skipping anything else.
  5. Kill the process in `finally`.
  - The child env is `os.environ` with `PATH` set to `CODEX_DIRS` joined. Don't use `account/usage/read`.
- Fake `tests/fakes/codex`:
  - It reads `FAKE_CODEX` JSON: `{"rate": {...}|null, "error": {"code", "message"}|null, "hang": bool, "noise": bool, "argv_file": path}`.
  - It writes its argv to `argv_file` and answers `initialize` with `{"id": 1, "result": {}}`.
  - With `noise`, it first prints `not json` and `{"method": "account/rateLimits/updated", "params": {}}`.
  - It answers id 2 with `result` or `error`. With `hang`, it never answers.

- [ ] **Step 1: Write the failing tests.** Tests load the module directly, set `CODEX_DIRS = [<tmp dir holding a copy of tests/fakes/codex named codex>]`, and set `FAKE_CODEX` via `mock.patch.dict(os.environ, …)`.
  - `test_primary_and_secondary_windows`: rate `{"rateLimits": {"planType": "pro", "primary": {"usedPercent": 41, "windowDurationMins": 10080, "resetsAt": 1900000000}, "secondary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1890000000}, "credits": {"hasCredits": True, "unlimited": False, "balance": "12000"}}}`. Expect:
    - `plan == "pro"`.
    - `limits == [{"label": "Week", "pct": 41.0, "resets_at": 1900000000, "severity": "normal"}, {"label": "5-hour", "pct": 12.0, "resets_at": 1890000000, "severity": "normal"}]`.
    - `facts == ["12,000 credits left"]`.
  - `test_null_windows_and_credits`: `primary: None, secondary: None, credits: None` → `limits == []`, `facts == []`, still `ok`.
  - `test_labels`: `label_for(10080, None) == "Week"`, `(300, None) == "5-hour"`, `(120, None) == "2-hour"`, `(2880, None) == "2-day"`, `(30, None) == "30-min"`, `(None, None) == "Limit"`, `(10080, "GPT-6 Sol") == "GPT-6 Sol · Week"`, `(10080, "codex") == "Week"`.
  - `test_by_limit_id_wins`: `rateLimitsByLimitId` with two snapshots (`limitName` "codex" and "GPT-6 Sol") gives limits from both, labelled per `label_for`. The mirrored `rateLimits` is not counted twice.
  - `test_reached_marks_fullest_window_critical`: `rateLimitReachedType: "rate_limit_reached"`, primary 100 and secondary 30 → primary severity `"critical"`, secondary `"normal"`. With `spendControlReached: True` and no window at 100, the highest window is critical.
  - `test_blocked`: top-level `ordinaryUsageAllowed: False` → `blocked is True`. A missing value or `None` gives no `blocked` key.
  - `test_unlimited_credits`: `{"unlimited": True}` → `facts == ["Unlimited credits"]`.
  - `test_signed_out`: error `{"code": -32000, "message": "not logged in"}` → `Fail("Signed out · open Codex")`. Other messages → "Codex didn't answer".
  - `test_hang_times_out`: `hang: True`, `ask(..., timeout=1)` → `Fail("Codex didn't answer")` within 3 s, and the child is gone.
  - `test_skips_noise_and_notifications`: `noise: True` still parses.
  - `test_finds_codex_without_PATH`: `PATH=/usr/bin:/bin` in env with `CODEX_DIRS` → found. With empty `CODEX_DIRS`, fetch fails with "Codex isn't installed".
  - `test_runs_app_server`: the `argv_file` holds `app-server`.
  - `test_never_reads_codex_auth`: the module source contains no `auth.json`.
- [ ] **Step 2:** Run `/usr/bin/python3 -m unittest tests.test_usage_codex -v`. Expected: errors.
- [ ] **Step 3: Implement** `bin/usage_codex.py`.
  - Format the credit balance with `{:,}` when it is a whole number, else `{:,.2f}`.
  - "Signed out" matches `auth|log ?in|sign|token|unauthori` case-insensitively.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then run `/usr/bin/python3 -I bin/ai-usage codex` once by hand and confirm it prints one `ok` line. Don't paste the real numbers anywhere.
- [ ] **Step 5:** Commit `ai-usage: Codex limits through codex app-server`.

### Task 6: xAI credits

**Files:**
- Create: `bin/usage_xai.py`, `tests/test_usage_xai.py`

**Interfaces:**
- Consumes: `usage_common.get_json`, `Fail` and `money` (Task 4).
- Produces:
  - `BASE = "https://management-api.x.ai/v1/billing/teams/{team}/"`.
  - `cents(v) -> Optional[float]`: takes `{"val": "123"}`, `"123"` or `123` and returns dollars. Anything else gives `None`.
  - `normalize(balance: dict, invoice: Optional[dict], limits: Optional[dict], budget: Optional[float]) -> dict`.
  - `fetch(key, opts)`:
    - `opts["team_id"]` must match `^[A-Za-z0-9-]{1,64}$`, else `Fail("Add your team ID")`.
    - It calls `prepaid/balance` (required), then `postpaid/invoice/preview` and `postpaid/spending-limits`. The last two are optional; any `Fail` other than auth is ignored.
    - 401 and 403 → "Needs a Management key, not an API key".

- [ ] **Step 1: Write the failing tests.** Use the patched `URLOPEN` from Task 4, routing on URL suffix.
  - `test_balance_sign`: balance `{"total": {"val": "-12345"}}` → `facts[0] == "$123.45 credits left"`.
  - `test_spend_against_effective_limit`: invoice `{"coreInvoice": {"amountAfterVat": {"val": "4000"}}}` and limits `{"spendingLimits": {"effectiveSl": {"val": "10000"}}}` → `credits == [{"label": "This month", "used": 40.0, "limit": 100.0, "pct": 40.0, "resets_at": None}]`.
  - `test_before_vat_fallback`: only `amountBeforeVat` → used from it.
  - `test_budget_when_no_limit`: no `effectiveSl`, budget 80 → limit 80.
  - `test_spend_fact_without_any_cap`: → `facts` contains `"This month $40.00"`, `credits == []`.
  - `test_optional_endpoints_may_fail`: invoice 404 → still ok with the balance fact.
  - `test_auth_errors`: 401 or 403 on balance → "Needs a Management key, not an API key".
  - `test_team_id_required`: missing or `"bad id!"` → "Add your team ID", and no request is made.
  - `test_cents_shapes`: `cents({"val": "250"}) == 2.5`, `cents("250") == 2.5`, `cents(250) == 2.5`, `cents({}) is None`, `cents("x") is None`.
  - `test_through_dispatcher`: `main(["xai", "--team-id", "team-test", "--key-stdin"], stdin="xai-testkey123\n")` gives `provider: "xai"`, and the key isn't printed.
- [ ] **Step 2:** Run `/usr/bin/python3 -m unittest tests.test_usage_xai -v`. Expected: errors.
- [ ] **Step 3:** Implement `bin/usage_xai.py`. Put a top comment saying it's built from xAI's published docs and untested against a live account.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `ai-usage: xAI credits from the Management API (untested live)`.

### Task 7: usage_alerts.lua — the red alert, once per window

**Files:**
- Create: `usage_alerts.lua`, `tests/usage_alerts_spec.lua`

**Interfaces:**
- Consumes: `P.level` and `P.settings` (Task 2).
- Produces:
  - `A.check(state, id, items, s) -> fires, state`. `items` are the visible items, already hide-filtered by the caller. `state` maps `id .. "|" .. label` to true once fired. It is changed in place and returned. A fire happens when the level is "hot" and the key isn't set. A key clears when the level is "ok". With `s.alert_red` off, it returns `{}` and leaves the state untouched.
  - `A.line(name, item, resetPhrase) -> string`.

- [ ] **Step 1: Write the failing spec:**

```lua
local P, A = dofile(dir .. "/providers.lua"), dofile(dir .. "/usage_alerts.lua")
local on, state = P.settings({ usage = { alert_red = true } }), {}
local fires; fires, state = A.check(state, "codex", { { label = "Week", pct = 91 } }, on)
t.eq(#fires, 1, "turning red fires"); t.eq(fires[1].label, "Week", "the item that fired"); t.ok(state["codex|Week"], "remembered")
t.eq(#A.check(state, "codex", { { label = "Week", pct = 95 } }, on), 0, "no repeat while red")
t.eq(#A.check(state, "codex", { { label = "Week", pct = 80 } }, on), 0, "yellow doesn't re-arm"); t.ok(state["codex|Week"], "still fired")
A.check(state, "codex", { { label = "Week", pct = 10 } }, on); t.eq(state["codex|Week"], nil, "a drop below yellow re-arms")
t.eq(#A.check(state, "codex", { { label = "Week", pct = 92 } }, on), 1, "fires again next window")
t.eq(#A.check({}, "codex", { { label = "Week", pct = 40, severity = "critical" } }, on), 1, "critical fires below red")
t.eq(#A.check({}, "openrouter", { { label = "This month", used = 46, limit = 50, pct = 92 } }, on), 1, "credits fire")
local quiet = {}
t.eq(#A.check(quiet, "codex", { { label = "Week", pct = 99 } }, P.settings({})), 0, "off by default"); t.eq(next(quiet), nil, "nothing stored")
t.eq(A.line("Codex", { label = "Week", pct = 91.4 }, "Resets Mon 9:00 AM"), "Heads up: Codex Week is at 91%. Resets Mon 9:00 AM.", "line")
t.eq(A.line("OpenRouter", { label = "This month", used = 46, limit = 50, pct = 92 }, ""), "Heads up: OpenRouter This month is at 92%.", "no reset")
```

- [ ] **Step 2:** Run the Lua specs. Expected: FAIL.
- [ ] **Step 3:** Implement `usage_alerts.lua`.
- [ ] **Step 4:** Run the Lua specs. Expected: PASS.
- [ ] **Step 5:** Commit `usage_alerts.lua: one red alert per limit per window`.

### Task 8: usage_poll.lua — run the fetchers on their own timers

**Files:**
- Create: `usage_poll.lua`, `tests/fakes/ai-usage` (executable Python), `tests/usage_poll_spec.lua`

**Interfaces:**
- Produces: `Poll.run(python, script, args, input, done, timeout)`.
  - It runs `python -I script <args…>` through `hs.task`. `input`, when non-nil, goes to stdin.
  - The env is `HOME`, `USER`, `LOGNAME`, `TMPDIR`, and `PATH = $HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`.
  - It calls `done(res)` exactly once:
    - with the decoded table;
    - with `{ ok = false, error = "Usage check failed" }` for output that isn't a JSON table;
    - with `{ ok = false, error = "Didn't answer" }` after `timeout` seconds (default 30), terminating the task.
- Produces: `Poll.new(opts) -> p`.
  - `opts`: `{ python, script, ids, argsFor(id) -> args, refreshFor(id) -> seconds, store = { get, set } (default hs.settings), onResult(id), timeout }`.
  - Fields: `p.results[id]` (last good result), `p.errors[id]` (string or nil), `p.running[id]` (task or nil), `p.waitUntil[id]`.
  - `p:start()` loads `store.get("claudeUsageWidget.provider." .. id)`. It fetches each id now unless the saved `fetched_at` is under 60 s old, then starts one `hs.timer.doEvery(refreshFor(id))` per id.
  - `p:refresh(id)`, `p:refreshAll()` and `p:stop()`.
  - A good result is saved to the store and clears `errors[id]`. A failure keeps `results[id]` and sets `errors[id]`. `retry_after` sets `waitUntil[id] = now + clamp(retry_after, 60, 3600)`.
- Fake `tests/fakes/ai-usage <id> [...]`:
  - `codex` → `{"ok": true, "provider": "codex", "fetched_at": <now>, "limits": [{"label": "Week", "pct": 41}]}`.
  - `openrouter --key-stdin` → `facts: ["stdin:yes"]` when the stdin line is `sk-or-v1-testkey123`, else `"stdin:no"`.
  - `busy` → `{"ok": false, "error": "Busy", "retry_after": 600}`.
  - `junk` → `not json`.
  - `slow` → sleep 5.

- [ ] **Step 1: Write the failing async spec.** Return a check function, as `tests/run.lua` allows. Use a memory store `{ get = function(k) return mem[k] end, set = function(k, v) mem[k] = v end }`. Expect:
  - `run` with stdin → `res.facts[1] == "stdin:yes"`.
  - `junk` → `"Usage check failed"`.
  - `slow` with timeout 1 → `"Didn't answer"`.
  - A poller over `{ "codex", "busy" }` → `results.codex.limits[1].pct == 41`, `mem["claudeUsageWidget.provider.codex"]` is saved, `errors.busy == "Busy"`, and `waitUntil.busy > os.time()`. A following `p:refresh("busy")` leaves `running.busy == nil`.
  - A second poller with `mem` seeded at `fetched_at = os.time()` → `running.codex == nil` right after `start()`, and the result is the seeded one.
  - Stop both pollers at the end.
- [ ] **Step 2:** Run the Lua specs. Expected: FAIL.
- [ ] **Step 3:** Implement `usage_poll.lua`, modelled on `refresh()` in `usage_widget.lua` and on `W.loadVoices` in `setup.lua` (timer guard).
- [ ] **Step 4:** Run the Lua specs. Expected: PASS within the runner's 10 s async budget.
- [ ] **Step 5:** Commit `usage_poll.lua: each AI on its own timer`.

### Task 9: Card colours and Claude settings from config

**Files:**
- Modify: `usage_widget.lua` (`barColor`, `isStale`, `REFRESH`, the Claude limit and credit rows in `M.elements`)
- Test: `tests/usage_card_spec.lua`

**Interfaces:**
- Consumes: `P.settings`, `P.level`, `P.visible` and `P.figure` (Task 2).
- Produces:
  - `S`, a module local equal to `P.settings(CFG)`. `M.inject` accepts `settings`.
  - `M.barColor(pct, severity)` maps `P.level` to `C.ok`, `C.warn` or `C.hot`.
  - `M.C`, for tests.
  - `isStale` uses `3 * S.providers.claude.refresh`.
  - `M.start` uses `S.providers.claude.refresh` for the fetch and token timers.
  - Claude's rows draw `P.visible(data, S.providers.claude.hide)`. Credits use `P.figure`, which gives the same strings as today.

- [ ] **Step 1: Add failing cases:**

```lua
local P = dofile(dir .. "/providers.lua")
W.inject({ settings = P.settings({}) })
t.ok(W.barColor(72) == W.C.warn and W.barColor(91) == W.C.hot and W.barColor(10) == W.C.ok, "default levels")
t.ok(W.barColor(10, "critical") == W.C.hot, "API severity wins")
W.inject({ settings = P.settings({ usage = { warn_at = 50, hot_at = 80 } }) })
t.ok(W.barColor(60) == W.C.warn and W.barColor(85) == W.C.hot, "the user's levels")
W.inject({ settings = P.settings({ usage = { providers = { claude = { hide = { "Week · all models" } } } } }), data = CLAUDE })
t.ok(not table.concat(texts((W.elements(now))), "|"):find("Week · all models", 1, true), "hidden Claude limit left off")
W.inject({ settings = P.settings({ usage = { providers = { claude = { refresh = 600 } } } }) })
t.ok(not W.isStale(now - 20 * 60, now), "slower Claude refresh, later grey")
W.inject({ settings = P.settings({}), data = CLAUDE })  -- then Task 1's assertion runs again unchanged
```
Move Task 1's text assertion so it runs after this last `inject`, as well as before.

- [ ] **Step 2:** Run the Lua specs. Expected: FAIL.
- [ ] **Step 3:** Implement. `usage_widget_spec.lua`'s stale cases must still pass under the defaults.
- [ ] **Step 4:** Run the Lua specs. Expected: PASS.
- [ ] **Step 5:** Commit `usage card: colour levels, hidden limits and Claude refresh from config`.

### Task 10: The "Other AIs" list, the lead provider, the click menu, live data and alerts

**Files:**
- Modify: `usage_widget.lua` (`M.elements`, `startDrag`, `M.start`, the Claude `refresh` callback, the wake watcher), `buddy.lua` (add `M.alert`)
- Test: `tests/usage_card_spec.lua`

**Interfaces:**
- Consumes: `P.*` (Tasks 2–3), `Poll.new`/`Poll.run` (Task 8), `A.check`/`A.line` (Task 7).
- Produces:
  - `M.others() -> { { id, name, res, err } … }` for every enabled non-Claude provider, in order. `grok_plan`'s `res` is `P.grokPlan(ps, os.time())`.
  - `M.current()` returns nil when Claude is off.
  - `M.otherRows = { { top, bottom, id } … }`, filled by `elements`.
  - `M.providerMenuItems(id) -> items` for `hs.menubar:setMenu`.
  - `M.inject` accepts `results` and `errors`, used in place of the poller's.
  - `ClaudeBuddy.alert(text)` in `buddy.lua` runs `say(text, true)`, then `Telegram.send(text)` when `Telegram and Telegram.running()`.
  - Settings key `claudeUsageWidget.alerts` holds the alert state.
- Layout:
  - **Claude on:** the Claude section exactly as today. Then, when `#S.rest > 0` and after Claude's error line, the list:
    - a 1 px `C.edge` divider and an 11 px dim "Other AIs";
    - one 22 px row per id in `S.rest`: the name in a 76 px column, a 4 px bar, and a 64 px right-aligned figure from `P.short(tightest)`, coloured by level or `C.dim` when stale.
    - With no tightest, the first fact goes in the figure slot in dim with no bar. `blocked` shows "Blocked" in `C.hot` with a full bar. No result shows "Checking…", or "—" when there is an error.
    - A 16 px note line follows when there is an error (`C.warn`), or when the result is stale ("From " .. `ageText`, dim).
  - **Claude off:** the header shows the lead's name and `(Plan · )age` (warn colour when stale). The lead's visible items go through `row()` and its facts as dim 11 px lines, followed by its error. There is no token strip, Buddy row, value row or breakdown. Then the list above for `S.rest`.
- Clicks: a click inside an `M.otherRows` band pops `providerMenuItems(id)` through `hs.menubar.new(false)`, like `valueMenu`. With Claude off, any other click runs `poller:refreshAll()` instead of opening the chart.
- Menu items:
  1. each visible item as `label .. "  " .. P.figure(item)`, plus `"  · " .. resetText(resets_at)` when there is a reset;
  2. `"-"`, then the facts, then the error, each with no `fn`;
  3. `"Updated " .. ageText(fetched_at)`;
  4. `"Check now"`, which runs `poller:refresh(id)`.
- Live wiring in `M.start`:
  - With `S.claudeOn`, start Claude's loop, the token scan and its timers as today. Otherwise start none of them; the updater, tick timer and watchers still start.
  - Create the poller for the enabled ids whose `P.byId(id).fetch` is true, with `argsFor = P.args(id, S.providers[id], false)` and `refreshFor = S.providers[id].refresh`. Its `onResult` runs the alerts, then `render()`.
  - The wake watcher also calls `poller:refreshAll()`.
- Alerts: after every good Claude result and every provider result, run `A.check(state, id, P.visible(res, hide), S)`. Save the state, then send each fire's `A.line(name, item, resetText(item.resets_at))` to `ClaudeBuddy.alert` when it exists.

- [ ] **Step 1: Add failing cases:**

```lua
local multi = P.settings({ usage = { order = { "claude", "codex", "openrouter", "grok_plan" },
  providers = { grok_plan = { plan = "SuperGrok", renews_day = 14 } } } })
local CODEX = { ok = true, provider = "codex", fetched_at = now - 30, limits = { { label = "5-hour", pct = 12 }, { label = "Week", pct = 41 } } }
W.inject({ settings = multi, data = CLAUDE, results = { codex = CODEX }, errors = { openrouter = "Key not accepted" } })
local s = table.concat(texts((W.elements(now))), "|")
local renew = P.grokPlan({ plan = "SuperGrok", renews_day = 14 }, now).facts[1]
t.ok(s:find("This week: Opus 30%|Other AIs|Codex|41% wk|OpenRouter|—|Key not accepted|Grok|" .. renew, 1, true), "Other AIs under Claude")
t.eq(#W.otherRows, 3, "one click band per row"); t.eq(W.otherRows[2].id, "openrouter", "bands in order")
t.ok(W.otherRows[1].bottom <= W.otherRows[2].top, "bands don't overlap")
local items = W.providerMenuItems("codex")
t.eq(items[1].title .. "|" .. items[2].title, "5-hour  12%|Week  41%", "menu lists every limit"); t.eq(items[#items].title, "Check now", "check now last")
t.eq(#W.others(), 3, "others for the buddy text"); t.eq(W.current(), CLAUDE, "Claude data while Claude is on")
W.inject({ settings = P.settings({ usage = { order = { "codex", "grok_plan" } } }), data = CLAUDE, results = { codex = CODEX } })
s = table.concat(texts((W.elements(now))), "|")
t.ok(s:find("^Codex|") and s:find("5-hour|12%", 1, true) and s:find("Other AIs|Grok", 1, true), "Codex leads when Claude is off")
t.ok(not s:find("Tokens · 24h", 1, true) and not s:find("Reading Claude", 1, true), "no Claude strip when Claude is off")
t.eq(W.current(), nil, "no Claude data when Claude is off")
W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, fetched_at = now - 905, limits = { { label = "Week", pct = 41 } } } } })
t.ok(table.concat(texts((W.elements(now))), "|"):find("From ", 1, true), "stale row says when it's from")
W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, blocked = true, fetched_at = now, limits = {} } } })
t.ok(table.concat(texts((W.elements(now))), "|"):find("Codex|Blocked", 1, true), "blocked says so")
W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, fetched_at = now, limits = { { pct = "x" }, "junk" } } } })
t.ok(pcall(W.elements, now), "junk saved result renders")
W.inject({ settings = P.settings({}), data = CLAUDE, results = {}, errors = {} })  -- Task 1's text assertion again
```

- [ ] **Step 2:** Run the Lua specs. Expected: FAIL.
- [ ] **Step 3:** Implement the layout, menu, clicks, poller, alerts and `M.alert`. Update the header comment of `usage_widget.lua` to describe the other AIs.
- [ ] **Step 4:** Run the Lua specs. Expected: PASS, including Task 1's unchanged Claude-only text.
- [ ] **Step 5:** Live check with the `testing-hammerspoon-widgets` skill. Load the worktree's module the way that skill describes, then:
  - add a temporary `usage = { order = { "claude", "codex" } }` to a copy of the config. The Codex row shows real numbers and the click menu opens.
  - check that without `usage`, the card looks as before.
  - restore the live setup afterwards.

  Don't save screenshots that show real numbers in the repo.
- [ ] **Step 6:** Commit `usage card: Other AIs list, lead provider, click menu, live checks and red alerts`.

### Task 11: keys.lua and the wizard's Lua side

**Files:**
- Create: `keys.lua`, `tests/keys_spec.lua`
- Modify: `setup.lua` (`runChecks`, `save`, `W.initial`, `W.open` message handling, `close`)
- Test: `tests/setup_spec.lua`

**Interfaces:**
- Produces, in `keys.lua`:
  - `K.security = "/usr/bin/security"` (tests swap it) and `K.ACCOUNT`.
  - `K.service(id) -> "claude-buddy-" .. id`.
  - `K.clean(s) -> trimmed string`.
  - `K.valid(key) -> bool`: 8–512 characters matching `^[%w%-_.:]+$`.
  - `K.has(id, done(bool))`: `find-generic-password -s -a`, without `-w`.
  - `K.save(id, key, done(ok))`: `security -i` with `add-generic-password -U -s <svc> -a <acct> -w <key>\n` on stdin, then reads it back with `-w` and compares.
  - `K.forget(id, done())`.
- Produces, in `setup.lua`:
  - `W.usageConfig(old, answers) -> table|nil`. It keeps only allowed fields:
    - `order`, `warn_at`, `hot_at`, `alert_red`;
    - per provider: `refresh`, `hide` (a list), `budget`, `team_id`, `plan`, `renews_day`.
    - It drops values equal to the defaults and empty tables. It starts from `old.providers`, so settings for providers that are turned off are kept. It returns nil when nothing is left.
  - `save()` sets `new.usage = W.usageConfig(cfg.usage, b.usage)` when `b.usage ~= nil`, else keeps `cfg.usage`.
  - `W.initial(cfg).usage = { order, warn_at, hot_at, alert_red, providers = { [id] = { refresh, hide = {sorted labels}, budget, team_id, plan, renews_day } }, known = P.LIST }`.
  - `runChecks` adds `res.usage.labels`, the Claude limit and credit labels.
  - `W.saveKeys(K, keys, removals, done(failedId|nil))`: saves each `keys[id]` in turn, stopping at the first failure, then forgets each `removals[id]`.
- Messages, handled in `W.open`:
  - `{ type = "providerCheck", id, key?, fields }`:
    - An unknown id is ignored.
    - `grok_plan` is answered with `P.grokPlan(fields)`.
    - Otherwise:
      - `key = K.clean(key)`. An invalid key gets `onProviderCheck{ id, ok = false, text = "That doesn't look like a key" }`.
      - A valid key goes into `W.keys[id]`.
      - With `k = key or W.keys[id]`, the check runs `Poll.run(python(), dir .. "/bin/ai-usage", P.args(id, fields, k ~= nil), k and k .. "\n", …)`. With no `k`, the fetcher reads the Keychain.
      - The page sends `budget` and `renews_day` as numbers or leaves them out.
    - The reply is `js("window.onProviderCheck", { id, ok, text = P.checkText(res, {}), labels = {…} })`. It never echoes a key.
  - `{ type = "keyRemove", id }` clears `W.keys[id]` and sets `W.removeKeys[id] = true`.
  - On open, after the page is up, `K.has` runs for each key provider, then `js("window.onKeys", { openrouter = bool, xai = bool })`.
  - `save` runs `W.saveKeys(K, W.keys, W.removeKeys, …)` before the Telegram branch. A failure gives `onSaveFailed{ text = "Couldn't put the " .. name .. " key in your Keychain. Try Save again." }`.
  - `close()` clears `W.keys` and `W.removeKeys`.

- [ ] **Step 1: Write the failing specs.**
  - In `tests/keys_spec.lua`, use a fake `security` shell script modelled on the one in `telegram_spec.lua`. It stores per service in `$D/<service>`, writes its args to `$D/args`, handles `-i` by parsing `-s` and `-w` from the stdin line, exits 0 for `find-generic-password` without `-w` when the file exists, and supports `delete-generic-password`.
  - `keys_spec.lua` asserts, async:

```lua
t.ok(K.valid("sk-or-v1-testkey123") and not K.valid("has space1") and not K.valid("short") and not K.valid(("a"):rep(600))
  and not K.valid("sk'quote1234"), "key shapes"); t.eq(K.clean("  sk-or-v1-testkey123\n"), "sk-or-v1-testkey123", "trimmed")
-- async: save → ok true; has openrouter → true; has xai → false; args file has "-s claude-buddy-openrouter" and no "testkey123";
-- forget → has → false
```
  - `setup_spec.lua` asserts:

```lua
S.save(tmp, {}, { chatter = "normal" }); t.eq(dofile(tmp .. "/config.lua").usage, nil, "no usage answers, no usage table")
S.save(tmp, {}, { chatter = "normal", usage = { order = { "claude" }, warn_at = 70, hot_at = 90, alert_red = false,
  providers = { claude = { refresh = 300, hide = {} } } } })
t.eq(dofile(tmp .. "/config.lua").usage, nil, "all defaults write nothing")
S.save(tmp, {}, { chatter = "normal", usage = { order = { "claude", "codex", "grok_plan" }, warn_at = 60, hot_at = 85, alert_red = true,
  providers = { claude = { refresh = 300, hide = { "Week · Sonnet" } }, codex = { refresh = 300 },
    openrouter = { refresh = 900, budget = 50, key = "sk-or-v1-testkey123" }, grok_plan = { plan = "SuperGrok", renews_day = 14 } } } })
local u = dofile(tmp .. "/config.lua").usage
t.eq(table.concat(u.order, ","), "claude,codex,grok_plan", "order saved"); t.eq(u.warn_at .. "/" .. u.hot_at, "60/85", "levels saved")
t.eq(u.alert_red, true, "alert saved"); t.eq(u.providers.claude.hide[1], "Week · Sonnet", "hidden labels saved")
t.eq(u.providers.claude.refresh, nil, "default refresh dropped"); t.eq(u.providers.codex, nil, "an all-default provider dropped")
t.eq(u.providers.openrouter.budget, 50, "budget kept while OpenRouter is off"); t.eq(u.providers.grok_plan.renews_day, 14, "renewal day")
t.ok(not io.open(tmp .. "/config.lua"):read("a"):find("testkey123", 1, true), "a key never reaches config.lua")
local back = S.initial(dofile(tmp .. "/config.lua")).usage
t.eq(table.concat(back.order, ","), "claude,codex,grok_plan", "round trip order"); t.eq(back.providers.claude.hide[1], "Week · Sonnet", "round trip hide")
t.eq(table.concat(S.initial({}).usage.order, ","), "claude", "wizard starts Claude only"); t.eq(#S.initial({}).usage.known, 5, "every provider offered")
S.save(tmp, { usage = { alert_red = true } }, { chatter = "normal" }); t.eq(dofile(tmp .. "/config.lua").usage.alert_red, true, "kept when the page sends none")
-- W.saveKeys with a stub K: saved.openrouter == "k1", forgot.xai == true, failed == nil; a stub whose save fails → failed == "openrouter"
```

- [ ] **Step 2:** Run the Lua specs. Expected: FAIL.
- [ ] **Step 3:** Implement `keys.lua` and the `setup.lua` changes.
- [ ] **Step 4:** Run the Lua specs. Expected: PASS.
- [ ] **Step 5:** Commit `wizard: provider checks, keys held until Save and written to the Keychain`.

### Task 12: The two wizard steps in setup.html

**Files:**
- Modify: `setup.html`
- Create: `tests/test_setup_page.py`

**Interfaces:**
- Consumes:
  - `INIT.usage` (Task 11).
  - The messages `providerCheck` and `keyRemove`.
  - The callbacks `window.onProviderCheck`, `window.onKeys` and `window.onChecks` (which now carries `usage.labels`).
- Produces:
  - `collect().usage = { order, warn_at, hot_at, alert_red, providers }`. No keys appear anywhere in `state` or `collect()`.
  - Section `data-step` names: `checks` (the existing second section), then new `ais` and `card`.
- Step "ais", titled "Which AIs do you use?". It follows the mockup at https://claude.ai/artifact/PULmRCeuwnBTbeA2ds3PzX and reuses `.check`, `.pill`, `.btn.small` and the inputs. Each row has an on/off checkbox, the name, a hint by kind and a pill.
  - Claude's pill copies the `checks` result.
  - Codex is checked when the step opens.
  - **Key rows:**
    - A key row shows a password input with Check. Check posts `providerCheck` with `key`, then clears the input.
    - When `onKeys` says a key is saved, the row shows "Key saved" with Replace and Remove instead, and it is checked from the Keychain when the step opens.
    - Remove posts `keyRemove` and says "Removed when you hit Save".
    - OpenRouter and xAI also have a budget number field ("Monthly budget, used only when the key has no cap"). xAI has a team ID field.
  - **The Grok row** has a plan name input and a day select (1–31). It posts `providerCheck` on change and shows the reply in its pill.
  - Next is refused with a hint when nothing is on.
- Step "card", titled "Set up your card". It covers:
  - the enabled providers in order. Claude is pinned on top when on. The others have up/down buttons.
  - a refresh select per provider from `known[i].choices`, labelled in minutes.
  - one checkbox per label from the provider's latest check (`state.labels[id]`), checked unless hidden. Before a check it says "Its limits show up after the first check." Grok has no checkboxes.
  - yellow (50–95) and red (60–100) sliders in the `.dial` style. Red stays at least 5 above yellow.
  - "Tell me when one turns red" with the hint "I say it out loud, and on Telegram if you've paired it. Once per limit until it drops back."
- `show()`:
  - Replace `step === 1` with `dataset.step === "checks"`.
  - Opening `ais` checks Codex and any saved-key rows.
  - Opening `card` re-renders from `state`.
- The summary adds two rows: "AIs on the card" (names in order) and "Red alerts" (On or Off).

- [ ] **Step 1: Write the failing test** `tests/test_setup_page.py`, modelled on `tests/test_whatsnew_page.py`:
  - `test_steps_found_by_name`: the page contains `data-step="checks"`, `data-step="ais"` and `data-step="card"`, and not `step === 1`.
  - `test_message_types`: the set of `post({ type: "…"` includes `providerCheck` and `keyRemove`.
  - `test_no_innerHTML`: `innerHTML` doesn't appear.
  - `test_keys_not_in_collect`: the `collect()` body has no `key`.
  - `test_script_parses`: under `node --check`, with `/*__INIT__*/null` replaced by `json.dumps` of a minimal INIT that carries `usage`. Skip it when there is no node.
- [ ] **Step 2:** Run `/usr/bin/python3 -m unittest tests.test_setup_page -v`. Expected: FAIL.
- [ ] **Step 3:** Implement the two sections, their CSS (reuse existing classes and add only what's missing), the JS, and the summary rows.
- [ ] **Step 4:** Run the page test and the Lua specs. Expected: PASS.
- [ ] **Step 5:** Live check of the wizard (`testing-hammerspoon-widgets`):
  - Open it from the worktree. Step through both new steps; Codex should show "Working · …".
  - Paste a made-up key in OpenRouter → "Key not accepted".
  - Press "Not now" so nothing is saved.
  - Confirm the window fits at 640×752, and that the steps scroll rather than overflow.
- [ ] **Step 6:** Commit `wizard: pick your AIs and set up the card`.

### Task 13: Docs, full test run and the final review

**Files:**
- Modify: `config.example.lua` (document `usage`, after `plan_price`), `README.md` (feature tour line), and the header comment of `setup.lua`

- [ ] **Step 1:** Document the `usage` table in `config.example.lua` with the spec's example. Mark everything optional, and say that keys live in the Keychain and are set in the wizard. Add a README line on usage from Codex, OpenRouter, xAI credits and a Grok plan.
- [ ] **Step 2:** Run everything:
  - `/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests` → first line `N passed, 0 failed`;
  - `/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py'` → `OK`.
- [ ] **Step 3:** Privacy sweep with the `auditing-public-repos-for-personal-data` skill over the branch diff. There must be no real numbers, keys, team IDs or names.
- [ ] **Step 4:** Commit `docs: usage from every AI`.
- [ ] **Step 5:** Run one whole-branch review (superpowers:requesting-code-review) and fix what it confirms.
- [ ] **Step 6:** Tell the owner what works, what's stubbed (xAI is untested live), and what each provider needs:
  - Codex needs nothing.
  - OpenRouter needs a key.
  - Grok needs a plan name and renewal day.

  Offer to run the wizard with them to turn on Codex, Grok and the red alert in their own config.lua.
  Then ask before merging or releasing, per `coordinating-buddy-releases`.

---

**Calls this plan makes that the spec left open:**
- Codex reads only `account/rateLimits/read` and skips the "tokens today" fact.
- A Codex "limit reached" marks the fullest window critical.
- OpenRouter's `resets_at` is null, since the label says the period.
- When Claude is on, it always takes the full section and sits pinned at the top of the order.
- With Claude off, a click outside the rows re-checks instead of opening the chart.
- A turned-on list with nothing in it means Claude only.
- A removed key is deleted at Save, not at once.
- A well-formed key is kept for Save even when its check fails.
- `blocked` changes the row and the text but isn't an alert by itself.
