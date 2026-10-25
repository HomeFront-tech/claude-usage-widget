-- The buddy's health sidekick (Hammerspoon module)
--
-- Decides when to nudge you to move (after a stretch of sitting), when to ask about a
-- meal (inside your breakfast, lunch and dinner windows, if none is logged yet), and when
-- a window title mentions food or fitness. It keeps your goals, workout plans and a week
-- of meals, workouts and breaks in one small JSON file on this Mac. In chat Claude adds
-- to it through the buddy-tools health_log tool, which appends to health-new.jsonl in the
-- same folder; absorb() folds those lines in. wipe() empties it all for Forget.
-- Loading this does nothing; buddy.lua makes the store with H.new(folder, config).

local H = {}

local DEFAULTS = {
  sit_minutes = 60, break_minutes = 5, daily_cap = 8,
  meals = { breakfast = { 8, 10 }, lunch = { 12, 14 }, dinner = { 17, 19 } },
}
local SIT_REPEAT = 30 * 60   -- seconds before it nudges about sitting again
local SPOT_GAP = 2 * 3600    -- seconds before it remarks on food or fitness again
local MEAL_IDLE = 60         -- a meal question only while you are at the keyboard
local KEEP_DAYS = 7
local GOAL_ASKS = 3          -- times it asks for a goal, one a day, until you give one
local LOG_KINDS = { meal = true, workout = true, ["break"] = true, note = true }
local KINDS = { meal = true, workout = true, ["break"] = true, note = true, goal = true, plan = true }
local MAX_TEXT, MAX_GOALS, MAX_PLANS, MAX_LOG = 300, 10, 5, 200
local FOOD = { "skipthedishes", "skip the dishes", "uber eats", "ubereats", "doordash", "grubhub", "instacart" }
local FITNESS = { "workout", "fitness", "yoga", "hiit", "push-up", "pushup", "exercise", "strength training",
                  "stretching", "running" }

local Store = {}
Store.__index = Store

-- May a health line be said right now? o: muted, quietFor (seconds between lines; below 0
-- means "only when clicked"), busy (a call, meeting, game or full screen), watching, and
-- kind ("sit", "meal", "food", "fitness"). Spotting food or fitness also needs watching.
function H.mayDeliver(o)
  if o.muted or (o.quietFor or 0) < 0 or o.busy then return false end
  if (o.kind == "food" or o.kind == "fitness") and not o.watching then return false end
  return true
end

-- What health may do for each brain. engine: nil (plain rules), "ollama" or "claude".
-- Sitting nudges need nothing. Questions (meal check-ins, remarks on food or fitness) need a
-- brain to answer them in chat. Goals, plans and goal progress need Claude, which has the
-- health tools that write them down. Anything else is refused.
local NEEDS = { sit = "none", meal = "brain", food = "brain", fitness = "brain",
                goal = "claude", plan = "claude", progress = "claude" }
function H.allowed(engine, kind)
  local need = NEEDS[kind]
  if need == "none" then return true end
  if need == "brain" then return engine == "ollama" or engine == "claude" end
  if need == "claude" then return engine == "claude" end
  return false
end

-- A say() for a line that arrives later (a brain reply): gate() is asked again on arrival,
-- because a call, full screen, mute or a pause may have started since it was requested.
function H.late(kind, gate, say)
  return function(text)
    local o = gate()
    o.kind = kind
    if H.mayDeliver(o) then say(text) end
  end
end

local function dayOf(t) return os.date("%Y-%m-%d", math.floor(t)) end

local function minuteOf(t)
  local d = os.date("*t", math.floor(t))
  return d.hour * 60 + d.min
end

local function cut(s, n)
  local len = utf8.len(s)
  if len and len > n then return s:sub(1, utf8.offset(s, n + 1) - 1) end
  if not len and #s > n then return s:sub(1, n) end
  return s
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function mkdirs(path)
  local sofar = path:sub(1, 1) == "/" and "/" or ""
  for piece in path:gmatch("[^/]+") do
    sofar = sofar == "/" and ("/" .. piece) or (sofar == "" and piece or (sofar .. "/" .. piece))
    if not hs.fs.attributes(sofar) then hs.fs.mkdir(sofar) end
  end
end

local function matches(words, hay)
  for _, w in ipairs(words) do
    if hay:find(w, 1, true) then return true end
  end
  return false
end

