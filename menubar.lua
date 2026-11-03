-- The card in the menu bar (Hammerspoon module): a little Buddy and your tightest limit
-- at the top right, by the clock. Click it for every AI's limits and resets, and the
-- things you reach for most: check now, the chart, the IDE (Beta, when set up), chat, quiet for an hour, the card and
-- Buddy on or off the desktop, and Buddy's whole right-click menu.
--
-- usage_widget.lua starts it (config.lua: `menubar = false` leaves it out) and calls
-- update() whenever the card redraws. The menu is built fresh each time it opens.
-- MB.titleText and MB.items take plain tables and make no hs.* calls, so specs can check them.

local MB = {}

local STYLE_KEY = "claudeUsageWidget.menubarStyle" -- "percent" (default) or "icon"

-- Buddy on his 14 x 12 grid, the rectangles buddy.lua draws, with the eyes left out so
-- they show through when macOS tints the picture for a light or dark menu bar.
MB.SHAPE = {
  { 1, 0, 12, 3 }, { 1, 3, 2, 3 }, { 5, 3, 4, 3 }, { 11, 3, 2, 3 }, { 1, 6, 12, 4 }, -- body around the eyes
  { 0, 1, 1, 8 }, { 13, 1, 1, 8 },                                                  -- sides
  { 2, 10, 1, 2 }, { 4, 10, 1, 2 }, { 9, 10, 1, 2 }, { 11, 10, 1, 2 },              -- legs
}
local PX = 1.25 -- points per grid square: 17.5 x 15, about the height of the clock's text

function MB.icon()
  local c = hs.canvas.new({ x = 0, y = 0, w = 14 * PX + 1, h = 12 * PX + 1 })
  for i, r in ipairs(MB.SHAPE) do
    c[i] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 1 },
      frame = { x = 0.5 + r[1] * PX, y = 0.5 + r[2] * PX, w = r[3] * PX, h = r[4] * PX } }
  end
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

-- The words next to the icon: "41%", nothing in icon-only style or before any numbers.
-- t: { pct, level = "ok" | "warn" | "hot", stale } from the card's menuTitle().
function MB.titleText(t, style)
  if style == "icon" or type(t) ~= "table" or type(t.pct) ~= "number" then return "" end
  return string.format("%d%%", math.floor(t.pct + 0.5))
end

