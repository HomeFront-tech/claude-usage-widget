-- How Buddy paces his own chatter (Hammerspoon module)
--
-- A log of everything he said showed three habits: a line every 50 seconds from the same five
-- while you sat in one window, the same line twice within minutes, and a fresh "arrival" every
-- time you flipped between two windows. This module is what he checks before small talk:
--   lines     nothing he said in the last 40 minutes is said again; silence beats a repeat
--   budget    a gap between bits of small talk, and a cap on how many in ten minutes
--   ambient   the longer you stay in one window, the longer he waits before piping up
--   visits    a window you pass through gets no remark; one you were in a moment ago is a
--             return, not an arrival
--   workflow  going back and forth between the same two windows is one job; he says so now
--             and then, and remembers the pair (by app or site, never a window's title) so
--             he knows it next time
-- Loading this does nothing; buddy.lua makes one with C.new(opts).

local C = {}

local REPEAT = 2400   -- seconds before a line may be said again
local SETTLE = 3      -- seconds in a window before it counts as arriving there
local PASS = 2        -- a shorter stop than this was only passing through
local RETURN = 180    -- back within this many seconds: a return, not an arrival
local WINDOW = 360    -- how far back the back-and-forth pattern is looked for
local KEEP = 300      -- a workflow lasts this long after its last flip
local BREAK = 120     -- no look for this long (the Mac slept): the stay starts over
local WF_WAITS = { 480, 900, 1800 } -- seconds between remarks about one workflow
local MAX_PAIRS, PAIR_DAYS = 60, 60       -- remembered pairs, and days one is kept unseen
local LEVELS = { -- small talk: seconds between lines, lines per ten minutes, and how many of
  -- those may be ones he makes by himself (the rest are kept for arriving somewhere)
  -- gap: after any small talk, before a line of his own; arrive: before a remark on arriving
  chatty = { gap = 12, arrive = 4, cap = 6, filler = 4 }, normal = { gap = 30, arrive = 10, cap = 3, filler = 2 },
  quiet = { gap = 90, arrive = 30, cap = 1, filler = 1 },
}
C.PRIVATE = "\0private" -- the key for a window he may not look at: counted as away, never named

local D = {}
D.__index = D

local function dayOf(t) return os.date("%Y-%m-%d", math.floor(t)) end

local function mkdirs(path)
  local sofar = path:sub(1, 1) == "/" and "/" or ""
  for piece in path:gmatch("[^/]+") do
    sofar = sofar == "/" and ("/" .. piece) or (sofar == "" and piece or (sofar .. "/" .. piece))
    if not hs.fs.attributes(sofar) then hs.fs.mkdir(sofar) end
  end
end

-- Lines ------------------------------------------------------------------------

function D:fresh(key, t)
  local at = self.said[key]
  return not at or t - at >= REPEAT
end

function D:mark(key, t)
  if type(key) ~= "string" or key == "" then return end
  self.said[key] = t
  self.marks = self.marks + 1
  if self.marks % 200 == 0 then -- drop what is long past repeating
    for k, at in pairs(self.said) do if t - at >= REPEAT then self.said[k] = nil end end
  end
end

-- One of the lines not said lately, or nil when they all were. keyOf(line) names a line for
-- the memory (a template without its blanks, say); the line itself by default. The pick is
-- remembered right away.
function D:choose(list, t, keyOf)
  local open = {}
  for _, line in ipairs(list or {}) do
    if self:fresh(keyOf and keyOf(line) or line, t) then open[#open + 1] = line end
  end
  if #open == 0 then return nil end
  local line = open[self.random(#open)]
  self:mark(keyOf and keyOf(line) or line, t)
  return line
end

-- Small talk -------------------------------------------------------------------

-- May he make small talk now? kind "ambient": a line he makes by himself, which stops
-- sooner than a remark on arriving somewhere.
function D:can(t, kind)
  local L, own = self.level, kind == "ambient"
  if self.lastSmall and t - self.lastSmall < (own and L.gap or L.arrive) then return false end
  local n = 0
  for _, at in ipairs(self.smalls) do if t - at < 600 then n = n + 1 end end
  return n < (own and L.filler or L.cap)
end

function D:spent(t)
  self.lastSmall = t
  local keep = {}
  for _, at in ipairs(self.smalls) do if t - at < 600 then keep[#keep + 1] = at end end
  keep[#keep + 1] = t
  self.smalls = keep
end

-- By himself --------------------------------------------------------------------

-- Seconds of quiet before he pipes up: the base, doubled for each time he already did in
-- this window (up to eight times), with a wobble so it never ticks like a clock.
function D:ambientGap()
  return self.ambient * 2 ^ math.min(self.ambientN, 3) * self.wobble
end

function D:ambientSaid()
  self.ambientN = self.ambientN + 1
  if self.jitter then self.wobble = 0.85 + 0.4 * self.random() end
end

-- Visits -----------------------------------------------------------------------

local function pairId(a, b)
  if a > b then a, b = b, a end
  return a .. " + " .. b
end

-- Call every second or so with what's in front: a key (an app, a site, one window), what to
-- call it, and optionally the group it belongs to and that group's name (every Claude Code
-- session is one group). Returns "moved" on the look that finds a new window, else "same".
function D:visit(key, label, t, group, glabel)
  local cur = self.cur
  if cur and cur.key == key then
    -- back from a break in the same window: the stay and the ambient wait start over
    if cur.resting or t - cur.to > BREAK then cur.from, cur.resting, self.ambientN = t, nil, 0 end
    cur.to = t
    if label then cur.label = label end
    return "same"
  end
  if cur then
    self.left[cur.key] = cur.to
    if cur.to - cur.from >= PASS then
      local last = self.trail[#self.trail]
      if last and last.key == cur.key then last.to, last.label = cur.to, cur.label -- only passed through something
      else self.trail[#self.trail + 1] = cur end
    end
  end
  while self.trail[1] and (t - self.trail[1].to > WINDOW or #self.trail > 12) do table.remove(self.trail, 1) end
  for k, at in pairs(self.left) do if t - at > 3600 then self.left[k] = nil end end
  local back = self.left[key] ~= nil and t - self.left[key] <= RETURN
  self.cur = { key = key, label = label, group = group or key, glabel = glabel or label, from = t, to = t, back = back }
  if not back and not self:_inWorkflow(key, t) then self.ambientN = 0 end
  return "moved"
end

function D:_inWorkflow(key, t)
  local wf = self:workflow(t)
  return wf ~= nil and (wf.a.key == key or wf.b.key == key)
end

-- Once per visit, when you've been in the window SETTLE seconds: "arrival", or "return" for
-- a window you were in a moment ago or one half of the workflow you're in. nil otherwise.
function D:settled(t)
  local cur = self.cur
  if not cur or cur.told or t - cur.from < SETTLE then return nil end
  cur.told = true
  self:_pattern(t)
  if cur.back or self:_inWorkflow(cur.key, t) then return "return" end
  return "arrival"
end

-- Is the window in front one you came back to (or part of the workflow you're in)?
function D:returned(t)
  local cur = self.cur
  return cur ~= nil and (cur.back or self:_inWorkflow(cur.key, t))
end

-- Is the window in front one of the two in the workflow you're in?
function D:inWorkflow(t)
  return self.cur ~= nil and self:_inWorkflow(self.cur.key, t)
end

-- Seconds in the window in front.
function D:stayed(t)
  return self.cur and t - self.cur.from or 0
end

-- You stepped away (idle, or asleep): time until you're back doesn't count as staying.
function D:rest()
  if self.cur then self.cur.resting = true end
end

-- Workflows ---------------------------------------------------------------------

-- The settled window against the ones before it: the same two, turn about, four stops long
-- (three for a pair he has seen before) is a workflow.
function D:_pattern(t)
  if not self.watching then return end
  local cur, wf = self.cur, self:workflow(t)
  if wf and (wf.a.key == cur.key or wf.b.key == cur.key) then -- another flip of the same job
    local side = wf.a.key == cur.key and wf.a or wf.b
    side.label = cur.label
    if wf.at ~= cur.key then wf.flips, wf.at = wf.flips + 1, cur.key end
    wf.lastFlip = t
    return
  end
  if cur.key == C.PRIVATE then return end
  local other, first, n = nil, cur, 1
  for i = #self.trail, 1, -1 do
    local e = self.trail[i]
    local want = n % 2 == 1 and "other" or "cur"
    if e.key == C.PRIVATE or cur.from - e.to > WINDOW then break end
    if want == "other" then
      if e.key == cur.key or (other and e.key ~= other.key) then break end
      other = other or e
    elseif e.key ~= cur.key then break end
    first, n = e, n + 1
  end
  if not other then return end
  local id = pairId(cur.group, other.group)
  local seen = self.pairs[id]
  if n < ((seen and seen.times >= 2) and 3 or 4) then return end
  local a, b = first, (first.key == cur.key) and other or cur
  self.wf = { a = { key = a.key, label = a.label, group = a.group, glabel = a.glabel },
    b = { key = b.key, label = b.label, group = b.group, glabel = b.glabel },
    id = id, since = first.from, flips = n - 1, at = cur.key, lastFlip = t, told = 0, nextAt = t }
  if cur.key == a.key then self.wf.a.label = cur.label else self.wf.b.label = cur.label end
  -- remember the pair: how many times, on how many days
  local day = dayOf(t)
  seen = seen or { times = 0, days = 0 }
  seen.a, seen.b = a.glabel, b.glabel
  seen.times = seen.times + 1
  if seen.lastDay ~= day then seen.days, seen.lastDay = seen.days + 1, day end
  seen.lastAt = math.floor(t)
  self.pairs[id], self.dirty = seen, true
end

-- The workflow you're in, or nil: a, b = { key, label, group, glabel }, since, flips.
function D:workflow(t)
  local wf = self.wf
  if wf and (t - wf.lastFlip > KEEP or not self.watching) then self.wf, wf = nil, nil end
  return wf
end

function D:workflowDue(t)
  local wf = self:workflow(t)
  return wf ~= nil and t >= wf.nextAt
end

function D:workflowSaid(t)
  local wf = self:workflow(t)
  if not wf then return end
  wf.told = wf.told + 1
  wf.nextAt = t + (WF_WAITS[wf.told] or WF_WAITS[#WF_WAITS])
end

-- How many times, and on how many days, he has seen this workflow's pair (this time included).
function D:known(wf)
  local seen = wf and self.pairs[wf.id]
  if not seen then return 0, 0 end
  return seen.times, seen.days
end

-- Memory -----------------------------------------------------------------------

local function count(v, max) return type(v) == "number" and v >= 0 and v < max and v or nil end

function D:_load()
  self.pairs = {}
  local f = self.path and io.open(self.path)
  if not f then return end
  local text = f:read("a")
  f:close()
  local ok, data = pcall(hs.json.decode, text)
  if not ok or type(data) ~= "table" or type(data.pairs) ~= "table" then return end
  for id, p in pairs(data.pairs) do
    if type(id) == "string" and type(p) == "table" and count(p.times, 1e6) and count(p.days, 1e5) then
      self.pairs[id] = { times = p.times, days = p.days, lastAt = count(p.lastAt, 2 ^ 33) or 0,
        lastDay = type(p.lastDay) == "string" and p.lastDay or nil,
        a = type(p.a) == "string" and p.a or nil, b = type(p.b) == "string" and p.b or nil }
    end
  end
end

-- Keep the newest MAX_PAIRS pairs seen in the last PAIR_DAYS days. True when written.
function D:save(t)
  if not self.path then return false end
  t = t or os.time()
  local ids = {}
  for id, p in pairs(self.pairs) do
    if t - (p.lastAt or 0) > PAIR_DAYS * 86400 then self.pairs[id] = nil else ids[#ids + 1] = id end
  end
  table.sort(ids, function(x, y) return (self.pairs[x].lastAt or 0) > (self.pairs[y].lastAt or 0) end)
  for i = MAX_PAIRS + 1, #ids do self.pairs[ids[i]] = nil end
  mkdirs(self.path:match("^(.*)/[^/]*$") or ".")
  local f = io.open(self.path, "w")
  if not f then return false end
  f:write(hs.json.encode({ pairs = next(self.pairs) and self.pairs or hs.json.decode("{}") }))
  f:close()
  self.dirty = false
  return true
end

-- Forget: what he said, where you've been, the pairs and their file.
function D:wipe()
  self.said, self.marks = {}, 0
  self.cur, self.trail, self.left, self.wf = nil, {}, {}, nil
  self.pairs, self.dirty = {}, false
  if self.path then os.remove(self.path) end
end

-- opts: level ("chatty" | "normal" | "quiet"), ambient (base seconds of quiet before he pipes
-- up), path (where remembered pairs are kept; none = memory only), jitter = false (no
-- wobble, for specs), random (math.random by default).
function C.new(opts)
  opts = opts or {}
  local self = setmetatable({ level = LEVELS[opts.level] or LEVELS.normal, ambient = opts.ambient or 150,
    path = opts.path, jitter = opts.jitter ~= false, random = opts.random or math.random,
    said = {}, marks = 0, smalls = {}, ambientN = 0, wobble = 1, trail = {}, left = {}, dirty = false,
    watching = true }, D) -- watching: buddy.lua turns it off with Watching; then no workflows are learned
  if self.jitter then self.wobble = 0.85 + 0.4 * self.random() end
  self:_load()
  return self
end

return C
