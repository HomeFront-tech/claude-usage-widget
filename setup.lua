-- Setup wizard for the Claude buddy (Hammerspoon module)
--
-- A small window that gets to know you: your name, a check that the usage card can
-- reach Claude and that the macOS permissions are on, which other AIs go on the usage card
-- (each checked live; keys held here until Save puts them in the Keychain, keys.lua) and
-- how the card shows them, whether to bring in Claude Code's
-- older history for the chart (what's there is shown first), how the buddy should react to
-- the apps you use (most-used first, from what the buddy has seen; Auto lets the brain
-- work it out, Never look keeps an app out of its sight), your own websites, how chatty
-- it should be, how its personality dials (personality.lua) are set, which brain to use,
-- whether it may listen and speak, whether it may watch and look after you, and whether
-- to pair a Telegram bot so you can text it from your phone (telegram.lua does the
-- talking). It saves config.lua next to this file and reloads Hammerspoon. The page
-- itself is setup.html.

local W = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local Personality = dofile(DIR .. "/personality.lua")
local Voice = dofile(DIR .. "/voice.lua")
local Speech = dofile(DIR .. "/speech.lua")
local Providers = dofile(DIR .. "/providers.lua") -- the AIs the usage card can show
local Keys = dofile(DIR .. "/keys.lua")
W.poll = dofile(DIR .. "/usage_poll.lua") -- runs a provider's check (specs swap it)
W.keys, W.removeKeys = {}, {} -- pasted keys held until Save, and saved ones to delete then

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
      local labels = {} -- for the card step's checkboxes
      for _, it in ipairs(Providers.visible(d, {})) do labels[#labels + 1] = it.label end
      res.usage = { ok = true, text = pct and string.format("Connected · session %d%% used", math.floor(pct + 0.5)) or "Connected",
        labels = labels }
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

-- The usage table for config.lua from the page's answers (order, levels, the red alert and
-- each AI's settings), keeping only what differs from Claude only with the defaults: nil
-- when nothing does. Settings for an AI that's turned off are kept for when it's back on.
-- Keys are never among the fields copied.
function W.usageConfig(old, a)
  if type(a) ~= "table" then return old end
  old = type(old) == "table" and old or {}
  local u, providers = {}, {}
  for id, p in pairs(type(old.providers) == "table" and old.providers or {}) do providers[id] = p end
  for id, p in pairs(type(a.providers) == "table" and a.providers or {}) do
    local e = Providers.byId(id)
    if e and type(p) == "table" then
      local keep, hide = {}, {}
      if e.refresh and type(p.refresh) == "number" and p.refresh ~= e.refresh then keep.refresh = math.floor(p.refresh) end
      for _, label in ipairs(type(p.hide) == "table" and p.hide or {}) do
        if type(label) == "string" then hide[#hide + 1] = label end
      end
      table.sort(hide)
      keep.hide = #hide > 0 and hide or nil
      keep.budget = type(p.budget) == "number" and p.budget > 0 and p.budget or nil
      for _, k in ipairs({ "team_id", "plan" }) do
        if type(p[k]) == "string" and p[k] ~= "" then keep[k] = p[k] end
      end
      local day = type(p.renews_day) == "number" and math.tointeger(p.renews_day)
      keep.renews_day = day and day >= 1 and day <= 31 and day or nil
      providers[id] = next(keep) and keep or nil
    end
  end
  local order = {}
  for _, id in ipairs(type(a.order) == "table" and a.order or {}) do
    if Providers.byId(id) then order[#order + 1] = id end
  end
  if #order > 0 and not (#order == 1 and order[1] == "claude") then u.order = order end
  if type(a.warn_at) == "number" and a.warn_at ~= 70 then u.warn_at = a.warn_at end
  if type(a.hot_at) == "number" and a.hot_at ~= 90 then u.hot_at = a.hot_at end
  if a.alert_red == true then u.alert_red = true end
  if next(providers) then u.providers = providers end
  return next(u) and u or nil
end

-- What the page starts from: the settings in use, plus every AI it can offer.
function W.usageInitial(cfg)
  local s = Providers.settings(cfg)
  local providers, known = {}, {}
  for _, e in ipairs(Providers.LIST) do
    local ps, hide = s.providers[e.id], {}
    for label in pairs(ps.hide) do hide[#hide + 1] = label end
    table.sort(hide)
    providers[e.id] = { refresh = ps.refresh, hide = hide, budget = ps.budget, team_id = ps.team_id, plan = ps.plan,
      renews_day = ps.renews_day }
    known[#known + 1] = { id = e.id, name = e.name, kind = e.kind, refresh = e.refresh, min_refresh = e.min_refresh,
      choices = e.choices, fields = e.fields }
  end
  return { order = s.order, warn_at = s.warn_at, hot_at = s.hot_at, alert_red = s.alert_red, providers = providers, known = known }
end

-- Put the held keys in the Keychain one at a time, then delete the removed ones.
-- done(nil), or done(id, "save" or "remove") for the first one that didn't work.
function W.saveKeys(K, keys, removals, done)
  local ids, gone = {}, {}
  for id in pairs(keys or {}) do ids[#ids + 1] = id end
  for id in pairs(removals or {}) do gone[#gone + 1] = id end
  table.sort(ids)
  table.sort(gone)
  local function forget(i)
    if i > #gone then return done(nil) end
    K.forget(gone[i], function(ok)
      if ok then forget(i + 1) else done(gone[i], "remove") end
    end)
  end
  local function put(i)
    if i > #ids then return forget(1) end
    K.save(ids[i], keys[ids[i]], function(ok)
      if ok then put(i + 1) else done(ids[i], "save") end
    end)
  end
  put(1)
end

-- Merge the wizard's answers into the existing config and write config.lua.
local function save(dir, cfg, b)
  local new = copy(cfg)
  new.name = (b.name or "") ~= "" and b.name or nil
  new.buddy_on_top = b.onTop and true or nil
  new.chatter = b.chatter
  if b.personality ~= nil then -- only the dials moved off their defaults are kept
    local dials = Personality.sparse(b.personality)
    new.personality = next(dials) and dials or nil
  end
  new.sleep_after = math.floor(tonumber(b.sleepAfter) or 10)
  new.check_updates = b.checkUpdates == false and false or nil
  new.import_history = b.importHistory and true or nil
  local price = tonumber(b.planPrice)
  new.plan_price = price and price > 0 and price or nil
  new.ai = brainConfig(cfg.ai, b.brain)
  local auto = b.autoReactions == true and new.ai ~= nil -- Auto needs a brain
  new.auto_reactions = auto and true or nil
  new.watch = b.watch ~= false
  if b.usage ~= nil then new.usage = W.usageConfig(cfg.usage, b.usage) end
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

-- Voice switches live in Hammerspoon settings, separate from config.lua. Write listen
-- first so its first-use answer default applies only when the page left answers out, and
-- the bubble switch after the slider so an explicit off wins over a slider above never.
function W.saveVoice(b)
  if type(b) ~= "table" then return end
  for _, key in ipairs({ "listen", "answers", "outLoud", "bubbles", "voice", "phrase" }) do
    if b[key] ~= nil then Voice.set(key, b[key]) end
  end
end

-- Optional arguments make the platform check deterministic in the Lua specs.
function W.voiceTrouble(version, checkTools)
  version = version or hs.host.operatingSystemVersion()
  if (version.major or 0) < 26 then return "Voice needs macOS 26 or later." end
  checkTools = checkTools or function() -- a file check, so opening the wizard runs nothing
    for _, p in ipairs({ "/Library/Developer/CommandLineTools/usr/bin/swiftc",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" }) do
      if hs.fs.attributes(p) then return true end
    end
    return false
  end
  if not checkTools() then
    return "Voice needs Apple's Command Line Tools: xcode-select --install"
  end
  return nil
end

-- The Mac's voices, then each installed engine's (`<wrapper> --voices`, 5 s at most),
-- gathered in the background so opening the wizard never waits on them. done(choices)
-- runs once, with { engine, name, label } rows.
function W.loadVoices(engines, done)
  local installed = {}
  for _, e in ipairs(engines or {}) do if e.installed then installed[#installed + 1] = e end end
  local left, found = 1 + #installed, {}
  local function finish()
    left = left - 1
    if left > 0 then return end
    local choices, order = {}, { "system" }
    for _, e in ipairs(installed) do order[#order + 1] = e.id end
    for _, key in ipairs(order) do
      for _, c in ipairs(found[key] or {}) do choices[#choices + 1] = c end
    end
    done(choices)
  end
  W.voiceTasks = W.voiceTasks or {}
  local function run(path, args, take)
    local task
    task = hs.task.new(path, function(code, out)
      if W.voiceTasks[task] then W.voiceTasks[task]:stop() end
      W.voiceTasks[task] = nil
      if code == 0 then take(out or "") end
      finish()
    end, args)
    if task and task:start() then
      W.voiceTasks[task] = hs.timer.doAfter(5, function() if task:isRunning() then task:terminate() end end)
    else finish() end
  end
  run("/usr/bin/say", { "-v", "?" }, function(out)
    found.system = {}
    for _, v in ipairs(Speech.parseVoices(out)) do
      found.system[#found.system + 1] = { engine = "system", name = v.name, label = "Mac voice: " .. v.name }
    end
  end)
  local home = os.getenv("HOME") or ""
  for _, engine in ipairs(installed) do
    run(home .. "/Library/Application Support/claude-usage-widget/voices/" .. engine.id, { "--voices" }, function(out)
      found[engine.id] = {}
      for line in out:gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" then
          found[engine.id][#found[engine.id] + 1] = { engine = engine.id, name = name, label = engine.name .. ": " .. name }
        end
      end
    end)
  end
end

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
    chatter = cfg.chatter or "chatty", personality = Personality.normalize(cfg.personality), sleepAfter = cfg.sleep_after or 10,
    checkUpdates = cfg.check_updates ~= false, brain = brain,
    importHistory = cfg.import_history == true, planPrice = cfg.plan_price, proud = proud, reading = reading,
    telegram = tg and { bot = tg.bot or "", name = tg.name or "" } or false,
    autoReactions = cfg.auto_reactions == true, watch = cfg.watch ~= false,
    health = cfg.health == true or type(cfg.health) == "table",
    sitMinutes = math.floor(tonumber(health.sit_minutes) or 60),
    usage = W.usageInitial(cfg),
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
  W.keys, W.removeKeys = {}, {}
  W.voiceTestToken = (W.voiceTestToken or 0) + 1
  if W.testSound then W.testSound:stop(); W.testSound = nil end
  if W.testFile then os.remove(W.testFile); W.testFile = nil end
  if W.telegram then W.telegram.cancelPair() end
  W.closeTimer = hs.timer.doAfter(0, function()
    if W.wv then W.wv:delete() end
    W.wv = nil
  end)
end

-- opts: dir, config (current config.lua table), builtinMood(bundleID, name), firstRun,
-- voiceSetup(engineID, done(message)) when task sessions are available
function W.open(opts)
  if W.wv then
    W.wv:show():bringToFront(true)
    hs.focus()
    return
  end
  local cfg = opts.config
  Voice.configure(cfg)
  W.telegram, W.tgToken, W.tgPaired = opts.telegram, nil, nil
  W.keys, W.removeKeys = {}, {}
  local moods = {}
  for _, m in ipairs(MOOD_LABELS) do moods[#moods + 1] = { key = m[1], label = m[2] } end
  local init = W.initial(cfg)
  init.moods, init.apps, init.firstRun = moods, scanApps(opts.builtinMood, cfg), opts.firstRun and true or false
  init.voice, init.engines = Voice.settings(), Speech.engines()
  init.voices = {} -- filled in the background once the page is up (W.loadVoices)
  init.voiceTrouble, init.canSetup = W.voiceTrouble(), opts.voiceSetup ~= nil
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
    elseif b.type == "providerCheck" and type(b.id) == "string" and Providers.byId(b.id) and b.id ~= "claude" then
      -- one AI's check from the "Which AIs" step; a pasted key comes along once and is held here
      local id, fields = b.id, type(b.fields) == "table" and b.fields or {}
      local function reply(res)
        local labels = {}
        for _, it in ipairs(Providers.visible(res, {})) do labels[#labels + 1] = it.label end
        js("window.onProviderCheck", { id = id, ok = type(res) == "table" and res.ok == true,
          text = Providers.checkText(res, {}), labels = labels })
      end
      if Providers.byId(id).kind == "manual" then
        local day = math.tointeger(tonumber(fields.renews_day) or 0)
        return reply(Providers.grokPlan({ plan = type(fields.plan) == "string" and fields.plan ~= "" and fields.plan or nil,
          renews_day = day and day >= 1 and day <= 31 and day or nil }))
      end
      if b.key ~= nil then
        local key = Keys.clean(b.key)
        if not Keys.valid(key) then
          return js("window.onProviderCheck", { id = id, ok = false, text = "That doesn't look like a key", labels = {} })
        end
        W.keys[id], W.removeKeys[id] = key, nil
      end
      local key = W.keys[id] -- without one, bin/ai-usage reads the saved key from the Keychain
      local ps = { budget = tonumber(fields.budget), team_id = type(fields.team_id) == "string" and fields.team_id or nil }
      W.poll.run(python(), opts.dir .. "/bin/ai-usage", Providers.args(id, ps, key ~= nil), key and key .. "\n", reply)
    elseif b.type == "keyStatus" then
      -- which AIs already have a key saved (the keys themselves stay in the Keychain)
      local status, left = {}, 0
      for _, e in ipairs(Providers.LIST) do if e.kind == "key" then left = left + 1 end end
      for _, e in ipairs(Providers.LIST) do
        if e.kind == "key" then
          Keys.has(e.id, function(has)
            status[e.id], left = has, left - 1
            if left == 0 then js("window.onKeys", status) end
          end)
        end
      end
    elseif b.type == "keyRemove" and type(b.id) == "string" and Providers.byId(b.id) and Providers.byId(b.id).kind == "key" then
      W.keys[b.id], W.removeKeys[b.id] = nil, true
    elseif b.type == "save" then
      local answers = b.config or {}
      local function finish()
        W.saveVoice(answers.voice)
        save(opts.dir, cfg, answers)
        close()
        W.reloadTimer = hs.timer.doAfter(0.4, hs.reload)
      end
      local function telegram()
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
      end
      -- the AI keys go in the Keychain before anything is written
      W.saveKeys(Keys, W.keys, W.removeKeys, function(failed, what)
        if not failed then return telegram() end
        local name = Providers.byId(failed).name
        js("window.onSaveFailed", { text = what == "remove"
          and "Couldn't remove the " .. name .. " key from your Keychain. Try Save again."
          or "Couldn't put the " .. name .. " key in your Keychain. Try Save again." })
      end)
    elseif b.type == "tgConnect" and W.telegram then
      pairTelegram(W.telegram, b.token)
    elseif b.type == "tgCancel" and W.telegram then
      W.telegram.cancelPair()
    elseif b.type == "tgOpen" and type(b.url) == "string" and b.url:match("^https://t%.me/[%w_]+") then
      hs.urlevent.openURL(b.url)
    elseif b.type == "voiceOpen" and type(b.url) == "string"
        and b.url:match("^https://github%.com/[%w_.-]+/[%w_.-]+/?$") then
      hs.urlevent.openURL(b.url)
    elseif b.type == "voiceSetup" and opts.voiceSetup and not init.voiceTrouble then
      for _, engine in ipairs(init.engines) do
        if engine.id == b.id and not engine.installed then
          opts.voiceSetup(b.id, function(message)
            js("window.onVoiceSetup", { id = b.id, message = tostring(message or "Setup finished.") })
          end)
          break
        end
      end
    elseif b.type == "voiceTest" and type(b.choice) == "table" then
      local choice = b.choice
      local valid = choice.engine == "system" and choice.name == nil
      for _, v in ipairs(init.voices) do
        if choice.engine == v.engine and choice.name == v.name then valid = true; break end
      end
      if not valid then
        js("window.onVoiceTest", { ok = false, text = "Choose an available voice." })
      elseif init.voiceTrouble then
        js("window.onVoiceTest", { ok = false, text = init.voiceTrouble })
      else
        W.voiceTestToken = (W.voiceTestToken or 0) + 1
        local token = W.voiceTestToken
        if W.testSound then W.testSound:stop(); W.testSound = nil end
        if W.testFile then os.remove(W.testFile); W.testFile = nil end
        Speech.render("Hi, I'm Buddy. This is my voice.", choice, function(path, why)
          if token ~= W.voiceTestToken then if path then os.remove(path) end; return end
          if not path then
            js("window.onVoiceTest", { ok = false, text = why or "Couldn't make the voice sample." })
            return
          end
          local sound = hs.sound.getByFile(path)
          if not sound then
            os.remove(path)
            js("window.onVoiceTest", { ok = false, text = "Couldn't play the voice sample." })
            return
          end
          W.testSound = sound
          W.testFile = path
          sound:setCallback(function(ok)
            os.remove(path)
            if W.testSound == sound then W.testSound = nil end
            if W.testFile == path then W.testFile = nil end
            if token == W.voiceTestToken then
              js("window.onVoiceTest", ok
                and { ok = true, text = "Sample finished." }
                or { ok = false, text = "Couldn't finish playing the voice sample." })
            end
          end)
          if not sound:play() then
            W.testSound = nil
            W.testFile = nil
            os.remove(path)
            js("window.onVoiceTest", { ok = false, text = "Couldn't play the voice sample." })
          else
            js("window.onVoiceTest", { ok = true, text = "Playing…" })
          end
        end)
      end
    elseif b.type == "close" then
      close()
    end
  end)

  local scr = hs.screen.mainScreen():frame()
  local w, h = 640, 720 + 32
  -- The page runs under the title bar (setup.html pads its top 32px): on macOS 26 and later
  -- a webview window's own title bar is see-through and shows the desktop behind it. The page
  -- is always dark (theme.css), so the window is too, which keeps the title readable in light mode.
  W.wv = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + math.max(40, (scr.h - h) / 3), w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable", "fullSizeContentView" })
    :darkMode(true)
    :windowTitle("Claude Buddy Setup")
    :allowTextEntry(true)
    :deleteOnClose(true)
    :windowCallback(function(action)
      if action == "closing" then
        W.keys, W.removeKeys = {}, {}
        W.voiceTestToken = (W.voiceTestToken or 0) + 1
        if W.testSound then W.testSound:stop(); W.testSound = nil end
        if W.testFile then os.remove(W.testFile); W.testFile = nil end
        W.wv = nil
        if W.telegram then W.telegram.cancelPair() end
      end
    end)
    :html(html)
    :show()
  W.wv:bringToFront(true)
  hs.focus()
  W.loadVoices(init.engines, function(choices)
    init.voices = choices
    js("window.setVoices", choices)
  end)
end

return W
