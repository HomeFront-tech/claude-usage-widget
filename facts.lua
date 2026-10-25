-- Running facts about what you use (Hammerspoon module)
--
-- Counts how many times you opened each app or site today, how long you stayed, your
-- streak of days and the part of the day you usually use it, and turns that into a plain
-- line ("YouTube for the third time today!") or a summary for the brain. Everything stays
-- in one small JSON file on this Mac, kept for 14 days; wipe() empties it for Forget.
-- Loading this does nothing; buddy.lua makes the store with F.new(path).

local F = {}

local KEEP_DAYS = 14
local AWAY = 60        -- seconds away before coming back counts as a new open
local GAP = 15 * 60  -- seconds before it comments on the same app or site again
local MAX_STEP = 30    -- a longer silence between observations is a break, not time spent
local HABIT_MIN = 1800 -- seconds in the last 14 days before a usual part of day is claimed
local LABELS = { youtube = "YouTube", github = "GitHub", chatgpt = "ChatGPT", gmail = "Gmail",
                 netflix = "Netflix", twitch = "Twitch", soundcloud = "SoundCloud", spotify = "Spotify" }
local THIRD = { "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth" }

local Store = {}
Store.__index = Store

local function dayOf(t) return os.date("%Y-%m-%d", math.floor(t)) end

-- The day n days before t, found from local noon so daylight saving can't skip a day.
local function daysBack(t, n)
  local d = os.date("*t", math.floor(t))
  return dayOf(os.time({ year = d.year, month = d.month, day = d.day - n, hour = 12 }))
end

local function part(t)
  local h = tonumber(os.date("%H", math.floor(t)))
  if h >= 5 and h < 12 then return "morning" end
  if h >= 12 and h < 17 then return "afternoon" end
  if h >= 17 and h < 22 then return "evening" end
  return "night"
end

local function capital(s) return (s:gsub("^%l", string.upper)) end

-- A key and a label for what the front window is: an app by bundle id, a site by the
-- first matching title rule or the name after the last " - " / " — ".
function F.keyFor(bid, appName, title, isBrowser, titleRules)
  bid, appName, title = bid or "", appName or "", title or ""
  local fallback = bid ~= "" and bid or appName
  if not isBrowser then return fallback, appName end
  local lower = title:lower()
  for _, r in ipairs(titleRules or {}) do
    if lower:find(r[1], 1, true) then return r[1], LABELS[r[1]] or capital(r[1]) end
  end
  local site = title:match(".* %- (.+)$") or title:match(".* — (.+)$")
  local dash = title:match(".*() — ")
  local hyphen = title:match(".*() %- ")
  if dash and (not hyphen or dash > hyphen) then site = title:match(".* — (.+)$") end -- whichever comes last
  site = site and site:gsub("^%s+", ""):gsub("%s+$", "")
  if site and site ~= "" and site:lower() ~= appName:lower() then
    site = site:sub(1, 40)
    return site:lower(), site
  end
  return fallback, appName
end

local function mkdirs(path)
  local sofar = path:sub(1, 1) == "/" and "/" or ""
  for piece in path:gmatch("[^/]+") do
    sofar = sofar == "/" and ("/" .. piece) or (sofar == "" and piece or (sofar .. "/" .. piece))
    if not hs.fs.attributes(sofar) then hs.fs.mkdir(sofar) end
  end
end

function Store:_reset()
  self.days, self.seen = {}, {}
  self.cur, self.lastT, self.lastKey = nil, nil, nil
end

local function count(v) return type(v) == "number" and v >= 0 and v < 1e9 and v or nil end

-- A saved record kept only if it has the right shape; anything else is dropped.
local function validEntry(e)
  if type(e) ~= "table" then return nil end
  local opens, seconds = count(e.opens), count(e.seconds)
  if not opens or not seconds then return nil end
  local parts = {}
  if type(e.parts) == "table" then
    for _, p in ipairs({ "morning", "afternoon", "evening", "night" }) do
      parts[p] = count(e.parts[p])
    end
  end
  return { label = type(e.label) == "string" and e.label or nil, opens = opens, seconds = seconds, parts = parts }
end

function Store:_load()
  self:_reset()
  local f = io.open(self.path)
  if not f then return end
  local text = f:read("a")
  f:close()
  local ok, data = pcall(hs.json.decode, text)
  if not ok or type(data) ~= "table" or type(data.days) ~= "table" then return end
  for day, keys in pairs(data.days) do
    if type(day) == "string" and day:match("^%d%d%d%d%-%d%d%-%d%d$") and type(keys) == "table" then
      local clean = {}
      for key, e in pairs(keys) do
        local good = validEntry(e)
        if type(key) == "string" and good then clean[key] = good end
      end
      self.days[day] = clean
    end
  end
  if type(data.seen) == "table" then
    for k, v in pairs(data.seen) do
      -- a real timestamp: a number (not NaN) that os.date can format
      if type(k) == "string" and type(v) == "number" and v > 0 and v < 2 ^ 33 then self.seen[k] = v end
    end
  end
