-- What the buddy learns about each app and site (Hammerspoon module)
--
-- Watches how long you stay in each app or site and, once it has seen enough, asks the
-- brain (brain.lua classify) which of the buddy's moods fits, and whether it differs by
-- time of day. The answer is kept in one small JSON file on this Mac; recent window
-- titles are held in memory only. It may also hand back a question for you (at most 3
-- a day, see canAsk). wipe() empties it for Forget. Loading this does nothing; buddy.lua
-- makes the store with L.new(path, moods).

local L = {}

local FIRST = 120       -- seconds seen before the first look at an app
local MORE = 3600       -- new seconds before looking again...
local REDO = 86400      -- ...and not sooner than this since the last look
local HOLD = 1800       -- seconds to leave an app alone after a look that couldn't start
local MAX_STEP = 30     -- a longer silence between observations is a break, not time spent
local TITLES, TITLE_MAX = 8, 80
local QUESTION_MAX = 200
local DAILY_ASKS = 3
local MAX_APPS = 300
local PARTS = { "morning", "afternoon", "evening", "night" }

-- One line each, for the brain to choose from.
local MEANINGS = {
  generic = "no particular activity, just say hi", coding = "writing or running code",
  reading = "reading documents, spreadsheets or serious text", browsing = "browsing the web",
  watching = "watching videos or shows", music = "listening to music", gaming = "playing a game",
  chat = "chatting with people", mail = "email", curious = "poking around files and folders",
  tinker = "fixing or configuring things", snow = "checking the weather or snow", proud = "something of their own",
  love = "something about Claude", jealous = "a rival AI", idle = "calm, nothing going on",
  health = "health, fitness or a break", food = "food, meals or cooking",
}

-- A mood list (key -> one-line meaning) for the keys that have a meaning.
function L.moodList(keys)
  local out = {}
  for _, k in ipairs(keys) do
    if MEANINGS[k] then out[k] = MEANINGS[k] end
  end
  return out
end

local Store = {}
Store.__index = Store

local function dayOf(t) return os.date("%Y-%m-%d", math.floor(t)) end

local function part(t)
  local h = tonumber(os.date("%H", math.floor(t)))
  if h >= 5 and h < 12 then return "morning" end
  if h >= 12 and h < 17 then return "afternoon" end
  if h >= 17 and h < 22 then return "evening" end
  return "night"
end

local function cut(s, n)
  local len = utf8.len(s)
  if len and len > n then return s:sub(1, utf8.offset(s, n + 1) - 1) end
  if not len and #s > n then return s:sub(1, n) end
  return s
end

local function mkdirs(path)
  local sofar = path:sub(1, 1) == "/" and "/" or ""
  for piece in path:gmatch("[^/]+") do
    sofar = sofar == "/" and ("/" .. piece) or (sofar == "" and piece or (sofar .. "/" .. piece))
    if not hs.fs.attributes(sofar) then hs.fs.mkdir(sofar) end
  end
end

function Store:_reset()
  self.apps, self.titles, self.asks = {}, {}, { day = "", n = 0 }
  self.lastKey, self.lastT, self.dirty = nil, nil, false
  self.holdUntil = {}
end

local function number(v, max) return type(v) == "number" and v >= 0 and v < max and v or nil end

-- A saved record kept only if it has the right shape and its moods are still on the list.
function Store:_valid(e)
  if type(e) ~= "table" then return nil end
  local out = { label = type(e.label) == "string" and e.label or nil, fresh = number(e.fresh, 1e9) or 0,
                seen = number(e.seen, 2 ^ 33) or 0, dayparts = {} }
  if type(e.mood) == "string" and self.moods[e.mood] then
    out.mood, out.decidedAt = e.mood, number(e.decidedAt, 2 ^ 33) or 0
    for _, p in ipairs(PARTS) do
      local m = type(e.dayparts) == "table" and e.dayparts[p]
      if type(m) == "string" and self.moods[m] then out.dayparts[p] = m end
    end
  end
  return out
end

function Store:_load()
  self:_reset()
  local f = io.open(self.path)
  if not f then return end
  local text = f:read("a")
  f:close()
  local ok, data = pcall(hs.json.decode, text)
  if not ok or type(data) ~= "table" or type(data.apps) ~= "table" then return end
  for key, e in pairs(data.apps) do
    local good = self:_valid(e)
    if type(key) == "string" and key ~= "" and good then self.apps[key] = good end
  end
  local a = data.asks
  if type(a) == "table" and type(a.day) == "string" and number(a.n, 1e6) then self.asks = { day = a.day, n = a.n } end
end

-- Call every second or so with what's in front.
function Store:observe(key, label, title, t)
  if not key or key == "" then return end
  local e = self.apps[key]
  if not e then e = { fresh = 0, seen = t, dayparts = {} }; self.apps[key] = e end
  e.label = label or e.label
  if self.lastKey == key and self.lastT then
    local dt = t - self.lastT
    if dt >= 0 and dt <= MAX_STEP then e.fresh = e.fresh + dt end
  end
  self.lastKey, self.lastT, e.seen, self.dirty = key, t, t, true
  if type(title) == "string" and title ~= "" then
    title = cut(title, TITLE_MAX)
    local list = self.titles[key] or {}
    for i = #list, 1, -1 do
      if list[i] == title then table.remove(list, i) end
    end
    table.insert(list, 1, title)
    list[TITLES + 1] = nil
    self.titles[key] = list
  end
