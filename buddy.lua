-- Claude buddy: a little pixel Claude that lives on the desktop (Hammerspoon module)
--
-- Plain rules, no AI. It watches which app and window you're in and plays a matching
-- animation with a short line: a laptop for terminals (sparkles while Claude Code is
-- working, a wave when it's your turn), popcorn for YouTube, a side-eye for ChatGPT,
-- a shovel for snow forecasts. Its eyes follow the mouse; it gets bored after 3 min
-- away, falls asleep after 10, and sweats when the Claude session is nearly used up
-- (read from the usage card). Click it for a hello; drag it to move it.
--
-- Window titles come from the window list, which needs Hammerspoon to have Screen
-- Recording permission; without it the buddy still reacts to each app. No
-- Accessibility permission is needed. Try a mood: hs -c 'ClaudeBuddy.test("love")'
-- Personal tweaks (your name, extra rules and lines) go in config.lua next to this file.

local M = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local CFG = (function()
  local chunk = loadfile(DIR .. "/config.lua")
  local ok, cfg = pcall(chunk or function() end)
  return ok and type(cfg) == "table" and cfg or {}
end)()

local POS_KEY = "claudeBuddy.topLeft"
local NAME = CFG.name or ""      -- used in greetings
local ON_TOP = CFG.buddy_on_top  -- true floats it above windows instead of sitting on the desktop
local FPS = 12
local W, H = 200, 170    -- canvas
local S = 5              -- one pixel of the character, in screen points
local BODY_TOP = 98      -- body top inside the canvas, before animation offsets
local GROUND = BODY_TOP + 12 * S
local SAY_FOR = 3.5      -- seconds a speech bubble stays up
local QUIET_FOR = 4      -- minimum seconds between unprompted lines
local BORED_AFTER, SLEEP_AFTER = 180, 600 -- seconds without keyboard or mouse

local FONT = hs.styledtext.defaultFonts.system.name
local BOLD = hs.styledtext.defaultFonts.boldSystem.name

local C = {
  body   = { red = 0.85, green = 0.47, blue = 0.34, alpha = 1 }, -- Claude orange
  shade  = { red = 0.70, green = 0.36, blue = 0.26, alpha = 1 },
  shine  = { red = 0.94, green = 0.62, blue = 0.50, alpha = 1 },
  eye    = { red = 0.10, green = 0.08, blue = 0.08, alpha = 1 },
  pink   = { red = 0.97, green = 0.42, blue = 0.58, alpha = 1 },
  blush  = { red = 0.97, green = 0.42, blue = 0.58, alpha = 0.55 },
  white  = { red = 0.97, green = 0.97, blue = 0.97, alpha = 1 },
  grey   = { red = 0.58, green = 0.60, blue = 0.64, alpha = 1 },
  dark   = { red = 0.20, green = 0.21, blue = 0.24, alpha = 1 },
  red    = { red = 0.86, green = 0.22, blue = 0.22, alpha = 1 },
  yellow = { red = 0.99, green = 0.88, blue = 0.55, alpha = 1 },
  brown  = { red = 0.48, green = 0.31, blue = 0.19, alpha = 1 },
  blue   = { red = 0.45, green = 0.75, blue = 0.98, alpha = 1 },
  shadow = { red = 0, green = 0, blue = 0, alpha = 0.28 },
  bubble = { red = 1, green = 1, blue = 1, alpha = 0.95 },
  ink    = { red = 0.12, green = 0.12, blue = 0.13, alpha = 1 },
}
local TEXT_SHADOW = { offset = { h = -1, w = 0 }, blurRadius = 2, color = { red = 0, green = 0, blue = 0, alpha = 0.7 } }

-- What it does in each situation. eyes: track (follow mouse) | scan | down | ahead |
-- squint | happy | hearts | wide | sleepy | closed. "%s" in a line becomes the app name,
-- " {name}" becomes your name from config.lua (or nothing).
local MOODS = {
  idle       = { eyes = "track", body = "breathe", arms = "rest",
                 lines = { "Hi {name}!", "What are we up to?", "Ready when you are.", "Nice desktop." } },
  sleepy     = { eyes = "sleepy", body = "breathe", arms = "rest",
                 lines = { "It's getting late…", "*yawn*", "Bedtime soon?" } },
  morning    = { eyes = "track", body = "breathe", arms = "rest", prop = "mug", emit = "steam",
                 lines = { "Morning! Coffee?", "Rise and shine!", "Big day today?" } },
  coding     = { eyes = "down", body = "type", arms = "type", prop = "laptop",
                 lines = { "Let's build.", "*clack clack clack*", "Terminal time!", "Ship it!" } },
  claudeWork = { eyes = "down", body = "type", arms = "type", prop = "laptop", emit = "spark",
                 lines = { "Claude's cooking!", "Big brain time.", "Thinking, thinking…", "Go team!" } },
  claudeWait = { eyes = "track", body = "breathe", arms = "wave",
                 lines = { "Claude's done! Your turn.", "Waiting on you, boss.", "Ready for more!" } },
  love       = { eyes = "hearts", body = "bounce", arms = "up", blush = true, emit = "heart",
                 lines = { "Ooh, Claude!", "My favourite app!", "Hey, that's family!" } },
  jealous    = { eyes = "squint", body = "breathe", arms = "rest", mouth = "flat",
                 lines = { "Oh. Them.", "I can do that too…", "Hmph.", "Seeing other AIs?" } },
  watching   = { eyes = "ahead", body = "breathe", arms = "rest", prop = "popcorn",
                 lines = { "Movie time!", "Pass the popcorn.", "Ooh, what's on?" } },
  gaming     = { eyes = "down", body = "jitter", arms = "type", prop = "controller",
                 lines = { "Game on!", "Get 'em!", "Player two ready!" } },
  mail       = { eyes = "track", body = "breathe", arms = "rest", prop = "envelope",
                 lines = { "You've got mail!", "Anything good?", "Inbox time." } },
  chat       = { eyes = "happy", body = "breathe", arms = "wave",
                 lines = { "Who's texting?", "Say hi for me!", "Ooh, gossip?" } },
  reading    = { eyes = "ahead", body = "breathe", arms = "rest", glasses = true,
                 lines = { "Crunching numbers…", "Hmm, let me see.", "Very serious reading." } },
  curious    = { eyes = "scan", body = "breathe", arms = "rest", emit = "question",
                 lines = { "What's in here?", "Looking for something?", "Ooh, files!" } },
  tinker     = { eyes = "down", body = "breathe", arms = "hold", prop = "wrench",
                 lines = { "Fixing things!", "Careful in there…", "Tweak, tweak." } },
  browsing   = { eyes = "scan", body = "breathe", arms = "rest",
                 lines = { "Surfing the web!", "Find anything good?", "So many tabs…" } },
  snow       = { eyes = "track", body = "breathe", arms = "rest", prop = "shovel", emit = "snow",
                 lines = { "Snow day? Let's go!", "Shovels ready!", "Checking the forecast?" } },
  proud      = { eyes = "happy", body = "bounce", arms = "up", blush = true, emit = "spark", -- point your own site at it in config.lua
                 lines = { "Hey, that's us!", "Looking sharp!", "Ooh, fancy." } },
  music      = { eyes = "happy", body = "sway", arms = "up", emit = "note",
                 lines = { "Turn it up!", "Dance break!", "This one's a bop." } },
  home       = { eyes = "happy", body = "breathe", arms = "wave",
                 lines = { "That's where I live!", "Peeking at my code?" } },
  generic    = { eyes = "track", body = "breathe", arms = "rest",
                 lines = { "Ooh, %s!", "What's %s for?", "%s, huh?" } },
  bored      = { eyes = "sleepy", body = "breathe", arms = "rest", mouth = "yawn",
                 lines = { "*yawn*", "Still there?", "Hello-o?" } },
  sleep      = { eyes = "closed", body = "sleep", arms = "rest", emit = "z", lines = {} },
}

-- Short moves layered over the mood (clicks, waking up, idle fidgets).
local ACTIONS = {
  joy     = { eyes = "happy", body = "bounce", arms = "up", blush = true, emit = "heart" },
  startle = { eyes = "wide", mouth = "o", body = "hop", arms = "up" },
  hop     = { body = "hop" },
  wave    = { arms = "wave", eyes = "happy" },
  look    = { eyes = "scan" },
  stretch = { arms = "up", eyes = "closed", mouth = "yawn" },
}
local TRICKS = { { "hop", 0.7 }, { "wave", 1.6 }, { "look", 2.2 }, { "stretch", 1.4 } }
local CLICK_LINES = { "Hehe!", "Boop!", "Hi!", "That tickles!", "Need something?" }

local EMIT = {
  heart    = { rate = 2.5, glyphs = { "♥" }, color = "pink", size = 13, from = "head", vy = -30, spread = 36, life = 1.3 },
  spark    = { rate = 2, glyphs = { "✦", "✧", "✶" }, color = "body", size = 12, from = "head", vy = -24, spread = 60, life = 1.2 },
  note     = { rate = 1.5, glyphs = { "♪", "♫" }, color = "white", size = 15, from = "head", vy = -26, spread = 50, life = 1.5 },
  z        = { rate = 0.6, glyphs = { "z" }, color = "white", size = 11, from = "side", vy = -12, vx = 7, spread = 0, life = 2.6, grow = 8 },
  snow     = { rate = 3, glyphs = { "❄", "•", "*" }, color = "white", size = 10, from = "sky", vy = 22, spread = 0, life = 5 },
  steam    = { rate = 1.2, glyphs = { "~" }, color = "white", size = 13, from = "mug", vy = -14, spread = 4, life = 1.2 },
  question = { rate = 0.35, glyphs = { "?" }, color = "white", size = 18, from = "head", vy = -12, spread = 30, life = 2 },
}

-- Which mood an app or window gets. Browser titles are checked in order; first match wins.
local TERMINALS = { ["com.apple.Terminal"] = true, ["com.mitchellh.ghostty"] = true,
                    ["com.googlecode.iterm2"] = true, ["dev.warp.Warp-Stable"] = true }
local BROWSERS = { ["com.google.Chrome"] = true, ["com.apple.Safari"] = true, ["org.mozilla.firefox"] = true,
                   ["ru.yandex.desktop.yandex-browser"] = true, ["company.thebrowser.Browser"] = true }
local TITLE_RULES = {
  { "youtube", "watching" }, { "netflix", "watching" }, { "twitch", "watching" },
  { "gmail", "mail" }, { "inbox", "mail" }, { "outlook", "mail" },
  { "chatgpt", "jealous" }, { "grok", "jealous" }, { "gemini", "jealous" },
  { "claude", "love" },
  { "github", "coding" }, { "localhost", "coding" }, { "cloudflare", "coding" },
  { "google sheets", "reading" }, { "google docs", "reading" }, { "invoice", "reading" }, { ".pdf", "reading" },
  { "snow", "snow" }, { "weather", "snow" }, { "forecast", "snow" },
  { "spotify", "music" }, { "soundcloud", "music" },
}
local APPS = { -- bundle id or app name
  ["com.anthropic.claudefordesktop"] = "love",
  ["com.openai.codex"] = "jealous", ["com.openai.chat"] = "jealous", ["ChatGPT"] = "jealous",
  ["Grok"] = "jealous",
  ["Cursor"] = "coding", ["com.microsoft.VSCode"] = "coding", ["com.apple.dt.Xcode"] = "coding",
  ["Obsidian"] = "reading", ["LibreOffice"] = "reading", ["com.microsoft.Excel"] = "reading",
  ["com.apple.iWork.Numbers"] = "reading", ["com.apple.Preview"] = "reading",
  ["com.apple.MobileSMS"] = "chat", ["Telegram"] = "chat", ["com.apple.mail"] = "mail",
  ["com.apple.finder"] = "curious",
  ["com.apple.systempreferences"] = "tinker", ["Activity Monitor"] = "tinker", ["Stats"] = "tinker",
  ["Battle.net"] = "gaming", ["RemotePlay"] = "gaming", ["Steam"] = "gaming",
  ["Stremio"] = "watching", ["com.apple.TV"] = "watching", ["VLC"] = "watching", ["IINA"] = "watching",
  ["com.apple.Music"] = "music", ["Spotify"] = "music",
  ["org.hammerspoon.Hammerspoon"] = "home",
}
-- Claude Code puts ✳ in the window title while it waits and a spinner while it works.
local SPINNER = { "◐", "◓", "◑", "◒", "✢", "✶", "✻", "✽" }

-- config.lua additions: its title rules go first, its apps and lines replace built-ins.
for i, r in ipairs(CFG.title_rules or {}) do table.insert(TITLE_RULES, i, r) end
for k, v in pairs(CFG.apps or {}) do APPS[k] = v end
for k, v in pairs(CFG.lines or {}) do if MOODS[k] then MOODS[k].lines = v end end

local t0 = hs.timer.secondsSinceEpoch()
local mood, moodApp, lastPid = "idle", nil, nil
local action, actionStart, actionUntil = nil, 0, 0
local bubble, bubbleUntil, lastSaid = nil, 0, 0
local particles, emitClock, lastEmit = {}, 0, nil
local nextBlink, blinkUntil, nextTrick = 0, 0, 0
local away = "active" -- active | bored | asleep
local lookAt, lookUntil, winCenter = nil, 0, nil
local lastUsageWarn, pinnedUntil, lastFrame, lastSig = 0, 0, nil, nil
local sizeCache = {}

local function now() return hs.timer.secondsSinceEpoch() end
local function pick(list) return list[math.random(#list)] end
local function literal(s) return (s:gsub("%%", "%%%%")) end

local function fill(line, appName)
  line = line:gsub(" {name}", literal(NAME ~= "" and " " .. NAME or ""))
  return (line:gsub("%%s", literal(appName or "this")))
end

local function lineFor(m, appName)
  local spec = MOODS[m]
  if m == "idle" then
    local h = os.date("*t").hour
    if h >= 23 or h < 5 then spec = MOODS.sleepy elseif h < 10 then spec = MOODS.morning end
  end
  if not spec or #spec.lines == 0 then return nil end
  return fill(pick(spec.lines), appName)
end

local function say(text, force)
  local t = now()
  if not text or (not force and t - lastSaid < QUIET_FOR) then return end
  bubble, bubbleUntil, lastSaid = text, t + SAY_FOR, t
end

local function doAction(name, dur)
  local t = now()
  action, actionStart, actionUntil = name, t, t + dur
end

local function setMood(m, appName)
  local changed = m ~= mood or (m == "generic" and appName ~= moodApp)
  mood, moodApp = m, appName
  if changed then
    say(lineFor(m, appName))
    if m == "love" or m == "proud" or m == "claudeWait" then doAction("hop", 0.7) end
  end
end

local function frontWindow(app)
  local pid = app:pid()
  for _, w in ipairs(hs.window.list(false) or {}) do
    local b = w.kCGWindowBounds
    if w.kCGWindowOwnerPID == pid and w.kCGWindowLayer == 0 and b and b.Width > 80 and b.Height > 80 then
      return w.kCGWindowName or "", { x = b.X + b.Width / 2, y = b.Y + b.Height / 2 }
    end
  end
  return "", nil
end

local function classify(app, title)
  local bid, name = app:bundleID() or "", app:name() or ""
  local lname, ltitle = name:lower(), title:lower()
  if TERMINALS[bid] then
    if title:find("✳", 1, true) then return "claudeWait" end
    for _, g in ipairs(SPINNER) do
      if title:find(g, 1, true) then return "claudeWork" end
    end
    return "coding"
  end
  if BROWSERS[bid] then
    for _, r in ipairs(TITLE_RULES) do
      if ltitle:find(r[1], 1, true) then return r[2] end
    end
    return "browsing"
  end
  if bid == "com.apple.finder" and title == "" then return "idle" end -- clicked the desktop
  if APPS[bid] or APPS[name] then return APPS[bid] or APPS[name] end
  if lname:find("chiaki", 1, true) or lname:find("remote play", 1, true) then return "gaming" end
  return "generic"
end

local function sessionPct()
  local d = ClaudeUsage and ClaudeUsage.current and ClaudeUsage.current()
  for _, l in ipairs(d and d.limits or {}) do
    if l.label == "Current session" then return l.pct end
  end
  return 0
end

local function currentSpec(t)
  local base
  if away == "asleep" then base = MOODS.sleep
  elseif away == "bored" then base = MOODS.bored
  else
    base = MOODS[mood] or MOODS.idle
    if mood == "idle" then
      local h = os.date("*t").hour
      if h >= 23 or h < 5 then base = MOODS.sleepy elseif h < 10 then base = MOODS.morning end
    end
  end
  local spec = {}
  for k, v in pairs(base) do spec[k] = v end
  if action and t < actionUntil then
    for k, v in pairs(ACTIONS[action]) do spec[k] = v end
  else
    action = nil
  end
  spec.sweat = sessionPct() >= 80
  return spec
end

local function poll()
  local t = now()
  if t < pinnedUntil then return end

  local idle = hs.host.idleTime()
  if idle >= SLEEP_AFTER then
    away = "asleep"
  elseif idle >= BORED_AFTER then
    if away == "active" then say(lineFor("bored"), true) end
    if away ~= "asleep" then away = "bored" end
  elseif away ~= "active" then
    if away == "asleep" then
      doAction("startle", 1.2)
      say(pick({ "Oh! You're back!", "Wha—? I was awake!", "Welcome back!" }), true)
    end
    away = "active"
  end

  local app = hs.application.frontmostApplication()
  if app then
    local title, center = frontWindow(app)
    if center then winCenter = center end
    if app:pid() ~= lastPid then lookAt, lookUntil = center, t + 1.5 end
    lastPid = app:pid()
    setMood(classify(app, title), app:name())
  end

  local pct = sessionPct()
  if pct >= 95 and t - lastUsageWarn > 1800 then
    lastUsageWarn = t
    say("We're almost out of Claude!", true)
  end

  if away == "active" and not action and t > nextTrick then
    nextTrick = t + 12 + math.random() * 18
    local calm = { idle = 1, browsing = 1, generic = 1, reading = 1, mail = 1, watching = 1 }
    if calm[mood] then
      local trick = pick(TRICKS)
      doAction(trick[1], trick[2])
    end
  end
end

-- Drawing -----------------------------------------------------------------------

local function withAlpha(c, a)
  return { red = c.red, green = c.green, blue = c.blue, alpha = (c.alpha or 1) * a }
end

local function styled(s, size, color, font, align)
  return hs.styledtext.new(s, { font = { name = font or BOLD, size = size }, color = color,
    paragraphStyle = { alignment = align or "center" }, shadow = TEXT_SHADOW })
end

local function bodyOffset(kind, t)
  if kind == "breathe" then return 0, math.floor(math.sin(t * 2.2) * 1.5 + 0.5) end
  if kind == "bounce" then return 0, -math.floor(math.abs(math.sin(t * 7)) * 10) end
  if kind == "type" then return 0, math.floor(t * 10) % 2 end
  if kind == "sway" then return math.floor(math.sin(t * 4) * 5 + 0.5), -math.floor(math.abs(math.sin(t * 8)) * 3) end
  if kind == "jitter" then return (math.floor(t * 14) % 2 == 0) and -1 or 1, 0 end
  if kind == "sleep" then return 0, 2 + math.floor(math.sin(t * 1.2) * 1.5 + 0.5) end
  if kind == "hop" then
    local p = (now() - actionStart) / math.max(actionUntil - actionStart, 0.1)
    return 0, -math.floor(math.sin(math.min(p, 1) * math.pi) * 14)
  end
  return 0, 0
end

local function drawEyes(px, kind, dx, dy, blinking)
  local open = { track = true, scan = true, down = true, ahead = true }
  if blinking and (open[kind] or kind == "squint") then
    px(3 + dx, 4 + dy, 2, 1, C.eye); px(9 + dx, 4 + dy, 2, 1, C.eye)
  elseif open[kind] then
    for _, c in ipairs({ 3, 9 }) do
      px(c + dx, 3 + dy, 2, 3, C.eye)
      px(c + dx, 3 + dy, 1, 1, C.white)
    end
  elseif kind == "squint" then
    px(3 + dx, 4, 2, 1, C.eye); px(9 + dx, 4, 2, 1, C.eye)
  elseif kind == "closed" then
    px(3, 5, 2, 1, C.eye); px(9, 5, 2, 1, C.eye)
  elseif kind == "sleepy" then
    px(3 + dx, 4, 2, 2, C.eye); px(9 + dx, 4, 2, 2, C.eye)
  elseif kind == "wide" then
    for _, c in ipairs({ 3, 9 }) do px(c, 2, 2, 4, C.eye); px(c, 2, 1, 1, C.white) end
  elseif kind == "happy" then
    for _, o in ipairs({ 0, 6 }) do
      px(2 + o, 4, 1, 1, C.eye); px(3 + o, 3, 2, 1, C.eye); px(5 + o, 4, 1, 1, C.eye)
    end
  elseif kind == "hearts" then
    for _, o in ipairs({ 1, 8 }) do
      px(o + 1, 2, 1, 1, C.pink); px(o + 3, 2, 1, 1, C.pink)
      px(o, 3, 5, 1, C.pink); px(o + 1, 4, 3, 1, C.pink); px(o + 2, 5, 1, 1, C.pink)
    end
  end
end

local function drawArms(px, kind, f)
  if kind == "up" then
    local hand = 2 - f % 2
    px(-1, 4, 1, 1, C.body); px(-2, 3, 1, 1, C.body); px(-2, hand, 1, 1, C.body)
    px(14, 4, 1, 1, C.body); px(15, 3, 1, 1, C.body); px(15, hand, 1, 1, C.body)
  elseif kind == "wave" then
    px(-1, 5, 1, 2, C.body)
    px(14, 4, 1, 1, C.body); px(15, 3, 1, 1, C.body); px(15 + f % 2, 2, 1, 1, C.body)
  elseif kind == "type" then
    px(-1, 5 + f % 2, 1, 2, C.body); px(14, 6 - f % 2, 1, 2, C.body)
  elseif kind == "hold" then
    px(-1, 5, 1, 2, C.body); px(14, 6, 1, 1, C.body); px(15, 7, 1, 1, C.body)
  else
    px(-1, 5, 1, 2, C.body); px(14, 5, 1, 2, C.body)
  end
end

local PROPS = {
  laptop = function(px)
    px(2, 6, 10, 4, C.grey); px(1, 10, 12, 1, C.dark); px(6, 7, 2, 2, C.white)
  end,
  popcorn = function(px)
    px(15, 6, 3, 4, C.white); px(15, 6, 1, 4, C.red); px(17, 6, 1, 4, C.red)
    px(15, 4, 3, 2, C.yellow); px(16, 3, 1, 1, C.yellow)
  end,
  controller = function(px, f)
    px(3, 7, 8, 3, C.dark); px(2, 8, 1, 3, C.dark); px(11, 8, 1, 3, C.dark)
    px(4, 8, 1, 1, C.grey); px(9, 8 - f % 2, 1, 1, C.red); px(8, 7 + f % 2, 1, 1, C.blue)
  end,
  mug = function(px)
    px(15, 6, 3, 4, C.white); px(18, 7, 1, 2, C.white); px(15, 6, 3, 1, C.brown)
  end,
  envelope = function(px)
    px(15, 3, 5, 4, C.white)
    for i, r in ipairs({ 3, 4, 5, 4, 3 }) do px(14 + i, r, 1, 1, C.grey) end
  end,
  wrench = function(px, f)
    local y = f % 2
    px(17, 3 + y, 1, 2, C.grey); px(19, 3 + y, 1, 2, C.grey); px(18, 4 + y, 1, 1, C.grey)
    px(18, 5 + y, 1, 1, C.grey); px(17, 6 + y, 1, 1, C.grey); px(16, 7 + y, 1, 1, C.grey)
  end,
  shovel = function(px)
    px(15, -1, 3, 1, C.brown); px(16, 0, 1, 9, C.brown); px(15, 9, 3, 3, C.grey)
  end,
}

local function spawn(e, ox, oy, cx)
  local x, y
  if e.from == "head" then x, y = cx + (math.random() - 0.5) * e.spread, oy - 4
  elseif e.from == "side" then x, y = ox + 14 * S + 6, oy + 6
  elseif e.from == "sky" then x, y = math.random(8, W - 8), 4
  else x, y = ox + 16.5 * S + (math.random() - 0.5) * e.spread, oy + 4 * S end
  if #particles < 16 then
    particles[#particles + 1] = { ch = pick(e.glyphs), color = C[e.color], size = e.size, grow = e.grow or 0,
      x = x, y = y, vx = (e.vx or 0) + (math.random() - 0.5) * 8, vy = e.vy, age = 0, life = e.life }
  end
end

local function frame()
  if not M.canvas then return end
  local t = now()
  local dt = math.min(t - (lastFrame or t), 0.25)
  lastFrame = t
  local spec = currentSpec(t)
  local at = t - t0
  local f = math.floor(at * 6)

  local bx, by = bodyOffset(spec.body, at)
  local ox, oy = math.floor((W - 14 * S) / 2) + bx, BODY_TOP + by
  local cx = ox + 7 * S

  local els, sig = {}, {}
  local function px(c, r, w, h, color, track)
    local fr = { x = ox + c * S, y = oy + r * S, w = w * S, h = h * S }
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = color, frame = fr, trackMouseDown = track }
    sig[#sig + 1] = fr.x .. "," .. fr.y .. "," .. fr.w .. "," .. fr.h .. tostring(color)
  end

  -- shadow on the ground shrinks as it jumps
  local lift = math.max(0, -by)
  els[#els + 1] = { type = "oval", action = "fill", fillColor = C.shadow,
    frame = { x = cx - (36 - lift), y = GROUND - 3, w = 2 * (36 - lift), h = 7 } }
  sig[#sig + 1] = "s" .. lift

  -- legs (alternate when dancing), body, face
  for i, c in ipairs({ 2, 4, 9, 11 }) do
    local up = spec.body == "sway" and ((i + f) % 2 == 0) and 1 or 0
    px(c, 10, 1, 2 - up, C.shade)
  end
  px(1, 0, 12, 10, C.body, true); px(0, 1, 1, 8, C.body, true); px(13, 1, 1, 8, C.body, true)
  px(1, 9, 12, 1, C.shade); px(2, 1, 2, 1, C.shine)
  if spec.blush then px(1, 6, 2, 1, C.blush); px(11, 6, 2, 1, C.blush) end

  if t > nextBlink then blinkUntil, nextBlink = t + 0.14, t + 2.5 + math.random() * 4 end
  local dx, dy = 0, 0
  if spec.eyes == "track" or spec.eyes == "down" then
    local tl = M.canvas:topLeft()
    local target = (t < lookUntil and lookAt) or hs.mouse.absolutePosition()
    local ex, ey = target.x - (tl.x + cx), target.y - (tl.y + oy + 4 * S)
    dx = math.abs(ex) > 60 and (ex > 0 and 1 or -1) or 0
    dy = spec.eyes == "down" and 1 or (math.abs(ey) > 80 and (ey > 0 and 1 or -1) or 0)
  elseif spec.eyes == "scan" then
    dx = math.max(-1, math.min(1, math.floor(math.sin(at * 1.6) * 1.5 + 0.5)))
  elseif spec.eyes == "squint" and winCenter then
    dx = winCenter.x > M.canvas:topLeft().x + cx and 1 or -1
  end
  drawEyes(px, spec.eyes, dx, dy, t < blinkUntil)

  if spec.mouth == "o" then px(6, 7, 2, 2, C.eye)
  elseif spec.mouth == "flat" then px(6, 8, 2, 1, C.eye)
  elseif spec.mouth == "yawn" and at % 6 < 2 then px(6, 7, 2, 2 + f % 2, C.eye)
  elseif spec.eyes == "happy" or spec.eyes == "hearts" then
    px(5, 7, 1, 1, C.eye); px(6, 8, 2, 1, C.eye); px(8, 7, 1, 1, C.eye)
  end
  if spec.glasses then
    for _, c in ipairs({ 2, 8 }) do
      px(c, 2, 4, 1, C.dark); px(c, 6, 4, 1, C.dark); px(c, 2, 1, 5, C.dark); px(c + 3, 2, 1, 5, C.dark)
    end
    px(6, 3, 2, 1, C.dark)
  end
  if spec.sweat then
    local drip = math.floor(at * 1.5) % 3
    px(15, drip, 1, 1, C.blue); px(14, 1 + drip, 2, 1, C.blue)
  end

  drawArms(px, spec.arms, f)
  if spec.prop and PROPS[spec.prop] then PROPS[spec.prop](px, f) end

  -- floating particles
  local e = EMIT[spec.emit]
  if spec.emit ~= lastEmit then emitClock, lastEmit = 0, spec.emit end
  if e and away ~= "bored" then
    emitClock = emitClock + dt * e.rate
    while emitClock >= 1 do emitClock = emitClock - 1; spawn(e, ox, oy, cx) end
  end
  local alive = {}
  for _, p in ipairs(particles) do
    p.age = p.age + dt
    if p.age < p.life then
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      local a = 1 - p.age / p.life
      local size = p.size + p.grow * (p.age / p.life)
      els[#els + 1] = { type = "text", text = styled(p.ch, size, withAlpha(p.color, a)),
        frame = { x = math.floor(p.x - 12), y = math.floor(p.y - 12), w = 24, h = 26 } }
      sig[#sig + 1] = p.ch .. math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. math.floor(a * 10)
      alive[#alive + 1] = p
    end
  end
  particles = alive

  -- speech bubble
  if bubble and t > bubbleUntil then bubble = nil end
  if bubble then
    local st = styled(bubble, 11.5, C.ink, FONT)
    local size = sizeCache[bubble] or hs.drawing.getTextDrawingSize(st)
    sizeCache[bubble] = size
    local bw, bh = math.min(W - 6, math.ceil(size.w) + 18), math.ceil(size.h) + 10
    local bxp = math.max(3, math.min(W - bw - 3, cx - bw / 2))
    local byp = BODY_TOP - bh - 22
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.bubble,
      roundedRectRadii = { xRadius = 9, yRadius = 9 }, frame = { x = bxp, y = byp, w = bw, h = bh } }
    els[#els + 1] = { type = "segments", action = "fill", fillColor = C.bubble, closed = true, coordinates = {
      { x = cx - 6, y = byp + bh - 1 }, { x = cx + 6, y = byp + bh - 1 }, { x = cx - 1, y = byp + bh + 8 } } }
    els[#els + 1] = { type = "text", text = st, frame = { x = bxp + 4, y = byp + 5, w = bw - 8, h = bh - 6 } }
    sig[#sig + 1] = "b" .. bubble
  end

  local key = table.concat(sig, "|")
  if key ~= lastSig then
    lastSig = key
    M.canvas:replaceElements(els)
  end
end

-- Placement and mouse ------------------------------------------------------------

local function onAScreen(p)
  for _, s in ipairs(hs.screen.allScreens()) do
    local fr = s:frame()
    if p.x >= fr.x - 40 and p.x < fr.x + fr.w - 60 and p.y >= fr.y - 40 and p.y < fr.y + fr.h - 60 then return true end
  end
  return false
end

-- Saved spot if its screen is connected; otherwise beside the usage card.
local function place()
  local p = hs.settings.get(POS_KEY)
  if not (p and onAScreen(p)) then
    local card = ClaudeUsage and ClaudeUsage.canvas and ClaudeUsage.canvas:topLeft()
    if card then
      p = { x = card.x + 264, y = card.y + 96 }
    else
      local fr = hs.screen.primaryScreen():frame()
      p = { x = fr.x + 24, y = fr.y + 24 }
    end
  end
  M.canvas:topLeft(p)
end

-- Same polling drag as the usage card (no Accessibility permission needed).
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
      elseif away == "active" then
        doAction("joy", 1.6)
        say(pick(CLICK_LINES), true)
      end
      return
    end
    if math.abs(m.x - m0.x) + math.abs(m.y - m0.y) > 3 then moved = true end
    if moved then M.canvas:topLeft({ x = p0.x + m.x - m0.x, y = p0.y + m.y - m0.y }) end
  end)
end

function M.start()
  math.randomseed(os.time())
  M.canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = H })
  M.canvas:level(ON_TOP and hs.canvas.windowLevels.floating or hs.canvas.windowLevels.desktopIcon)
  M.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  M.canvas:clickActivating(false)
  M.canvas:mouseCallback(function(_, msg) if msg == "mouseDown" then startDrag() end end)
  place()
  M.canvas:show()

  poll()
  say(fill("Hi {name}! I'm your Claude buddy."), true)
  M.frameTimer = hs.timer.doEvery(1 / FPS, frame)
  M.pollTimer = hs.timer.doEvery(1, poll)
  M.appWatcher = hs.application.watcher.new(function(_, ev)
    if ev == hs.application.watcher.activated then poll() end
  end):start()
  M.screenWatcher = hs.screen.watcher.new(function()
    M.placeTimer = hs.timer.doAfter(2, place)
  end):start()
  M.sleepWatcher = hs.caffeinate.watcher.new(function(ev) -- no animating to a dark screen
    if ev == hs.caffeinate.watcher.screensDidSleep then M.frameTimer:stop()
    elseif ev == hs.caffeinate.watcher.screensDidWake then M.frameTimer:start() end
  end):start()
  return M
end

-- Preview a mood (and optional action) for a few seconds, e.g. ClaudeBuddy.test("love").
function M.test(m, secs, act)
  pinnedUntil = now() + (secs or 8)
  away = "active"
  setMood(m, "Test")
  say(lineFor(m, "Test"), true)
  if act then doAction(act, secs or 8) end
end

M.say = say
return M