-- The whole menu. u: the card's menuUsage() items; b: Buddy's part ({ brain, muted,
-- tasks, menu, visible } or nil without Buddy); s: { style, cardVisible, inApp, canMakeApp, ide };
-- f: the functions the items call.
function MB.items(u, b, s, f)
  local items = {}
  for _, it in ipairs(u or {}) do items[#items + 1] = it end
  if #items > 0 then items[#items + 1] = { title = "-" } end
  items[#items + 1] = { title = "Check usage now", fn = f.checkNow }
  if f.chart then items[#items + 1] = { title = "Open the usage chart", fn = f.chart } end
  if s.ide then
    items[#items + 1] = { title = "Open the IDE (Beta)", fn = f.ide, tooltip = "Option-click to open it in your browser" }
  end
  if b then
    items[#items + 1] = { title = "-" }
    if b.brain then items[#items + 1] = { title = "Chat with Buddy", fn = f.chat } end
    items[#items + 1] = { title = b.muted and "Talk again" or "Quiet for an hour", fn = f.mute }
    if b.tasks then items[#items + 1] = { title = "Task sessions", menu = b.tasks } end
    if b.menu then items[#items + 1] = { title = "Buddy", menu = b.menu } end
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Usage card on the desktop", checked = s.cardVisible, fn = f.toggleCard }
  if b then items[#items + 1] = { title = "Buddy on the desktop", checked = b.visible, fn = f.toggleBuddy } end
  items[#items + 1] = { title = "Show the % in the menu bar", checked = s.style ~= "icon", fn = f.toggleStyle }
  items[#items + 1] = { title = "-" }
  if s.canMakeApp then items[#items + 1] = { title = "Make Buddy an app…", fn = f.makeApp } end
  if f.checkUpdates then -- f.updateTitle(), when there, says "Update to v…" once one is out
    local title = type(f.updateTitle) == "function" and f.updateTitle() or "Check for updates…"
    items[#items + 1] = { title = title, fn = f.checkUpdates }
  end
  items[#items + 1] = { title = "Restart Buddy", fn = f.restart }
  if s.inApp then items[#items + 1] = { title = "Quit Claude Buddy", fn = f.quit } end
  return items
end

-- opts: usage (the card module), buddy() (Buddy's module, or nil), app (app.lua), dir,
-- ide (ide.lua when config.lua turns the IDE on, else nil).
function MB.start(opts)
  local U, App = opts.usage, opts.app
  local function buddy()
    local B = opts.buddy and opts.buddy()
    return type(B) == "table" and B.canvas and B or nil
  end
  local function style() return hs.settings.get(STYLE_KEY) == "icon" and "icon" or "percent" end
  local shown

  local f = {
    checkNow = function() U.refreshAll() end,
    chart = U.claudeOn() and function() U.chart(); U.refresh() end or nil,
    chat = function() local B = buddy(); if B then B.chat() end end,
    mute = function() local B = buddy(); if B then B.toggleMute() end end,
    toggleCard = function() U.setVisible(not U.visible()) end,
    toggleBuddy = function() local B = buddy(); if B then B.setVisible(not B.visible()) end end,
    toggleStyle = function()
      hs.settings.set(STYLE_KEY, style() == "icon" and "percent" or "icon")
      MB.update()
    end,
    -- hs.menubar hands an item's fn the keys held down: Option opens it in the browser
    ide = function(mods)
      if not opts.ide then return end
      if type(mods) == "table" and mods.alt then opts.ide.browser() else opts.ide.open() end
    end,
    makeApp = function() local B = buddy(); App.offer(opts.dir, B and B.say) end,
    restart = function() hs.reload() end,
    -- the card's updater.lua: ask GitHub now; "Update to v…" once a newer release is known
    checkUpdates = function() if U.updater then U.updater.checkNow() end end,
    updateTitle = function() return U.updater and U.updater.menuTitle() end,
    -- a normal quit, so the voice helper and the other children are stopped on the way out
    quit = function()
      MB.quitTimer = hs.timer.doAfter(0.1, function()
        local me = hs.application.applicationForPID(hs.processInfo.processID)
        if me then me:kill() else os.exit(0) end
      end)
    end,
  }

  local function menu()
    local B = buddy()
    local b
    if B then
      b = { brain = B.hasBrain(), muted = B.muted(), tasks = B.tasks.menu and B.tasks.lib and B.tasks.menu() or nil,
        menu = B.menuItems(), visible = B.visible() }
    end
    local s = { style = style(), cardVisible = U.visible(), inApp = App.inApp(),
      canMakeApp = not App.inApp() and App.installed() == nil, ide = opts.ide ~= nil }
    local ok, items = pcall(MB.items, U.menuUsage(), b, s, f)
    if ok then return items end
    print("ClaudeUsage menubar: " .. tostring(items))
    return { { title = "Couldn't build the menu" }, { title = "Restart Buddy", fn = f.restart } }
  end

  MB.item = hs.menubar.new(true, "ClaudeBuddyUsage")
  if not MB.item then return MB end
  MB.item:setIcon(MB.icon(), true)
  MB.item:setMenu(menu)
  function MB.update()
    if not MB.item then return end
    local t = U.menuTitle()
    local text = MB.titleText(t, style())
    local key = text .. (t and t.level or "") .. tostring(t and t.stale) .. (t and t.tooltip or "")
    if key == shown then return end
    shown = key
    local color = t and not t.stale and (t.level == "hot" and "systemRedColor" or t.level == "warn" and "systemOrangeColor")
    if text ~= "" and color then
      MB.item:setTitle(hs.styledtext.new(" " .. text, { font = hs.styledtext.defaultFonts.menuBar,
        color = { list = "System", name = color } }))
    else
      MB.item:setTitle(text ~= "" and " " .. text or nil)
    end
    MB.item:setTooltip(t and t.tooltip or "Claude usage")
  end
  MB.update()
  return MB
end

function MB.stop()
  if MB.item then MB.item:delete() end
  MB.item = nil
end

return MB
