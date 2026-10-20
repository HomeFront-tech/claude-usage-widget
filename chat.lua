-- Chat panel for the Claude buddy (Hammerspoon module)
--
-- A small floating chat box next to the buddy. You type, or hold space and talk
-- (dictate.lua), and the buddy answers through brain.lua with a fresh look at the window
-- you were in. The page is chat.html; Escape or ✕ closes it. Drag it by its header; it
-- remembers where you put it relative to the buddy and opens there next time.
--
-- The chat and the speech bubble share one transcript: every line the buddy says out
-- loud lands here too, live while the panel is open, and opening the panel shows the
-- conversation from its last 5 lines on. The transcript lives in Hammerspoon's settings
-- (the last 80 lines), so a reload doesn't wipe it.

local C = {}

local KEY = "claudeBuddy.chat"
local POS_KEY = "claudeBuddy.chatOffset" -- where you dragged the panel, relative to the buddy
local KEEP = 80             -- lines kept
local SHOW = 5              -- the buddy's lines shown when the panel opens
local GREET_AFTER = 20 * 60 -- quiet this long and opening the panel gets a fresh hello
local history = hs.settings.get(KEY) or {}
local Dictate

local function now() return hs.timer.secondsSinceEpoch() end

local function js(fn, data)
  if not C.wv then return end
  -- hs.json.encode only takes tables, so wrap plain values and unwrap the array
  local arg = type(data) == "table" and hs.json.encode(data) or hs.json.encode({ data }):sub(2, -2)
  C.wv:evaluateJavaScript(fn .. "(" .. arg .. ")")
end

