-- Chat panel for the Claude buddy (Hammerspoon module)
--
-- A small floating chat box next to the buddy. You type, or hold space and talk
-- (dictate.lua), and the buddy answers through brain.lua with a fresh look at the window
-- you were in. The page is chat.html; Escape or ✕ closes it. Drag it by its header, or
-- any edge or corner to resize it; it remembers where you put it relative to the buddy,
-- and how big, and opens that way next time.
--
-- The chat and the speech bubble share one transcript: every line the buddy says out
-- loud lands here too, live while the panel is open, and opening the panel shows the
-- conversation from its last 5 lines on. The transcript lives in Hammerspoon's settings
-- (the last 80 lines), so a reload doesn't wipe it.

local C = {}

local KEY = "claudeBuddy.chat"
local SEQ_KEY = "claudeBuddy.chatSeq"
local POS_KEY = "claudeBuddy.chatOffset" -- where you dragged the panel, relative to the buddy
local SIZE_KEY = "claudeBuddy.chatSize"  -- how big you dragged it
local SIZE = { w = 320, h = 400 }        -- until you resize it
local MIN = { w = 260, h = 220 }         -- small enough for a corner, big enough to read
C.MIN = MIN
local KEEP = 80             -- lines kept
local SHOW = 5              -- the buddy's lines shown when the panel opens
local GREET_AFTER = 20 * 60 -- quiet this long and opening the panel gets a fresh hello
local history = hs.settings.get(KEY) or {}
local sequence = math.max(tonumber(hs.settings.get(SEQ_KEY)) or 0, #history)
for i, entry in ipairs(history) do
  if not entry.seq then entry.seq = sequence - #history + i end
end
local archive = (os.getenv("HOME") or "") .. "/Library/Application Support/claude-usage-widget/chat-archive.jsonl"
local Dictate

local function now() return hs.timer.secondsSinceEpoch() end

-- The archive outlives the short settings transcript; keep complete JSON lines when
-- trimming so chat_search can read it after a long conversation.
local function archiveLine(entry)
  local folder = archive:match("^(.*)/[^/]+$")
  if folder and not hs.fs.attributes(folder) then
    local parent = folder:match("^(.*)/[^/]+$")
    if parent and hs.fs.attributes(parent) then hs.fs.mkdir(folder) end
  end
  local file = io.open(archive, "a")
  if not file then return end
  file:write(hs.json.encode({ role = entry.role, content = entry.content, via = entry.via,
    name = entry.name, at = entry.at }) .. "\n")
  file:close()
  local size = hs.fs.attributes(archive, "size") or 0
  if size <= 5 * 1024 * 1024 then return end
  file = io.open(archive, "r")
  if not file then return end
  local lines, bytes = {}, 0
  for line in file:lines() do lines[#lines + 1] = line end
  file:close()
  local kept = {}
  for i = #lines, 1, -1 do
    local line = lines[i] .. "\n"
    if bytes > 0 and bytes + #line > 2.5 * 1024 * 1024 then break end
    table.insert(kept, 1, line)
    bytes = bytes + #line
  end
  file = io.open(archive, "w")
  if file then file:write(table.concat(kept)); file:close() end
end

function C.setArchivePath(path) archive = path end -- temp folder for specs
function C.setDictate(d) Dictate = d end -- a stand-in recorder for specs

local function js(fn, data)
  if not C.wv then return end
  -- hs.json.encode only takes tables, so wrap plain values and unwrap the array
  local arg = type(data) == "table" and hs.json.encode(data) or hs.json.encode({ data }):sub(2, -2)
  C.wv:evaluateJavaScript(fn .. "(" .. arg .. ")")
end

local function add(entry, show)
  entry.at = now()
  sequence = sequence + 1
  entry.seq = sequence
  history[#history + 1] = entry
  while #history > KEEP do table.remove(history, 1) end
  hs.settings.set(KEY, history)
  hs.settings.set(SEQ_KEY, sequence)
  archiveLine(entry)
  if show then js("window.add", entry) end
end

-- A line the buddy said out loud in its speech bubble.
function C.said(text)
  local last = history[#history]
  if last and last.role == "assistant" and last.content == text then return end
  add({ role = "assistant", content = text, said = true }, true)
end

-- A line from someone else in the conversation. role "grok": a reply the buddy passed on
-- from Grok Bot; role "task": an update from a Claude Code session it started (tasks.lua),
-- labelled with the session's name. via "telegram": said over Telegram (telegram.lua),
-- labelled that way here.
function C.post(role, text, via, name)
  add({ role = role, content = text, via = via, name = name }, true)
end

-- The whole transcript, newest last (the brain reads it for messages from Telegram).
function C.history() return history end

function C.forget()
  history = {}
  hs.settings.set(KEY, history)
  os.remove(archive)
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
  if C.opts and C.opts.onDictate then C.opts.onDictate(false) end
  if C.opts and C.opts.onClose then C.opts.onClose() end
  C.live = nil -- closing the panel ends a live chat
  if C.dragTimer then C.dragTimer:stop(); C.dragTimer = nil end
  if C.opts and C.opts.remember then C.opts.remember(history) end
  C.closeTimer = hs.timer.doAfter(0, function()
    if C.wv then C.wv:delete() end
    C.wv = nil
    if C.prevApp and C.prevApp:bundleID() ~= "org.hammerspoon.Hammerspoon" then C.prevApp:activate() end
  end)
end

-- "okay Buddy" (voice.lua): live words in the box while listening (state "listening"), or
-- clear them (state "off"). The page keeps anything you'd typed in front of them.
-- The live chat's state (live, hold, liveoff) is also kept for the page's INIT: "okay Buddy"
-- opens the panel and sends "live" in the same moment, before the page can take it.
function C.voice(state, text)
  if state == "live" or state == "hold" then C.live = state elseif state == "liveoff" then C.live = nil end
  js("window.voice", { state = state, text = text or "" })
end

-- The pause after you talk: the page sends the box (your typing plus the spoken words) as
-- a message said out loud. False when the panel isn't open.
function C.sendVoice(text)
  if not C.wv then return false end
  js("window.voice", { state = "send", text = text or "" })
  return true
end

-- Hold space: record; let go: transcribe into the text box.
local function listen(start)
  Dictate = Dictate or dofile(C.opts.dir .. "/dictate.lua").configure(C.opts.dictation)
  local function heard(text, why) js("window.heard", { text = text, error = why }) end
  -- a live voice chat looks away while you hold space (dictation has the microphone)
  if C.opts.onDictate then C.opts.onDictate(start) end
  if not start then return Dictate.stop(heard) end
  local ok, why = Dictate.start(function(err) -- the recording died on its own: listen again
    if C.opts.onDictate then C.opts.onDictate(false) end
    heard(nil, err)
  end)
  if not ok then heard(nil, why); if C.opts.onDictate then C.opts.onDictate(false) end end
end

-- The screen holding a point, or nil when it's on none (hs.screen.find would return the
-- nearest screen even then).
local function screenAt(x, y)
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:frame()
    if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then return s end
  end
end

-- The panel's frame after its edge or corner (n, s, e, w, ne, nw, se, sw) was dragged dx, dy
-- from frame f0: the opposite side stays put, it never gets smaller than MIN, and with a
-- screen frame it stops 4 pt short of that screen's edge.
function C.resizeFrame(f0, edge, dx, dy, screen)
  local left, top, right, bottom = f0.x, f0.y, f0.x + f0.w, f0.y + f0.h
  if edge:find("e") then
    right = f0.x + f0.w + dx
    if screen then right = math.min(right, screen.x + screen.w - 4) end
    right = math.max(right, left + MIN.w)
  end
  if edge:find("w") then
    left = f0.x + dx
    if screen then left = math.max(left, screen.x + 4) end
    left = math.min(left, right - MIN.w)
  end
  if edge:find("s") then
    bottom = f0.y + f0.h + dy
    if screen then bottom = math.min(bottom, screen.y + screen.h - 4) end
    bottom = math.max(bottom, top + MIN.h)
  end
  if edge:find("n") then
    top = f0.y + dy
    if screen then top = math.max(top, screen.y + 4) end
    top = math.min(top, bottom - MIN.h)
  end
  return { x = left, y = top, w = right - left, h = bottom - top }
end

-- Same polling as the buddy's drag (no Accessibility permission needed): a mousedown in
-- the page starts it, letting go of the button ends it. move(dx, dy) runs on every tick
-- while the button is down; afterwards the panel's new spot and size are remembered.
local function track(move)
  if C.dragTimer then C.dragTimer:stop() end
  local m0, f0 = hs.mouse.absolutePosition(), C.wv:frame()
  C.dragTimer = hs.timer.doEvery(1 / 60, function()
    if not C.wv then C.dragTimer:stop(); C.dragTimer = nil; return end
    local m = hs.mouse.absolutePosition()
    if not hs.eventtap.checkMouseButtons().left then
      C.dragTimer:stop()
      C.dragTimer = nil
      local f, a = C.wv:frame(), C.opts.anchor()
      if f.x ~= f0.x or f.y ~= f0.y then hs.settings.set(POS_KEY, { x = f.x - a.x, y = f.y - a.y }) end
      if f.w ~= f0.w or f.h ~= f0.h then hs.settings.set(SIZE_KEY, { w = f.w, h = f.h }) end
      return
    end
    move(f0, m.x - m0.x, m.y - m0.y)
  end)
end

-- Drag by the header: the whole panel follows the mouse.
local function drag()
  track(function(f0, dx, dy) C.wv:topLeft({ x = f0.x + dx, y = f0.y + dy }) end)
end

-- Drag an edge or corner: that side follows the mouse, within the panel's screen.
local function resize(edge)
  local f = C.wv:frame()
  local scr = screenAt(f.x + f.w / 2, f.y + f.h / 2)
  local bounds = scr and scr:frame()
  track(function(f0, dx, dy) C.wv:frame(C.resizeFrame(f0, edge, dx, dy, bounds)) end)
end

-- opts: dir, anchor() (the buddy canvas frame, now), title, ask(history, done, meta), opener(done),
-- onReply(text, meta), remember(history), dictation (config.lua's ai.dictation), noFocus (open
-- without taking the keyboard: "okay Buddy" from another app). meta.voice: it was said out loud.
function C.open(opts)
  if C.wv then
    if opts.noFocus then C.wv:show() else C.wv:show():bringToFront(true); hs.focus() end
    return
  end
  C.opts = opts
  local last = history[#history]
  local greet = opts.opener and (not last or now() - (last.at or 0) > GREET_AFTER)

  local fh = assert(io.open(opts.dir .. "/chat.html"))
  local html = fh:read("a")
  fh:close()
  html = dofile(opts.dir .. "/theme.lua").inline(html, opts.dir)
  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode({ title = opts.title or "Buddy", history = recent(), thinking = greet and true or false,
      dictation = opts.dictation ~= false, live = C.live }):gsub("</", "<\\/"))
  end)

  local function reply(text, err, meta)
    if not text then
      return js("window.add", { role = "assistant", content = err or ("My brain's offline." .. (opts.offlineHint or "")), error = true })
    end
    add({ role = "assistant", content = text }, true)
    if opts.onReply then opts.onReply(text, meta) end
  end

  -- The page shows your line itself; this files it and asks for the answer.
  local function send(text, meta)
    add({ role = "user", content = text })
    local function answered(t, e) reply(t, e, meta) end
    if opts.command then
      local answer = opts.command(text)
      if answer == true then return js("window.thinking", false) end
      if answer then return answered(answer) end
    end
    js("window.thinking", true)
    opts.ask(history, answered, meta)
  end
  C.send = send

  local uc = hs.webview.usercontent.new("buddy")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if b.type == "send" and (b.text or ""):match("%S") then
      send(b.text, b.voice and { voice = true } or nil)
    elseif b.type == "listen" or b.type == "stop" then
      listen(b.type == "listen")
    elseif b.type == "drag" then
      drag()
    elseif b.type == "resize" and type(b.edge) == "string" and b.edge:match("^[nsew][ew]?$") then
      resize(b.edge)
    elseif b.type == "close" then
      C.close()
    end
  end)

  -- The size you last dragged it to (never below MIN, never bigger than the screen), where
  -- you last dragged it if that's on a screen; otherwise above the buddy when there's room,
  -- or beside it, on its screen. Always fully on the screen.
  local size = hs.settings.get(SIZE_KEY)
  local w, h = SIZE.w, SIZE.h
  if type(size) == "table" and tonumber(size.w) and tonumber(size.h) then
    w, h = math.max(MIN.w, tonumber(size.w)), math.max(MIN.h, tonumber(size.h))
  end
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
  w, h = math.min(w, sf.w - 8), math.min(h, sf.h - 8)
  x = math.max(sf.x + 4, math.min(sf.x + sf.w - w - 4, x))
  y = math.max(sf.y + 4, math.min(sf.y + sf.h - h - 4, y))

  C.prevApp = not opts.noFocus and hs.application.frontmostApplication() or nil
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
  if not opts.noFocus then
    C.wv:bringToFront(true)
    hs.focus()
  end

  if greet then C.openerTimer = hs.timer.doAfter(0.3, function() opts.opener(reply) end) end
end

return C
