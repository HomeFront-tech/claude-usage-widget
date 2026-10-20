-- Setup wizard for the Claude buddy (Hammerspoon module)
--
-- A small window that gets to know you: your name, a check that the usage card can
-- reach Claude and that the macOS permissions are on, how the buddy should react to
-- the apps you use (most-used first, from what the buddy has seen), your own
-- websites, and how chatty it should be. It saves config.lua next to this file and
-- reloads Hammerspoon. The page itself is setup.html.

local W = {}

local MOOD_LABELS = {
  { "generic", "🙂 Just say hi" }, { "coding", "💻 Coding" }, { "reading", "🤓 Reading (glasses)" },
  { "browsing", "🌐 Browsing" }, { "watching", "🍿 Watching" }, { "music", "🎵 Music" },
  { "gaming", "🎮 Gaming" }, { "chat", "💬 Chatting" }, { "mail", "✉️ Mail" },
  { "curious", "❓ Curious" }, { "tinker", "🔧 Tinkering" }, { "snow", "❄️ Weather" },
  { "proud", "✨ Proud (it's yours!)" }, { "love", "😍 Love" }, { "jealous", "😒 Side-eye (rival AI)" },
  { "idle", "😌 Calm" },
}

-- Lua source for a config table; short lists of plain values stay on one line.
local function ser(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return "nil" end
  local inner, parts = indent .. "  ", {}
  if #v > 0 then
    local flat = true
    for _, x in ipairs(v) do
      if type(x) == "table" then flat = false end
      parts[#parts + 1] = ser(x, inner)
    end
    if flat then return "{ " .. table.concat(parts, ", ") .. " }" end
    return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. ",\n" .. indent .. "}"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  if #keys == 0 then return "{}" end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local key = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or "[" .. ser(k) .. "]"
    parts[#parts + 1] = inner .. key .. " = " .. ser(v[k], inner)
  end
  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end

-- Running apps plus everything in /Applications and ~/Applications, most-used first.
local function scanApps(builtinMood, cfgApps)
  local used = hs.settings.get("claudeBuddy.appSeconds") or {}
  local seen, list = {}, {}
  local function add(path, running)
    if not path or seen[path] then return end
    seen[path] = true
    local info = hs.application.infoForBundlePath(path)
    local id = info and info.CFBundleIdentifier
    if not id or seen[id] then return end
    seen[id] = true
    local name = info.CFBundleDisplayName or info.CFBundleName or path:match("([^/]+)%.app$")
    local default = builtinMood(id, name)
    local icon = hs.image.iconForFile(path)
    list[#list + 1] = {
      id = id, name = name, default = default, mood = cfgApps[id] or cfgApps[name] or default,
      running = running, minutes = math.floor((used[id] or 0) / 60),
      icon = icon and icon:setSize({ w = 32, h = 32 }):encodeAsURLString() or "",
    }
  end
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:kind() == 1 then add(app:path(), true) end
  end
  for _, dir in ipairs({ "/Applications", os.getenv("HOME") .. "/Applications" }) do
    if hs.fs.attributes(dir) then
      for f in hs.fs.dir(dir) do
        if f:match("%.app$") then add(dir .. "/" .. f, false) end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.minutes ~= b.minutes then return a.minutes > b.minutes end
    if a.running ~= b.running then return a.running end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

local function python()
  for _, p in ipairs({ "/opt/homebrew/bin/python3", "/usr/local/bin/python3" }) do
    if hs.fs.attributes(p) then return p end
  end
  return "/usr/bin/python3"
end

local function js(fn, data)
  if W.wv then W.wv:evaluateJavaScript(fn .. "(" .. hs.json.encode(data) .. ")") end
end

local function runChecks(dir)
  local res = { screen = hs.screenRecordingState(), launch = hs.autoLaunch() }
  W.task = hs.task.new(python(), function(_, out)
    local ok, d = pcall(hs.json.decode, out or "")
    if ok and type(d) == "table" and d.ok then
      local pct
      for _, l in ipairs(d.limits or {}) do
        if l.label == "Current session" then pct = l.pct end
      end
      res.usage = { ok = true, text = pct and string.format("Connected · session %d%% used", math.floor(pct + 0.5)) or "Connected" }
    else
      res.usage = { ok = false, text = (ok and type(d) == "table" and d.error) or "Couldn't run the usage check" }
    end
    js("window.onChecks", res)
  end, { "-I", dir .. "/bin/claude-usage" })
  W.task:start()
end

-- Merge the wizard's answers into the existing config and write config.lua.
local function save(dir, cfg, b)
  local new = {}
  for k, v in pairs(cfg) do new[k] = v end
  new.name = (b.name or "") ~= "" and b.name or nil
  new.buddy_on_top = b.onTop and true or nil
  new.chatter = b.chatter
  new.sleep_after = math.floor(tonumber(b.sleepAfter) or 10)

  local apps = {}
  for k, v in pairs(cfg.apps or {}) do apps[k] = v end
  for _, a in ipairs(b.apps or {}) do
    apps[a.name] = nil -- older configs keyed apps by name; the wizard uses bundle ids
    apps[a.id] = a.mood ~= a.default and a.mood or nil
  end
  new.apps = next(apps) and apps or nil

  local rules = {}
  for _, r in ipairs(cfg.title_rules or {}) do
    if r[2] ~= "proud" and r[2] ~= "reading" then rules[#rules + 1] = r end
  end
  for _, s in ipairs(b.proud or {}) do rules[#rules + 1] = { s:lower(), "proud" } end
  for _, s in ipairs(b.reading or {}) do rules[#rules + 1] = { s:lower(), "reading" } end
  new.title_rules = #rules > 0 and rules or nil

  local f = assert(io.open(dir .. "/config.lua", "w"))
  f:write("-- Written by the buddy's setup wizard (Option-click the buddy to run it again).\n",
          "-- Safe to edit by hand; config.example.lua explains every setting.\n",
          "return ", ser(new), "\n")
  f:close()
end

local function close()
  W.closeTimer = hs.timer.doAfter(0, function()
    if W.wv then W.wv:delete() end
    W.wv = nil
  end)
end

-- opts: dir, config (current config.lua table), builtinMood(bundleID, name), firstRun
function W.open(opts)
  if W.wv then
    W.wv:show():bringToFront(true)
    hs.focus()
    return
  end
  local cfg = opts.config
  local proud, reading = {}, {}
  for _, r in ipairs(cfg.title_rules or {}) do
    if r[2] == "proud" then proud[#proud + 1] = r[1] elseif r[2] == "reading" then reading[#reading + 1] = r[1] end
  end
  local moods = {}
  for _, m in ipairs(MOOD_LABELS) do moods[#moods + 1] = { key = m[1], label = m[2] } end
  local init = {
    firstRun = opts.firstRun and true or false, name = cfg.name or "",
    onTop = cfg.buddy_on_top and true or false, chatter = cfg.chatter or "chatty",
    sleepAfter = cfg.sleep_after or 10, proud = proud, reading = reading,
    moods = moods, apps = scanApps(opts.builtinMood, cfg.apps or {}),
  }
  local fh = assert(io.open(opts.dir .. "/setup.html"))
  local html = fh:read("a")
  fh:close()
  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode(init):gsub("</", "<\\/"))
  end)

  local uc = hs.webview.usercontent.new("buddy")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if b.type == "check" then
      runChecks(opts.dir)
    elseif b.type == "screenRecording" then
      hs.screenRecordingState(true)
      hs.urlevent.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    elseif b.type == "launchAtLogin" then
      hs.autoLaunch(true)
      runChecks(opts.dir)
    elseif b.type == "save" then
      save(opts.dir, cfg, b.config or {})
      close()
      W.reloadTimer = hs.timer.doAfter(0.4, hs.reload)
    elseif b.type == "close" then
      close()
    end
  end)

  local scr = hs.screen.mainScreen():frame()
  local w, h = 640, 720
  W.wv = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + math.max(40, (scr.h - h) / 3), w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable" })
    :windowTitle("Claude Buddy Setup")
    :allowTextEntry(true)
    :deleteOnClose(true)
    :windowCallback(function(action) if action == "closing" then W.wv = nil end end)
    :html(html)
    :show()
  W.wv:bringToFront(true)
  hs.focus()
end

return W
