-- Setup wizard for the Claude buddy (Hammerspoon module)
--
-- A small window that gets to know you: your name, a check that the usage card can
-- reach Claude and that the macOS permissions are on, whether to bring in Claude Code's
-- older history for the chart (what's there is shown first), how the buddy should react to
-- the apps you use (most-used first, from what the buddy has seen; Auto lets the brain
-- work it out, Never look keeps an app out of its sight), your own websites, how chatty
-- it should be, which brain to use, whether it may watch and look after you, and whether
-- to pair a Telegram bot so you can text it from your phone (telegram.lua does the
-- talking). It saves config.lua next to this file and reloads Hammerspoon. The page
-- itself is setup.html.

local W = {}

local MOOD_LABELS = {
  { "generic", "🙂 Just say hi" }, { "coding", "💻 Coding" }, { "reading", "🤓 Reading (glasses)" },
  { "browsing", "🌐 Browsing" }, { "watching", "🍿 Watching" }, { "music", "🎵 Music" },
  { "gaming", "🎮 Gaming" }, { "chat", "💬 Chatting" }, { "mail", "✉️ Mail" },
  { "curious", "❓ Curious" }, { "tinker", "🔧 Tinkering" }, { "snow", "❄️ Weather" },
  { "proud", "✨ Proud (it's yours!)" }, { "love", "😍 Love" }, { "jealous", "😒 Side-eye (rival AI)" },
  { "health", "💪 Health" }, { "food", "🍎 Food" },
  { "teammate", "🤝 Teammate" },
  { "idle", "😌 Calm" },
}
W.MOOD_LABELS = MOOD_LABELS -- buddy.lua offers the brain these moods when it learns an app

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

-- One app row's starting mood: "never" for apps on never_look, else the pinned mood, else
-- "auto" when Auto reactions are on, else the built-in default. `name` finds older
-- configs that keyed apps by name. The second result is true when the mood is the user's own
-- choice (a pin or Never look), so the page never turns it into Auto.
local function rowMood(cfg, id, default, name)
  for _, v in ipairs(type(cfg.never_look) == "table" and cfg.never_look or {}) do
    if v == id then return "never", true end
  end
  local apps = type(cfg.apps) == "table" and cfg.apps or {}
  local pin = apps[id] or (name and apps[name])
  if pin then return pin, true end
  return cfg.auto_reactions == true and "auto" or default
end
W.rowMood = rowMood

-- Running apps plus everything in /Applications and ~/Applications, most-used first.
local function scanApps(builtinMood, cfg)
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
    local mood, picked = rowMood(cfg, id, default, name)
    list[#list + 1] = {
      id = id, name = name, default = default, mood = mood, picked = picked or nil,
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

-- What older Claude Code history there is to bring in (read only; nothing is written).
local function scanHistory(dir)
  W.histTask = hs.task.new(python(), function(_, out)
    local ok, d = pcall(hs.json.decode, out or "")
    js("window.onHistoryScan", ok and type(d) == "table" and d or { ok = false })
  end, { "-I", dir .. "/bin/claude-tokens", "--scan" })
  W.histTask:start()
end

-- Is a Claude model on this plan? One ping through bin/buddy-agent; done(ok) gets the answer.
-- Answers are cached for a day in claudeBuddy.modelChecks (an unreadable reply is not cached).
local MODEL_CHECK_FOR = 24 * 3600
W.modelTasks = {}
function W.checkModel(dir, cfg, alias, done)
  if not (alias == "auto" or alias == "haiku" or alias == "sonnet" or alias == "opus" or alias == "fable") then
    return done(false)
  end
  local cache = hs.settings.get("claudeBuddy.modelChecks")
  if type(cache) ~= "table" then cache = {} end
  local now = os.time()
  local hit = cache[alias]
  if type(hit) == "table" and type(hit.ok) == "boolean" and type(hit.at) == "number"
      and hit.at <= now and now - hit.at < MODEL_CHECK_FOR then
    return done(hit.ok)
  end
  local home = os.getenv("HOME") or ""
  local agent = type(cfg.ai) == "table" and cfg.ai.agent_dir or nil
  if type(agent) == "string" and agent:sub(1, 2) == "~/" then agent = home .. agent:sub(2) end
  if type(agent) ~= "string" or agent == "" then agent = home .. "/Library/Application Support/claude-usage-widget/agent" end
  local task
  local made, created = pcall(hs.task.new, "/usr/bin/python3", function(_, out)
    W.modelTasks[alias] = nil
    local line
    for candidate in (out or ""):gmatch("[^\r\n]+") do
      if candidate:sub(1, 1) == "{" then line = candidate end
    end
    local parsed, d = false, nil
    if line then parsed, d = pcall(hs.json.decode, line) end
    if not (parsed and type(d) == "table") then return done(false) end
    local latest = hs.settings.get("claudeBuddy.modelChecks")
    if type(latest) ~= "table" then latest = {} end
    latest[alias] = { ok = d.ok == true, at = os.time() }
    hs.settings.set("claudeBuddy.modelChecks", latest)
    done(d.ok == true)
  end, { dir .. "/bin/buddy-agent" })
  if not made or not created then return done(false) end
  task = created
  local ran, started = pcall(function()
    task:setEnvironment({ HOME = home, PATH = home .. "/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
      BUDDY_AGENT_DIR = agent, USER = os.getenv("USER"), LOGNAME = os.getenv("LOGNAME"), TMPDIR = os.getenv("TMPDIR") })
    task:setInput(hs.json.encode({ kind = "ping", model = alias, system = "Reply with OK.", prompt = "OK?" }))
    W.modelTasks[alias] = task
    return task:start()
  end)
  if not ran or not started then
    W.modelTasks[alias] = nil
    done(false)
  end
end

-- The `ai` table for a brain choice: "auto", "haiku", "sonnet", "opus" or "fable" (Claude,
-- that model), "ollama" or true (a model on this Mac), false for plain rules. The legacy
-- "claude" keeps the old Claude model, else "haiku". Other ai keys are kept.
local CLAUDE_MODELS = { auto = true, haiku = true, sonnet = true, opus = true, fable = true }
local function brainConfig(old, choice)
  if not (CLAUDE_MODELS[choice] or choice == "claude" or choice == "ollama" or choice == true) then return nil end
  old = type(old) == "table" and old or {}
  local ai = {}
  for k, v in pairs(old) do ai[k] = v end
  if choice == "ollama" or choice == true then
    ai.engine = nil
    ai.model = (old.engine == nil or old.engine == "ollama") and old.model or "gemma3:4b"
  else
    ai.engine = "claude"
    ai.model = choice == "claude" and (old.engine == "claude" and old.model or "haiku") or choice
  end
  if not ai.model then ai.model = "gemma3:4b" end
  return ai
end

local function writeConfig(dir, new)
  local f = assert(io.open(dir .. "/config.lua", "w"))
  f:write("-- Written by the buddy's setup wizard (Option-click the buddy to run it again).\n",
          "-- Safe to edit by hand; config.example.lua explains every setting.\n",
          "return ", ser(new), "\n")
  f:close()
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- Merge the wizard's answers into the existing config and write config.lua.
local function save(dir, cfg, b)
  local new = copy(cfg)
  new.name = (b.name or "") ~= "" and b.name or nil
  new.buddy_on_top = b.onTop and true or nil
  new.chatter = b.chatter
  new.sleep_after = math.floor(tonumber(b.sleepAfter) or 10)
  new.check_updates = b.checkUpdates == false and false or nil
  new.import_history = b.importHistory and true or nil
  local price = tonumber(b.planPrice)
  new.plan_price = price and price > 0 and price or nil
  new.ai = brainConfig(cfg.ai, b.brain)
  local auto = b.autoReactions == true and new.ai ~= nil -- Auto needs a brain
  new.auto_reactions = auto and true or nil
  new.watch = b.watch ~= false
  new.wizard = 2 -- marks a config the new wizard saved (facts.lua talks only for these)
  if b.health then
    local h = copy(type(cfg.health) == "table" and cfg.health or {})
    local mins = math.floor(tonumber(b.sitMinutes) or 60)
    h.sit_minutes = mins > 0 and mins or 60
    new.health = h
  else
    new.health = nil
  end

  -- Auto keeps every pick (a pin may equal the built-in); without it only changes are kept.
  local apps, never, rowIds = {}, {}, {}
  for k, v in pairs(cfg.apps or {}) do apps[k] = v end
  for _, a in ipairs(b.apps or {}) do
    rowIds[a.id] = true
    if a.name then apps[a.name] = nil end -- older configs keyed apps by name; the wizard uses bundle ids
    if a.mood == "never" or a.mood == "auto" then
      apps[a.id] = nil
    elseif auto then
      apps[a.id] = a.mood
    else
      apps[a.id] = a.mood ~= a.default and a.mood or nil
    end
  end
  new.apps = next(apps) and apps or nil
  for _, id in ipairs(type(cfg.never_look) == "table" and cfg.never_look or {}) do
    if not rowIds[id] then never[#never + 1] = id end
  end
  for _, a in ipairs(b.apps or {}) do
    if a.mood == "never" then never[#never + 1] = a.id end
  end
  new.never_look = #never > 0 and never or nil

  local rules = {}
  for _, r in ipairs(cfg.title_rules or {}) do
    if r[2] ~= "proud" and r[2] ~= "reading" then rules[#rules + 1] = r end
  end
  for _, s in ipairs(b.proud or {}) do rules[#rules + 1] = { s:lower(), "proud" } end
  for _, s in ipairs(b.reading or {}) do rules[#rules + 1] = { s:lower(), "reading" } end
  new.title_rules = #rules > 0 and rules or nil

  -- telegram: a newly paired chat { chat_id, bot, name }, false for off, nil to keep it
  if b.telegram == false then
    new.telegram = nil
  elseif type(b.telegram) == "table" and math.tointeger(b.telegram.chat_id) then
    local tg = {}
    for k, v in pairs(type(cfg.telegram) == "table" and cfg.telegram or {}) do tg[k] = v end
    tg.chat_id, tg.bot, tg.name = math.tointeger(b.telegram.chat_id), b.telegram.bot, b.telegram.name
    new.telegram = tg
  end

  writeConfig(dir, new)
end
W.save = save

-- Switch the brain (see brainConfig) and write config.lua with only that change.
function W.setBrain(dir, cfg, choice)
  local new = copy(cfg)
  new.ai = brainConfig(cfg.ai, choice)
  writeConfig(dir, new)
  return new
end

-- A brain choice (string, or false/true) as its menu key, its label and whether it is a
-- Claude model: false -> "plain", true -> "ollama".
local BRAIN_LABELS = {
  auto = "Auto", haiku = "Haiku", sonnet = "Sonnet", opus = "Opus", fable = "Fable",
  ollama = "Ollama on this Mac", plain = "Plain rules",
}
function W.brainInfo(choice)
  local key = choice
  if choice == false or choice == "plain" then key = "plain"
  elseif choice == true then key = "ollama" end
  return key, BRAIN_LABELS[key] or tostring(key), CLAUDE_MODELS[key] == true
end

-- Set (or, with nil, remove) one top-level setting and write config.lua.
function W.setOption(dir, cfg, key, value)
  local new = copy(cfg)
  new[key] = value
  writeConfig(dir, new)
  return new
end

function W.initial(cfg)
  cfg = cfg or {}
  local proud, reading = {}, {}
  for _, r in ipairs(cfg.title_rules or {}) do
    if r[2] == "proud" then proud[#proud + 1] = r[1] elseif r[2] == "reading" then reading[#reading + 1] = r[1] end
  end
  local brain = false
  if type(cfg.ai) == "table" then
    if cfg.ai.engine == "claude" then
      brain = CLAUDE_MODELS[cfg.ai.model] and cfg.ai.model or "haiku"
    else
      brain = "ollama"
    end
  end
  local health = type(cfg.health) == "table" and cfg.health or {}
  local tg = type(cfg.telegram) == "table" and math.tointeger(cfg.telegram.chat_id) and cfg.telegram or nil
  return {
    name = cfg.name or "", onTop = cfg.buddy_on_top and true or false,
    chatter = cfg.chatter or "chatty", sleepAfter = cfg.sleep_after or 10,
    checkUpdates = cfg.check_updates ~= false, brain = brain,
    importHistory = cfg.import_history == true, planPrice = cfg.plan_price, proud = proud, reading = reading,
    telegram = tg and { bot = tg.bot or "", name = tg.name or "" } or false,
    autoReactions = cfg.auto_reactions == true, watch = cfg.watch ~= false,
    health = cfg.health == true or type(cfg.health) == "table",
    sitMinutes = math.floor(tonumber(health.sit_minutes) or 60),
  }
end

-- A QR code of text as a PNG data URL, drawn by macOS (Core Image), or nil.
local function qrCode(text)
  local ok, png = hs.osascript.javascript([[
ObjC.import('CoreImage'); ObjC.import('AppKit');
const f = $.CIFilter.filterWithName('CIQRCodeGenerator');
f.setValueForKey($(]] .. hs.json.encode({ text }):sub(2, -2) .. [[).dataUsingEncoding($.NSUTF8StringEncoding), 'inputMessage');
f.setValueForKey($('M'), 'inputCorrectionLevel');
const rep = $.NSBitmapImageRep.alloc.initWithCIImage(f.outputImage.imageByApplyingTransform($.CGAffineTransformMakeScale(6, 6)));
rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).base64EncodedStringWithOptions(0).js;]])
  return ok and type(png) == "string" and png ~= "" and "data:image/png;base64," .. png or nil
end
W.qrCode = qrCode

-- Telegram pairing: check the pasted token, then wait for the code from the phone. The
-- token stays here until Save puts it in the Keychain.
local function pairTelegram(T, token)
  token = (token or ""):gsub("%s+", "")
  W.tgToken, W.tgPaired = nil, nil
  local n = tonumber(hs.host.uuid():gsub("%-", ""):sub(1, 8), 16)
  W.tgCode = string.format("%06d", n % 1000000)
  T.pair(token, W.tgCode, function(kind, info)
    if not W.wv then return end
    if kind == "bot" then
      W.tgBot = info.username
      local link = (info.username or ""):match("^[%w_]+$") and ("https://t.me/" .. info.username .. "?start=" .. W.tgCode)
      js("window.onTelegram", { state = "waiting", bot = info.username or "", code = W.tgCode,
        link = link or "", qr = link and qrCode(link) or "" })
    elseif kind == "paired" then
      W.tgToken, W.tgPaired = token, { chat_id = info.chat_id, bot = W.tgBot, name = info.name }
      js("window.onTelegram", { state = "paired", bot = W.tgBot or "", name = info.name or "" })
    else
      js("window.onTelegram", { state = "error", text = info })
    end
  end)
end

local function close()
  if W.telegram then W.telegram.cancelPair() end
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
  W.telegram, W.tgToken, W.tgPaired = opts.telegram, nil, nil
  local moods = {}
  for _, m in ipairs(MOOD_LABELS) do moods[#moods + 1] = { key = m[1], label = m[2] } end
  local init = W.initial(cfg)
  init.moods, init.apps, init.firstRun = moods, scanApps(opts.builtinMood, cfg), opts.firstRun and true or false
  local fh = assert(io.open(opts.dir .. "/setup.html"))
  local html = fh:read("a")
  fh:close()
  html = dofile(opts.dir .. "/theme.lua").inline(html, opts.dir)
  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode(init):gsub("</", "<\\/"))
  end)

  local uc = hs.webview.usercontent.new("buddy")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if b.type == "check" then
      runChecks(opts.dir)
    elseif b.type == "historyScan" then
      scanHistory(opts.dir)
    elseif b.type == "modelCheck" and type(b.model) == "string" then
      local alias = b.model
      W.checkModel(opts.dir, cfg, alias, function(ok) js("window.onModelCheck", { model = alias, ok = ok }) end)
    elseif b.type == "screenRecording" then
      hs.screenRecordingState(true)
      hs.urlevent.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    elseif b.type == "launchAtLogin" then
      hs.autoLaunch(true)
      runChecks(opts.dir)
    elseif b.type == "save" then
      local answers = b.config or {}
      local function finish()
        save(opts.dir, cfg, answers)
        close()
        W.reloadTimer = hs.timer.doAfter(0.4, hs.reload)
      end
      local T = W.telegram
      if answers.telegram == "new" and W.tgPaired and T then
        answers.telegram = W.tgPaired
        return T.saveToken(W.tgToken, function(ok)
          if ok then return finish() end
          js("window.onSaveFailed", { text = "Couldn't put the Telegram token in your Keychain. Try Save again." })
        end)
      end
      if answers.telegram ~= false then answers.telegram = nil end -- "keep", or never paired
      if answers.telegram == false and cfg.telegram and T then return T.forgetToken(finish) end
      finish()
    elseif b.type == "tgConnect" and W.telegram then
      pairTelegram(W.telegram, b.token)
    elseif b.type == "tgCancel" and W.telegram then
      W.telegram.cancelPair()
    elseif b.type == "tgOpen" and type(b.url) == "string" and b.url:match("^https://t%.me/[%w_]+") then
      hs.urlevent.openURL(b.url)
    elseif b.type == "close" then
      close()
    end
  end)

  local scr = hs.screen.mainScreen():frame()
  local w, h = 640, 720 + 32
  -- The page runs under the title bar (setup.html pads its top 32px): on macOS 26 and later
  -- a webview window's own title bar is see-through and shows the desktop behind it.
  W.wv = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + math.max(40, (scr.h - h) / 3), w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable", "fullSizeContentView" })
    :windowTitle("Claude Buddy Setup")
    :allowTextEntry(true)
    :deleteOnClose(true)
    :windowCallback(function(action)
      if action == "closing" then
        W.wv = nil
        if W.telegram then W.telegram.cancelPair() end
      end
    end)
    :html(html)
    :show()
  W.wv:bringToFront(true)
  hs.focus()
end

return W
