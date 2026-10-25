# API Value Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a card row that shows the API dollar value of your Claude use for a chosen period, a "× your plan" multiple, and a persistent fun comparison that Buddy writes and says out loud when spending has moved enough.

**Architecture:** `bin/claude-tokens` already tallies hourly API dollars and the older-history archive. It gains pure functions that compute six periods' totals (with the chart History tab's merge rule), past-period spreads and paid amounts, and prints them in its summary as `periods`. The card (`usage_widget.lua`) passes the plan's session and week start times in, renders the row, and owns the comparison state through a new pure module `value.lua`. Comparisons come from `brain.lua` (new `B.compare`, reached through `ClaudeBuddy.compare`) or from the built-in list in `comparisons.lua`.

**Tech Stack:** Hammerspoon Lua (`hs.canvas`, `hs.menubar`, `hs.settings`), Python 3 standard library (must run on macOS's `/usr/bin/python3`).

**Spec:** `docs/superpowers/specs/2026-10-24-api-value-row-design.md`

## Global Constraints

- Python stays compatible with macOS's bundled Python 3.9: no `X | None`, no `match`.
- Prices only from `PRICES` / `price_for()` in `bin/claude-tokens`. Period sums add up the `$` already stored in tallies (index 5); no new cost formula. If the companion branch's `usage_cost()` is on main when you start, any new cost math must call it.
- Buddy's tally: `tokens.json["buddy"][hour] = {"m": {model: [in, out, write, read, replies, $]}, "k": …, "n": …}`. Read it if present; never require it.
- All dollars are US dollars.
- Content rule for comparisons (hard): everyday, light, all-ages subjects only. Never politics or social issues from any side, sexuality or gender topics, religion, disasters, tragedies, violence or crime, real private people, or anything from the user's screen, files or work.
- Public repo: no personal names, session names or real usage figures in code, tests, docs or screenshots.
- `render()` change is ONE inserted block between the credits loop and the "This week:" line. The companion branch inserts a Buddy bar under the "24h" line; don't touch that spot.
- Work only in the worktree `.claude/worktrees/api-value` on branch `api-value-row`. Never push, merge into main, or run `tools/release`. The live widget runs from the main checkout.
- Lua tests: `R=$PWD; timeout 60 hs -c "return dofile('$R/tests/run.lua')('$R')"`. Expected last summary line: `N passed, 0 failed`.
- Python tests: `/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py' -v`. Expected: `OK`.

## Review Focus

1. **A user with no older history, no billing.json, no `plan_price`, no brain and no weekly limit in the plan data** (new install, card only): the row must still show every period from hourly logs (Week from Monday), hide the multiple, and use the built-in list. Tests in Task 1 (`period starts local`, `None` week start) and Task 6 (`row lines with nothing but hourly tallies`).
2. **A brain reply that isn't usable** (prose instead of JSON, price 0 or negative, missing `{n}`, a blocked word, a 600-character line): must fall back to the built-in list, never show raw model text. Tests in Task 3 (`fill rejects`) and Task 5 (`parseComparison rejects`).
3. **Huge and tiny amounts**: $0.03 in a fresh session and $250,000 all-time must both produce a readable line (count for cheap things, percent for expensive ones, no "0 lattes", no "1e-07%"). Test in Task 3 (`fill formats extremes`).
4. **Clock and calendar edges**: a period starting at local midnight on a DST change day, and a month rollover at 23:59→00:00 must neither double-count an hour nor keep last month's comparison. Tests in Task 1 (`period starts across DST`) and Task 3 (`due on rollover`).
5. **A year of hourly data**: `claude-tokens` runs every 5 minutes under `nice`; computing all periods and spreads must take under 0.3 s for 9,000 hourly entries. Test in Task 2 (`periods is fast on a year of hours`).

---

### Task 1: Period starts and the History merge rule (Python)

**Files:**
- Modify: `bin/claude-tokens` (new functions after `archive_view`)
- Create: `tests/test_claude_tokens.py` (load the script with `SourceFileLoader`, as `tests/test_claude_usage.py` does)

**Interfaces:**
- Produces:
  - `value_records(hours: dict, archive: Optional[dict]) -> List[Tuple[int, float]]`: `(t, dollars)` per record. A port of `historyRecords()` in `chart.html`: per UTC day, if the archive day's 4-type token total is > 0 and the logged hours' 4-type total for that day is `< total * 0.99`, the archive day replaces that day's hours, as one record at `utc_day + 43200`; otherwise the hours stand. Add a comment in both places pointing at the other.
  - `period_starts(now: float, session_start: Optional[int], week_start: Optional[int]) -> Dict[str, int]`: keys `session, today, week, month, ytd, all`. `session` = `session_start` or `now - 5*3600`; `today` = local midnight; `week` = `week_start` or the latest local Monday 00:00; `month` = local 1st 00:00; `ytd` = local Jan 1 00:00; `all` = 0.
  - `sum_value(records, start: int, end: float) -> float`: sum of dollars for `start <= t < end` (whole buckets; no prorating).

- [ ] **Step 1: Write the failing tests**

```python
def test_archive_replaces_thin_logged_day(self):
    # day 2026-09-01 UTC: logs hold 100 tokens, archive 1000 tokens → archive wins
    recs = cli.value_records(hours_with(day="2026-09-01", tokens=100, dollars=1.0),
                             archive_with(day="2026-09-01", tokens=1000, dollars=9.0))
    self.assertEqual(sum(d for _, d in recs), 9.0)

def test_logs_kept_when_they_hold_as_much(self):
    recs = cli.value_records(hours_with(day="2026-09-01", tokens=1000, dollars=10.0),
                             archive_with(day="2026-09-01", tokens=1000, dollars=9.0))
    self.assertEqual(sum(d for _, d in recs), 10.0)

def test_no_archive_means_hours_only(self): ...   # archive None → one record per hour

def test_period_starts_local(self):
    with tz("America/Edmonton"):
        now = local(2026, 10, 24, 15, 30)
        s = cli.period_starts(now, None, None)
        self.assertEqual(s["today"], local(2026, 10, 24, 0, 0))
        self.assertEqual(s["week"], local(2026, 10, 19, 0, 0))   # Monday
        self.assertEqual(s["month"], local(2026, 10, 1, 0, 0))
        self.assertEqual(s["ytd"], local(2026, 1, 1, 0, 0))
        self.assertEqual(s["session"], now - 5 * 3600)
        self.assertEqual(cli.period_starts(now, 111, 222)["session"], 111)

def test_period_starts_across_dst(self):
    with tz("America/Edmonton"):
        now = local(2026, 11, 1, 12, 0)                 # DST ends 2026-11-01 02:00
        self.assertEqual(cli.period_starts(now, None, None)["today"], local(2026, 11, 1, 0, 0))

def test_sum_value_whole_buckets(self):
    recs = [(1000, 1.0), (4600, 2.0), (8200, 4.0)]
    self.assertEqual(cli.sum_value(recs, 4600, 8200), 2.0)
```

`tz()` sets `TZ` and calls `time.tzset()`, restoring both on exit. `hours_with`/`archive_with` build the `tokens.json` shapes (`hours[str(epoch)] = {"m": {model: [in, out, write, read, replies, $]}, "s": []}`; `archive["days"][date] = {"m": {model: [...6]}, "a": [msgs, sessions, tools]}`).

- [ ] **Step 2: Run to verify failure**

Run: `/usr/bin/python3 -m unittest tests.test_claude_tokens -v`
Expected: FAIL / AttributeError on `value_records`.

- [ ] **Step 3: Implement the three functions in `bin/claude-tokens`**

Local calendar math via `time.localtime` / `time.mktime` with `tm_isdst=-1`.

- [ ] **Step 4: Run to verify pass**

Run: `/usr/bin/python3 -m unittest tests.test_claude_tokens -v`
Expected: OK.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-tokens tests/test_claude_tokens.py chart.html
git commit -m "claude-tokens: period starts and the History tab's day merge rule"
```

---

### Task 2: Spreads, paid amounts and the `periods` summary (Python)

**Files:**
- Modify: `bin/claude-tokens` (new functions; `main()` argument parsing and summary)
- Test: `tests/test_claude_tokens.py`

**Interfaces:**
- Consumes: Task 1's `value_records`, `period_starts`, `sum_value`.
- Produces:
  - `past_totals(records, key: str, starts: Dict[str, int], now: float) -> List[float]`: totals of past periods with spending (> 0), excluding the current one. `session`: back-to-back 5-hour windows ending at `starts["session"]`, over the last 90 days. `today`: the previous local days, last 90. `week`: back-to-back 7-day windows ending at `starts["week"]`, last 90 days. `month`, `ytd`, `all`: every past local calendar month with data.
  - `spread(totals: List[float]) -> Optional[float]`: population standard deviation when `len(totals) >= 5`, else `None`.
  - `paid_between(billing: Optional[dict], plan_price: Optional[float], start: int, end: float) -> Optional[float]`: each charge spread evenly over its days from `from` up to but **not including** `to` (missing `to` = one month after `from`, as in `chart.html`); days with no charge use `plan_price / days_in_that_month` when `plan_price` is set and cost 0 otherwise; a part-day period takes its share of the day. Returns `None` if nothing covers any of the period.
  - `periods(hours, archive, buddy, billing, plan_price, now, session_start, week_start) -> dict`: `{"first": int|None, "has_buddy": bool, "list": {key: {"from": int, "value": float, "buddy": float, "paid": float|None, "spread": float|None}}}` for the six keys. `value` excludes Buddy; `buddy` is Buddy's dollars in the same window (0.0 without the key). Round dollars to 4 places.
  - `main()`: new optional args `--session-start EPOCH`, `--week-start EPOCH`, `--plan-price DOLLARS`. Reads `billing.json` from `OUT_DIR` if present (ignore it if unreadable). Adds `"periods": periods(...)` to the printed summary. `tokens.json` is unchanged.

- [ ] **Step 1: Write the failing tests**

```python
def test_spread_needs_five(self):
    self.assertIsNone(cli.spread([1, 2, 3, 4]))
    self.assertAlmostEqual(cli.spread([2, 4, 4, 4, 5, 5, 7, 9]), 2.0)

def test_past_days_skip_today_and_empty_days(self): ...   # 3 past days with $, 1 empty, today → [a, b, c]

def test_paid_to_is_exclusive(self):
    billing = {"charges": [
        {"date": "2026-03-04", "amount": 31.0, "from": "2026-03-04", "to": "2026-04-04"},
        {"date": "2026-04-04", "amount": 30.0, "from": "2026-04-04", "to": "2026-05-04"}]}
    # 2026-04-04 belongs to the second charge only: $1.00, not $2.00
    self.assertAlmostEqual(cli.paid_between(billing, None, local(2026, 4, 4), local(2026, 4, 5)), 1.0)

def test_paid_gap_uses_plan_price(self): ...   # day with no charge, plan_price 31 in a 31-day month → 1.0
def test_paid_none_when_nothing_covers(self):
    self.assertIsNone(cli.paid_between(None, None, 0, 86400))

def test_periods_shape_and_buddy(self):
    p = cli.periods(hours, None, {"%d" % h: {"m": {"claude-haiku-5-5": [1, 1, 0, 0, 1, 0.5]}, "k": {}, "n": 1}},
                    None, None, now, None, None)
    self.assertTrue(p["has_buddy"])
    self.assertEqual(set(p["list"]), {"session", "today", "week", "month", "ytd", "all"})
    self.assertAlmostEqual(p["list"]["today"]["buddy"], 0.5)

def test_main_prints_periods(self): ...   # run main() with OUT_DIR and log dirs pointed at a tmpdir; summary has "periods"

def test_periods_is_fast_on_a_year_of_hours(self):
    hours = {str(h): {"m": {"claude-opus-5-5": [1, 1, 1, 1, 1, 0.01]}, "s": []}
             for h in range(start, start + 9000 * 3600, 3600)}
    t0 = time.time(); cli.periods(hours, None, None, None, 100.0, now, None, None)
    self.assertLess(time.time() - t0, 0.3)
```

Check how `main()` finds `OUT_DIR` and the log roots (`log_files()`, `CLAUDE_CONFIG_DIR`) and point them at a temp dir in `test_main_prints_periods` the same way.

- [ ] **Step 2: Run to verify failure**

Run: `/usr/bin/python3 -m unittest tests.test_claude_tokens -v`
Expected: FAIL on the new tests.

- [ ] **Step 3: Implement the functions and `main()` changes**

Bucket records once (for example by local day index and month key) so the past totals don't rescan every record per window.

- [ ] **Step 4: Run to verify pass**

Run: `/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py' -v`
Expected: OK.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-tokens tests/test_claude_tokens.py
git commit -m "claude-tokens: period totals, spreads and what you paid, in the summary"
```

---

### Task 3: `value.lua`, the row's logic

**Files:**
- Create: `value.lua`
- Create: `tests/value_spec.lua`

**Interfaces:**
- Consumes: the `periods` summary from Task 2 (`p = periods.list[key]`).
- Produces (module table `V`):
  - `V.PERIODS`: `{ {key="session",label="Session"}, {key="today",label="Today"}, {key="week",label="Week"}, {key="month",label="Month"}, {key="ytd",label="Year to date"}, {key="all",label="All time"} }`
  - `V.figure(p, includeBuddy) -> number`: `p.value + (includeBuddy and p.buddy or 0)`.
  - `V.money(x) -> string`: `< 100` → `"$26.40"`; `>= 100` → `"$1,284"` (commas, no cents).
  - `V.multiple(p, figure) -> string|nil`: `string.format("%.1f× your plan", figure / p.paid)` when `p.paid` is a number > 0, else nil.
  - `V.threshold(p, figure) -> number`: `p.spread` when it's a number > 0, else `math.max(1, 0.25 * figure)`.
  - `V.due(saved, p, figure) -> "new"|"rollover"|nil`. `saved` = `{from, at, text}` or nil. If `saved` exists and `saved.from ~= p.from` → `"rollover"` (the caller clears that period's line, then calls `V.due(nil, p, figure)` again). Otherwise `at` = `saved and saved.at or 0`, and the result is `"new"` when `math.abs(figure - at) >= V.threshold(p, figure)`, else nil.
  - `V.fill(reply, figure) -> string|nil`. `reply = {emoji, thing, price, count, part}` (the shape both the brain and the built-in list return); `price` > 0. If `price <= figure`: use `count`, `n` = `math.floor(figure / price)` with commas. Otherwise use `part`, `n` = `figure / price * 100` as a percent with two significant digits and no exponent (`"0.0000041%"`, `"0.50%"`). The chosen string must contain `{n}`. Result `emoji .. " " .. text`, max 90 characters; anything else → nil.
  - `V.allowed(text) -> boolean`: a keyword check on comparison text. (Removed before release: the content rule lives only in the brain prompt.)

- [ ] **Step 1: Write the failing tests** (`tests/value_spec.lua`, `return function(t, dir) local V = dofile(dir .. "/value.lua") … end`)

```lua
t.eq(V.money(26.4), "$26.40", "money under 100")
t.eq(V.money(1284.2), "$1,284", "money with commas")
t.eq(V.multiple({ paid = 200 }, 1284), "6.4× your plan", "multiple")
t.eq(V.multiple({ paid = nil }, 1284), nil, "no multiple without paid")
t.eq(V.threshold({ spread = 12 }, 50), 12, "spread wins")
t.eq(V.threshold({}, 2), 1, "floor of $1")
t.eq(V.threshold({}, 400), 100, "25% without history")
t.eq(V.due(nil, { from = 10, spread = 5 }, 6), "new", "first one when figure passes threshold")
t.eq(V.due(nil, { from = 10, spread = 5 }, 4), nil, "nothing below threshold")
t.eq(V.due({ from = 10, at = 20 }, { from = 10, spread = 5 }, 24), nil, "small move keeps the line")
t.eq(V.due({ from = 10, at = 20 }, { from = 10, spread = 5 }, 25), "new", "one spread moves it")
t.eq(V.due({ from = 10, at = 20 }, { from = 99, spread = 5 }, 2), "rollover", "due on rollover")
local latte = { emoji = "☕", thing = "latte", price = 6, count = "That's {n} lattes", part = "{n} of a latte" }
t.eq(V.fill(latte, 1284), "☕ That's 214 lattes", "count")
t.eq(V.fill(latte, 0.03), "☕ 0.50% of a latte", "fill formats extremes: tiny")
t.eq(V.fill({ emoji = "🏙️", thing = "skyscraper", price = 1e9, count = "{n} skyscrapers", part = "{n} of a skyscraper" }, 41),
  "🏙️ 0.0000041% of a skyscraper", "fill formats extremes: huge price")
t.eq(V.fill({ emoji = "x", thing = "x", price = 6, count = "no placeholder", part = "{n}" }, 100), nil, "fill rejects: no {n}")
t.eq(V.fill({ emoji = "x", thing = "x", price = 0, count = "{n}", part = "{n}" }, 100), nil, "fill rejects: zero price")
t.ok(not V.allowed("That's 3 election campaigns"), "blocked topic")
t.ok(V.allowed("That's 214 lattes"), "everyday topic allowed")
t.ok(V.allowed("3 warm pretzels and a transit pass"), "short words match whole words only")
```

- [ ] **Step 2: Run to verify failure**

Run: `R=$PWD; timeout 60 hs -c "return dofile('$R/tests/run.lua')('$R')"`
Expected: FAIL lines for `value`.

- [ ] **Step 3: Implement `value.lua`**

- [ ] **Step 4: Run to verify pass** (same command; `0 failed`)

- [ ] **Step 5: Commit**

```bash
git add value.lua tests/value_spec.lua
git commit -m "value.lua: money, plan multiple, when a new comparison is due, filling it in"
```

---

### Task 4: `comparisons.lua`, the built-in list

**Files:**
- Create: `comparisons.lua`
- Create: `tests/comparisons_spec.lua`

**Interfaces:**
- Consumes: `V.fill`, `V.allowed` from Task 3.
- Produces:
  - `C.LIST`: about 80 entries `{ thing = "latte", emoji = "☕", price = 6, count = "That's {n} lattes", part = "{n} of a latte" }`, spread from about $2 to about $2,000,000,000 (coffees, pizzas, sneakers, bikes, cars, cabins, private jets, stadiums, skyscrapers as construction costs). US prices, everyday subjects only.
  - `C.pick(figure: number, recent: {string}) -> entry`: returns one `C.LIST` entry as is (the same shape `V.fill` takes). Candidates: things you'd get 1 to 500 of (`figure / 500 <= price <= figure`), plus things the amount is 0.000001% to 1% of (`figure * 100 <= price <= figure * 1e8`). If there are none, the cheapest thing. Pick at random among candidates not in `recent`; when every candidate is recent, take the one used longest ago (`recent[1]` is the newest).

- [ ] **Step 1: Write the failing tests**

```lua
local C = dofile(dir .. "/comparisons.lua")
local V = dofile(dir .. "/value.lua")
t.ok(#C.LIST >= 75, "about 80 things")
for _, c in ipairs(C.LIST) do
  t.ok(V.allowed(c.count) and V.allowed(c.part), "allowed: " .. c.thing)
  t.ok(c.count:find("{n}", 1, true) and c.part:find("{n}", 1, true), "placeholders: " .. c.thing)
end
for _, fig in ipairs({ 0.02, 3, 26, 1284, 25000, 250000 }) do
  t.ok(V.fill(C.pick(fig, {}), fig) ~= nil, "fills at $" .. fig)
end
local r1 = C.pick(26, {}); local r2 = C.pick(26, { r1.thing })
t.ok(r1.thing ~= r2.thing, "avoids recent")
-- exhaustion: every thing recent → least recently used comes back
local all = {}; for i = #C.LIST, 1, -1 do all[#all + 1] = C.LIST[i].thing end
t.ok(C.pick(26, all) ~= nil, "reuses when all are recent")
```

- [ ] **Step 2: Run to verify failure** (Lua test command; FAIL lines for `comparisons`)
- [ ] **Step 3: Implement `comparisons.lua`**
- [ ] **Step 4: Run to verify pass** (`0 failed`)
- [ ] **Step 5: Commit**

```bash
git add comparisons.lua tests/comparisons_spec.lua
git commit -m "comparisons.lua: built-in everyday things for when there's no brain"
```

---

### Task 5: Buddy's brain writes comparisons

**Files:**
- Modify: `brain.lua` (new `B.compare`, `B.parseComparison`)
- Modify: `buddy.lua` (export `M.compare`)
- Create: `tests/brain_compare_spec.lua`

**Interfaces:**
- Consumes: `dispatch()` in `brain.lua`; kind `"quip"` (no tools, one turn, low effort in `bin/buddy-agent`; no Python change).
- Produces:
  - `B.parseComparison(text) -> table|nil`: takes the first `{…}` JSON object in `text`; returns `{emoji, thing, price, count, part}` only if all are present, `price` is a number > 0, `count`/`part` contain `{n}` and are ≤ 80 characters, and `V.allowed` (load `value.lua` with `dofile(DIR .. "/value.lua")`) passes on `thing`, `count` and `part`. Otherwise nil.
  - `B.compare(ctx, done) -> boolean`: `ctx = {figure, period (label), avoid = {thing…}}`. Returns false (and never calls `done`) if `inflight > 0`, or if `ENGINE == "claude"` and `not Agent.unprompted()`. Otherwise dispatches with its own system prompt (not `persona()`, which bans emoji and dollar amounts) and `done(parsed or nil)`. Temperature 0.9, 160 max tokens.
  - System prompt (exact intent, wording is the builder's): you pick one fun, everyday thing to compare an amount of money to; reply with one JSON object `{"emoji","thing","price","count","part"}`; `price` is a believable US price in dollars for one; `count` uses `{n}` for how many ("That's {n} large pizzas"); `part` uses `{n}` for a percentage of one ("{n} of a private jet"); pick something whose price makes the number fun at this amount; the content rule from Global Constraints, word for word; don't use any of the avoid list. The user message carries only the figure (`V.money`), the period label and the avoid list.
  - `buddy.lua`: `function M.compare(ctx, done) return Brain ~= nil and Brain.compare(ctx, done) or false end`.

- [ ] **Step 1: Write the failing tests**

```lua
local B = dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "haiku", agent_dir = t.tmpdir() }, "", false)
local ok = '{"emoji":"🍕","thing":"large pizza","price":18,"count":"That\'s {n} large pizzas","part":"{n} of a large pizza"}'
t.eq(B.parseComparison("Sure! " .. ok).thing, "large pizza", "JSON found inside prose")
t.eq(B.parseComparison("That's a lot of pizza"), nil, "parseComparison rejects prose")
t.eq(B.parseComparison(ok:gsub("18", "0")), nil, "parseComparison rejects zero price")
t.eq(B.parseComparison(ok:gsub("large pizza\"", "election\"")), nil, "parseComparison rejects blocked topic")
t.eq(B.parseComparison(ok:gsub("{n} of a", "half of a")), nil, "parseComparison rejects missing {n}")
local saved = hs.settings.get("claudeBuddy.agentDay")
hs.settings.set("claudeBuddy.agentDay", { day = os.date("%Y-%m-%d"), n = 300 })
t.eq(B.compare({ figure = 26, period = "Today", avoid = {} }, function() end), false, "capped compare refused")
hs.settings.set("claudeBuddy.agentDay", saved)
-- with a fake hs.task.new (pattern in brain_claude_spec.lua) returning {"ok":true,"text":ok}:
-- B.compare(...) returns true and done() receives the parsed table
```

- [ ] **Step 2: Run to verify failure** (Lua test command)
- [ ] **Step 3: Implement `B.parseComparison`, `B.compare` and `M.compare`**
- [ ] **Step 4: Run to verify pass** (`0 failed`)
- [ ] **Step 5: Commit**

```bash
git add brain.lua buddy.lua tests/brain_compare_spec.lua
git commit -m "Brain: write a fresh money comparison as JSON, within the daily cap"
```

---

### Task 6: The row on the card, the period menu and the comparison flow

**Files:**
- Modify: `usage_widget.lua` (`scanTokens`, `render`, `startDrag`, new local functions; requires `value.lua` and `comparisons.lua` via `dofile(DIR .. …)`)
- Modify: `tests/usage_widget_spec.lua`

**Interfaces:**
- Consumes: `M.tokens.periods` (Task 2), `V` (Task 3), `C` (Task 4), `ClaudeBuddy.compare` / `ClaudeBuddy.say` (Task 5; `say(text, true)` respects "quiet for an hour").
- Produces:
  - Settings keys: `claudeUsageWidget.valuePeriod` (default `"month"`), `claudeUsageWidget.valueBuddy` (default `true`), `claudeUsageWidget.comparisons` (`{[key] = {from, at, text}}`), `claudeUsageWidget.comparedThings` (newest first, max 50).
  - `M.valueLines(periods, key, includeBuddy, saved) -> {label, figure, multiple, comparison}|nil` (pure, exported for tests): `label = "API value"`, `figure = V.money(...)`, `multiple` = `V.multiple(...)` with `" · since " .. (os.date("%b %d", periods.first):gsub(" 0", " "))` appended when `IMPORT_HISTORY` is false and key is `ytd` or `all`; `comparison = saved and saved.from == p.from and saved.text or nil`. Nil when `periods` is nil.
  - `scanTokens()` passes `--session-start`, `--week-start` (from `data.limits` labels `"Current session"` minus 18000 and `"Week · all models"` minus 604800, when present) and `--plan-price` (`CFG.plan_price`, when a number).
  - After each successful token scan: `checkComparison()` for the selected period only. If `V.due` says `"rollover"`, clear that period's saved line and call `V.due(nil, p, figure)` again. If that says `"new"`: build `ctx` (`figure`, period label, `avoid` = comparedThings); try `ClaudeBuddy and ClaudeBuddy.compare(ctx, cb)`; if that returns false, or `cb` gets nil, or `V.fill` returns nil, use `C.pick(figure, comparedThings)`. Save `{from = p.from, at = figure, text = line}`, push `thing` to comparedThings, `render()`, then `ClaudeBuddy.say(line, true)` when `ClaudeBuddy` exists. Never more than one comparison request in flight.
  - Switching period runs the same `checkComparison()` for the new period right away (a catch-up comparison is new, so Buddy says it; showing an existing saved one says nothing).
  - `render()`: one block after the credits loop and before "This week:". Line 1 in `row()`'s label/figure style without a bar: label `"API value  " .. periodLabel .. " ▾"`, figure in `C.ok`. Line 2 dim (multiple), only if present. Line 3 comparison in a warmer colour (`{ red = 0.95, green = 0.77, blue = 0.66, alpha = 1 }`), `lineBreak = "wordWrap"`, height for up to two lines. Record `M.valueY = {top, bottom}` of line 1.
  - `startDrag(clickY)`: a click (not a drag) inside `M.valueY` opens the period menu instead of the chart: `hs.menubar.new(false):setMenu(items):popupMenu(hs.mouse.absolutePosition())`. Items: the six periods (checked = selected) and, when `periods.has_buddy`, a separator and `"Include Buddy's own use"` (checked = valueBuddy). Choosing an item saves the setting, re-renders and runs `checkComparison()`.

- [ ] **Step 1: Write the failing tests** (add to `tests/usage_widget_spec.lua`)

```lua
local P = { first = 1785196800, has_buddy = false, list = {
  month = { from = 100, value = 1284.2, buddy = 0, paid = 200, spread = 300 },
  today = { from = 200, value = 26.4, buddy = 1, paid = nil, spread = nil } } }
