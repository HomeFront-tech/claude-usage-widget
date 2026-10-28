# Usage for every AI: Claude, Codex, OpenRouter, Grok and more on one card

## Why
The card shows Claude plan limits only. The owner also uses Codex, OpenRouter and
Grok, and wants to see how close each one is to its limit in one place, so they can
tell at a glance which AI still has room before they hand it work. Other people who
install Buddy use different mixes, some with no Claude at all, so anyone should be able
to pick their own AIs in the setup wizard.

Success: every AI the owner pays for shows up on the card with honest numbers, and
someone who only uses Claude sees no change.

## Goals
- A provider abstraction. Each AI plugs in the same way, and adding a new one later
  means one fetcher plus one entry in the provider list.
- Real limits wherever a provider publishes them. Where it doesn't, the card says so
  plainly and offers spend against a budget the user sets, or plan facts.
- A setup wizard that covers providers: pick your AIs, add keys, choose what each one
  shows, set the order, refresh rates and warning levels.
- Keys kept in the macOS Keychain and nowhere else.
- Existing setups keep working with no migration step.

## Non-goals (for now)
- Cursor, the ChatGPT app, Gemini, and the Anthropic or OpenAI admin (API org) usage
  reports. The abstraction must leave room for them; none of them is built now.
- History and charts for the other AIs. The chart window stays Claude-only.
- Changing how Claude's numbers are fetched. `bin/claude-usage` is not touched.

## Anti-goals (would make this a failure even if it works)
- Anything changes for someone who only uses Claude: the card, `/usage`, the chat
  answer or the chart.
- A key ends up in config.lua, a log, a command line, an environment variable, the
  wizard page's JavaScript state after Save, Hammerspoon settings or the git repo.
- Buddy reads another app's own login files or cookies (Grok Bot, Cursor, browsers).
  Codex is reached through its official `codex app-server`, which uses Codex's own login;
  Buddy never opens `~/.codex/auth.json`.
- A slow, broken or signed-out provider delays, blanks or breaks the Claude section.
- Alerts that nag: the same limit announced more than once per reset window.

## What the owner decided
- Card layout **C: Claude in full, others small.** Claude's section stays exactly as
  it is today: header, 24-hour token strip, limit bars, credits, the API value row and
  the weekly breakdown. Below it, an **"Other AIs"** list with one compact row per enabled
  provider: name, one thin bar and a short figure. Each row shows that provider's
  **tightest limit**, the one with the highest percent used.
- With only Claude enabled (every existing config), the "Other AIs" list doesn't
  appear at all.
