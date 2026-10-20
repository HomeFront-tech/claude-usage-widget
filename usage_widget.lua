-- Claude usage desktop widget (Hammerspoon module)
--
-- Shows the same plan limits as Claude Code's /usage: the current 5-hour session,
-- the weekly limits, any credits, and extra usage when it's turned on.
-- Numbers come from bin/claude-usage (Anthropic's usage API, signed in with
-- Claude Code's own Keychain login). The card sits on the desktop on every Space,
-- under your windows, like a macOS widget. It also starts updater.lua.
-- Click it to refresh now (or to update, when it says a new version is out);
-- drag it to move it (the spot is remembered).
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

local REFRESH = 120 -- seconds between usage API checks
local TICK = 30     -- seconds between redraws (countdowns and "updated" age)
local W, PAD = 264, 16

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
}

local data, lastError, task

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

  local y = 42
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
  if update then
    els[#els + 1] = { type = "text", text = txt("↑ v" .. update.version .. " is out · click to update", 10.5, C.ok, "left", true),
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
  task = hs.task.new(PYTHON, function(_, out)
    local ok, res = pcall(hs.json.decode, out or "")
    if ok and type(res) == "table" and res.ok then
      data, lastError = res, nil
    else
      lastError = (ok and type(res) == "table" and res.error) or "Usage check failed"
    end
    render()
  end, { "-I", FETCH })
  task:start()
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

local function startDrag()
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
      elseif M.updater and M.updater.available then
        M.updater.prompt()
      else
        refresh()
      end
      return
    end
    if math.abs(m.x - m0.x) + math.abs(m.y - m0.y) > 3 then moved = true end
    if moved then M.canvas:topLeft({ x = p0.x + m.x - m0.x, y = p0.y + m.y - m0.y }) end
  end)
end

function M.start()
  M.canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = 100 })
  M.canvas:level(hs.canvas.windowLevels.desktopIcon)
  M.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  M.canvas:clickActivating(false)
  M.canvas:canvasMouseEvents(true, false, false, false)
  M.canvas:mouseCallback(function(_, msg) if msg == "mouseDown" then startDrag() end end)
  place()
  render()
  M.canvas:show()

  refresh()
  M.fetchTimer = hs.timer.doEvery(REFRESH, refresh)
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