local function add(entry, show)
  entry.at = now()
  history[#history + 1] = entry
  while #history > KEEP do table.remove(history, 1) end
  hs.settings.set(KEY, history)
  if show then js("window.add", entry) end
end

-- A line the buddy said out loud in its speech bubble.
function C.said(text)
  local last = history[#history]
  if last and last.role == "assistant" and last.content == text then return end
  add({ role = "assistant", content = text, said = true }, true)
end

-- A line from someone else in the conversation. role "grok": a reply the buddy passed on
-- from Grok Bot.
function C.post(role, text)
  add({ role = role, content = text }, true)
end

function C.forget()
  history = {}
  hs.settings.set(KEY, history)
end

-- The conversation from the buddy's last SHOW lines on, plus the question before the first.
local function recent()
  local first, n = 1, 0
  for i = #history, 1, -1 do
    if history[i].role == "assistant" then n = n + 1 end
    if n == SHOW then first = i; break end
  end
  if first > 1 and history[first - 1].role == "user" then first = first - 1 end
  return { table.unpack(history, first) }
end

function C.isOpen() return C.wv ~= nil end

-- Closing hands the keyboard back to the app you were in before the panel opened, and
-- lets the brain note anything worth remembering from the chat.
function C.close()
  if Dictate then Dictate.cancel() end
  if C.dragTimer then C.dragTimer:stop(); C.dragTimer = nil end
  if C.opts and C.opts.remember then C.opts.remember(history) end
  C.closeTimer = hs.timer.doAfter(0, function()
    if C.wv then C.wv:delete() end
    C.wv = nil
    if C.prevApp and C.prevApp:bundleID() ~= "org.hammerspoon.Hammerspoon" then C.prevApp:activate() end
  end)
end

-- Hold space: record; let go: transcribe into the text box.
local function listen(start)
  Dictate = Dictate or dofile(C.opts.dir .. "/dictate.lua").configure(C.opts.dictation)
  local function heard(text, why) js("window.heard", { text = text, error = why }) end
  if not start then return Dictate.stop(heard) end
  local ok, why = Dictate.start(function(err) heard(nil, err) end)
  if not ok then heard(nil, why) end
end

-- Same polling drag as the buddy (no Accessibility permission needed): the header's
-- mousedown starts it, letting go of the button ends it and saves the spot.
local function drag()
  if C.dragTimer then C.dragTimer:stop() end
  local m0, p0 = hs.mouse.absolutePosition(), C.wv:topLeft()
  C.dragTimer = hs.timer.doEvery(1 / 60, function()
    if not C.wv then C.dragTimer:stop(); C.dragTimer = nil; return end
    local m = hs.mouse.absolutePosition()
    if not hs.eventtap.checkMouseButtons().left then
      C.dragTimer:stop()
      C.dragTimer = nil
      local p, a = C.wv:topLeft(), C.opts.anchor()
      if p.x ~= p0.x or p.y ~= p0.y then hs.settings.set(POS_KEY, { x = p.x - a.x, y = p.y - a.y }) end
      return
    end
    C.wv:topLeft({ x = p0.x + m.x - m0.x, y = p0.y + m.y - m0.y })
  end)
end

-- opts: dir, anchor() (the buddy canvas frame, now), title, ask(history, done), opener(done),
-- onReply(text), remember(history), dictation (config.lua's ai.dictation)
function C.open(opts)
  if C.wv then
    C.wv:show():bringToFront(true)
    hs.focus()
    return
  end
  C.opts = opts
  local last = history[#history]
  local greet = opts.opener and (not last or now() - (last.at or 0) > GREET_AFTER)

  local fh = assert(io.open(opts.dir .. "/chat.html"))
  local html = fh:read("a")
  fh:close()
  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode({ title = opts.title or "Buddy", history = recent(), thinking = greet and true or false,
      dictation = opts.dictation ~= false }):gsub("</", "<\\/"))
  end)

  local function reply(text)
    if not text then
      return js("window.add", { role = "assistant", content = "My brain's offline. Is Ollama running?", error = true })
    end
    add({ role = "assistant", content = text }, true)
    if opts.onReply then opts.onReply(text) end
  end

  local uc = hs.webview.usercontent.new("buddy")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if b.type == "send" and (b.text or ""):match("%S") then
      add({ role = "user", content = b.text })
      js("window.thinking", true)
      opts.ask(history, reply)
    elseif b.type == "listen" or b.type == "stop" then
      listen(b.type == "listen")
    elseif b.type == "drag" then
      drag()
    elseif b.type == "close" then
      C.close()
    end
  end)

  -- Where you last dragged it, if that's on a screen; otherwise above the buddy when
  -- there's room, or beside it, on its screen. Always fully on the screen.
  local w, h = 320, 400
  local a = opts.anchor()
  local x, y, scr
  local off = hs.settings.get(POS_KEY)
  if off then
    x, y = a.x + off.x, a.y + off.y
    -- not hs.screen.find: that returns the nearest screen even for a point on none
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:frame()
      if x + w / 2 >= f.x and x + w / 2 < f.x + f.w and y + h / 2 >= f.y and y + h / 2 < f.y + f.h then scr = s end
    end
  end
  if not scr then
    scr = hs.screen.find({ x = a.x + a.w / 2, y = a.y + a.h / 2, w = 1, h = 1 }) or hs.screen.mainScreen()
    local sf = scr:frame()
    x, y = a.x + a.w / 2 - w / 2, a.y - h + 40
    if y < sf.y then x, y = a.x + a.w - 10, a.y + a.h - h end
    if x + w > sf.x + sf.w then x = a.x - w + 10 end
  end
  local sf = scr:frame()
  x = math.max(sf.x + 4, math.min(sf.x + sf.w - w - 4, x))
  y = math.max(sf.y + 4, math.min(sf.y + sf.h - h - 4, y))

  C.prevApp = hs.application.frontmostApplication()
  C.wv = hs.webview.new({ x = x, y = y, w = w, h = h }, { developerExtrasEnabled = false }, uc)
    :windowStyle({ "borderless" })
    :transparent(true)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.floating)
    :behavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
    :deleteOnClose(true)
    :windowCallback(function(action) if action == "closing" then C.wv = nil end end)
    :html(html)
    :show()
  C.wv:bringToFront(true)
  hs.focus()

  if greet then C.openerTimer = hs.timer.doAfter(0.3, function() opts.opener(reply) end) end
end

return C
