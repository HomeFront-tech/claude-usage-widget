# API value row with fun comparisons — design

Status: draft for owner review, 2026-10-24.
Builds on: the hourly token tallies and older-history archive in `bin/claude-tokens`, the
card in `usage_widget.lua`, Buddy's brain (`brain.lua`) and speech bubble (`buddy.lua`).
Shares the card with the companion work on branch `companion`
(`docs/superpowers/specs/2026-10-24-buddy-companion-design.md`, part 6).

## Intent

The card already knows what your Claude Code use would cost at API list prices (the "≈$"
in the 24-hour line, and **API value** in the chart). The owner wants that number up front
and fun: a dollar figure for a period they choose, how many times over the plan has paid
for itself, and a playful comparison that puts the number in everyday terms ("That's 214
Starbucks lattes", "0.00004% of what the Hoover Dam cost to build"). Buddy says each new
comparison out loud.

It's for everyone who installs the widget, not one person. A new user should see their
whole history the first time it runs, as far back as Claude Code's logs and daily stats
go. The older-history import already does that; this feature reads from it.

## What it looks like

A new row on the card, **directly under the credit rows and above the "This week:" line**
(the owner picked this spot from three mockups):

```
API value  Month ▾                      $1,284
6.4× your plan
☕ That's 214 Starbucks lattes
```

- Line 1 looks like the other rows (`row()` style label and figure). It has no bar; there's
  no limit to measure against.
- `Month ▾` is the period picker. Clicking it opens a native popup menu: **Session · Today ·
  Week · Month · Year to date · All time**. A click anywhere else on the card still opens
  the chart, as today.
- Line 2 (dim) is the plan multiple. Line 3 (dim, warmer colour, italic if the canvas
  allows) is the fun comparison.
- The chosen period is remembered across reloads and restarts.

## Goals

### 1. The dollar figure per period

| Period | Covers (my call where marked) |
|---|---|
| Session | The current 5-hour plan window: from the "Current session" limit's reset time minus 5 hours, up to now. With no plan data, the last 5 hours. |
| Today | Local midnight to now. |
| Week | The plan's weekly window (the "Week · all models" reset time minus 7 days), so it matches the week bar on the same card. With no plan data, Monday 00:00 local. *(my call)* |
| Month | The 1st of this calendar month, local, to now. |
| Year to date | 1 January, local, to now. |
| All time | Everything the widget has: hourly tallies plus the older-history archive. |

- **Dollars must match the chart's History tab.** With Buddy left out, the row's figure for
  a range must equal the API value the History tab shows for the same days. (The Tokens tab
  uses hourly logs only, so on a day where the archive holds more it can be lower; that's
  accepted.) *(my call)* Use the same sources and the same rule for combining them: per UTC day, the archive's estimate replaces the logged
  hours only when the logs still on disk hold less (see `historyRecords()` in `chart.html`).
  The builder decides whether that rule moves into one shared place (for example a
  `periods` block that `bin/claude-tokens` writes into `tokens.json`) or is ported, but
  there must be one tested definition, not two that drift apart. The chart may be
  refactored to share that definition, but what it shows must not change.
- **Boundaries are whole buckets.** An hourly tally counts when the hour it starts falls
  inside the period; an archive day counts when its date falls inside the period. No
  prorating of partial hours or days. This makes Session up to an hour fuzzy at its start,
  which is fine for a fun figure. *(my call)* Session and Today only ever need hourly logs,
  which always cover recent hours.
- Prices come only from `PRICES` / `price_for()` in `bin/claude-tokens`, through the
  `usage_cost()` helper the companion branch adds there. No second price table or cost
  formula anywhere, including in the comparison code.
- **Buddy's own usage.** The companion work adds Buddy's tally to `tokens.json` under the
  key `"buddy"`: `buddy[hour] = {"m": {model: [in, out, write, read, replies, $]}, "k": …,
  "n": …}`, where `"m"` matches `hours` exactly, so one period sum serves both. When it exists,
  the figure includes Buddy by default, and the popup menu gets a checkable **Include
  Buddy's own use** item. *(my call)* Until the companion work lands, there's nothing to
  include and the menu item is hidden.
- If older history is off (`import_history` false), All time and Year to date only cover
  the logs; line 2 then ends with "· since <first day with data>" so
  the number doesn't pretend to be complete. *(my call)*

### 2. The plan multiple ("6.4× your plan")

- What you paid that covers the period, divided into the period's API value.
- **What you paid comes from `billing.json`** when it exists: each charge's amount is
  spread evenly over its days, from `from` up to but not including `to` (the README's
  consecutive receipts share their boundary date, so `to` must be exclusive here or that
  day is paid twice; the chart's plan strip keeps its own rule). The period takes the
  share of the days it covers; Session and Today take a share of a day. Days no charge
  covers use `plan_price` when it's set, and cost nothing otherwise. Amounts are taken as
  US dollars, like API prices; the README says to enter them that way. *(my call)*
- Without `billing.json`, a new config key `plan_price` (monthly, in dollars) is used the
  same way, spread over each month. The setup wizard asks for it once, offering the
  current list prices for Pro and the two Max tiers. `bin/claude-usage` only reports
  "max", not which Max, so it can't be guessed. *(my call)*
- If nothing you paid covers the period (no billing, no `plan_price`), line 2 is hidden.
  Never show a made-up multiple.

### 3. The fun comparison line

- **Buddy's brain writes it fresh each time** (the owner's choice over a fixed list),
  using whichever brain is set up: Claude Haiku or Ollama.
- **Buddy does the arithmetic, not the model.** The brain returns a thing, a believable
  unit price in US dollars, an emoji and a short phrasing template. Buddy computes the
  count or percentage from the period's dollar figure and fills it in. A wrong price
  can slip through; wrong arithmetic can't. The exact prompt and reply format are the
  builder's call.
- **Scaled to the amount.** For small amounts, small things (coffees, pizzas); for big
  ones, big things (cars, houses, jets, landmarks). Very large things work as a
  percentage ("0.00004% of …"), small ones as a count.
- **No repeats.** Buddy keeps its last 50 comparisons and tells the brain to avoid those
  things. The built-in list (below) avoids its own recent picks the same way; when every
  size-matched item has been used recently, it reuses the one used longest ago.
- **Content rule (hard):** everyday, light, all-ages subjects only: food and drink,
  vehicles, buildings and landmarks (as construction costs only), travel, sports,
  gadgets, animals and pets, household things. **Never** politics or social issues from
  any side, sexuality or gender topics, religion, disasters, tragedies, violence or
  crime, or real private people. Nothing about what's on the user's screen, their files
  or their work. The prompt gets only the dollar figure, the period name and the
  avoid-list. This is the owner's main "would make me wince" item. If a reply looks off
  (fails to parse, or the price is missing or zero), discard it and fall back to the built-in list.
- **No brain configured ("plain rules"):** a built-in list of about 80 everyday things
  with US prices, under the same content rule, picked with the same no-repeat and
  size-matching logic. This keeps the feature working for every new user.
- **Currency:** all figures are US dollars, because API list prices are. *(my call)*

### 4. When a new comparison appears

The owner's rule: the line stays put, and changes only after the dollar figure has moved
by about one standard deviation since the last comparison.

- **My reading (my call, flagged for the owner):** each period keeps its own comparison
  and the dollar figure it was made at. The threshold for a new one is one standard
  deviation of that period's past totals:
  - Session: past 5-hour windows. Today: past days. Week: past plan weeks. Month: past
    months.
  - Year to date and All time: past months, because there's no long list of past years.
  - Only periods with spending count, over the last 90 days (or all the history there is
    for Month and longer).
  - A new comparison is made once `|current − at_last_comparison| ≥ threshold`. In
    practice that's a few new lines per period: a few a day on Today, a few a month on
    Month.
- **The comparison's text is fixed when it's made.** It keeps saying "214 lattes" while
  the dollar figure above it keeps climbing, until the next one replaces it. That's the
  owner's "it stays there until it's updated".
- **When a period rolls over** (a new session, day, plan week, month or year), its old
  comparison is dropped and line 3 is hidden until the new period's figure reaches its
  threshold from $0. That first one is made and said like any other. *(my call)*
- **Toggling "Include Buddy's own use"** doesn't force a new comparison; the figure changes
  and the usual threshold check decides. *(my call)*
- **Too little history to measure a spread** (a new user, or fewer than 5 past periods):
  the threshold is 25% of the current figure, with a floor of $1. *(my call)*
- **Only the period on the card makes new comparisons.** The others catch up when you
  switch to them: if a period has no comparison yet, or has passed its threshold while
  you weren't looking, it gets a new one when it appears.
- The check runs whenever the card gets fresh token numbers (every 5 minutes while awake,
  and on wake). Nothing changes between checks.

### 5. Buddy says it out loud

- Each new comparison (not ones you switch back to) is said once in Buddy's bubble, and
  like everything he says, it lands in the chat.
- Quiet for an hour: the card still updates; Buddy stays silent.
- With the Claude brain, generating the line counts against `daily_unprompted`
  (`Agent.unprompted()`). When the cap is reached, the line comes from the built-in list
  and Buddy still says it.

## Non-goals

- Counting Claude chats in the desktop app or on claude.ai, or cloud sessions. They leave
  no logs on the Mac.
- Recovering days that neither logs nor daily stats kept. Gaps stay gaps; the chart
  already labels them.
- A cost forecast, budget alerts, or any number that implies the plan charges per token.
- Changing the chart, the History tab, or how older history is imported.
- A second price table, or live price fetching.

## Anti-goals (failure even if it works)

- Any comparison touching politics, social issues, sexuality or gender, religion, or
  tragedy (see the content rule).
- Buddy announcing comparisons so often he becomes noise, or the line churning on every
  refresh.
- The row's dollar figure disagreeing with the chart's API value for the same range.
- A plan multiple shown from a guessed price.
- Comparisons that reveal anything about the user's screen, files or work.

## Constraints

- Hammerspoon Lua for the card and Buddy; Python 3 standard library for `bin/*`, runnable
  on the Python that ships with macOS (no `X | None` syntax).
- Public repo: no personal data, usage numbers or business details in code, tests, docs or
  screenshots. The README's screenshot of the card should be regenerated from demo data
  if it changes.
- Coordinate with the companion branch. It inserts a Buddy bar under the "24h" line in
  `render()` and adds `tally_buddy` plus summary fields to `bin/claude-tokens`. This
  feature's `render()` change is one inserted block between the credits loop and "This
  week:". Whoever lands first in `render()` or `bin/claude-tokens` tells the other which
  lines and functions changed.
- Tests: extend `tests/usage_widget_spec.lua` and `tests/test_claude_usage.py` (or a new
  test file for `bin/claude-tokens`). Period boundaries, the archive/log merge, billing
  spreading, the threshold rule and the arithmetic fill-in all need tests. Brain replies
  use the existing fakes in `tests/fakes`.
- New config keys go in `config.example.lua` and the setup wizard; the README gets a short
  section; a release goes out through `tools/release`.
- `hs -c 'ClaudeUsage.chart(true)'` demo data should also drive the new row, so it can be
  seen with made-up numbers.

## Left to the builder

- Where the period totals and the merge rule live (Python writing into `tokens.json`, or
  Lua reading it), as long as there's one tested definition shared with the chart.
- The brain prompt and reply format, the built-in fallback list's contents, emoji
  choice.
- Exact fonts, colours, spacing and truncation of the comparison line within the card's
  264 px width (it may wrap to two lines; it must never be cut off mid-word).
- How the period menu is built (hs.menubar popup or similar) and where the per-period
  comparison state is stored (hs.settings is fine).
