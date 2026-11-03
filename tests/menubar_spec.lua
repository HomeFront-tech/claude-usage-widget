-- The menu bar item: its words, its menu, and the card's numbers behind both.
return function(t, dir)
  local MB = dofile(dir .. "/menubar.lua")

  t.eq(MB.titleText({ pct = 41.4, level = "ok" }, "percent"), "41%", "the tightest limit, rounded")
  t.eq(MB.titleText({ pct = 41, level = "ok" }, "icon"), "", "icon-only style has no words")
  t.eq(MB.titleText(nil, "percent"), "", "no numbers yet, no words")

  -- every square of Buddy stays on his 14 x 12 grid and off his eyes
  local onGrid, eyesClear = true, true
  for _, r in ipairs(MB.SHAPE) do
    if r[1] < 0 or r[2] < 0 or r[1] + r[3] > 14 or r[2] + r[4] > 12 then onGrid = false end
    for _, eye in ipairs({ 3, 9 }) do
      if r[1] < eye + 2 and r[1] + r[3] > eye and r[2] < 6 and r[2] + r[4] > 3 then eyesClear = false end
    end
  end
  t.ok(onGrid, "icon on Buddy's grid")
  t.ok(eyesClear, "icon leaves the eyes open")

  local f = setmetatable({}, { __index = function(_, k) return k end }) -- each fn is its name
  local function titles(items)
    local out = {}
    for _, it in ipairs(items) do out[#out + 1] = it.title end
    return table.concat(out, "|")
  end
  local usage = { { title = "Claude" }, { title = "Current session   41%", indent = 1 } }
  local s = { style = "percent", cardVisible = true, inApp = false, canMakeApp = true }
  t.eq(titles(MB.items(usage, nil, s, f)),
    "Claude|Current session   41%|-|Check usage now|Open the usage chart|-|Usage card on the desktop|"
    .. "Show the % in the menu bar|-|Make Buddy an app…|Check for updates…|Restart Buddy", "card only, in Hammerspoon")
  local b = { brain = true, muted = false, tasks = { { title = "fix-bug (working)" } }, menu = { { title = "Tell me a joke" } }, visible = true }
  local inApp = { style = "icon", cardVisible = false, inApp = true, canMakeApp = false }
  local items = MB.items(usage, b, inApp, f)
  t.eq(titles(items), "Claude|Current session   41%|-|Check usage now|Open the usage chart|-|Chat with Buddy|"
    .. "Quiet for an hour|Task sessions|Buddy|-|Usage card on the desktop|Buddy on the desktop|"
    .. "Show the % in the menu bar|-|Check for updates…|Restart Buddy|Quit Claude Buddy", "with Buddy, in the app")
  local byTitle = {}
  for _, it in ipairs(items) do byTitle[it.title] = it end
  t.eq(byTitle["Usage card on the desktop"].checked, false, "card switch shows it's off")
  t.eq(byTitle["Show the % in the menu bar"].checked, false, "icon-only style unticks the %")
  t.eq(byTitle["Buddy"].menu[1].title, "Tell me a joke", "Buddy's own menu under Buddy")
  t.eq(byTitle["Quiet for an hour"].fn, "mute", "quiet calls mute")
  t.eq(byTitle["Check for updates…"].fn, "checkUpdates", "the update item checks")
  local named = setmetatable({ updateTitle = function() return "Update to v1.16.0…" end }, getmetatable(f))
  t.ok(titles(MB.items(usage, b, inApp, named)):find("|Update to v1.16.0…|Restart Buddy", 1, true),
    "a known update names itself, just above Restart")
  t.ok(not titles(MB.items(nil, nil, s, { checkNow = "c" })):find("updates", 1, true), "no updater, no update item")
  b.muted, b.brain, b.tasks = true, false, nil
  local quiet = titles(MB.items(usage, b, inApp, f))
  t.ok(quiet:find("Talk again", 1, true) and not quiet:find("Chat with Buddy", 1, true) and not quiet:find("Task sessions", 1, true),
    "muted, no brain, no tasks")
  t.eq(titles(MB.items(nil, nil, s, { checkNow = "c" })):sub(1, 15), "Check usage now", "no usage lines, no divider first")

  -- the card's side: the words and lines it hands the menu bar
  local W = dofile(dir .. "/usage_widget.lua")
  local P = dofile(dir .. "/providers.lua")
  local now = os.time()
  local CLAUDE = { ok = true, plan = "max", fetched_at = now - 30,
    limits = { { label = "Current session", pct = 72, severity = "normal", resets_at = now + 2 * 3600 + 13 * 60 + 30 },
               { label = "Week · all models", pct = 38, severity = "normal" } } }
  W.inject({ settings = P.settings({}), data = CLAUDE, lastError = false, tokens = { tokens24h = 1234567, replies24h = 42 } })
  local tt = W.menuTitle(now)
  t.eq(tt and tt.pct, 72, "title: the tightest Claude limit")
  t.eq(tt and tt.level, "warn", "72% is past the yellow level")
  t.eq(tt and tt.stale, false, "fresh numbers")
  t.eq(titles(W.menuUsage(now)), "Claude  ·  Max · updated just now|Current session   72%  ·  Resets in 2 hr 13 min|"
    .. "Week · all models   38%|Last 24 hours: 1.2M tokens · 42 replies", "Claude's lines")
  t.eq(W.menuUsage(now)[2].indent, 1, "limits sit under the name")
  W.inject({ data = { ok = true, fetched_at = now - 3600, limits = CLAUDE.limits } })
  t.eq(W.menuTitle(now).stale, true, "an hour-old check is stale")
  W.inject({ data = false, lastError = "No Claude Code login found", tokens = false })
  t.eq(W.menuTitle(now), nil, "no numbers, no title")
  t.eq(titles(W.menuUsage(now)), "Claude|No Claude Code login found", "the error instead")
  W.inject({ lastError = false })
  t.eq(titles(W.menuUsage(now)), "Claude|Checking…", "before the first check")

  local multi = P.settings({ usage = { order = { "claude", "codex" } } })
  W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, fetched_at = now,
    limits = { { label = "Week", pct = 41 } } } }, errors = {} })
  local lines = W.menuUsage(now)
  t.eq(lines[#lines].title, "Codex   41% wk", "another AI: one line with its tightest limit")
  t.eq(lines[#lines].menu and lines[#lines].menu[1].title, "Week  41%", "…and its limits a click away")
  W.inject({ settings = P.settings({ usage = { order = { "codex" } } }) })
  t.eq(W.menuTitle(now).pct, 41, "Claude off: the first AI's limit")
  W.inject({ settings = P.settings({}), data = false, lastError = false, results = {}, errors = {} })
end