end

local function entry(self, day, key, label)
  local d = self.days[day]
  if not d then d = {}; self.days[day] = d end
  local e = d[key]
  if type(e) ~= "table" then e = { label = label, opens = 0, seconds = 0, parts = {} }; d[key] = e end
  e.label = label or e.label
  e.opens, e.seconds = tonumber(e.opens) or 0, tonumber(e.seconds) or 0
  if type(e.parts) ~= "table" then e.parts = {} end
  return e
end

-- Call every second or so with what's in front. Returns true when this counted a new open.
function Store:observe(key, label, t)
  if not key or key == "" then return false end
  if self.cur and self.lastT then
    local dt = t - self.lastT
    if dt >= 0 and dt <= MAX_STEP then
      local e = entry(self, dayOf(self.lastT), self.cur.key, self.cur.label)
      e.seconds = e.seconds + dt
      local p = part(self.lastT)
      e.parts[p] = (tonumber(e.parts[p]) or 0) + dt
      self.seen[self.cur.key] = t
    else
      self.cur = nil -- a gap: asleep, away, or not watching
    end
  end
  local opened = false
  if self.lastKey == key and self.lastT then
    -- the same thing as at the last look, even after a gap (you stepped away, or it stopped
    -- looking for a while): the same visit goes on, so it isn't a new open
    if dayOf(t) ~= dayOf(self.lastT) then opened = true end -- midnight passed: today's first open
  else
    local last = self.seen[key]
    opened = not last or t - last >= AWAY
  end
  if opened then entry(self, dayOf(t), key, label).opens = entry(self, dayOf(t), key, label).opens + 1 end
  if not self.seen[key] then self.seen[key] = t end
  self.cur, self.lastT, self.lastKey = { key = key, label = label }, t, key
  return opened
end

-- opens and seconds today, seconds since last seen, the usual part of day, days running.
function Store:get(key, t)
  local today = dayOf(t)
  local e = self.days[today] and self.days[today][key]
  local out = { opens = e and tonumber(e.opens) or 0, seconds = e and tonumber(e.seconds) or 0 }
  out.sinceLast = self.seen[key] and math.max(0, t - self.seen[key]) or nil
  local totals, sum = {}, 0
  local cutoff = daysBack(t, KEEP_DAYS - 1) -- today and the 13 days before it
  for day, keys in pairs(self.days) do
    local k = keys[key]
    if day >= cutoff and day <= today and type(k) == "table" and type(k.parts) == "table" then
      for p, secs in pairs(k.parts) do
        totals[p] = (totals[p] or 0) + (tonumber(secs) or 0)
        sum = sum + (tonumber(secs) or 0)
      end
    end
  end
  if sum >= HABIT_MIN then
    local best
    for _, p in ipairs({ "morning", "afternoon", "evening", "night" }) do
      if totals[p] and (not best or totals[p] > totals[best]) then best = p end
    end
    out.daypart = best
  end
  local streak = 0
  while streak < KEEP_DAYS do
    local d = self.days[daysBack(t, streak)]
    local k = d and d[key]
    if not (k and ((tonumber(k.opens) or 0) > 0 or (tonumber(k.seconds) or 0) > 0)) then break end
    streak = streak + 1
  end
  out.streak = streak
  return out
end

local function ordinal(n)
  local tens, ones = n % 100, n % 10
  local suffix = "th"
  if tens < 11 or tens > 13 then suffix = ({ [1] = "st", [2] = "nd", [3] = "rd" })[ones] or "th" end
  return n .. suffix
end

