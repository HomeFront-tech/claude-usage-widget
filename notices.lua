-- Notices from other programs on this Mac (Hammerspoon module)
--
-- Another program (a meal tracker, a script, a scheduled job) appends one JSON line per
-- message to notices-new.jsonl in Buddy's folder: {"text": "...", "bubble": "...",
-- "mood": "health", "telegram": true, "at": 1792956374, "from": "meals"}. Only text is
-- needed; bubble is a short line for the speech bubble, else its first line is used.
-- buddy.lua checks every few seconds: poll() takes the file (renames it, as health.lua does
-- with its tools' file), reads it on the next check and returns the notices, which buddy.lua
-- puts in the chat as its own line, in the bubble and on Telegram. Off unless config.lua has
-- `notices = true`.
-- A line over an hour old is dropped (Buddy was off or the Mac asleep); 5 a pickup, 30 a day.

local N = {}

local MAX_TEXT, MAX_BUBBLE = 1000, 120
local MAX_AGE, MAX_AHEAD = 3600, 300 -- seconds a line may be old, or ahead of this clock
local PER_PICKUP, PER_DAY = 5, 30

local function cut(s, n)
  local len = utf8.len(s)
  if len and len > n then return s:sub(1, utf8.offset(s, n + 1) - 1) end
  if not len and #s > n then return s:sub(1, n) end
  return s
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- One line of the file -> { text, bubble, mood, telegram }, or nil for junk, an empty text
-- or a stale line. moods: the moods Buddy knows; any other mood is left out.
function N.parse(line, now, moods)
  local ok, d = pcall(hs.json.decode, line)
  if not ok or type(d) ~= "table" or type(d.text) ~= "string" then return nil end
  local text = trim(d.text)
  if text == "" then return nil end
  if d.at ~= nil then
    local at = tonumber(d.at)
    if not at or at < now - MAX_AGE or at > now + MAX_AHEAD then return nil end
  end
  local bubble = type(d.bubble) == "string" and trim(d.bubble) or ""
  return { text = cut(text, MAX_TEXT), bubble = bubble ~= "" and cut(bubble, MAX_BUBBLE) or nil,
    mood = type(d.mood) == "string" and moods and moods[d.mood] and d.mood or nil,
    telegram = d.telegram ~= false }
end

local Store = {}
Store.__index = Store

-- path: the notices-new.jsonl file. opts.moods: Buddy's moods; opts.settingsKey: where the
-- day's count lives in hs.settings.
function N.new(path, opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({ path = path, moods = opts.moods or {},
    key = opts.settingsKey or "claudeBuddy.noticesDay" }, Store)
end

-- Each call reads what the previous call took, then takes the file anew (renames it; a writer
-- then starts a fresh one). Reading one call later leaves time for a writer that opened the
-- old file just before the rename to finish its line. Returns a list of notices (maybe empty).
function Store:poll(now)
  local taken = self.path .. ".reading"
  local out = hs.fs.attributes(taken) and self:_read(taken, now) or {}
  if hs.fs.attributes(self.path) then os.rename(self.path, taken) end
  return out
end

function Store:_read(taken, now)
  local out = {}
  local f = io.open(taken)
  if f then
    local day = os.date("%Y-%m-%d", math.floor(now))
    local count = hs.settings.get(self.key)
    local n = type(count) == "table" and count.day == day and tonumber(count.n) or 0
    for line in f:lines() do
      if #out >= PER_PICKUP or n >= PER_DAY then break end
      local notice = N.parse(line, now, self.moods)
      if notice then out[#out + 1], n = notice, n + 1 end
    end
    f:close()
    if #out > 0 then hs.settings.set(self.key, { day = day, n = n }) end
  end
  os.remove(taken)
  return out
end

-- Forget: drop anything waiting.
function Store:wipe()
  os.remove(self.path)
  os.remove(self.path .. ".reading")
end

return N
