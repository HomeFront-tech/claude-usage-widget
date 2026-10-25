-- Claude Code sessions Buddy starts for a task (Hammerspoon module)
--
-- Ask Buddy for a bigger job, in the chat or over Telegram, and it opens a Claude Code
-- session for it in a new Terminal window with Remote Control on, so you can drive it from
-- the Claude app on your phone as well. bin/buddy-task opens, types into and stops the
-- sessions; each session's hooks write what happens to its events.jsonl, which poll()
-- reads and buddy.lua passes on. Nothing opens without your yes: the brain's task tools
-- only propose (pending.json), and ask() / answer() here put the question to you.
-- Off with tasks = false in config.lua; see config.example.lua.

local K = {}

local HOME = os.getenv("HOME") or ""
local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local PATH = HOME .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
local FRESH = 15 * 60   -- a question waits this long for its yes or no
local KEEP_MSGS = 200   -- Telegram messages remembered, so a reply finds its session
local KEEP_ENDED = 86400 -- an ended session stays in the list this long
local STATES = { starting = "starting up", working = "working", waiting = "waiting on you",
  asking = "waiting for your OK", ended = "ended" }

local function set(list)
  local out = {}
  for _, w in ipairs(list) do out[w] = true end
  return out
end
local YES = set({ "y", "yes", "yep", "yeah", "yup", "ya", "sure", "ok", "okay", "k", "go", "go ahead", "do it",
  "yes please", "please", "start it", "send it", "sounds good", "go for it", "yes do it", "ok go", "👍" })
local NO = set({ "n", "no", "nope", "nah", "cancel", "no thanks", "don t", "never mind", "nevermind", "not now", "👎" })

local cfg, seen, msgs = {}, {}, {}
local running = {} -- hs.task objects, kept from garbage collection

local function now() return hs.timer.secondsSinceEpoch() end