local l = W.valueLines(P, "month", true, { month = { from = 100, at = 1200, text = "☕ That's 214 lattes" } })
t.eq(l.figure, "$1,284", "row figure")
t.eq(l.multiple, "6.4× your plan", "row multiple")
t.eq(l.comparison, "☕ That's 214 lattes", "saved comparison shown")
t.eq(W.valueLines(P, "month", true, { month = { from = 99, at = 1, text = "old" } }).comparison, nil, "last period's line hidden")
local today = W.valueLines(P, "today", true, nil)
t.eq(today.figure, "$27.40", "Buddy included")
t.eq(today.multiple, nil, "row lines with nothing but hourly tallies: no multiple")
t.eq(W.valueLines(P, "today", false, nil).figure, "$26.40", "Buddy left out")
t.eq(W.valueLines(nil, "month", true, nil), nil, "no periods, no row")
```

- [ ] **Step 2: Run to verify failure** (Lua test command)
- [ ] **Step 3: Implement the changes in `usage_widget.lua`**
- [ ] **Step 4: Run to verify pass** (`0 failed`), then reload this worktree's copy by hand to look at it: `hs -c "ClaudeUsage.canvas:delete(); ClaudeUsage = dofile('$PWD/usage_widget.lua').start()"`. Check: the row sits between the credits and "This week:", the menu opens on click, the chart still opens on clicks elsewhere. Restore the live copy afterwards with `hs -c "hs.reload()"`.
- [ ] **Step 5: Commit**

```bash
git add usage_widget.lua tests/usage_widget_spec.lua
git commit -m "Card: API value row with period menu and a fun comparison Buddy says"
```

---

### Task 7: Plan price in the wizard, docs and demo

**Files:**
- Modify: `setup.html` (new segment), `setup.lua` (`save()` writes `plan_price`; the INIT table passes it), `config.example.lua`, `README.md`, `usage_widget.lua` (demo)
- Modify: `tests/setup_spec.lua`

**Interfaces:**
- Produces:
  - Config key `plan_price` (number, US dollars per month). Wizard segment `data-key="planPrice"` after the older-history section: buttons `Pro · $20`, `Max 5x · $100`, `Max 20x · $200`, `Skip` (values `20`, `100`, `200`, `""`), with the hint "Used for '× your plan' on the card. A billing.json with your receipts takes over when you add one." Confirm the three prices on claude.com/pricing when you build; if they've changed, use the current ones.
  - `setup.lua save()`: `new.plan_price = tonumber(b.planPrice) or nil`.
  - `config.example.lua`: `plan_price = 100, -- your plan's monthly price in US dollars, for "× your plan" on the card`.
  - `README.md`: a short **API value** paragraph under "The usage card": the period menu, what "× your plan" uses (billing.json, else `plan_price`), that comparisons come from Buddy's brain or a built-in list and Buddy says each new one, that a new one comes after a typical-sized jump, and that only Claude Code use counts.
  - Demo: `M.chart(true)` also sets `M.demoPeriods` to fixed made-up `periods` (all six keys, `has_buddy = true`) and a saved demo comparison, which `render()` prefers over `M.tokens.periods` while set. `M.chart()` without demo clears it.

- [ ] **Step 1: Write the failing test** (`tests/setup_spec.lua`, following its existing save tests): saving with `planPrice = "100"` writes `plan_price = 100`; with `planPrice = ""` leaves it out.
- [ ] **Step 2: Run to verify failure** (Lua test command)
- [ ] **Step 3: Implement the wizard, config example, README and demo**
- [ ] **Step 4: Run both suites**

Run: `R=$PWD; timeout 60 hs -c "return dofile('$R/tests/run.lua')('$R')"` → `0 failed`
Run: `/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py' -v` → `OK`

- [ ] **Step 5: Commit**

```bash
git add setup.html setup.lua config.example.lua README.md usage_widget.lua tests/setup_spec.lua
git commit -m "Plan price in the wizard; README and demo for the API value row"
```

---

## After the last task

- Once the companion branch has landed on `main`, run `git rebase main` in this worktree. Resolve `bin/claude-tokens` `main()` and `render()` conflicts by keeping both changes. Rerun both suites.
- Report to the release captain session (it's merging tonight's branches): branch `api-value-row`, head commit, both suites' summary lines. Don't push, merge or release.
