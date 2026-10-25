# Buddy companion — design

Date: 2026-10-24 · Branch: `companion` (worktree `.claude/worktrees/companion`)

## Intent

The owner wants Buddy to grow from a reaction mascot into a sidekick that sits alongside
you through the day: it watches what you do, learns how you use your apps, makes up
candid lines on the spot, looks after your health, and does things when you ask. In
his words: "Making unique quips up on the fly, like as it's sitting alongside you kind
of as an assistant through your day and workflows. Watching what you do, learning from
you, making little quips and lines and being able to take actions when requested." The
example he loved: opening YouTube for the third time today and Buddy saying "YouTube
for the third time today."

He also wants the brain to run on any Claude model on his plan, with smart routing by
default, and to see how much of his Claude usage is Buddy's own, by model.

Buddy is a public, auto-updating project (HomeFront-tech/claude-usage-widget). Every
feature has to make sense for any user on a fresh install, not just the owner.

## The six parts

1. **Auto reactions that learn**: Buddy picks the reaction for every app himself and
   keeps changing it as he learns how you use each one.
2. **Live candid lines**: quips made up from what is actually happening right now.
3. **Health sidekick**: breaks, meals, goals, workout and diet help.
4. **Privacy**: plain disclosure, an off switch, and a way to make Buddy forget.
5. **Any Claude model**, with Auto routing as the default.
6. **Buddy's own usage**: a right-click report and a Buddy bar on the usage card.

## Goals

### 1. Auto reactions that learn
- The wizard's "How should I react to your apps?" step gets an **Auto** mode: Buddy
  decides the reaction for every app, including apps he has never seen. (the owner)
- Reactions **change as Buddy learns** how you use each app. He learns by **looking at
  the screen and asking you questions**. (the owner)
- Learning is per app and per use: Chrome with invoices in the morning and Chrome with
  YouTube at night can get different reactions. *(my call)*
- Any app you set by hand in the wizard keeps your pick. Auto only decides apps you left
  alone. Each row's dropdown gets an "Auto" choice, the default when Auto mode is on.
  *(my call)*
- He asks short questions in his bubble ("You're in Numbers every night, is that
  invoicing?"). Clicking the bubble opens the chat (the `bubble-click` feature shipping
  tonight), where you answer. Answers go into his memory. Questions are capped per day
  (3 by default) and never come during calls, meetings, full-screen games or quiet
  time. *(my call on the cap and the quiet rules)*
- This replaces today's "You use X a lot! Option-click me to teach me." when Auto is on.
- Auto needs a brain. With plain rules, the wizard shows Auto as unavailable and the
  built-in `APPS` / `TITLE_RULES` table works as today. *(my call)*