local function minutes(secs)
  local m = math.floor(secs / 60 + 0.5)
  if m < 1 then return "under a minute" end
  if m < 60 then return m .. " min" end
  return string.format("%dh %02d min", m // 60, m % 60)
end

-- A short summary for the brain: "YouTube: 3rd time today, 47 min so far, usually in the evening".
function Store:describe(key, label, t)
  local g = self:get(key, t)
  local out = label .. ": " .. (g.opens > 0 and (ordinal(g.opens) .. " time today") or "not opened today")
  if g.seconds >= 1 then out = out .. ", " .. minutes(g.seconds) .. " so far" end
  if g.streak >= 2 then out = out .. ", " .. g.streak .. " days running" end
  if g.daypart then out = out .. ", usually in the " .. g.daypart end
  return out
end

-- The summary for the window in front (w: app, title, bid), or nil when nothing is known about
-- it yet. For a screen quip's prompt; the caller has already checked watching and privacy.
function Store:aboutWindow(w, isBrowser, titleRules, t)
  if type(w) ~= "table" or (w.bid or "") == "" then return nil end
  local key, label = F.keyFor(w.bid, w.app, w.title, isBrowser, titleRules)
  if not self.seen[key] then return nil end
  return self:describe(key, label, t)
end

-- A plain canned line about today's count, or nil when there's nothing to remark on.
function Store:line(key, label, t)
  local g = self:get(key, t)
  if g.seconds >= 7200 then return "Two hours of " .. label .. " today!" end
  if g.opens == 2 then return label .. " again!" end
  if g.opens >= 3 and g.opens <= 10 then return label .. " for the " .. THIRD[g.opens - 2] .. " time today!" end
  if g.opens > 10 then return label .. ", round " .. g.opens .. " today." end
  return nil
end

function Store:save()
  -- keep the last 14 days up to the newest observation
  local ref = self.lastT or os.time()
  local cutoff = daysBack(ref, KEEP_DAYS - 1)
  for day in pairs(self.days) do
    if day < cutoff then self.days[day] = nil end
  end
  for key, at in pairs(self.seen) do
    if dayOf(at) < cutoff then self.seen[key] = nil end
  end
  mkdirs(self.path:match("^(.*)/[^/]*$") or ".")
  local f = io.open(self.path, "w")
  if not f then return false end
  f:write(hs.json.encode({ days = self.days, seen = self.seen }))
  f:close()
  return true
end

-- Forget: empty memory and delete the file.
function Store:wipe()
  self:_reset()
  os.remove(self.path)
end

-- What the buddy does with the window in front for each state of you: nil while you're
-- asleep (nothing counts), "count" once you've gone quiet (time still adds up, so a video you
-- watch without touching the mouse is counted, but nothing is said), "talk" while active.
function F.stage(away)
  if away == "active" then return "talk" end
  if away == "bored" then return "count" end
  return nil
end

-- Fact lines are on only for configs the setup wizard wrote: its save() marks the file
-- `wizard = 2`, and the menu's watching switch never does. Older configs keep today's
-- behaviour. Counting runs regardless.
function F.talks(cfg)
  return type(cfg) == "table" and type(cfg.wizard) == "number" and cfg.wizard >= 2
end

-- May a fact line be said now? g: muted, quietFor (below 0 = only when clicked), busy (a
-- call, meeting, game or full screen), watching. A brain's line also needs watching on.
function F.mayDeliver(g, fromBrain)
  if g.muted or (g.quietFor or 0) < 0 or g.busy then return false end
  return not fromBrain or g.watching == true
end

-- One poll's worth: count what's in front, and when it was opened again say so. o:
-- t, bid, app (name), title, isBrowser, rules (title rules), mood, privacy (private, busy,
-- watching), lines (false = count only, no talking), quiet (muted or "only when clicked"),
-- brain (or nil), say(text, force), said (key -> last time it spoke; kept by the caller),
-- gate() (optional; the gates again when a line is about to be said, since a brain's line
-- can land after a mute, a pause or a call started).
-- A brain writes the line from the facts, but only while watching is on; otherwise a
-- plain template. Returns the key it counted, or nil when it skipped the window.
function F.tick(store, o)
  if o.bid == "" or o.privacy.private(o.bid, o.app, o.title) then return nil end
  local key, label = F.keyFor(o.bid, o.app, o.title, o.isBrowser, o.rules)
  if store:observe(key, label, o.t) and o.lines and not o.quiet
      and not o.privacy.busy(o.bid, o.title, false, o.mood)
      and store:get(key, o.t).opens >= 2 and o.t - (o.said[key] or -math.huge) >= GAP then
    o.said[key] = o.t
    local plain = store:line(key, label, o.t)
    local started = o.brain and o.privacy.watching() and not o.brain.busy() and o.brain.quip(
      { kind = "fact", facts = store:describe(key, label, o.t), unprompted = true },
      function(line)
        local text = line or plain
        if text and (not o.gate or F.mayDeliver(o.gate(), line ~= nil)) then o.say(text, true) end
      end)
    if not started and plain then o.say(plain, true) end
  end
  return key
end

function F.new(path)
  local self = setmetatable({ path = path }, Store)
  self:_load()
  return self
end

return F
