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
local SEQ_KEY = "claudeBuddy.chatSeq"
local POS_KEY = "claudeBuddy.chatOffset" -- where you dragged the panel, relative to the buddy
local KEEP = 80             -- lines kept
local SHOW = 5              -- the buddy's lines shown when the panel opens
local GREET_AFTER = 20 * 60 -- quiet this long and opening the panel gets a fresh hello
local GROW_TO = 0.5         -- while the box fills, the panel may grow to this share of its screen's height...
local GROW_MIN = 160        -- ...and at least this much (px, about eight lines) when the screen has the room
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

-- The screen a point is on, or nil. Not hs.screen.find: that returns the nearest screen
-- even for a point on none.
local function screenAt(x, y)
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:frame()
    if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then return s end
  end
end

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
  C.base, C.grow = nil, 0
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

-- The page's box is `grow` px taller than one line (its "size" message, 0 after a send): the
-- window grows upward by as much so the box stays where it is, and only when that would
-- leave the top of the screen does it grow downward instead. C.base is the one-line frame
-- the panel comes back to; C.maxGrow (set when it opens) is the room the screen allows.
local function resize(grow)
  if not C.wv or not C.base then return end
  grow = math.floor(math.max(0, math.min(tonumber(grow) or 0, C.maxGrow or 0)))
  if grow == C.grow then return end
  C.grow = grow
  local b = C.base
  local scr = screenAt(b.x + b.w / 2, b.y + b.h / 2) or hs.screen.mainScreen()
  local sf = scr:frame()
  C.wv:frame({ x = b.x, y = math.max(sf.y + 4, b.y - grow), w = b.w, h = b.h + grow })
end

-- Same polling drag as the buddy (no Accessibility permission needed): the header's
-- mousedown starts it, letting go of the button ends it and saves the spot. A drag while
-- the box is tall moves the one-line frame by the same amount.
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
      if p.x ~= p0.x or p.y ~= p0.y then
        C.base.x, C.base.y = C.base.x + p.x - p0.x, C.base.y + p.y - p0.y
        hs.settings.set(POS_KEY, { x = C.base.x - a.x, y = C.base.y - a.y })
      end
      return
    end
    C.wv:topLeft({ x = p0.x + m.x - m0.x, y = p0.y + m.y - m0.y })
  end)
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
  -- Where you last dragged it, if that's on a screen; otherwise above the buddy when
  -- there's room, or beside it, on its screen. Always fully on the screen.
  local w, h = 320, 400
  local a = opts.anchor()
  local x, y, scr
  local off = hs.settings.get(POS_KEY)
  if off then
    x, y = a.x + off.x, a.y + off.y
    scr = screenAt(x + w / 2, y + h / 2)
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
  C.base, C.grow = { x = x, y = y, w = w, h = h }, 0
  C.maxGrow = math.max(0, math.min(math.max(math.floor(sf.h * GROW_TO), h + GROW_MIN), sf.h - 8) - h)

  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode({ title = opts.title or "Buddy", history = recent(), thinking = greet and true or false,
      dictation = opts.dictation ~= false, live = C.live, grow = C.maxGrow }):gsub("</", "<\\/"))
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
    elseif b.type == "size" then
      resize(b.grow)
    elseif b.type == "drag" then
      drag()
    elseif b.type == "close" then
      C.close()
    end
  end)

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