end

-- Is it time to ask the brain about this app or site?
function Store:due(key, t)
  local e = self.apps[key]
  if not e or t < (self.holdUntil[key] or 0) then return false end
  if not e.mood then return e.fresh >= FIRST end
  return e.fresh >= MORE and t - (e.decidedAt or 0) >= REDO
end

-- Its daypart mood if it has one for this time of day, else the app's mood.
function Store:moodFor(key, t)
  local e = self.apps[key]
  if not e or not e.mood then return nil end
  return e.dayparts[part(t)] or e.mood
end

-- Keep what the brain said that is on the mood list; nil when the main mood isn't.
function Store:_clean(res)
  if type(res) ~= "table" or type(res.mood) ~= "string" or not self.moods[res.mood] then return nil end
  local out = { mood = res.mood, dayparts = {} }
  for _, p in ipairs(PARTS) do
    local m = type(res.dayparts) == "table" and res.dayparts[p]
    if type(m) == "string" and self.moods[m] then out.dayparts[p] = m end
  end
  if type(res.question) == "string" and res.question:match("%S") then
    out.question = cut(res.question:gsub("^%s+", ""):gsub("%s+$", ""), QUESTION_MAX)
  end
  return out
end

-- Ask the brain about one app. ctx: t (now), facts (a line from facts.lua), image (a
-- snapshot, base64). Nothing starts while watching is off (returns false); the answer is
-- dropped if watching turned off or Forget ran meanwhile. done(result|nil) gets
-- { mood, dayparts, question }; a failed or unusable answer waits for another 120 s.
function Store:decide(key, label, ctx, brain, privacy, done)
  local e = self.apps[key]
  if not e or not privacy.watching() then return false end
  local gen = self.gen
  local started = brain.classify({ label = label, titles = { table.unpack(self.titles[key] or {}) },
    facts = ctx.facts, moods = self.moods, image = ctx.image }, function(res)
    local cur = self.apps[key]
    if gen ~= self.gen or not cur or not privacy.watching() then return done(nil) end
    local clean = self:_clean(res)
    cur.fresh, self.dirty = 0, true
    if clean then
      cur.mood, cur.dayparts, cur.decidedAt = clean.mood, clean.dayparts, ctx.t
    end
    done(clean)
  end)
  return started ~= false
end

-- One learning look. o: t, facts, image (a snapshot, optional), brain, privacy, now() (a
-- clock), snapshot() (takes the image, only called once the brain can start; or pass image),
-- ponder(on) (show or clear the looking-at-the-screen pose; only used with an image, held
-- until the answer lands or is dropped), hushed() (muted or only-when-clicked), busy() (call,
-- meeting, full screen, game: asked again when the answer arrives), say(text).
-- A question is said only if canAsk, not hushed and not busy right then; the mood is kept
-- either way. A look that can't start (the daily cap, watching off) takes no snapshot and
-- leaves that app alone for half an hour. Returns whether the look started.
function Store:look(key, label, o)
  local can = o.brain.canClassify
  if can and not can() then
    self.holdUntil[key] = o.t + HOLD
    return false
  end
  local image = o.image or (o.snapshot and o.snapshot()) or nil
  if image then o.ponder(true) end
  local started = self:decide(key, label, { t = o.t, facts = o.facts, image = image }, o.brain, o.privacy, function(result)
    if image then o.ponder(false) end
    local at = o.now()
    if result and result.question and self:canAsk(at) and not o.hushed() and not o.busy() then
      o.say(result.question)
      self:asked(at)
    end
  end)
  if not started then
    if image then o.ponder(false) end
    self.holdUntil[key] = o.t + HOLD
  end
  return started
end

-- The first reaction that applies, in order: your picks, a Claude Code state in a terminal,
-- what it learned (only while watching is on), then the built-in one (a function, only
-- called when needed).
function L.reaction(o)
  return o.picked or o.claude or (o.watching and o.learned) or o.builtin()
end

function Store:canAsk(t)
  return self.asks.day ~= dayOf(t) or self.asks.n < DAILY_ASKS
end

function Store:asked(t)
  local day = dayOf(t)
  if self.asks.day ~= day then self.asks = { day = day, n = 0 } end
  self.asks.n = self.asks.n + 1
  self.dirty = true
end

function Store:save()
  local keys = {}
  for k in pairs(self.apps) do keys[#keys + 1] = k end
  if #keys > MAX_APPS then -- keep the most recently seen
    table.sort(keys, function(a, b) return self.apps[a].seen > self.apps[b].seen end)
    for i = MAX_APPS + 1, #keys do self.apps[keys[i]], self.titles[keys[i]] = nil, nil end
  end
  mkdirs(self.path:match("^(.*)/[^/]*$") or ".")
  local f = io.open(self.path, "w")
  if not f then return false end
  f:write(hs.json.encode({ apps = self.apps, asks = self.asks }))
  f:close()
  self.dirty = false
  return true
end

-- Forget: empty memory and delete the file; an answer still on its way is dropped.
function Store:wipe()
  self:_reset()
  self.gen = self.gen + 1
  os.remove(self.path)
end

-- moods: key -> one-line meaning (see L.moodList).
function L.new(path, moods)
  local self = setmetatable({ path = path, moods = moods or {}, gen = 0 }, Store)
  self:_load()
  return self
end

return L
