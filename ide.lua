-- The IDE (Beta): a local web workbench, such as a dashboard of your projects and Claude Code
-- sessions, opened in its own window from the menu bar. Off unless config.lua has `ide`:
--   ide = { url = "http://127.0.0.1:8750/", dir = "~/dev/my-hub", start = "python3 hub.py" }
-- url must be on this Mac (127.0.0.1, localhost or [::1]). When nothing answers there and
-- `start` is set, Buddy runs `start` in `dir` (detached, so it outlives a Buddy restart),
-- waits for the page, then opens it. Links that leave the page open in your browser.
--
-- usage_widget.lua calls I.setup(CFG.ide) and hands the result to menubar.lua.
-- I.settings, I.isLocal and I.sameOrigin are plain functions the specs check.

local I = {}

local FRAME_KEY = "claudeBuddy.ideFrame"
local WAIT = 20 -- seconds to wait for a freshly started server
local SUPPORT = os.getenv("HOME") .. "/Library/Application Support/claude-usage-widget"

local function tilde(p)
  if type(p) ~= "string" or p == "" then return nil end
  return (p:gsub("^~/", os.getenv("HOME") .. "/"))
end

-- "http://127.0.0.1:8750/x" -> "http", "127.0.0.1", "8750"
local function parts(url)
  if type(url) ~= "string" then return nil end
  local scheme, host, port = url:match("^(https?)://(%[[^%]]+%])(:?%d*)")
  if not scheme then scheme, host, port = url:match("^(https?)://([^/:?#]+)(:?%d*)") end
  if not scheme then return nil end
  return scheme:lower(), host:lower(), port
end

function I.isLocal(url)
  local _, host = parts(url)
  return host == "127.0.0.1" or host == "localhost" or host == "[::1]"
end

function I.sameOrigin(a, b)
  local s1, h1, p1 = parts(a)
  local s2, h2, p2 = parts(b)
  return s1 ~= nil and s1 == s2 and h1 == h2 and p1 == p2
end

-- config.lua's `ide` -> { url, dir, start, title } or nil (with a reason for the console).
function I.settings(cfg)
  if cfg == nil or cfg == false then return nil end
  if type(cfg) ~= "table" then return nil, "ide should be a table with a url" end
  if not I.isLocal(cfg.url) then return nil, "ide.url must be a page on this Mac (http://127.0.0.1:...)" end
  local start = type(cfg.start) == "string" and cfg.start ~= "" and cfg.start or nil
  local dir = tilde(cfg.dir)
  if start and not dir then return nil, "ide.start needs ide.dir, the folder to run it in" end
  return { url = cfg.url, dir = dir, start = start,
    title = type(cfg.title) == "string" and cfg.title ~= "" and cfg.title or "IDE (Beta)" }
end

local function tell(msg)
  if ClaudeBuddy and ClaudeBuddy.say and ClaudeBuddy.canvas then
    ClaudeBuddy.say(msg, "user")
  else
    hs.alert.show(msg, 4)
  end
end

local function answering(url, done)
  hs.http.asyncGet(url, nil, function(status) done(type(status) == "number" and status >= 200 and status < 400) end)
end

-- Start the server in the background; nohup and & let it outlive this shell and Buddy.
local function launch(S)
  hs.fs.mkdir(SUPPORT)
  I.startTask = hs.task.new("/bin/sh", nil, { "-c",
    'cd "$IDE_DIR" || exit 1; nohup /bin/sh -c "$IDE_START" >>"$IDE_LOG" 2>&1 </dev/null &' })
  local env = I.startTask:environment() or {} -- Buddy's own, plus Homebrew on the PATH
  env.PATH = "/opt/homebrew/bin:/usr/local/bin:" .. (env.PATH or "/usr/bin:/bin")
  env.IDE_DIR, env.IDE_START, env.IDE_LOG = S.dir, S.start, SUPPORT .. "/ide.log"
  I.startTask:setEnvironment(env)
  return I.startTask:start() ~= false
