-- Claude usage desktop widget (Hammerspoon module)
--
-- Shows the same plan limits as Claude Code's /usage: the current 5-hour session,
-- the weekly limits, any credits, and extra usage when it's turned on.
-- Numbers come from bin/claude-usage (Anthropic's usage API, signed in with
-- Claude Code's own Keychain login). The card sits on the desktop on every Space,
-- under your windows, like a macOS widget. It also starts updater.lua.
-- Every check is saved to a history file on this Mac, and bin/claude-tokens tallies
-- Claude Code's token use from its own logs. The card shows the last 24 hours of tokens
-- as hourly bars; clicking it opens the full chart (chart.lua).
-- Numbers that have missed a couple of checks turn grey, with the day they're from.
-- Click the "is out" line to update when a new version is out; drag the card to move
-- it (the spot is remembered).
--
-- Dragging polls the mouse instead of using an event tap, so Hammerspoon
-- doesn't need Accessibility permission.

local M = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local CFG = (function() -- the same config.lua the buddy and its setup wizard use
  local chunk = loadfile(DIR .. "/config.lua")
  local ok, cfg = pcall(chunk or function() end)
  return ok and type(cfg) == "table" and cfg or {}
end)()
-- Bring in Claude Code's older history (its /stats daily totals and prompt times) for the
-- chart's History tab. Off unless you choose it in the setup wizard.
local IMPORT_HISTORY = CFG.import_history == true
local FETCH = DIR .. "/bin/claude-usage"
local PYTHON = "/usr/bin/python3"
for _, p in ipairs({ "/opt/homebrew/bin/python3", "/usr/local/bin/python3" }) do
  if hs.fs.attributes(p) then PYTHON = p; break end
end
local POS_KEY = "claudeUsageWidget.topLeft"

-- The AIs on the card, their order, what each hides, how often each checks and the yellow
-- and red levels (config.lua's usage table; without one, Claude only, as always).
local P = dofile(DIR .. "/providers.lua")
local S = P.settings(CFG)
-- Seconds between Claude usage checks (its API rate-limits frequent callers, so never under
-- 5 minutes); numbers older than three checks have missed some and show grey.
local function claudeRefresh() return S.providers.claude.refresh end
local function staleAfter() return 3 * claudeRefresh() end
local LAST_KEY = "claudeUsageWidget.lastData" -- last good numbers, shown again after a reload
local TICK = 30     -- seconds between redraws (countdowns and "updated" age)
local W, PAD = 264, 16

-- Usage history: one JSON line per check, {t, v = {label = pct}, r = {label = resets_at}}.
local HIST_DIR = os.getenv("HOME") .. "/Library/Application Support/claude-usage-widget"
local HIST = HIST_DIR .. "/history.jsonl"
local KEEP_DAYS = 90
local STRIP_H = 32 -- height of the card's 24-hour token strip

local REG = hs.styledtext.defaultFonts.system.name
local BOLD = hs.styledtext.defaultFonts.boldSystem.name
local UI = assert(loadfile(DIR .. "/theme.lua"))()

local C = {
  bg    = UI.colors.bg,
  edge  = UI.colors.line,
  text  = UI.colors.ink,
  dim   = UI.colors.secondary,
  track = UI.colors.line,
  ok    = UI.colors.accent,
  warn  = UI.colors.warn,
  hot   = UI.colors.danger,
  okDim = { red = UI.colors.accent.red, green = UI.colors.accent.green, blue = UI.colors.accent.blue, alpha = 0.55 },
  -- Buddy bar: one colour per model family
  haiku  = UI.colors.blue,
  sonnet = UI.colors.warn,
  opus   = UI.colors.accent,
  fable  = UI.colors.pink,
  ollama = UI.colors.secondary,
  other  = UI.colors.muted,
}

local data, lastError, task = hs.settings.get(LAST_KEY), nil, nil
local waitUntil = 0

local function txt(s, size, color, align, bold)
  return hs.styledtext.new(s, {
    font = { name = bold and BOLD or REG, size = size },
    color = color,
    paragraphStyle = { alignment = align or "left", lineBreak = "truncateTail" },
  })
end

-- Wrap summaries by their drawn width, so long model lists and comparisons keep every line.
local function wrapped(s, size, color, width)
  local lines, line = {}, ""
  for word in s:gmatch("%S+") do
    local nextLine = line == "" and word or line .. " " .. word
    if line ~= "" and hs.drawing.getTextDrawingSize(txt(nextLine, size, color)).w > width then
      lines[#lines + 1], line = line, word
    else line = nextLine end
  end
  if line ~= "" then lines[#lines + 1] = line end
  local styled = txt(table.concat(lines, "\n"), size, color)
  return styled, math.max(16, math.ceil(hs.drawing.getTextDrawingSize(styled).h / 4) * 4)
end

local function clock(ts)
  return (os.date("%I:%M %p", ts):gsub("^0", ""))
end

-- "at 4:10 AM" today, "Oct 21, 4:10 AM" on another day.
local function when(ts, now)
  if os.date("%x", ts) == os.date("%x", now) then return "at " .. clock(ts) end
  return (os.date("%b %d", ts):gsub(" 0", " ")) .. ", " .. clock(ts)
end

local function resetText(ts, now)
  if not ts then return "" end
  now = now or os.time()
  local s = ts - now
  if s <= -staleAfter() then return "Reset " .. when(ts, now) end -- the bar's number is from before it
  if s <= 0 then return "Resetting now" end
  if s < 3600 then return string.format("Resets in %d min", math.ceil(s / 60)) end
  if s < 86400 then return string.format("Resets in %d hr %d min", s // 3600, (s % 3600) // 60) end
  if s < 7 * 86400 then return "Resets " .. os.date("%a", ts) .. " " .. clock(ts) end
  return "Resets " .. (os.date("%b %d", ts):gsub(" 0", " "))
end

local function ageText(ts, now)
  now = now or os.time()
  local m = (now - ts) // 60
  if m < 1 then return "just now" end
  if m < 60 then return m .. " min ago" end
  return when(ts, now)
end

local function isStale(ts, now)
  return (now or os.time()) - ts > staleAfter()
end

-- The user's yellow and red levels; the API's own severity wins when it's higher.
local LEVEL_COLOR = { ok = C.ok, warn = C.warn, hot = C.hot }
local function barColor(pct, severity)
  return LEVEL_COLOR[P.level(pct, severity, S)]
end

-- Drop history lines older than KEEP_DAYS (and any half-written line).
local function pruneHistory()
  hs.fs.mkdir(HIST_DIR)
  local f = io.open(HIST)
  if not f then return end
  local now, kept, total = os.time(), {}, 0
  for line in f:lines() do
    total = total + 1
    local t = tonumber(line:match('"t":%s*(%d+)'))
    if t and t >= now - KEEP_DAYS * 86400 and line:match("}%s*$") then kept[#kept + 1] = line end
  end
  f:close()
  if #kept < total then
    local out = io.open(HIST, "w")
    if out then out:write(table.concat(kept, "\n"), #kept > 0 and "\n" or ""); out:close() end
  end
end

-- Save one check to the history file. Returns the point.
local function record(res)
  local v, r = {}, {}
  for _, l in ipairs(res.limits or {}) do
    v[l.label], r[l.label] = l.pct, l.resets_at
  end
  local p = { t = res.fetched_at or os.time(), v = v, r = r }
  local f = io.open(HIST, "a")
  if f then f:write(hs.json.encode(p), "\n"); f:close() end
  return p
end

-- The last 24 hours of Claude Code tokens as hourly bars (this hour brightest). Returns the next y.
local function strip(els, y)
  local bw, spark = W - 2 * PAD, M.tokens and M.tokens.spark
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.track,
    frame = { x = PAD, y = y + STRIP_H, w = bw, h = 1 } }
  if type(spark) ~= "table" or #spark == 0 then
    els[#els + 1] = { type = "text", text = txt("Reading Claude Code's logs…", 11, C.dim, "center"),
      frame = { x = PAD, y = y + 8, w = bw, h = 16 } }
  else
    local hi, slot = 1, bw / #spark
    for _, v in ipairs(spark) do hi = math.max(hi, v) end
    local bar = math.max(2, slot - 2)
    for i, v in ipairs(spark) do
      if v > 0 then
        local h = math.max(1.5, v / hi * STRIP_H)
        els[#els + 1] = { type = "rectangle", action = "fill", fillColor = i == #spark and C.ok or C.okDim,
          roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
          frame = { x = PAD + (i - 1) * slot + (slot - bar) / 2, y = y + STRIP_H - h, w = bar, h = h } }
      end
    end
  end
  els[#els + 1] = { type = "text", text = txt("Tokens · 24h", 11, C.dim), frame = { x = PAD, y = y + STRIP_H + 4, w = bw / 2, h = 16 } }
  els[#els + 1] = { type = "text", text = txt("Open chart ›", 11, C.dim, "right"), frame = { x = W / 2, y = y + STRIP_H + 4, w = bw / 2, h = 16 } }
  return y + STRIP_H + 28
end

-- One limit: label and figure, a bar, then the reset line. Returns the next y.
local function row(els, y, label, figure, pct, color, sub)
  local bw = W - 2 * PAD
  local number = txt(figure, 13, color, "right", true)
  local nw = math.min(bw * 0.6, math.ceil(hs.drawing.getTextDrawingSize(number).w) + 2)
  els[#els + 1] = { type = "text", text = txt(label, 12, C.text), frame = { x = PAD, y = y, w = bw - nw - 8, h = 18 } }
  els[#els + 1] = { type = "text", text = number, frame = { x = W - PAD - nw, y = y - 1, w = nw, h = 18 } }
  local bar = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 3, yRadius = 3 } }
  els[#els + 1] = hs.fnutils.copy(bar)
  els[#els].fillColor, els[#els].frame = C.track, { x = PAD, y = y + 20, w = bw, h = 6 }
  local fill = math.max(0, math.min(1, pct / 100)) * bw
  if fill > 0 then
    els[#els + 1] = hs.fnutils.copy(bar)
    els[#els].fillColor, els[#els].frame = color, { x = PAD, y = y + 20, w = math.max(fill, 6), h = 6 }
  end
  els[#els + 1] = { type = "text", text = txt(sub, 11, C.dim), frame = { x = PAD, y = y + 30, w = bw, h = 16 } }
  return y + 56
end

-- The API value row: dollars for a chosen period (bin/claude-tokens works them out), the
-- "× your plan" line, and a fun comparison that stays until spending moves by a typical
-- amount for that period. Buddy writes and says new ones; comparisons.lua covers for him.
local Value = dofile(DIR .. "/value.lua")
local Compare = dofile(DIR .. "/comparisons.lua")
local PERIOD_KEY, BUDDY_KEY = "claudeUsageWidget.valuePeriod", "claudeUsageWidget.valueBuddy"
local COMPARE_KEY, THINGS_KEY = "claudeUsageWidget.comparisons", "claudeUsageWidget.comparedThings"
local WARM = UI.colors.hover
local KEEP_THINGS = 50

local function setting(key, default)
  local v = hs.settings.get(key)
  if v == nil then return default end
  return v
end
local function selected() return setting(PERIOD_KEY, "month") end
local function includeBuddy() return setting(BUDDY_KEY, true) end
local function shortDay(ts) return (os.date("%b %d", ts):gsub(" 0", " ")) end

local function periodLabel(key)
  for _, p in ipairs(Value.PERIODS) do
    if p.key == key then return p.label end
  end
  return key
end

-- When the plan's current session and week began, from their reset times; nil for one that's
-- unknown or a session that's over (bin/claude-tokens then uses the last 5 hours or Monday).
local function planStarts(usage, now)
  local session, week
  now = now or os.time()
  for _, l in ipairs(usage and usage.limits or {}) do
    if l.resets_at and l.label == "Current session" and l.resets_at > now then session = l.resets_at - 5 * 3600 end
    if l.resets_at and l.label == "Week · all models" then
      -- a week reset that has just passed is where the new week starts (until the next check says so)
      if l.resets_at > now then week = l.resets_at - 7 * 86400 elseif l.resets_at > now - 7 * 86400 then week = l.resets_at end
    end
  end
  return session, week
end

-- What the row says for one period, or nil with no numbers for it. comparisons: the saved
-- { [period] = { from, at, text } }. importHistory: older history is on (the default is the
-- config's); without it, year to date and all time say how far back the logs go.
local function valueLines(periods, key, withBuddy, comparisons, importHistory)
  if importHistory == nil then importHistory = IMPORT_HISTORY end
  local p = type(periods) == "table" and type(periods.list) == "table" and periods.list[key]
  if type(p) ~= "table" then return nil end
  local figure = Value.figure(p, withBuddy)
  local multiple = Value.multiple(p, figure)
  if not importHistory and (key == "ytd" or key == "all") and periods.first and periods.first > (p.from or 0) then
    local since = "since " .. shortDay(periods.first)
    multiple = multiple and (multiple .. " · " .. since) or (since:gsub("^%l", string.upper))
  end
  local saved = type(comparisons) == "table" and comparisons[key] or nil
  return {
    label = "API value", period = periodLabel(key), figure = Value.money(figure), multiple = multiple,
    comparison = saved and (Value.same(saved.from, p.from) or p.rolling) and saved.text or nil,
  }
end

local function periodsNow() return M.demoPeriods or (M.tokens and M.tokens.periods) end

-- Made-up numbers for the row, shown with the chart's demo (ClaudeUsage.chart(true)).
function M.demoValue(on)
  if not on then
    M.demoPeriods, M.demoComparisons = nil, nil
    return
  end
  local function p(value, buddy, paid) return { from = 0, value = value, buddy = buddy, paid = paid, spread = value / 3 } end
  M.demoPeriods = { first = os.time() - 140 * 86400, has_buddy = true, list = {
    session = p(18.4, 0.3, 0.7), today = p(41.2, 0.6, 3.3), week = p(236.8, 2.1, 23.1),
    month = p(1284.2, 9.5, 100), ytd = p(6420.5, 40, 500), all = p(6420.5, 40, 500) } }
  M.demoComparisons = {
    session = { from = 0, text = "🌮 That's 6 tacos" }, today = { from = 0, text = "☕ That's 6 Starbucks lattes" },
    week = { from = 0, text = "⛽ That's 3 tanks of gas" }, month = { from = 0, text = "🍕 That's 71 large pepperoni pizzas" },
    ytd = { from = 0, text = "🚗 43% of a used Honda Civic" }, all = { from = 0, text = "🚗 43% of a used Honda Civic" } }
end

-- Draws the row after the credits. Returns the next y; M.valueY is where its first line sits.
local function valueRow(els, y)
  M.valueY = nil
  local l = valueLines(periodsNow(), selected(), includeBuddy(), M.demoPeriods and M.demoComparisons or setting(COMPARE_KEY, {}))
  if not l then return y end
  local bw = W - 2 * PAD
  local number = txt(l.figure, 13, C.ok, "right", true)
  local nw = math.min(bw * 0.6, math.ceil(hs.drawing.getTextDrawingSize(number).w) + 2)
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.edge,
    frame = { x = PAD, y = y, w = bw, h = 1 } }
  y = y + 12
  els[#els + 1] = { type = "text", text = txt(l.label .. "  " .. l.period .. " ▾", 12, C.text), frame = { x = PAD, y = y, w = bw - nw - 8, h = 18 } }
  els[#els + 1] = { type = "text", text = number, frame = { x = W - PAD - nw, y = y - 1, w = nw, h = 18 } }
  M.valueY = { y - 4, y + 20 }
  y = y + 24
  if l.multiple then
    els[#els + 1] = { type = "text", text = txt(l.multiple, 11, C.dim), frame = { x = PAD, y = y, w = bw, h = 16 } }
    y = y + 20
  end
  if l.comparison then
    local styled, h = wrapped(l.comparison, 11, WARM, bw)
    els[#els + 1] = { type = "text", text = styled, frame = { x = PAD, y = y, w = bw, h = h } }
    y = y + h
  end
  return y + 8
end

-- Buddy's own tokens by model family, largest first: { { family = "haiku", share = 0.81 }, ... }.
-- `b.models` is { model id = tokens }; shares add up to 1 (round only for display).
function M.buddyParts(b)
  local sums, total = {}, 0
  for model, n in pairs(type(b) == "table" and b.models or {}) do
    if type(n) == "number" and n > 0 then
      local fam = model:match("^claude%-(%a+)%-%d") or model:match("^claude%-(%a+)$")
      if model:find("^ollama:") then fam = "ollama"
      elseif fam ~= "haiku" and fam ~= "sonnet" and fam ~= "opus" and fam ~= "fable" then fam = "other" end
      sums[fam], total = (sums[fam] or 0) + n, total + n
    end
  end
  local parts = {}
  for fam, n in pairs(sums) do parts[#parts + 1] = { family = fam, share = n / total } end
  table.sort(parts, function(a, c)
    if a.share ~= c.share then return a.share > c.share end
    return a.family < c.family
  end)
  return parts
end

-- Lay the family parts out across a track: { { x, w, family } }, contiguous from x to x + width.
-- Tiny shares keep a visible minimum; the difference comes off the largest segment.
function M.buddySegments(parts, x, width)
  local segs, sum, big = {}, 0, 1
  local minW = #parts > 0 and math.min(2, width / #parts) or 0
  for i, e in ipairs(parts) do
    segs[i] = { w = math.max(minW, e.share * width), family = e.family }
    sum = sum + segs[i].w
    if segs[i].w > segs[big].w then big = i end
  end
  if #segs > 0 then segs[big].w = segs[big].w - (sum - width) end
  local at = x
  for _, sg in ipairs(segs) do sg.x, at = at, at + sg.w end
  if #segs > 0 then segs[#segs].w = x + width - segs[#segs].x end -- absorb float drift
  return segs
end

-- Shown whenever Buddy made calls in the 24 h, even if none counted any tokens.
function M.buddyVisible(b) return type(b) == "table" and (b.calls or 0) > 0 end

-- Buddy's slice of the 24 h tokens: label and share, a bar split by model family, then the
-- top families and what he cost. Hidden when he made no calls. Returns the next y.
local function buddyRow(els, y)
  local b = M.tokens and M.tokens.buddy24h
  if not M.buddyVisible(b) then return y end
  local parts = M.buddyParts(b)
  local bw, share = W - 2 * PAD, math.max(0, math.min(1, M.tokens.share24h or 0))
  local pct = math.floor(share * 100 + 0.5)
  els[#els + 1] = { type = "text", text = txt("Buddy", 12, C.text), frame = { x = PAD, y = y, w = bw - 118, h = 18 } }
  els[#els + 1] = { type = "text", text = txt(pct < 1 and share > 0 and "<1% of 24h" or string.format("%d%% of 24h", pct), 13, C.ok, "right", true),
    frame = { x = W - PAD - 110, y = y - 1, w = 110, h = 18 } }
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.track,
    roundedRectRadii = { xRadius = 3, yRadius = 3 }, frame = { x = PAD, y = y + 20, w = bw, h = 6 } }
  for _, sg in ipairs(M.buddySegments(parts, PAD, bw)) do
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C[sg.family],
      frame = { x = sg.x, y = y + 20, w = sg.w, h = 6 } }
  end
  local desc = {}
  for i, e in ipairs(parts) do
    if i <= 3 then desc[#desc + 1] = string.format("%s %d%%", e.family:sub(1, 1):upper() .. e.family:sub(2), math.floor(e.share * 100 + 0.5)) end
  end
  desc[#desc + 1] = string.format("≈$%.2f", b.cost or 0)
  local summary, h = wrapped(table.concat(desc, " · "), 11, C.dim, bw)
  els[#els + 1] = { type = "text", text = summary, frame = { x = PAD, y = y + 30, w = bw, h = h } }
  return y + 40 + h
end

-- The other AIs -----------------------------------------------------------------------------
-- Each AI after Claude (config.lua's usage.order) gets a small row: its name, one bar for its
-- tightest limit and a short figure; a click lists all its limits. With Claude off, the first
-- one takes Claude's place at the top. usage_poll.lua fetches their numbers.
local Poll = dofile(DIR .. "/usage_poll.lua")
local Alerts = dofile(DIR .. "/usage_alerts.lua")
local ALERTS_KEY = "claudeUsageWidget.alerts" -- which limits have had their red alert
local poller, injected -- injected: { results, errors } from a test, in place of the poller's

-- An AI's latest numbers and error. The Grok subscription is worked out from config.lua.
local function resultsFor(id)
  if P.byId(id).kind == "manual" then return P.grokPlan(S.providers[id], os.time()), nil end
  local from = injected or poller
  if not from then return nil, nil end
  return from.results[id], from.errors[id]
end

-- Every AI that's on, other than Claude, in order: { id, name, res, err } (the buddy's
-- /usage and chat answers use it).
function M.others()
  local list = {}
  for _, id in ipairs(S.order) do
    if id ~= "claude" then
      local res, err = resultsFor(id)
      list[#list + 1] = { id = id, name = P.byId(id).name, res = res, err = err }
    end
  end
  return list
end

-- "Tell me when one turns red": Buddy says it (and texts it, when Telegram is paired) once
-- per limit until it drops back below yellow.
local function alerts(id, res)
  if not (S.alert_red and type(res) == "table" and res.ok) then return end
  local fires, state = Alerts.check(hs.settings.get(ALERTS_KEY) or {}, id, P.visible(res, S.providers[id].hide), S)
  hs.settings.set(ALERTS_KEY, state)
  for _, it in ipairs(fires) do
    local line = Alerts.line(P.byId(id).name, it, resetText(it.resets_at))
    if ClaudeBuddy and ClaudeBuddy.alert then ClaudeBuddy.alert(line) end
  end
end

-- Alerts never hold up a redraw: a broken say or Telegram send is logged, not raised.
local function checkAlerts(id, res)
  local ok, err = pcall(alerts, id, res)
  if not ok then print("ClaudeUsage alert: " .. tostring(err)) end
end
M.checkAlerts = checkAlerts

local NAME_W, FIG_W = 76, 72
-- One small row. Returns the next y and records its click band in M.otherRows.
local function otherRow(els, y, id, now)
  local e, ps = P.byId(id), S.providers[id]
  local res, err = resultsFor(id)
  local top = P.tightest(res, ps.hide)
  local fetched = type(res) == "table" and type(res.fetched_at) == "number" and res.fetched_at
  local stale = fetched and e.refresh and P.isStale(fetched, ps.refresh, now)
  local bw, figure, color, pct = W - 2 * PAD, nil, C.dim, nil
  local facts = type(res) == "table" and type(res.facts) == "table" and res.facts or {}
  if type(res) == "table" and res.blocked then figure, color, pct = "Blocked", C.hot, 100
  elseif top then figure, color, pct = P.short(top), barColor(top.pct, top.severity), top.pct
  elseif type(facts[1]) == "string" then figure = facts[1]
  elseif res or err then figure = "—"
  else figure = "Checking…" end
  if stale then color = C.dim end
  local y0 = y
  els[#els + 1] = { type = "text", text = txt(e.name, 12, C.text), frame = { x = PAD, y = y, w = NAME_W, h = 18 } }
  if pct then
    local bx, bwide = PAD + NAME_W + 8, bw - NAME_W - FIG_W - 16
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.track, roundedRectRadii = { xRadius = 2, yRadius = 2 },
      frame = { x = bx, y = y + 7, w = bwide, h = 4 } }
    local fill = math.max(0, math.min(1, pct / 100)) * bwide
    if fill > 0 then
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = color, roundedRectRadii = { xRadius = 2, yRadius = 2 },
        frame = { x = bx, y = y + 7, w = math.max(fill, 4), h = 4 } }
    end
    els[#els + 1] = { type = "text", text = txt(figure, 12, color, "right", true), frame = { x = W - PAD - FIG_W, y = y, w = FIG_W, h = 18 } }
  else -- a fact or a status, in the room the bar would have used
    els[#els + 1] = { type = "text", text = txt(figure, 11, C.dim, "right"),
      frame = { x = PAD + NAME_W + 8, y = y + 1, w = bw - NAME_W - 8, h = 16 } }
  end
  y = y + 22
  local note, noteColor
  if err then note, noteColor = err, C.warn
  elseif stale then note, noteColor = "From " .. ageText(fetched, now), C.dim end
  if note then
    els[#els + 1] = { type = "text", text = txt(note, 11, noteColor), frame = { x = PAD, y = y - 4, w = bw, h = 16 } }
    y = y + 16
  end
  M.otherRows[#M.otherRows + 1] = { top = y0 - 2, bottom = y - 2, id = id }
  return y
end

-- The "Other AIs" list, when any are on. Returns the next y.
local function otherSection(els, y, now)
  M.otherRows = {}
  if #S.rest == 0 then return y end
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.edge, frame = { x = PAD, y = y, w = W - 2 * PAD, h = 1 } }
  els[#els + 1] = { type = "text", text = txt("Other AIs", 11, C.dim), frame = { x = PAD, y = y + 8, w = W - 2 * PAD, h = 16 } }
  y = y + 30
  for _, id in ipairs(S.rest) do
    -- a row that can't be drawn (odd saved numbers) is left out; the rest of the card stays
    local row = {}
    local ok, nextY = pcall(otherRow, row, y, id, now)
    if ok then
      for _, e in ipairs(row) do els[#els + 1] = e end
      y = nextY
    end
  end
  return y + 4
end

-- With Claude off, the first AI in the order is drawn the way Claude is. Returns the next y.
local function leadSection(els, id, now)
  local e, ps = P.byId(id), S.providers[id]
  local res, err = resultsFor(id)
  local ok = type(res) == "table"
  local fetched = ok and type(res.fetched_at) == "number" and res.fetched_at
  local stale = fetched and e.refresh and P.isStale(fetched, ps.refresh, now)
  local plan = ok and type(res.plan) == "string" and res.plan ~= "" and (res.plan:gsub("^%l", string.upper) .. " · ") or ""
  local status = fetched and plan .. ageText(fetched, now) or ""
  local bw = W - 2 * PAD
  els[#els + 1] = { type = "text", text = txt(e.name, 14, C.text, "left", true), frame = { x = PAD, y = 12, w = 112, h = 20 } }
  els[#els + 1] = { type = "text", text = txt(status, 11, stale and C.warn or C.dim, "right"), frame = { x = PAD + 120, y = 15, w = bw - 120, h = 16 } }
  local y = 44
  if ok then
    if res.blocked then
      els[#els + 1] = { type = "text", text = txt("Blocked right now", 12, C.hot), frame = { x = PAD, y = y, w = bw, h = 16 } }
      y = y + 22
    end
    for _, it in ipairs(P.visible(res, ps.hide)) do
      y = row(els, y, it.label, P.figure(it), it.pct, stale and C.dim or barColor(it.pct, it.severity), resetText(it.resets_at, now))
    end
    for _, f in ipairs(type(res.facts) == "table" and res.facts or {}) do
      if type(f) == "string" then
        local line, h = wrapped(f, 11, C.dim, bw)
        els[#els + 1] = { type = "text", text = line, frame = { x = PAD, y = y, w = bw, h = h } }
        y = y + h + 4
      end
    end
  elseif not err then
    els[#els + 1] = { type = "text", text = txt("Loading…", 12, C.dim), frame = { x = PAD, y = y, w = bw, h = 16 } }
    y = y + 22
  end
  if err then
    local message, h = wrapped(err, 11, C.warn, bw)
    els[#els + 1] = { type = "text", text = message, frame = { x = PAD, y = y, w = bw, h = h } }
    y = y + h + 4
  end
  return y
end

-- The menu from a click on a small row: every limit with its figure and reset, the facts,
-- what went wrong, when it's from, and Check now.
function M.providerMenuItems(id)
  local res, err = resultsFor(id)
  local items, more = {}, {}
  for _, it in ipairs(P.visible(res, S.providers[id].hide)) do
    local reset = resetText(it.resets_at)
    items[#items + 1] = { title = it.label .. "  " .. P.figure(it) .. (reset ~= "" and "  · " .. reset or "") }
  end
  if type(res) == "table" and res.blocked then more[#more + 1] = { title = "Blocked right now" } end
  for _, f in ipairs(type(res) == "table" and type(res.facts) == "table" and res.facts or {}) do
    if type(f) == "string" then more[#more + 1] = { title = f } end
  end
  if err then more[#more + 1] = { title = err } end
  if type(res) == "table" and type(res.fetched_at) == "number" then more[#more + 1] = { title = "Updated " .. ageText(res.fetched_at) } end
  if P.byId(id).fetch then
    more[#more + 1] = { title = "Check now", fn = function() if poller then poller:refresh(id) end end }
  end
  if #items > 0 and #more > 0 then items[#items + 1] = { title = "-" } end
  for _, m in ipairs(more) do items[#items + 1] = m end
  return items
end

local function providerMenu(id)
  M.providerMenu = M.providerMenu or hs.menubar.new(false)
  M.providerMenu:setMenu(M.providerMenuItems(id))
  M.providerMenu:popupMenu(hs.mouse.absolutePosition(), true)
end

local function otherAt(y)
  for _, r in ipairs(M.otherRows or {}) do
    if y >= r.top and y < r.bottom then return r.id end
  end
end

-- Claude's section: header, token strip, Buddy's share, limits, credits, the API value row,
-- the week's breakdown and any error. Returns the next y.
local function claudeSection(els, now)
  local status, stale = "", data and isStale(data.fetched_at, now)
  if data then
    status = (data.plan and (data.plan:gsub("^%l", string.upper) .. " · ") or "") .. ageText(data.fetched_at, now)
  end
  els[#els + 1] = { type = "text", text = txt("Claude", 14, C.text, "left", true), frame = { x = PAD, y = 12, w = 64, h = 20 } }
  els[#els + 1] = { type = "text", text = txt(status, 11, stale and C.warn or C.dim, "right"), frame = { x = PAD + 72, y = 15, w = W - 2 * PAD - 72, h = 16 } }

  local y = strip(els, 44)
  local tk = M.tokens
  if tk and (tk.tokens24h or 0) > 0 then
    local function big(n)
      if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
      if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
      if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
      return tostring(math.floor(n))
    end
    local line = string.format("24h: %s tokens · %d replies · ≈$%.0f", big(tk.tokens24h), tk.replies24h or 0, tk.cost24h or 0)
    local summary, h = wrapped(line, 11, C.dim, W - 2 * PAD)
    els[#els + 1] = { type = "text", text = summary, frame = { x = PAD, y = y - 4, w = W - 2 * PAD, h = h } }
    y = y + h + 4
  end
  y = buddyRow(els, y)
  if data then
    for _, it in ipairs(P.visible(data, S.providers.claude.hide)) do -- limits, then credits
      y = row(els, y, it.label, P.figure(it), it.pct, stale and C.dim or barColor(it.pct, it.severity), resetText(it.resets_at, now))
    end
    y = valueRow(els, y)
    local parts = {}
    for _, b in ipairs(data.breakdown or {}) do parts[#parts + 1] = b.name .. " " .. b.pct .. "%" end
    if #parts > 0 then
      local summary, h = wrapped("This week: " .. table.concat(parts, " · "), 11, C.dim, W - 2 * PAD)
      els[#els + 1] = { type = "text", text = summary, frame = { x = PAD, y = y, w = W - 2 * PAD, h = h } }
      y = y + h + 4
    end
  elseif not lastError then
    els[#els + 1] = { type = "text", text = txt("Loading…", 12, C.dim), frame = { x = PAD, y = y, w = W - 2 * PAD, h = 16 } }
    y = y + 22
  end
  if lastError then
    local message, h = wrapped(lastError, 11, C.warn, W - 2 * PAD)
    els[#els + 1] = { type = "text", text = message, frame = { x = PAD, y = y, w = W - 2 * PAD, h = h } }
    y = y + h + 4
  end
  return y
end

-- The card's elements and height, built without touching the canvas (render() draws them).
function M.elements(now)
  now = now or os.time()
  local bg = {
    type = "rectangle", action = "strokeAndFill", fillColor = C.bg, strokeColor = C.edge, strokeWidth = 1,
    roundedRectRadii = { xRadius = UI.radius.panel, yRadius = UI.radius.panel }, frame = { x = 0.5, y = 0.5, w = W - 1, h = 0 },
  }
  local els = { bg }
  local y
  if S.claudeOn then y = claudeSection(els, now) else y = leadSection(els, S.lead, now) end
  y = otherSection(els, y, now)
  local update = M.updater and M.updater.available
  M.updateY = nil
  if update then
    M.updateY = y - 2
    local message, h = wrapped("↑ v" .. update.version .. " is out · click here to update", 11, C.ok, W - 2 * PAD)
    els[#els + 1] = { type = "text", text = message, frame = { x = PAD, y = y, w = W - 2 * PAD, h = h } }
    y = y + h + 4
  end

  local h = y + 8
  bg.frame.h = h - 1
  return els, h
end

local function render()
  if not M.canvas then return end
  local els, h = M.elements()
  M.canvas:size({ w = W, h = h })
  M.canvas:replaceElements(els)
end

-- For tests: set the card's numbers directly (false clears one).
function M.inject(state)
  local function v(x) if x == false then return nil end return x end
  if state.data ~= nil then data = v(state.data) end
  if state.lastError ~= nil then lastError = v(state.lastError) end
  if state.tokens ~= nil then M.tokens = v(state.tokens) end
  if state.settings ~= nil then S = state.settings end
  if state.results ~= nil or state.errors ~= nil then
    injected = { results = state.results or {}, errors = state.errors or {} }
  end
end

-- A new comparison for the period on the card when its dollars have moved enough (value.lua
-- decides). Buddy's brain writes it if it can; otherwise the built-in list. Buddy says each
-- new one. One request at a time; one that never answers is given up on after 3 minutes.
local comparingSince
local function checkComparison()
  local periods = M.tokens and M.tokens.periods
  if M.demoPeriods or (comparingSince and os.time() - comparingSince < 180) then return end
  if type(periods) ~= "table" or type(periods.list) ~= "table" then return end
  local key = selected()
  local p = periods.list[key]
  if type(p) ~= "table" then return end
  local figure = Value.figure(p, includeBuddy())
  local saved = setting(COMPARE_KEY, {})
  local due = Value.due(saved[key], p, figure)
  if due == "rollover" then
    saved[key] = nil
    hs.settings.set(COMPARE_KEY, saved)
    render()
    due = Value.due(nil, p, figure)
  end
  if due == "rebase" then
    saved[key].at = figure
    hs.settings.set(COMPARE_KEY, saved)
    return
  end
  if due ~= "new" then return end
  local things = setting(THINGS_KEY, {})
  comparingSince = os.time()
  local function use(reply)
    comparingSince = nil
    local line = reply and Value.fill(reply, figure)
    if not line then
      reply = Compare.pick(figure, things)
      line = Value.fill(reply, figure)
    end
    if not line then return end
    local all = setting(COMPARE_KEY, {})
    all[key] = { from = p.from, at = figure, text = line }
    hs.settings.set(COMPARE_KEY, all)
    table.insert(things, 1, reply.thing)
    while #things > KEEP_THINGS do table.remove(things) end
    hs.settings.set(THINGS_KEY, things)
    render()
    if ClaudeBuddy and ClaudeBuddy.say then ClaudeBuddy.say(line, true) end
  end
  local ctx = { figure = figure, period = periodLabel(key), avoid = things }
  if not (ClaudeBuddy and ClaudeBuddy.compare and ClaudeBuddy.compare(ctx, use)) then use(nil) end
end

-- The period menu, from a click on the row's first line.
local function valueMenu()
  local items = {}
  for _, p in ipairs(Value.PERIODS) do
    items[#items + 1] = { title = p.label, checked = selected() == p.key, fn = function()
      hs.settings.set(PERIOD_KEY, p.key)
      render()
      checkComparison()
    end }
  end
  local periods = periodsNow()
  if periods and periods.has_buddy then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Include Buddy's own use", checked = includeBuddy(), fn = function()
      hs.settings.set(BUDDY_KEY, not includeBuddy())
      render()
      checkComparison()
    end }
  end
  M.valueMenu = M.valueMenu or hs.menubar.new(false)
  M.valueMenu:setMenu(items)
  M.valueMenu:popupMenu(hs.mouse.absolutePosition(), true)
end

local function refresh()
  if task and task:isRunning() then return end
  if os.time() < waitUntil then return end -- the API asked us to slow down
  task = hs.task.new(PYTHON, function(_, out)
    local ok, res = pcall(hs.json.decode, out or "")
    if ok and type(res) == "table" and res.ok then
      data, lastError = res, nil
      hs.settings.set(LAST_KEY, res)
      local point = record(res)
      if M.chartWin then M.chartWin.push(point, res) end
      checkAlerts("claude", res)
    else
      lastError = (ok and type(res) == "table" and res.error) or "Usage check failed"
      if ok and type(res) == "table" and res.retry_after then
        waitUntil = os.time() + math.max(60, math.min(tonumber(res.retry_after) or 600, 3600))
      end
    end
    render()
  end, { "-I", FETCH })
  task:start()
end

-- Token tallies from Claude Code's own logs (bin/claude-tokens; quick after the first run).
local TOKENS = HIST_DIR .. "/tokens.json"
local tokTask
local function scanTokens()
  if tokTask and tokTask:isRunning() then return end
  local args = { "-n", "10", PYTHON, "-I", DIR .. "/bin/claude-tokens" }
  if IMPORT_HISTORY then args[#args + 1] = "--history" end
  local session, week = planStarts(data)
  if session then args[#args + 1], args[#args + 2] = "--session-start", tostring(math.floor(session)) end
  if week then args[#args + 1], args[#args + 2] = "--week-start", tostring(math.floor(week)) end
  if type(CFG.plan_price) == "number" and CFG.plan_price > 0 then
    args[#args + 1], args[#args + 2] = "--plan-price", tostring(CFG.plan_price)
  end
  tokTask = hs.task.new("/usr/bin/nice", function(_, out)
    local ok, res = pcall(hs.json.decode, out or "")
    if ok and type(res) == "table" and res.ok then
      M.tokens = res
      if M.chartWin then M.chartWin.pushTokens(TOKENS) end
      render()
      checkComparison()
    end
  end, args)
  tokTask:start()
end

-- Open the usage chart window (demo = made-up data, for trying it out).
function M.chart(demo)
  M.demoValue(demo)
  render()
  M.chartWin = M.chartWin or dofile(DIR .. "/chart.lua")
  M.chartWin.open({ dir = DIR, history = HIST, tokens = TOKENS, billing = HIST_DIR .. "/billing.json", current = data, demo = demo,
                    importHistory = IMPORT_HISTORY })
  scanTokens()
end

local function onAScreen(p)
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:frame()
    if p.x >= f.x and p.x < f.x + f.w - 40 and p.y >= f.y and p.y < f.y + f.h - 40 then return true end
  end
  return false
end

-- Saved spot if that screen is connected, otherwise the top-left of the main screen.
-- The saved spot is kept for when its screen returns.
local function place()
  local p = hs.settings.get(POS_KEY)
  if not (p and onAScreen(p)) then
    local f = hs.screen.primaryScreen():frame()
    p = { x = f.x + 24, y = f.y + 24 }
  end
  M.canvas:topLeft(p)
end

-- clickY: where in the card the mouse went down (a click on the update line updates).
local function startDrag(clickY)
  if M.dragTimer then M.dragTimer:stop() end
  local m0, p0, moved = hs.mouse.absolutePosition(), M.canvas:topLeft(), false
  M.dragTimer = hs.timer.doEvery(1 / 60, function()
    local m = hs.mouse.absolutePosition()
    if not hs.eventtap.checkMouseButtons().left then
      M.dragTimer:stop()
      M.dragTimer = nil
      if moved then
        local p = M.canvas:topLeft()
        hs.settings.set(POS_KEY, { x = p.x, y = p.y })
      elseif M.updater and M.updater.available and M.updateY and (clickY or 0) >= M.updateY then
        M.updater.prompt()
      elseif M.valueY and clickY and clickY >= M.valueY[1] and clickY <= M.valueY[2] then
        valueMenu()
      elseif clickY and otherAt(clickY) then
        providerMenu(otherAt(clickY))
      elseif not S.claudeOn then -- no Claude chart to open: check the AIs again instead
        if poller then poller:refreshAll() end
      else
        M.chart()
        refresh()
      end
      return
    end
    if math.abs(m.x - m0.x) + math.abs(m.y - m0.y) > 3 then moved = true end
    if moved then M.canvas:topLeft({ x = p0.x + m.x - m0.x, y = p0.y + m.y - m0.y }) end
  end)
end

function M.start()
  pruneHistory()
  M.canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = 100 })
  -- One above the desktop-icon level: Finder's full-screen desktop window shares that
  -- level and, once it's ordered in front, swallows every click meant for the card.
  M.canvas:level(hs.canvas.windowLevels.desktopIcon + 1)
  M.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  M.canvas:clickActivating(false)
  M.canvas:canvasMouseEvents(true, false, false, false)
  M.canvas:mouseCallback(function(_, msg, _, _, y) if msg == "mouseDown" then startDrag(y) end end)
  place()
  render()
  M.canvas:show()

  if S.claudeOn then
    if not (data and data.fetched_at and os.time() - data.fetched_at < 60) then refresh() end -- reloads reuse fresh numbers
    M.fetchTimer = hs.timer.doEvery(claudeRefresh(), refresh)
    scanTokens()
    M.tokenTimer = hs.timer.doEvery(claudeRefresh(), scanTokens)
  end
  local ids = {}
  for _, id in ipairs(S.order) do
    if P.byId(id).fetch then ids[#ids + 1] = id end
  end
  if #ids > 0 then
    poller = Poll.new({ python = PYTHON, script = DIR .. "/bin/ai-usage", ids = ids,
      argsFor = function(id) return P.args(id, S.providers[id], false) end,
      refreshFor = function(id) return S.providers[id].refresh end,
      onResult = function(id)
        checkAlerts(id, poller.results[id])
        render()
      end })
    M.poller = poller:start()
  end
  M.updater = dofile(DIR .. "/updater.lua").start({ dir = DIR, onChange = render })
  M.tickTimer = hs.timer.doEvery(TICK, render)
  M.screenWatcher = hs.screen.watcher.new(function()
    M.placeTimer = hs.timer.doAfter(2, place)
  end):start()
  M.wakeWatcher = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake or ev == hs.caffeinate.watcher.screensDidUnlock then
      M.wakeTimer = hs.timer.doAfter(5, function()
        if S.claudeOn then refresh() end
        if poller then poller:refreshAll() end
      end)
    end
  end):start()
  return M
end

M.refresh = refresh
M.ageText, M.resetText, M.isStale = ageText, resetText, isStale -- for tests
M.barColor, M.C = barColor, C
M.valueLines, M.planStarts, M.checkComparison = valueLines, planStarts, checkComparison
-- Latest Claude usage JSON (the buddy reads it); none while Claude is off the card.
function M.current() return S.claudeOn and data or nil end
return M
