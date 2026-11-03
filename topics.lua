-- Topical lines (Hammerspoon module)
--
-- Off unless config.lua has `topics`, and only with a brain. Every few hours it reads a
-- few headline feeds (RSS or Atom; Google News by default), and the brain (brain.lua
-- topics) picks light, joke-friendly topics from them and writes a fresh batch of lines
-- for some of Buddy's moods. Both are kept in one small JSON file on this Mac. brain.lua
-- brings the topics up in some of its made-up lines, and buddy.lua mixes the fresh lines
-- in with the canned ones (`share`, half by default). Nothing here looks at the screen;
-- the feeds only get a plain request for their headlines. wipe() empties it for Forget.
-- Loading this does nothing; buddy.lua makes the store with T.new(path, opts).

local T = {}

-- Google News sections in English; config.lua topics.feeds replaces the list.
T.FEEDS = {
  "https://news.google.com/rss/headlines/section/topic/ENTERTAINMENT",
  "https://news.google.com/rss/headlines/section/topic/TECHNOLOGY",
  "https://news.google.com/rss/headlines/section/topic/SPORTS",
  "https://news.google.com/rss",
}

-- The moods it writes lines for, and what each means (for the brain).
T.MOODS = {
  idle = "nothing special going on",
  sleepy = "it's late at night and they should be in bed",
  morning = "early morning, first coffee",
  coding = "they're coding",
  claudeWork = "Claude Code, in another window, is busy on a task for them (you're watching, not working)",
  claudeWait = "Claude Code, in another window, finished a task and is waiting for their reply",
  browsing = "browsing the web",
  watching = "watching videos or shows",
  jealous = "they opened a rival AI",
  snow = "checking the weather",
  health = "time for a break, some water or a stretch",
  food = "time to eat",
  bored = "they've stepped away from the keyboard",
}

local EVERY = 4            -- hours between refreshes (config.lua topics.every_hours)
local RETRY = 1800         -- seconds before trying again after a refresh that failed
local STALE = 2 * 86400    -- topics and lines older than this aren't used
local PER_FEED, MAX_HEADLINES = 12, 40
local MAX_TOPICS, MAX_LINES, MAX_LEN, MAX_TOPIC_LEN = 10, 6, 90, 80
local UA = "Mozilla/5.0 (Macintosh) ClaudeBuddy"

local NAMED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function codepoint(n)
  n = tonumber(n)
  return n and n > 0 and n < 0x110000 and utf8.char(n) or ""
end

-- Feed text as plain text: CDATA unwrapped, tags dropped, entities decoded, spaces tidied.
local function plain(s)
  s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("<[^>]*>", "")
  s = s:gsub("&#[xX](%x+);", function(h) return codepoint(tonumber(h, 16)) end)
  s = s:gsub("&#(%d+);", codepoint)
  s = s:gsub("&(%a+);", function(name) return NAMED[name] end)
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- The headlines in an RSS or Atom feed, up to limit, without repeats. Google News ends
-- each title with " - Source" and gives the source its own element; that part goes.
-- A title that isn't valid UTF-8 (a Latin-1 feed, a stray surrogate entity) is skipped:
-- it would spoil the JSON sent to the brain.
function T.parse(xml, limit)
  local out, seen = {}, {}
  if type(xml) ~= "string" then return out end
  for _, tag in ipairs({ "item", "entry" }) do
    for item in xml:gmatch("<" .. tag .. "[%s>].-</" .. tag .. ">") do
      if #out >= limit then return out end
      local title = plain(item:match("<title[^>]*>(.-)</title>") or "")
      if item:find("<source[%s>]") then title = title:match("^(.-) %- [^%-]+$") or title end
      if title ~= "" and utf8.len(title) and not seen[title] then
        seen[title] = true
        out[#out + 1] = title
      end
    end
  end
  return out
end

-- A line Buddy may say: plain, short, one breath; nil for anything else. Quotation marks,
-- emoji, hashtags, links, stage directions, long numbers and dollar amounts are out, and
-- so is % (buddy.lua fills %s and friends).
function T.clean(line)
  if type(line) ~= "string" then return nil end
  line = line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):gsub("^[Bb]uddy: ", "")
  local n = utf8.len(line)
  if not n or n < 3 or n > MAX_LEN then return nil end
  if line:find('["#@%%$*{}<>|~`\\]') or line:find("\226\128[\156\157]") or line:find("[\240-\244]")
    or line:lower():find("http", 1, true) or line:lower():find("www%.") then return nil end
  if line:find("%d%d%d%d%d") or line:find("%d%d%d[%-%. ]%d%d%d") then return nil end
  return line
end