end

-- Make sure something answers at the url (starting it if we can), then call done(ok).
local function ready(S, done)
  if I.startup then
    table.insert(I.startup.callbacks, done)
    return
  end
  local op = { callbacks = { done } }
  I.startup = op
  local function finish(ok)
    if I.startup ~= op then return end
    if op.timer then op.timer:stop() end
    I.startup, I.waitTimer, I.startTask = nil, nil, nil
    for _, callback in ipairs(op.callbacks) do callback(ok) end
  end
  answering(S.url, function(up)
    if I.startup ~= op then return end
    if up then return finish(true) end
    if not S.start then
      tell("The IDE isn't running at " .. S.url .. ".")
      return finish(false)
    end
    if not launch(S) then
      tell("I couldn't start the IDE.")
      return finish(false)
    end
    tell("Starting the IDE…")
    local tries, probing = 0, false
    op.timer = hs.timer.doEvery(0.5, function()
      if I.startup ~= op then return end
      tries = tries + 1
      if tries >= WAIT * 2 then
        tell("The IDE didn't start. Its log is in " .. SUPPORT .. "/ide.log.")
        return finish(false)
      end
      if probing then return end
      probing = true
      answering(S.url, function(ok)
        if I.startup ~= op then return end
        probing = false
        if ok then finish(true) end
      end)
    end)
    I.waitTimer = op.timer
  end)
end

local function frame()
  local saved = hs.settings.get(FRAME_KEY)
  local scr = hs.screen.mainScreen():frame()
  if type(saved) == "table" and saved.w and saved.h then
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:frame()
      if saved.x >= f.x - 50 and saved.y >= f.y - 50 and saved.x < f.x + f.w - 100 and saved.y < f.y + f.h - 100 then
        return saved
      end
    end
  end
  local w, h = math.min(1400, scr.w - 80), math.min(860, scr.h - 80) + 32
  return { x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 3, w = w, h = h }
end

local function show(S)
  if I.wv then I.wv:show():bringToFront(true); hs.focus(); return end
  -- fullSizeContentView: on macOS 26 and later WebKit keeps a loaded page's content below the
  -- title bar by itself and fills the bar with the page's background, so the page needs no padding.
  I.wv = hs.webview.new(frame(), { developerExtrasEnabled = false })
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable", "fullSizeContentView" })
    :darkMode(hs.host.interfaceStyle() == "Dark")
    :windowTitle(S.title)
    :allowTextEntry(true)
    :allowNewWindows(false)
    :deleteOnClose(true)
    -- stay on the IDE's own pages; anything else goes to the browser
    :policyCallback(function(action, wv, d)
      if action ~= "navigationAction" then return true end
      local url = d and d.request and d.request.URL
      if not url or url == "about:blank" or I.sameOrigin(url, S.url) then return true end
      if url:match("^https?://") then hs.urlevent.openURL(url) end
      return false
    end)
    :windowCallback(function(action, wv, f)
      if action == "closing" and I.wv == wv then I.wv = nil
      elseif action == "frameChange" and type(f) == "table" then
        hs.settings.set(FRAME_KEY, { x = f.x, y = f.y, w = f.w, h = f.h })
      end
    end)
    :url(S.url)
    :show()
  I.wv:bringToFront(true)
  hs.focus()
end

-- I.setup(CFG.ide) -> the module with open() and browser(), or nil when the IDE is off.
function I.setup(cfg)
  local S, why = I.settings(cfg)
  if not S then
    if why then print("ClaudeUsage ide: " .. why) end
    return nil
  end
  I.S = S
  return I
end

function I.open()
  if I.wv then return show(I.S) end
  ready(I.S, function(ok) if ok then show(I.S) end end)
end

function I.browser()
  ready(I.S, function(ok) if ok then hs.urlevent.openURL(I.S.url) end end)
end

return I