-- Lower case, punctuation and extra spaces gone: "Yes!" and "yes" are the same answer.
local function words(text)
  return ((text or ""):lower():gsub("[%p%s]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- At most n bytes plus "…", cut at a space when there's one in the second half, and never
-- inside a UTF-8 character.
local function clip(s, n)
  s = s or ""
  if #s <= n then return s end
  local cut = n - 1
  while cut > 1 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  local head = s:sub(1, cut)
  local at = head:match("^.*()%s")
  if at and at > n / 2 then head = head:sub(1, at - 1) end
  return head .. "…"
end

local function tilde(path)
  path = path or HOME
  if HOME ~= "" and path:sub(1, #HOME) == HOME then return "~" .. path:sub(#HOME + 1) end
  return path
end

local function readJson(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  local ok, v = pcall(hs.json.decode, s or "")
  return ok and type(v) == "table" and v or nil
end

-- opts: terminal ("Terminal" or "iTerm"), owner (their name), model, effort (config.lua
-- tasks), and for specs: dir, bin, python, env (extra environment), seenKey, msgKey.
function K.configure(opts)
  cfg = opts or {}
  cfg.dir = cfg.dir or HOME .. "/Library/Application Support/claude-usage-widget/tasks"
  cfg.bin = cfg.bin or DIR .. "/bin/buddy-task"
  cfg.python = cfg.python or "/usr/bin/python3"
  cfg.seenKey = cfg.seenKey or "claudeBuddy.taskSeen"   -- how far each events.jsonl has been read
  cfg.msgKey = cfg.msgKey or "claudeBuddy.taskMessages" -- Telegram message id -> session id
  seen = hs.settings.get(cfg.seenKey) or {}
  msgs = hs.settings.get(cfg.msgKey) or {}
  K.pending = nil
  return K
end

function K.isYes(text) return YES[words(text)] == true end
function K.isNo(text) return NO[words(text)] == true end

-- Is text their own words, out of their message `said`? A send the brain proposes then
-- needs no extra yes.
function K.ownWords(text, said)
  local a = words(text)
  return a ~= "" and words(said):find(a, 1, true) ~= nil
end

-- A name for a session started with /task: its first few words.
function K.nameFor(text)
  local out = {}
  for w in (text or ""):gmatch("%S+") do
    out[#out + 1] = w
    if #out == 4 then break end
  end
  local name = clip(table.concat(out, " "), 40)
  return name ~= "" and (name:sub(1, 1):upper() .. name:sub(2)) or "Buddy task"
end

-- bin/buddy-task, done(info) with its JSON answer ({ ok = false, error = ... } when it fails).
local function run(args, input, done)
  local argv, task = { cfg.bin }, nil
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  local function fail(why) done({ ok = false, error = why or "Couldn't run bin/buddy-task." }) end
  local ok, created = pcall(hs.task.new, cfg.python, function(_, out, err)
    running[task] = nil
    local info
    for line in (out or ""):gmatch("[^\r\n]+") do
      if line:sub(1, 1) == "{" then
        local fine, v = pcall(hs.json.decode, line)
        if fine and type(v) == "table" then info = v end
      end
    end
    if not info then print("ClaudeBuddy tasks: " .. tostring(err)); return fail() end
    done(info)
  end, argv)
  if not ok or not created then return fail() end
  task = created
  local env = { HOME = HOME, PATH = PATH, USER = os.getenv("USER"), LOGNAME = os.getenv("LOGNAME"),
    TMPDIR = os.getenv("TMPDIR"), LANG = "en_US.UTF-8", BUDDY_TASKS_DIR = cfg.dir }
  for k, v in pairs(cfg.env or {}) do env[k] = v end
  task:setEnvironment(env)
  if input then task:setInput(input) end
  running[task] = true
  if not task:start() then
    running[task] = nil
    fail()
  end
end

-- Open a session for proposal p ({ task, name, folder }); origin "chat" or "telegram" is
-- where its updates go. done(info): info.task has its id, name and phone link (url).
function K.start(p, origin, done)
  run({ "start" }, hs.json.encode({ task = p.task, name = p.name, folder = p.folder, origin = origin,
    terminal = cfg.terminal, owner = cfg.owner, model = cfg.model, effort = cfg.effort }), done)
end

function K.send(id, text, done) run({ "send", id }, text, done) end
function K.stop(id, done) run({ "stop", id }, nil, done) end
function K.open(id, done) run({ "open", id, cfg.terminal or "Terminal" }, nil, done) end
-- Marks sessions that died without saying so as ended (each one becomes an "ended" event).
function K.sweep(done) run({ "list" }, nil, done or function() end) end

-- The sessions worth showing, oldest first: running ones and those that ended in the last day.
function K.list()
  local out, t = {}, os.time()
  if hs.fs.attributes(cfg.dir, "mode") ~= "directory" then return out end
  for name in hs.fs.dir(cfg.dir) do
    if name:match("^[a-z0-9-]+$") then
      local task = readJson(cfg.dir .. "/" .. name .. "/task.json")
      if task and task.id == name and (task.state ~= "ended" or t - (tonumber(task.ended) or 0) < KEEP_ENDED) then
        out[#out + 1] = task
      end
    end
  end
  table.sort(out, function(a, b) return (tonumber(a.created) or 0) < (tonumber(b.created) or 0) end)
  return out
end

-- A session by its number in K.list(), its id, or part of its name.
function K.find(ref)
  local list, n = K.list(), tonumber(ref)
  if n then return list[n] end
  local want = words(ref)
  if want == "" then return nil end
  for _, t in ipairs(list) do if t.id == ref then return t end end
  for _, t in ipairs(list) do if words(t.name):find(want, 1, true) then return t end end
  return nil
end

function K.state(task) return STATES[task.state] or task.state or "?" end

-- One line about the running sessions, for the brain; nil when there are none.
function K.summary()
  local lines = {}
  for _, t in ipairs(K.list()) do
    if t.state ~= "ended" then
      lines[#lines + 1] = string.format("%s (id %s, %s, in %s)", t.name, t.id, K.state(t), tilde(t.folder))
    end
  end
  return #lines > 0 and table.concat(lines, "; ") .. "." or nil
end

-- The answer to /tasks.
function K.listText()
  local list = K.list()
  if #list == 0 then return "No task sessions yet. Send /task and what it's for to start one." end
  local out = {}
  for i, t in ipairs(list) do
    out[#out + 1] = string.format("%d. %s: %s", i, t.name, K.state(t))
      .. (t.url and t.state ~= "ended" and ("\n" .. t.url) or "")
  end
  return table.concat(out, "\n") .. "\n\nReply to one of my updates to answer that session. /stop and a number ends one."
end

-- Read what the sessions' hooks wrote since last time; onEvent(task, ev) for each event,
-- ev = { kind = "done" | "asking" | "ended", text, at }. Only whole lines count, so a
-- line still being written waits for the next poll.
function K.poll(onEvent)
  if hs.fs.attributes(cfg.dir, "mode") ~= "directory" then return end
  local changed, present = false, {}
  for name in hs.fs.dir(cfg.dir) do
    if name:match("^[a-z0-9-]+$") then
      present[name] = true
      local base = cfg.dir .. "/" .. name
      local size = hs.fs.attributes(base .. "/events.jsonl", "size")
      if size and seen[name] == nil then
        local task = readJson(base .. "/task.json") -- one we haven't read: a running one from the start
        seen[name] = (task and task.state ~= "ended") and 0 or size
        changed = true
      end
      if size and size < seen[name] then seen[name], changed = size, true end
      if size and size > seen[name] then
        local f = io.open(base .. "/events.jsonl", "r")
        if f then
          f:seek("set", seen[name])
          local whole = (f:read("a") or ""):match("^.*\n") or ""
          f:close()
          seen[name], changed = seen[name] + #whole, true
          local task = readJson(base .. "/task.json")
          for line in whole:gmatch("[^\n]+") do
            local ok, ev = pcall(hs.json.decode, line)
            if ok and type(ev) == "table" and task then
              local fine, err = pcall(onEvent, task, ev)
              if not fine then print("ClaudeBuddy tasks: " .. tostring(err)) end
            end
          end
        end
      end
    end
  end
  for name in pairs(seen) do
    if not present[name] then seen[name], changed = nil, true end
  end
  if changed then hs.settings.set(cfg.seenKey, seen) end
end

-- A start or send the brain proposed since `since` (bin/buddy-tools wrote pending.json),
-- or nil. Taking it removes it, so an old one can't come back later.
function K.takeProposal(since)
  local path = cfg.dir .. "/pending.json"
  local p = readJson(path)
  if not p then return nil end
  os.remove(path)
  if (tonumber(p.at) or 0) < (since or 0) - 5 then return nil end
  if p.kind == "start" and type(p.task) == "string" and type(p.name) == "string" then
    p.folder = type(p.folder) == "string" and p.folder or HOME
    return p
  end
  if p.kind == "send" and type(p.id) == "string" and type(p.text) == "string" then return p end
  return nil
end

-- Hold p for their yes or no, and return the question to put to them.
function K.ask(p)
  K.pending = { p = p, at = now() }
  if p.kind == "send" then
    return string.format("Send this to %s?\n\n%s\n\nReply yes or no.", p.name or "that session", clip(p.text, 1500))
  end
  return string.format("Start a Claude Code session for this?\n\n%s, in %s:\n%s\n\nReply yes or no.",
    p.name, tilde(p.folder), clip(p.task, 600))
end

-- Their next message after ask(): "yes" or "no" plus the proposal, or nil when it's neither
-- (the question is dropped then, and the message goes on as usual).
function K.answer(text)
  local held = K.pending
  if not held then return nil end
  K.pending = nil
  if now() - held.at > FRESH then return nil end
  if K.isYes(text) then return "yes", held.p end
  if K.isNo(text) then return "no", held.p end
  return nil
end

-- Telegram messages that carried a session's update, so a reply to one goes to that session.
function K.remember(msgId, taskId)
  if not msgId then return end
  msgs[tostring(msgId)] = { id = taskId, at = os.time() }
  local n, oldest, key = 0, nil, nil
  for k, v in pairs(msgs) do
    n = n + 1
    if not oldest or (v.at or 0) < oldest then oldest, key = v.at or 0, k end
  end
  if n > KEEP_MSGS then msgs[key] = nil end
  hs.settings.set(cfg.msgKey, msgs)
end

function K.forMessage(msgId)
  local m = msgId and msgs[tostring(msgId)]
  return type(m) == "table" and m.id or nil
end

K.tilde, K.clip = tilde, clip
return K
