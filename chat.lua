-- Chat panel for the Claude buddy (Hammerspoon module)
--
-- A small floating chat box next to the buddy. You type, the buddy answers through
-- brain.lua with a fresh look at the window you were in. The page is chat.html;
-- Escape or ✕ closes it. The conversation is kept until it's been quiet for 20 min.

local C = {}

local FORGET_AFTER = 20 * 60
local history, lastTalk = {}, 0

local function js(fn, data)
  if not C.wv then return end
  -- hs.json.encode only takes tables, so wrap plain values and unwrap the array
  local arg = type(data) == "table" and hs.json.encode(data) or hs.json.encode({ data }):sub(2, -2)
  C.wv:evaluateJavaScript(fn .. "(" .. arg .. ")")
end

function C.isOpen() return C.wv ~= nil end

-- Closing hands the keyboard back to the app you were in before the panel opened.
function C.close()
  C.closeTimer = hs.timer.doAfter(0, function()
    if C.wv then C.wv:delete() end
    C.wv = nil
    if C.prevApp and C.prevApp:bundleID() ~= "org.hammerspoon.Hammerspoon" then C.prevApp:activate() end
  end)
end

-- opts: dir, anchor (buddy canvas frame), title, ask(history, done), opener(done)
function C.open(opts)
  if C.wv then
    C.wv:show():bringToFront(true)
    hs.focus()
    return
  end
  if hs.timer.secondsSinceEpoch() - lastTalk > FORGET_AFTER then history = {} end
  local greet = #history == 0 and opts.opener

  local fh = assert(io.open(opts.dir .. "/chat.html"))
  local html = fh:read("a")
  fh:close()
  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode({ title = opts.title or "Buddy", history = history, thinking = greet and true or false }):gsub("</", "<\\/"))
  end)

  local function reply(text)
    lastTalk = hs.timer.secondsSinceEpoch()
    if text then history[#history + 1] = { role = "assistant", content = text } end
    js("window.add", { role = "assistant", content = text or "My brain's offline. Is Ollama running?", error = not text })
    if text and opts.onReply then opts.onReply(text) end
  end

  local uc = hs.webview.usercontent.new("buddy")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if b.type == "send" and (b.text or ""):match("%S") then
      history[#history + 1] = { role = "user", content = b.text }
      lastTalk = hs.timer.secondsSinceEpoch()
      js("window.thinking", true)
      opts.ask(history, reply)
    elseif b.type == "close" then
      C.close()
    end
  end)

  -- Above the buddy when there's room, otherwise beside it; always on its screen.
  local w, h = 320, 400
  local a = opts.anchor
  local scr = hs.screen.find({ x = a.x + a.w / 2, y = a.y + a.h / 2, w = 1, h = 1 }) or hs.screen.mainScreen()
  local sf = scr:frame()
  local x, y = a.x + a.w / 2 - w / 2, a.y - h + 40
  if y < sf.y then x, y = a.x + a.w - 10, a.y + a.h - h end
  if x + w > sf.x + sf.w then x = a.x - w + 10 end
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