- Two new setup steps (mockup: https://claude.ai/artifact/PULmRCeuwnBTbeA2ds3PzX):
  1. **"Which AIs do you use?"** A row per provider with an on/off switch, a status
     pill (each provider is checked live), and whatever the provider needs: nothing for
     Claude and Codex, a key field with a Check button for OpenRouter, a plan name and
     renewal day for the Grok subscription, and a Management key plus team ID for xAI credits.
  2. **"Set up your card."** The order (move up/down), which limits each provider shows
     (checkboxes), how often each one checks, the yellow and red levels, and a switch for
     "Tell me when one turns red".
- Grok: the owner's Grok and Grok Bot are a consumer subscription billed through their X
  account. xAI publishes no usage or limits for subscriptions, so the **Grok
  subscription** provider shows only the plan name and its next renewal date, both typed in
  by the user. A separate **xAI credits** provider (pay as you go, console.x.ai) gets real
  numbers for the people who have that.

### Calls I made that the owner approved
- Clicking a row in "Other AIs" pops up a menu listing all of that provider's limits,
  each with its figure and reset time (built like the card's existing period menu).
- Stale numbers turn grey the same way Claude's do (`isStale`: older than 3× the
  provider's own refresh). When a provider fails, its row keeps the last numbers (greyed
  once stale) and shows a short reason in small text, such as "Codex: signed out".
- Yellow from 70% and red from 90% stay the defaults. The levels the user sets also
  apply to Claude's bars. The API's own `severity` still wins when it is higher.
- If Claude is turned off, the first provider in the user's order takes the full section
  at the top, drawn with the same row style Claude uses. The rest go in "Other AIs".
- The "turns red" alert is **off by default**. The owner's own config turns it on.
- `/usage` on Telegram, the chat answer (`M.usageText`) and the brain's status line cover
  every enabled provider. With only Claude enabled, the text stays exactly as it is now.
- Default refresh: Claude 5 min (as today), Codex 5 min, OpenRouter 15 min, xAI 30 min.
  Claude cannot be set faster than 5 min, because its API rate-limits frequent callers.
  Nothing can be set faster than 1 min.
- The Grok subscription renews monthly on a day of the month the user picks. If that day
  doesn't exist in a month, it falls on the last day of that month.

### Calls I made after the builder check (the owner sees these with the document)
- **Hidden means ignored.** A limit the user unticks in step 2 is left off the card and is
  also skipped for the tightest-limit choice, the `/usage` and chat text, and the red
  alert. People hide limits they don't care about, such as a model they never use. One
  exception: when a provider says the user is blocked outright (Codex
  `ordinaryUsageAllowed: false`), the row says so whatever is hidden.
- **The alert follows the red colour.** It fires when a bar turns red, whether from
  `hot_at` or from the provider's own `critical` severity, Codex's "limit reached"
  included.
- **The alert re-arms on a real drop, not a timestamp.** After it fires for a limit, it
  stays quiet for that limit until the limit falls below the yellow level (`warn_at`).
  Usage only climbs within a window, so a drop like that means a reset, or the user raised
  a cap or budget. This works for limits with no `resets_at`, such as Claude's extra usage
  and monthly credit rows.

## What each provider exposes (checked 2026-10-28)

| Provider | Source | Needs from the user | What it gives |
|---|---|---|---|
| Claude | `bin/claude-usage` (unchanged) | Nothing (Claude Code's login) | Session/week %, resets, credits, extra usage |
| Codex | `codex app-server` (stdio JSON-RPC): `initialize`, then `account/rateLimits/read`; optionally `account/usage/read` | Nothing (Codex's own login) | Limit windows with `usedPercent`, `windowDurationMins`, `resetsAt` (epoch s); credits `{hasCredits, unlimited, balance}`; `planType`; `rateLimitReachedType`; daily token buckets |
| OpenRouter | `GET https://openrouter.ai/api/v1/key`, Bearer API key | An API key | `limit`, `limit_remaining`, `limit_reset`, `usage`, `usage_daily`, `usage_weekly`, `usage_monthly` (USD), `is_free_tier` |
| xAI credits | `management-api.x.ai/v1/billing/teams/{team_id}/…`: `prepaid/balance`, `postpaid/invoice/preview`, `postpaid/spending-limits` | A **Management key** (Console → Settings → Management Keys, separate from an API key) and the team ID | Prepaid balance, this month's spend, effective spending limit, all in USD cents as strings |
| Grok subscription | Nothing to fetch | Plan name, renewal day | Plan and next renewal date only |

Notes for the builder:
- Codex: verified live against codex-cli 0.164.0. The app-server is marked
  experimental, so parse defensively. `rateLimitsByLimitId` can hold several limits; label
  each one from its `limitName`, or from its window (10080 min → "Week", 300 → "5-hour",
  anything else → "N-hour"/"N-day"). `primary` and `secondary` may each be null. `balance`
  is a decimal string, and there is no cap for it, so it shows as a fact ("12,000 credits
  left") with no bar. A non-null `rateLimitReachedType` or `spendControlReached` makes that
  limit critical. Find `codex` on the same PATH Buddy's tasks use
  (`~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`); kill the process after
  the answer or after 20 s.
- OpenRouter: with a cap, the bar is `used = limit - limit_remaining` against `limit`,
  labelled by `limit_reset` ("This month", "This week", "Today", or "Spending cap" when the
  cap never resets). With no cap, the user may set a monthly budget, and the bar becomes
  `usage_monthly / budget`. With neither, the figures show as facts ("Today $1.12 · Month
  $18.40") and the row has no bar. A 401 means "key not accepted", and a 402 means "out of
  credits or over the key's cap".
- xAI: built from the published docs only. Nobody here has a credits account to test with,
  so it ships marked untested against a live account. Balance sign: `PURCHASE` amounts are
  negative and `SPEND` is positive, so the remaining balance is `-total.val` cents. Bar:
  this month's spend against `effectiveSl` when that is set, else against the user's
  budget, else no bar. Spend is `coreInvoice.amountAfterVat` (or `amountBeforeVat`) from the
  invoice preview. The team ID is not secret and lives in config. A 401 or 403 means "needs
  a Management key, not an API key".
- Grok subscription: computed in Lua from config. No process, no network.

## Shape of the build

### One data shape for every provider
Each fetcher prints one line of JSON. It is the shape `bin/claude-usage` already prints,
plus `provider` and `facts`, so the card's existing drawing code works for all of them:

```json
{"ok": true, "provider": "codex", "plan": "pro", "fetched_at": 1793200000,
 "limits":  [{"label": "Week", "pct": 41.0, "resets_at": 1793800000, "severity": "normal"}],
 "credits": [{"label": "This month", "used": 18.4, "limit": 50, "pct": 36.8, "resets_at": null}],
 "facts":   ["12,000 credits left"]}
{"ok": false, "provider": "openrouter", "error": "Key not accepted", "retry_after": 600}
```

`pct` is 0–100. Times are epoch seconds. `error` is short, plain, and fit to show on the
card. The tightest limit is the highest `pct` across `limits` and `credits`; facts are
never tightest.

### Where things live (layout is the builder's call; these are the principles)
- **Fetchers** are Python 3, standard library only, like `bin/claude-usage`. Suggested:
  one dispatcher `bin/ai-usage <provider>` plus a module per provider, so each can be tested
  with fakes. Each fetcher reads its own key from the Keychain itself (`/usr/bin/security
  find-generic-password -s <service> -a <account> -w`), the way `bin/claude-usage` does.
  A key the wizard is checking before Save arrives on **stdin**, never in argv or env.
- **Provider registry** (Lua, e.g. `providers.lua`): the list of known providers, each with
  id, display name, kind (`login`, `key` or `manual`), Keychain service, default refresh,
  which wizard fields it needs, and how to fetch it. Adding a provider later means one entry
  here plus one fetcher.
- **Scheduler**: one timer per enabled non-Claude provider at its own refresh, the same
  one-task-at-a-time and `retry_after` handling `usage_widget.lua` uses for Claude, the
  last good result per provider saved in `hs.settings` (so a reload shows numbers
  straight away), and a wake re-check. Claude's existing fetch loop stays exactly as it is.
- **Card** (`usage_widget.lua`): after the Claude section, the "Other AIs" list and its
  click menu. The colour levels come from config (`barColor` gains the thresholds).
- **Keychain**: one generic-password item per provider, service
  `claude-buddy-<provider>` (for example `claude-buddy-openrouter`), the same account
  telegram.lua uses. Saved through `security -i` on stdin, the way `T.saveToken` does it, so
  the key never shows in a process list.

### Config (config.lua) and migration
A new optional `usage` table. When it's missing, the card behaves as Claude only with
today's defaults, which is exactly today's behaviour, so every existing config keeps
working untouched. The wizard writes the table only when the user changes something
from those defaults.

```lua
usage = {
  order = { "claude", "codex", "openrouter", "grok_plan" }, -- enabled providers, top first
  warn_at = 70, hot_at = 90,           -- yellow and red levels, percent
  alert_red = false,                   -- "Tell me when one turns red"
  providers = {
    claude     = { hide = { "Week · Sonnet" } },             -- refresh in seconds, default 300, min 300
    codex      = { refresh = 300 },
    openrouter = { refresh = 900, budget = 50 },             -- budget: monthly USD, used only without a cap
    xai        = { refresh = 1800, team_id = "…", budget = nil },
    grok_plan  = { plan = "SuperGrok", renews_day = 14 },
  },
}
```

- A provider is on when it appears in `order`. Claude is on when `usage` is missing or
  when `order` lists it.
- `hide` holds the labels the user turned off, not the ones they kept. New limits a
  provider adds later (Claude's API grows new labels) then show up by default.
- Document the table in `config.example.lua`.

### The wizard
- The two new sections go right after "Can I see everything I need?". The page finds
  steps by index today (`step === 1` runs the checks), so steps move to `data-step` names
  first.
- The Claude row's pill reuses the existing check. Every other row's Check runs that
  provider's fetcher (with a pasted key on stdin) and shows "Working · week 41%" or the
  error. Codex is checked as soon as the step opens.
- Keys work like the Telegram token: the page posts a key to Lua, Lua holds it in
  memory, and Save writes it to the Keychain before it writes config.lua. If the
  Keychain write fails, Save stops and the page says so (`onSaveFailed`). A key already in
  the Keychain shows as "Key saved" with Replace and Remove, and the key itself never goes
  back to the page. Turning a provider off leaves its key in place; Remove deletes it.
- Step 2's checkboxes list the limit labels from each provider's latest result (or its
  check), so they match what the card will show.
- The summary on the last step lists the enabled AIs in order.

### The red alert
When a shown limit turns red (at `hot_at`, or `critical` from the provider), and
`alert_red` is on, Buddy says one line ("Codex is at 91% of its week. Resets Monday.")
through `ClaudeBuddy.say`, and sends it on Telegram (`T.send`) when a chat is paired. Then
that limit stays quiet until it falls below `warn_at`, which re-arms it. The fired/armed
state per provider + label is saved in `hs.settings`, so a reload doesn't repeat an alert.
Claude's limits count too. Hidden limits never alert.

## Constraints
- Public repo. No real usage numbers, account IDs or keys in tests, fixtures, screenshots
  or docs. Personal settings stay in the gitignored config.lua. Follow the
  `shipping-widget-releases` and `coordinating-buddy-releases` skills before committing to
  main or releasing.
- Hammerspoon Lua and Python 3 standard library only, no new dependencies.
- Lua specs run with `tests/lua-tests` under `/usr/bin/lockf -k /tmp/buddy-hs.lock`, with a
  timeout. Don't add new lazy `hs.*` module loads at spec time.
- The card redraws every 30 s and after each fetch. Don't redraw on every provider
  callback more often than that needs.

## Tests
- Python unittest per fetcher, with a fake `security`, fake HTTP responses, and a fake
  `codex` app-server script. Cover: normal answers, missing and null fields, every error
  mapping, the key arriving on stdin, and that a key never shows in argv or output.
- Lua specs: a config with no `usage` table means Claude only, with identical card text;
  tightest-limit choice; threshold colours, including API severity winning; the stale rule
  per refresh; wizard save and initial round-tripping the `usage` table; `usageText` with one
  provider and with several; the alert firing once per window; renewal-day maths, including
  short months.
- Live check in Hammerspoon (the `testing-hammerspoon-widgets` skill): the card with Codex
  on, a Claude-only card unchanged, and the wizard steps.

## What the owner needs to provide
- Codex: nothing, as long as Codex is signed in.
- OpenRouter: an API key from openrouter.ai/keys, if they want it on the card.
- Grok subscription: the plan name and its renewal day.
- xAI credits: nothing; the owner doesn't use them.

## Left to the builder
File names and module split, exact wording on the card and in the wizard (plain words,
in the style of the existing pages), the click menu's layout, how the scheduler shares code
with Claude's fetch loop, and whether the Codex fetcher also reads `account/usage/read`
for a "tokens today" fact.
