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
-- Click the "is out" line to update when a new version is out; drag the card to move
-- it (the spot is remembered).
--
-- Dragging polls the mouse instead of using an event tap, so Hammerspoon
-- doesn't need Accessibility permission.

local M = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local FETCH = DIR .. "/bin/claude-usage"
local PYTHON = "/usr/bin/python3"
for _, p in ipairs({ "/opt/homebrew/bin/python3", "/usr/local/bin/python3" }) do
  if hs.fs.attributes(p) then PYTHON = p; break end
end
local POS_KEY = "claudeUsageWidget.topLeft"

local REFRESH = 300 -- seconds between usage API checks (it rate-limits frequent callers)
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

local function resetText(ts)
  if not ts then return "" end
  local s = ts - os.time()
  if s <= 0 then return "Resetting now" end
  if s < 3600 then return string.format("Resets in %d min", math.ceil(s / 60)) end
  if s < 86400 then return string.format("Resets in %d hr %d min", s // 3600, (s % 3600) // 60) end
  if s < 7 * 86400 then return "Resets " .. os.date("%a", ts) .. " " .. clock(ts) end
  return "Resets " .. (os.date("%b %d", ts):gsub(" 0", " "))
end

local function ageText(ts)
  local m = (os.time() - ts) // 60
  if m < 1 then return "just now" end
  if m < 60 then return m .. " min ago" end
  return "at " .. clock(ts)
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

local function render()
  if not M.canvas then return end
  local bg = {
    type = "rectangle", action = "strokeAndFill", fillColor = C.bg, strokeColor = C.edge, strokeWidth = 1,
    roundedRectRadii = { xRadius = 14, yRadius = 14 }, frame = { x = 0, y = 0, w = W, h = 0 },
  }
  local els = { bg }
  local status = ""
  if data then
    status = (data.plan and (data.plan:gsub("^%l", string.upper) .. " · ") or "") .. ageText(data.fetched_at)
  end
  els[#els + 1] = { type = "text", text = txt("Claude", 13, C.text, "left", true), frame = { x = PAD, y = 13, w = 100, h = 18 } }
  els[#els + 1] = { type = "text", text = txt(status, 10.5, C.dim, "right"), frame = { x = W - PAD - 150, y = 15, w = 150, h = 14 } }

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
        barColor(l.pct, l.severity), resetText(l.resets_at))
    end
    for _, c in ipairs(data.credits or {}) do
      local figure = c.limit and string.format("$%.2f / $%d", c.used, math.floor(c.limit)) or string.format("$%.2f", c.used)
      y = row(els, y, c.label, figure, c.pct, barColor(c.pct), resetText(c.resets_at))
    end
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
  tokTask = hs.task.new("/usr/bin/nice", function(_, out)
    local ok, res = pcall(hs.json.decode, out or "")
    if ok and type(res) == "table" and res.ok then
      M.tokens = res
      if M.chartWin then M.chartWin.pushTokens(TOKENS) end
      render()
    end
  end, { "-n", "10", PYTHON, "-I", DIR .. "/bin/claude-tokens" })
  tokTask:start()
end

-- Open the usage chart window (demo = made-up data, for trying it out).
function M.chart(demo)
  M.chartWin = M.chartWin or dofile(DIR .. "/chart.lua")
  M.chartWin.open({ dir = DIR, history = HIST, tokens = TOKENS, current = data, demo = demo })
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
function M.current() return data end -- latest usage JSON (the buddy reads it)
return M