-- A topic, as the brain wrote it: short and plain, or nil.
local function topic(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  local n = utf8.len(s)
  if not n or n < 2 or n > MAX_TOPIC_LEN then return nil end
  if s:find('"', 1, true) or s:find("\226\128[\156\157]") or s:find("[\240-\244]") then return nil end
  return s
end

-- opts: feeds, every_hours, share (0-1: how often a canned line gives way to a fresh one),
-- and for specs get(url, done(status, body)), now() and random(n).
function T.new(path, opts)
  opts = type(opts) == "table" and opts or {}
  local S = {}
  local feeds = {}
  for _, f in ipairs(type(opts.feeds) == "table" and opts.feeds or T.FEEDS) do
    if type(f) == "string" and f:match("^https?://") then feeds[#feeds + 1] = f end
  end
  local every = math.max(1, math.min(48, tonumber(opts.every_hours) or EVERY)) * 3600
  S.share = math.max(0, math.min(1, tonumber(opts.share) or 0.5))
  local now = opts.now or os.time
  local random = opts.random or math.random
  local get = opts.get or function(url, done)
    hs.http.asyncGet(url, { ["User-Agent"] = UA }, function(status, body) done(status, body) end)
  end
  local data, busy = { at = 0, tried = 0, topics = {}, lines = {} }, false

  local function save()
    local f = io.open(path, "w")
    if not f then return end
    f:write(hs.json.encode(data))
    f:close()
  end

  -- Keep what's usable from the brain's answer; true when anything was kept.
  function S.apply(result, t)
    if type(result) ~= "table" then return false end
    local topics, lines, any = {}, {}, false
    for _, x in ipairs(type(result.topics) == "table" and result.topics or {}) do
      local clean = topic(x)
      if clean and #topics < MAX_TOPICS then topics[#topics + 1] = clean; any = true end
    end
    for mood, list in pairs(type(result.lines) == "table" and result.lines or {}) do
      if T.MOODS[mood] and type(list) == "table" then
        local kept = {}
        for _, x in ipairs(list) do
          local clean = T.clean(x)
          if clean and #kept < MAX_LINES then kept[#kept + 1] = clean end
        end
        if #kept > 0 then lines[mood] = kept; any = true end
      end
    end
    if not any then return false end
    data.topics, data.lines, data.at = topics, lines, t or now()
    save()
    return true
  end

  do -- what an earlier run kept
    local f = io.open(path, "r")
    if f then
      local ok, d = pcall(hs.json.decode, f:read("*a") or "")
      f:close()
      if ok and type(d) == "table" then
        data.tried = tonumber(d.tried) or 0
        if S.apply(d, tonumber(d.at) or 0) then data.at = tonumber(d.at) or 0 end
      end
    end
  end

  local function fresh(t) return (t or now()) - data.at < STALE end

  function S.due(t)
    t = t or now()
    return not busy and #feeds > 0 and t - data.at >= every and t - data.tried >= RETRY
  end

  -- Current topics as one line ("a; b; c"), or nil when there are none or they're old.
  function S.text(t)
    if not fresh(t) or #data.topics == 0 then return nil end
    return table.concat(data.topics, "; ")
  end

  -- A fresh line for this mood, or nil.
  function S.line(kind, t)
    local pool = fresh(t) and data.lines[kind]
    if not pool or #pool == 0 then return nil end
    return pool[random(#pool)]
  end

  -- Fetch every feed, then ask(headlines, moods, done(result)) -> false when the brain
  -- can't start. finished(ok) is called once.
  function S.refresh(ask, finished)
    finished = finished or function() end
    if busy then return finished(false) end
    busy, data.tried = true, now()
    save()
    local results, left = {}, #feeds
    local function fail()
      busy = false
      finished(false)
    end
    local function gathered()
      local headlines, seen, round = {}, {}, 1
      local more = true
      while more and #headlines < MAX_HEADLINES do
        more = false
        for i = 1, #feeds do
          local h = results[i] and results[i][round]
          if h then
            more = true
            if not seen[h] and #headlines < MAX_HEADLINES then seen[h] = true; headlines[#headlines + 1] = h end
          end
        end
        round = round + 1
      end
      if #headlines == 0 then return fail() end
      local started = ask(headlines, T.MOODS, function(result)
        busy = false
        finished(S.apply(result))
      end)
      if not started then fail() end
    end
    if left == 0 then return fail() end
    for i, url in ipairs(feeds) do
      get(url, function(status, body)
        results[i] = status == 200 and T.parse(body, PER_FEED) or {}
        left = left - 1
        if left == 0 then gathered() end
      end)
    end
  end

  -- For hs -c 'return ClaudeBuddy.TOPICS.status()'.
  function S.status(t)
    t = t or now()
    local n = 0
    for _, list in pairs(data.lines) do n = n + #list end
    if data.at == 0 then return "No topics yet." end
    return #data.topics .. " topics and " .. n .. " fresh lines from " .. math.floor((t - data.at) / 60)
      .. " min ago" .. (fresh(t) and "" or " (too old to use)") .. ": " .. table.concat(data.topics, "; ")
  end

  function S.wipe()
    data = { at = 0, tried = 0, topics = {}, lines = {} }
    os.remove(path)
  end

  return S
end

return T