### 2. Live candid lines
- Buddy keeps simple running facts on this Mac: how many times you opened an app or site
  today, minutes in it today, time since you last left it, streaks, your usual hours for
  it. (the owner's YouTube example)
- With a brain, those facts go into the quip prompt so the line is about now: "YouTube:
  3rd time today, 47 min so far, you usually watch at night." The brain writes one fresh,
  candid line. (the owner: "unique quips up on the fly")
- Without a brain, a few fact templates ("%a for the third time today!") join the canned
  lines, so plain-rules users get some of it too. *(my call)*
- **Candid and evolving**: the persona grows more familiar the longer Buddy has known
  you (days together, chats, what's in his notes). It can be blunt ("Third YouTube break
  today, boss?") but stays affectionate. (the owner: "candid and evolve as it gets to know
  the user")
- Actions on request keep working as they do today (chat tools, standing jobs).

### 3. Health sidekick
- **Sitting too long**: after about 60 minutes of steady keyboard and mouse use without a
  break, Buddy nudges a short walk or some push-ups, with a stretch animation. The timer
  resets after 5 minutes away. The minutes are a setting. *(the owner wants the nudge; the
  numbers are my call)*
- **Food and fitness on screen**: if Buddy sees you ordering food (Skip, Uber Eats,
  DoorDash and similar) or watching fitness content, he brings it up and asks about it.
  (the owner)
- **Meal check-ins**: a few times a day he asks if you've eaten and what. Default windows
  8–10, 12–14 and 17–19, skipped once you've told him for that meal. *(the owner wants
  check-ins; the windows are my call)*
- **Goals**: he asks about your health and fitness goals (in the getting-to-know-you
  chat), keeps track of them, and brings up progress now and then. (the owner)
- **Plans**: in chat he can help build a workout plan and a diet plan, remember them, and
  check in on them. (the owner)
- **Caring, not nagging**: daily caps, silent during calls, meetings, full-screen games
  and presentations, follows "Quiet for an hour" and the chattiness setting. *(my call)*
- New looks for it: a health/workout mood (dumbbell prop) and a food mood (apple or bowl
  prop). *(my call)*
- Health check-ins have their own on/off switch in the wizard, separate from screen
  watching, because the sitting timer and meal check-ins don't need the screen.
  *(my call)*
- What he learns about your health stays in Buddy's own memory on this Mac. It is not
  wired to any outside log. *(my call)*

### 4. Privacy
- **Disclosure** in the wizard and README, in plain words: Buddy looks at your screen
  from time to time to learn from you; where the pictures go (Claude: to Anthropic
  through your Claude Code login, like any Claude Code use; Ollama: stays on this Mac);
  that pictures are never saved; what he remembers and where it's kept; which windows he
  never looks at (passwords, banking, plus your own words). (the owner)
- **One switch** for watching and learning (wizard, and right-click menu). Off means no
  screenshots, no auto learning, no questions about what's on screen, no food/fitness
  spotting. App reactions fall back to the built-in table plus your picks. (the owner)
- Right-click **Pause watching** (for an hour, or until tomorrow). *(my call)*
- Right-click **Forget what you've learned about me**: after a confirm, wipes his notes,
  app learning, health goals and log, and the chat transcript. *(my call)*
- When he takes a look at the screen he shows it (the existing `ponder` action: glasses
  and a question mark), so a look is never invisible. *(my call)*
- **Which windows are private** works by blocking, not by allowing: the owner wants Buddy
  to learn apps he has never seen, so an allow-list would defeat Auto. Private means any
  of: the built-in words (passwords, banking, sign-in and so on, as `brain.lua` has
  today), the user's own words (`ai.private`), well-known password-manager and banking
  apps by bundle id, and a new **Never look** choice on any row of the wizard's apps
  step. The disclosure says honestly that the filter goes by app names and window
  titles, so something private inside an ordinary window can still be seen, and points
  to Never look and the off switch. *(my call)*
- **What "off" (or paused) stops**: no screenshots, no new learning, no questions about
  what's on screen, no food/fitness spotting, and nothing about your activity (window
  titles, visit counts, facts, learned habits) goes into any model's prompt. Simple
  local counters (which apps you opened today and for how long, like today's app-time
  counter) keep running on the Mac, only for the plain fact lines ("%a for the third
  time today!"), and are wiped by Forget. Health timers follow their own switch.
  *(my call)*

### 5. Any Claude model
- The wizard's brain choice lists **Auto (recommended)**, **Haiku**, **Sonnet**,
  **Opus**, **Fable**, **Ollama on this Mac** and **No, plain rules**. Named models use
  Claude Code's aliases (`haiku`, `sonnet`, `opus`, `fable`), which always mean the
  latest version, so the list doesn't go stale. (the owner: "select from all of the
  Anthropic models available on our Claude subscription")
- Claude Code has no command that lists the models on a plan. When a model is chosen,
  the wizard runs a tiny one-turn test with it and marks it "not on your plan" if it
  fails. *(my call)*
- **A named model is used for everything** Buddy does with Claude: quips, chat, jobs,
  notes. (the owner: "we should be able to use whatever model we select")
- **Auto** routes by the size of the request. (the owner: "default interview should be
  with Opus 5.5 … some model routing automatically depending on the scale of the
  request … subagents for deeper thinking or research")
  - Quips, screen peeks, note-taking and app learning: Haiku, low effort.
  - Chat, the getting-to-know-you interview, health and diet plans, standing jobs:
    Opus (5.5 today).
  - Deeper research or planning in chat: Opus with helper subagents (Sonnet) that dig
    and report back. Helpers get the same read-only tools and limits as Buddy.
  - Routing is by request kind plus simple signals in the message, with no extra triage
    call. *(my call)*
- **Switch any time** from a right-click **Brain ▸** submenu with a check mark, as well
  as the wizard. A switch takes effect on the next request without reloading Hammerspoon
  and survives restarts. *(my call)*
- Buddy's limits stay the same on every model: he can find, read and open things, never
  send, change or delete. Longer models get longer timeouts.

### 6. Buddy's own usage
- Buddy's Claude runs use `--no-session-persistence`, so they never reach Claude Code's
  logs, and the card's token strip leaves Buddy out today. Buddy already writes a ledger
  (`agent/usage.jsonl`: kind, ok, ms, tools, token counts) but records no model and no
  cost.
- The ledger gains, per call: the model(s) used and their tokens, with the cache-write
  split, taken from the result's per-model usage. Ollama calls are logged too, as
  on-device and free. *(my call)*
- Dollars come from the one pricing table the repo already has (`PRICES` /
  `price_for()` in `bin/claude-tokens`, which the chart's "API value" uses), not from
  the cost Claude prints, so Buddy's dollars match the rest of the card and chart.
  Buddy's tally sits in `tokens.json` under the key `"buddy"`, in the same per-hour,
  per-model shape as the existing hourly tallies, so one "sum a period" function can
  include Buddy or split him out. *(agreed with the dollar-row work)*
- Right-click **Buddy's usage** shows today, the last 7 days and this month: calls,
  tokens and cost, split by model and by what they were for (lines, chat, jobs,
  learning, research helpers). (the owner)
- The usage card gets a **Buddy bar**: Buddy's share of your Claude tokens today, split
  into coloured segments by model, with a short label ("Buddy · 3% today · Haiku 81%").
  (the owner: "a separate Buddy bar … his model breakdown of usage")

## Non-goals
- Medical or nutrition advice beyond everyday encouragement and plans the user asks for.
- A model picker for Ollama models beyond what exists today.
- Changing how standing jobs, Grok teammate, skins or the Halloween theme work.
- Exact plan-limit accounting for Buddy (the plan API reports totals, not who used them).

## Anti-goals (failure even if it works)
- Buddy nags. Health and questions must feel like a friend, not a notification stream.
- Buddy quietly drains the plan. Frequent work stays on Haiku in Auto, and the Buddy bar
  makes the cost visible.
- A look at a window the private filter matches (see Privacy), or a line that reads out
  phone numbers, addresses, emails, passwords or dollar amounts on screen.
- Learning, notes, health data or screenshots leave the Mac except as the prompt to the
  chosen model. Nothing personal lands in the public repo.
- A fresh install without a brain gets worse. Plain rules must keep working as today.
- Shaming about food, weight or screen time.
- Breaking or clobbering tonight's other Buddy work.

## Constraints
- Hammerspoon Lua plus small Python helpers, no build step, public repo, auto-updated
  installs (`updater.lua`). Settings the wizard owns go in `config.lua`; runtime state in
  `hs.settings` or `~/Library/Application Support/claude-usage-widget/`.
- **Other sessions tonight**: `skins` (skin menu, persona sentence for the costume),
  `halloween-theme`, `bubble-click` (built), and an **API-dollar usage tracking**
  session that is still in design and also changes the usage card. Build on the
  `companion` branch; put new code in new files (for example `learn.lua`, `health.lua`,
  a routing piece for the agent, a usage report); keep `buddy.lua`, `brain.lua`,
  `setup.*` and `usage_widget.lua` changes to small call sites.
- **Agreed with the dollar-row work**: it will add period dollar
  totals to `bin/claude-tokens` and one dollar row with a period picker to
  `usage_widget.lua` `render()` (one inserted block, spot not yet decided, likely near
  the credits row). `PRICES` / `price_for()` is the only price table; if they change
  it, they say so first. Whoever edits `render()` or `bin/claude-tokens` first tells the
  other which lines and functions changed. Agree the Buddy bar's spot with them before
  touching `render()`.
- Merge and release follow `.claude/skills/shipping-widget-releases` ("Several sessions,
  one release"); reactions follow `.claude/skills/adding-buddy-reactions`.
- `bin/buddy-agent` runs `claude -p` isolated (`--setting-sources ""`, strict MCP,
  `buddy-tools` MCP only, plus WebSearch in chat). Helpers for research must not widen
  that: no Bash, no file writes, no sending.
- Screen Recording is needed for window titles and pictures; without it, Auto learning
  works from app names and time only.

## Left to the builder
- File and module layout, data formats for app profiles, facts, health log and goals.
- How often Auto re-decides an app's reaction, and how much evidence it needs.
- The routing signals inside Auto, effort levels per kind, and timeouts per model.
- How the "not on your plan" test runs and is cached.
- How the Buddy's usage report is shown (chat panel message or a small window).
- The Buddy bar's exact look, agreed with the dollar tracking session.
- Pixel art for the new props and moods, within the adding-buddy-reactions rules.
- Tests: Lua specs (`tests/*_spec.lua`) and Python unittests for every new module,
  fakes for screen and Claude, no live state.