function Store:_reset()
  self.goals, self.plans, self.log_ = {}, {}, {}
  self.eaten, self.asked, self.events = {}, {}, {}
  self.goalAsk = { day = "", n = 0 }
  self.progressDay = nil
  self.streak, self.lastSit, self.spotAt, self.newest = nil, nil, {}, nil
  self.dirty = false
end

local function timestamp(v) return type(v) == "number" and v > 0 and v < 2 ^ 33 and v or nil end

local function validNote(e)
  if type(e) ~= "table" or type(e.text) ~= "string" or e.text == "" then return nil end
  local at = timestamp(e.at)
  return at and { text = cut(e.text, MAX_TEXT), at = at } or nil
end

local function dayMap(v, leaf)
  local out = {}
  for day, inner in pairs(type(v) == "table" and v or {}) do
    if type(day) == "string" and day:match("^%d%d%d%d%-%d%d%-%d%d$") then
      local clean = leaf(inner)
      if clean then out[day] = clean end
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
  if not ok or type(data) ~= "table" then return end
  for _, e in ipairs(type(data.goals) == "table" and data.goals or {}) do
    local good = validNote(e)
    if good and #self.goals < MAX_GOALS then self.goals[#self.goals + 1] = good end
  end
  for _, e in ipairs(type(data.plans) == "table" and data.plans or {}) do
    local good = validNote(e)
    if good and #self.plans < MAX_PLANS then self.plans[#self.plans + 1] = good end
  end
  for _, e in ipairs(type(data.log) == "table" and data.log or {}) do
    local good = validNote(e)
    if good and type(e.kind) == "string" and LOG_KINDS[e.kind] and #self.log_ < MAX_LOG then
      good.kind = e.kind
      self.log_[#self.log_ + 1] = good
    end
  end
  local function flags(inner)
    local out, any = {}, false
    if type(inner) ~= "table" then return nil end
    for name, v in pairs(inner) do
      if type(name) == "string" and v == true then out[name], any = true, true end
    end
    return any and out or nil
  end
  self.eaten, self.asked = dayMap(data.eaten, flags), dayMap(data.asked, flags)
  self.events = dayMap(data.events, function(n)
    return type(n) == "number" and n >= 0 and n < 1e6 and n or nil
  end)
  if type(data.progressDay) == "string" and data.progressDay:match("^%d%d%d%d%-%d%d%-%d%d$") then
    self.progressDay = data.progressDay
  end
  if type(data.goalAsk) == "table" and type(data.goalAsk.day) == "string"
      and type(data.goalAsk.n) == "number" and data.goalAsk.n >= 0 then
    self.goalAsk = { day = data.goalAsk.day, n = math.floor(data.goalAsk.n) }
  end
end

local function number(v, default, min)
  v = tonumber(v)
  return v and v >= min and v or default
end

-- dir: the folder holding health.json (and the tools' health-new.jsonl); cfg: the `health`
-- table from config.lua (anything missing or odd falls back to the defaults).
function H.new(dir, cfg)
  cfg = type(cfg) == "table" and cfg or {}
  local self = setmetatable({ dir = dir, path = dir .. "/health.json", newPath = dir .. "/health-new.jsonl" }, Store)
  self.sitSecs = number(cfg.sit_minutes, DEFAULTS.sit_minutes, 1) * 60
  self.breakSecs = number(cfg.break_minutes, DEFAULTS.break_minutes, 1) * 60
  self.cap = math.floor(number(cfg.daily_cap, DEFAULTS.daily_cap, 1))
  local windows = {}
  for name, w in pairs(DEFAULTS.meals) do windows[name] = w end
  for name, w in pairs(type(cfg.meals) == "table" and cfg.meals or {}) do
    local a, b = type(w) == "table" and tonumber(w[1]), type(w) == "table" and tonumber(w[2])
    if type(name) == "string" and a and b and a >= 0 and b <= 24 and a < b then windows[name] = { a, b } end
  end
  self.meals = {} -- the windows by start time, so the earlier meal is asked about first
  for name, w in pairs(windows) do self.meals[#self.meals + 1] = { name = name, from = w[1] * 60, to = w[2] * 60 } end
  table.sort(self.meals, function(x, y) return x.from == y.from and x.name < y.name or x.from < y.from end)
  self:_load()
  return self
end

-- allow(kind) -> boolean (see H.allowed) says what this brain lets health do; unset allows all.
function Store:setAllow(allow) self.allow = allow end

function Store:_may(kind) return not self.allow or self.allow(kind) and true or false end

local function seen(self, t)
  if not self.newest or t > self.newest then self.newest = t end
end

local function used(self, day) return self.events[day] or 0 end

local function count(self, day)
  self.events[day] = used(self, day) + 1
  self.dirty = true
end

local function isBusy(busy)
  if type(busy) == "function" then return busy() and true or false end
  return busy and true or false
end

function Store:_markEaten(meal, t)
  local day = dayOf(t)
  self.eaten[day] = self.eaten[day] or {}
  self.eaten[day][meal] = true
  self.dirty = true
end

-- The meal whose window is open now and that was neither eaten nor asked about today.
function Store:_dueMeal(t, day)
  local m = minuteOf(t)
  for _, meal in ipairs(self.meals) do
    if m >= meal.from and m <= meal.to
        and not (self.eaten[day] and self.eaten[day][meal.name])
        and not (self.asked[day] and self.asked[day][meal.name]) then
      return meal.name
    end
  end
  return nil
end

-- Call every second or so while the Mac is awake. t: now; idle: seconds since the last
-- key or click; busy: a call, meeting, full screen, quiet time (a boolean, or a function
-- asked only when something is about to be said). Returns { kind = "sit", minutes = n } or
-- { kind = "meal", meal = "lunch" }, or nil. Being busy never uses an event up.
function Store:tick(t, idle, busy)
  seen(self, t)
  if idle >= self.breakSecs then -- a break; a sleep is one too
    self.streak, self.lastSit = nil, nil
    return nil
  end
  if not self.streak then self.streak = t end
  local day = dayOf(t)
  if used(self, day) >= self.cap then return nil end
  local meal = idle < MEAL_IDLE and self:_may("meal") and self:_dueMeal(t, day) or nil
  local sit = t - self.streak >= self.sitSecs and (not self.lastSit or t - self.lastSit >= SIT_REPEAT)
  if not meal and not sit then return nil end
  if isBusy(busy) then return nil end
  count(self, day)
  if meal then
    self.asked[day] = self.asked[day] or {}
    self.asked[day][meal] = true
    return { kind = "meal", meal = meal }
  end
  self.lastSit = t
  return { kind = "sit", minutes = math.floor((t - self.streak) / 60) }
end

-- The streak starts over (the caller noticed polling stopped, e.g. the Mac slept).
function Store:rest()
  self.streak, self.lastSit = nil, nil
end

-- Does the front window mention food or fitness? { kind = "food" | "fitness", what = title },
-- once per kind per 2 hours. The caller checks that watching is on and the window isn't private.
function Store:spot(app, title, t, busy)
  seen(self, t)
  local hay = ((app or "") .. " " .. (title or "")):lower()
  local day = dayOf(t)
  for _, set in ipairs({ { "food", FOOD }, { "fitness", FITNESS } }) do
    local kind = set[1]
    local last = self.spotAt[kind]
    if self:_may(kind) and matches(set[2], hay) and (not last or t - last >= SPOT_GAP) then
      if used(self, day) >= self.cap or isBusy(busy) then return nil end
      self.spotAt[kind] = t
      count(self, day)
      return { kind = kind, what = (title and title ~= "") and title or (app or "") }
    end
  end
  return nil
end

-- kind: meal | workout | break | goal | plan | note. Returns false for anything else.
function Store:log(kind, text, t)
  if not KINDS[kind] or type(text) ~= "string" then return false end
  text = cut(trim(text), MAX_TEXT)
  if text == "" then return false end
  t = tonumber(t) or os.time()
  seen(self, t)
  local entry = { text = text, at = t }
  if kind == "goal" then
    for i, g in ipairs(self.goals) do
      if g.text:lower() == text:lower() then table.remove(self.goals, i); break end
    end
    self.goals[#self.goals + 1] = entry
    while #self.goals > MAX_GOALS do table.remove(self.goals, 1) end
  elseif kind == "plan" then
    self.plans[#self.plans + 1] = entry
    while #self.plans > MAX_PLANS do table.remove(self.plans, 1) end
  else
    entry.kind = kind
    self.log_[#self.log_ + 1] = entry
    while #self.log_ > MAX_LOG do table.remove(self.log_, 1) end
    if kind == "meal" then -- a meal named in the text, or else the one whose window it fell in
      local lower, m, named = text:lower(), minuteOf(t), false
      for _, meal in ipairs(self.meals) do
        if lower:find(meal.name, 1, true) then self:_markEaten(meal.name, t); named = true end
      end
      if not named then
        for _, meal in ipairs(self.meals) do
          if m >= meal.from and m <= meal.to then self:_markEaten(meal.name, t) end
        end
      end
    end
  end
  self.dirty = true
  return true
end

-- You said you ate: no more questions about that meal today.
function Store:ate(meal, t)
  t = tonumber(t) or os.time()
  self:log("meal", meal, t)
  self:_markEaten(meal, t)
end

-- Fold in what the tools wrote to health-new.jsonl, then empty it. Returns how many lines it took.
function Store:absorb()
  if not hs.fs.attributes(self.newPath) then return 0 end
  local taken = self.newPath .. ".reading"
  if not os.rename(self.newPath, taken) then return 0 end -- the tool then starts a fresh file
  local f = io.open(taken)
  local took = 0
  if f then
    for line in f:lines() do
      local ok, e = pcall(hs.json.decode, line)
      if ok and type(e) == "table" and type(e.kind) == "string"
          and self:log(e.kind, e.text, timestamp(e.at)) then
        took = took + 1
      end
    end
    f:close()
  end
  os.remove(taken)
  if took > 0 then self:save() end
  return took
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- Goals, the latest plan's first line, and today's meals and breaks, for the chat prompt.
function Store:summary(t)
  local out = {}
  if #self.goals > 0 then
    local goals = {}
    for _, g in ipairs(self.goals) do goals[#goals + 1] = g.text end
    out[#out + 1] = "Goals: " .. table.concat(goals, "; ") .. "."
  end
  local plan = self.plans[#self.plans]
  if plan then out[#out + 1] = "Plan: " .. (plan.text:match("^[^\n]+") or plan.text) .. "." end
  local today = dayOf(t)
  local meals, breaks, workouts = {}, 0, 0
  for _, e in ipairs(self.log_) do
    if dayOf(e.at) == today then
      if e.kind == "meal" then meals[#meals + 1] = cut(e.text, 60)
      elseif e.kind == "break" then breaks = breaks + 1
      elseif e.kind == "workout" then workouts = workouts + 1 end
    end
  end
  local line = "Today: " .. (#meals > 0 and ("meals: " .. table.concat(meals, "; ")) or "no meals logged yet")
    .. ", " .. plural(breaks, "break")
  if workouts > 0 then line = line .. ", " .. plural(workouts, "workout") end
  out[#out + 1] = line .. "."
  return cut(table.concat(out, " "), 1200)
end

-- Time to ask for a goal? Only with Claude (it writes the answer down), none stored, once a
-- day, three times in all.
function Store:askGoal(t)
  if not self:_may("goal") or #self.goals > 0 then return false end
  local day = dayOf(t)
  if self.goalAsk.day == day or self.goalAsk.n >= GOAL_ASKS then return false end
  self.goalAsk = { day = day, n = self.goalAsk.n + 1 }
  self.dirty = true
  return true
end

-- Time to bring up how they're doing on their goals? At most once a day, with goals, Claude
-- and a free moment. Returns what to ask the brain to say, or nil. Being busy uses nothing up.
function Store:progress(t, busy)
  local day = dayOf(t)
  if not self:_may("progress") or #self.goals == 0 or self.progressDay == day then return nil end
  if used(self, day) >= self.cap or isBusy(busy) then return nil end
  self.progressDay = day
  count(self, day)
  return "These are their health goals and how today looks. " .. self:summary(t)
    .. " Say how they're doing against the goals."
end

function Store:save()
  local ref = self.newest or os.time()
  local cutoff = dayOf(ref - (KEEP_DAYS - 1) * 86400)
  for i = #self.log_, 1, -1 do
    if self.log_[i].at < ref - KEEP_DAYS * 86400 then table.remove(self.log_, i) end
  end
  for _, map in ipairs({ self.eaten, self.asked, self.events }) do
    for day in pairs(map) do
      if day < cutoff then map[day] = nil end
    end
  end
  mkdirs(self.dir)
  local f = io.open(self.path, "w")
  if not f then return false end
  f:write(hs.json.encode({ goals = self.goals, plans = self.plans, log = self.log_, eaten = self.eaten,
    asked = self.asked, events = self.events, goalAsk = self.goalAsk, progressDay = self.progressDay }))
  f:close()
  self.dirty = false
  return true
end

-- Forget: empty memory and delete both files.
function Store:wipe()
  self:_reset()
  os.remove(self.path)
  os.remove(self.newPath)
  os.remove(self.newPath .. ".reading")
end

return H
