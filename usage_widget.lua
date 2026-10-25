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

local REFRESH = 300 -- seconds between usage API checks (it rate-limits frequent callers)
local STALE = 3 * REFRESH -- numbers older than this have missed checks and show grey
local LAST_KEY = "claudeUsageWidget.lastData" -- last good numbers, shown again after a reload
local TICK = 30     -- seconds between redraws (countdowns and "updated" age)
local W, PAD = 264, 16

-- Usage history: one JSON line per check, {t, v = {label = pct}, r = {label = resets_at}}.
local HIST_DIR = os.getenv("HOME") .. "/Library/Application Support/claude-usage-widget"
local HIST = HIST_DIR .. "/history.jsonl"
local KEEP_DAYS = 90
local STRIP_H = 30 -- height of the card's 24-hour token strip

local REG = hs.styledtext.defaultFonts.system.name
local BOLD = hs.styledtext.defaultFonts.boldSystem.name

local C = {
  bg    = { red = 0.08, green = 0.08, blue = 0.10, alpha = 0.82 },
  edge  = { white = 1, alpha = 0.10 },
  text  = { white = 1, alpha = 0.92 },
  dim   = { white = 1, alpha = 0.55 },
  track = { white = 1, alpha = 0.12 },
  ok    = { red = 0.85, green = 0.47, blue = 0.34, alpha = 1 }, -- Claude orange
  warn  = { red = 0.96, green = 0.72, blue = 0.26, alpha = 1 },
  hot   = { red = 0.94, green = 0.33, blue = 0.31, alpha = 1 },
  okDim = { red = 0.85, green = 0.47, blue = 0.34, alpha = 0.5 },
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
  if s <= -STALE then return "Reset " .. when(ts, now) end -- the bar's number is from before it
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
  return (now or os.time()) - ts > STALE
end

local function barColor(pct, severity)
  if severity == "critical" or pct >= 90 then return C.hot end
  if severity == "warning" or pct >= 70 then return C.warn end
  return C.ok
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
    els[#els + 1] = { type = "text", text = txt("Reading Claude Code's logs…", 10.5, C.dim, "center"),
      frame = { x = PAD, y = y + 8, w = bw, h = 14 } }
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
  els[#els + 1] = { type = "text", text = txt("Tokens · 24h", 10, C.dim), frame = { x = PAD, y = y + STRIP_H + 3, w = 120, h = 13 } }
  els[#els + 1] = { type = "text", text = txt("Open chart ›", 10, C.dim, "right"), frame = { x = W - PAD - 120, y = y + STRIP_H + 3, w = 120, h = 13 } }
  return y + STRIP_H + 24
end

-- One limit: label and figure, a bar, then the reset line. Returns the next y.
local function row(els, y, label, figure, pct, color, sub)
  local bw = W - 2 * PAD
  els[#els + 1] = { type = "text", text = txt(label, 12, C.text), frame = { x = PAD, y = y, w = bw - 90, h = 16 } }
  els[#els + 1] = { type = "text", text = txt(figure, 12.5, color, "right", true), frame = { x = W - PAD - 110, y = y - 1, w = 110, h = 17 } }
  local bar = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 } }
  els[#els + 1] = hs.fnutils.copy(bar)
  els[#els].fillColor, els[#els].frame = C.track, { x = PAD, y = y + 20, w = bw, h = 5 }
  local fill = math.max(0, math.min(1, pct / 100)) * bw
  if fill > 0 then
    els[#els + 1] = hs.fnutils.copy(bar)
    els[#els].fillColor, els[#els].frame = color, { x = PAD, y = y + 20, w = math.max(fill, 5), h = 5 }
  end
  els[#els + 1] = { type = "text", text = txt(sub, 10.5, C.dim), frame = { x = PAD, y = y + 29, w = bw, h = 14 } }
  return y + 50
end

-- The API value row: dollars for a chosen period (bin/claude-tokens works them out), the
-- "× your plan" line, and a fun comparison that stays until spending moves by a typical
-- amount for that period. Buddy writes and says new ones; comparisons.lua covers for him.
local Value = dofile(DIR .. "/value.lua")
local Compare = dofile(DIR .. "/comparisons.lua")
local PERIOD_KEY, BUDDY_KEY = "claudeUsageWidget.valuePeriod", "claudeUsageWidget.valueBuddy"
local COMPARE_KEY, THINGS_KEY = "claudeUsageWidget.comparisons", "claudeUsageWidget.comparedThings"
local WARM = { red = 0.95, green = 0.77, blue = 0.66, alpha = 1 }
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
  els[#els + 1] = { type = "text", text = txt(l.label .. "  " .. l.period .. " ▾", 12, C.text), frame = { x = PAD, y = y, w = bw - 60, h = 16 } }
  els[#els + 1] = { type = "text", text = txt(l.figure, 12.5, C.ok, "right", true), frame = { x = W - PAD - 110, y = y - 1, w = 110, h = 17 } }
  M.valueY = { y - 3, y + 19 }
  y = y + 20
  if l.multiple then
    els[#els + 1] = { type = "text", text = txt(l.multiple, 10.5, C.dim), frame = { x = PAD, y = y, w = bw, h = 14 } }
    y = y + 15
  end
  if l.comparison then
    local styled = hs.styledtext.new(l.comparison, {
      font = { name = REG, size = 10.5 }, color = WARM, paragraphStyle = { lineBreak = "wordWrap" } })
    local wide = hs.drawing.getTextDrawingSize(styled).w
    local h = 14 * math.min(3, math.max(1, math.ceil(wide * 1.1 / bw)))
    els[#els + 1] = { type = "text", text = styled, frame = { x = PAD, y = y, w = bw, h = h } }
    y = y + h + 1
  end
  return y + 8
end

local function render()
  if not M.canvas then return end
  local bg = {
    type = "rectangle", action = "strokeAndFill", fillColor = C.bg, strokeColor = C.edge, strokeWidth = 1,
    roundedRectRadii = { xRadius = 14, yRadius = 14 }, frame = { x = 0, y = 0, w = W, h = 0 },
  }
  local els = { bg }
  local status, stale = "", data and isStale(data.fetched_at)
  if data then
    status = (data.plan and (data.plan:gsub("^%l", string.upper) .. " · ") or "") .. ageText(data.fetched_at)
  end
  els[#els + 1] = { type = "text", text = txt("Claude", 13, C.text, "left", true), frame = { x = PAD, y = 13, w = 100, h = 18 } }
  els[#els + 1] = { type = "text", text = txt(status, 10.5, stale and C.warn or C.dim, "right"), frame = { x = W - PAD - 150, y = 15, w = 150, h = 14 } }

  local y = strip(els, 40)
  local tk = M.tokens
  if tk and (tk.tokens24h or 0) > 0 then
    local function big(n)
      if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
      if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
      if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
      return tostring(math.floor(n))
    end
    local line = string.format("24h: %s tokens · %d replies · ≈$%.0f", big(tk.tokens24h), tk.replies24h or 0, tk.cost24h or 0)
    els[#els + 1] = { type = "text", text = txt(line, 10.5, C.dim), frame = { x = PAD, y = y - 6, w = W - 2 * PAD, h = 14 } }
    y = y + 14
  end
  if data then
    for _, l in ipairs(data.limits or {}) do
      y = row(els, y, l.label, string.format("%d%%", math.floor(l.pct + 0.5)), l.pct,
        stale and C.dim or barColor(l.pct, l.severity), resetText(l.resets_at))
    end
    for _, c in ipairs(data.credits or {}) do
      local figure = c.limit and string.format("$%.2f / $%d", c.used, math.floor(c.limit)) or string.format("$%.2f", c.used)
      y = row(els, y, c.label, figure, c.pct, stale and C.dim or barColor(c.pct), resetText(c.resets_at))
    end
    y = valueRow(els, y)
    local parts = {}
    for _, b in ipairs(data.breakdown or {}) do parts[#parts + 1] = b.name .. " " .. b.pct .. "%" end
    if #parts > 0 then
      els[#els + 1] = { type = "text", text = txt("This week: " .. table.concat(parts, " · "), 10.5, C.dim), frame = { x = PAD, y = y, w = W - 2 * PAD, h = 14 } }
      y = y + 18
    end
  elseif not lastError then
    els[#els + 1] = { type = "text", text = txt("Loading…", 12, C.dim), frame = { x = PAD, y = y, w = W - 2 * PAD, h = 16 } }
    y = y + 22
  end
  if lastError then
    els[#els + 1] = { type = "text", text = txt(lastError, 10.5, C.warn), frame = { x = PAD, y = y, w = W - 2 * PAD, h = 14 } }
    y = y + 18
  end
  local update = M.updater and M.updater.available
  M.updateY = nil
  if update then
    M.updateY = y - 2
    els[#els + 1] = { type = "text", text = txt("↑ v" .. update.version .. " is out · click here to update", 10.5, C.ok, "left", true),
      frame = { x = PAD, y = y, w = W - 2 * PAD, h = 14 } }
    y = y + 18
  end

  local h = y + 6
  bg.frame.h = h
  M.canvas:size({ w = W, h = h })
  M.canvas:replaceElements(els)
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

  if not (data and data.fetched_at and os.time() - data.fetched_at < 60) then refresh() end -- reloads reuse fresh numbers
  M.fetchTimer = hs.timer.doEvery(REFRESH, refresh)
  scanTokens()
  M.tokenTimer = hs.timer.doEvery(REFRESH, scanTokens)
  M.updater = dofile(DIR .. "/updater.lua").start({ dir = DIR, onChange = render })
  M.tickTimer = hs.timer.doEvery(TICK, render)
  M.screenWatcher = hs.screen.watcher.new(function()
    M.placeTimer = hs.timer.doAfter(2, place)
  end):start()
  M.wakeWatcher = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake or ev == hs.caffeinate.watcher.screensDidUnlock then
      M.wakeTimer = hs.timer.doAfter(5, refresh)
    end
  end):start()
  return M
end

M.refresh = refresh
M.ageText, M.resetText, M.isStale = ageText, resetText, isStale -- for tests
M.valueLines, M.planStarts, M.checkComparison = valueLines, planStarts, checkComparison
function M.current() return data end -- latest usage JSON (the buddy reads it)
return M
