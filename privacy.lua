-- The buddy's privacy rules (Hammerspoon module)
--
-- One place that decides whether it may look at your screen at all (the `watch` switch
-- in config.lua and the pause set from its menu), which windows it never looks at
-- (password managers, banking words, your own `never_look` apps and `ai.private` words),
-- when it must not interrupt (calls, meetings, full screen, games), and how Forget wipes
-- what it has learned. Loading it does nothing; buddy.lua calls P.configure(CFG).

local P = {}

local PAUSE_KEY = "claudeBuddy.watchPausedUntil"
local WORDS = { "1password", "bitwarden", "lastpass", "keychain", "passwords", "password", "bank", "login", "sign in" }
local PRIVATE_APPS = {
  "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.lastpass",
  "com.apple.keychainaccess", "com.apple.passwords", "com.dashlane.dashlanephonefinal",
}
local MEETING_APPS = {
  "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.facetime",
  "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
}
local MEETING_TITLES = { "meet.google.com", "google meet", "zoom meeting" }
local BUSY_MOODS = { gaming = true, call = true }

local watch, pausedUntil = true, nil
local words, apps = {}, {}

local function nowSecs() return hs.timer.secondsSinceEpoch() end

local function set(list, extra)
  local out = {}
  for _, v in ipairs(list) do out[v] = true end
  for _, v in ipairs(extra or {}) do if type(v) == "string" then out[v:lower()] = true end end
  return out
end

local function contains(list, s)
  for _, w in ipairs(list) do
    if s:find(w, 1, true) then return true end
  end
  return false
end

local function store(until_)
  pausedUntil = until_
  hs.settings.set(PAUSE_KEY, until_)
end

-- cfg: the whole config.lua table. watch ~= false keeps today's peeks for old configs.
function P.configure(cfg)
  cfg = type(cfg) == "table" and cfg or {}
  watch = cfg.watch ~= false
  pausedUntil = tonumber(hs.settings.get(PAUSE_KEY))
  words = {}
  for _, w in ipairs(WORDS) do words[#words + 1] = w end
  for _, w in ipairs(type(cfg.ai) == "table" and cfg.ai.private or {}) do words[#words + 1] = tostring(w):lower() end
  apps = set(PRIVATE_APPS, cfg.never_look)
  return P
end
P.configure({})

function P.pausedUntil(now)
  if pausedUntil and pausedUntil > (now or nowSecs()) then return pausedUntil end
  return nil
end

-- May it look at the screen, learn and use what it sees?
function P.watching(now)
  return watch and not P.pausedUntil(now)
end

function P.pause(seconds, now)
  store((now or nowSecs()) + seconds)
end

-- Until the next local 06:00.
function P.pauseUntilMorning(now)
  now = math.floor(now or nowSecs())
  local d = os.date("*t", now)
  local morning = os.time({ year = d.year, month = d.month, day = d.day + (d.hour >= 6 and 1 or 0), hour = 6, min = 0, sec = 0 })
  store(morning)
  return morning
end

function P.resume() store(nil) end

-- Windows whose bundle id, app or title mean passwords, banking or something you said to skip.
function P.private(bid, app, title)
  if bid and apps[bid:lower()] then return true end
  return contains(words, ((app or "") .. " " .. (title or "")):lower())
end

-- Moments it must not interrupt: a call or meeting, a full-screen window, a game.
function P.busy(bid, title, fullScreen, mood)
  if fullScreen or BUSY_MOODS[mood] then return true end
  for _, id in ipairs(MEETING_APPS) do
    if (bid or ""):lower() == id then return true end
  end
  return contains(MEETING_TITLES, (title or ""):lower())
end

-- parts: { brain, chat, stores = { {wipe = fn}, ... } }
function P.forget(parts)
  parts = parts or {}
  if parts.brain then parts.brain.forget() end
  if parts.chat then parts.chat.forget() end
  for _, s in ipairs(parts.stores or {}) do s:wipe() end
  hs.settings.set("claudeBuddy.appSeconds", nil)
  hs.settings.set("claudeBuddy.askedToTeach", nil)
  hs.settings.set("claudeBuddy.metAt", os.time()) -- you've just met again: no more "old friends"
end

-- Will it actually look at your screen? It needs a brain, watching on, and something that
-- looks: Auto reactions, or health spotting food and fitness in window titles. The one-time
-- "I peek at your screen" notice is only for that case.
function P.willLook(o)
  return o.brain == true and o.watching == true and (o.auto == true or o.health == true)
end

return P
