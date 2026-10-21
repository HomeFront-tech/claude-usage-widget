-- Grok Bot as the buddy's teammate (Hammerspoon module)
--
-- Off unless config.lua has a `grok` table; see config.example.lua. When you say
-- "ask Grok…" in the chat, the buddy sends your words (only your words) to the bot named
-- in grok.bot through the gbot CLI and brings the reply back. Grok can borrow Claude Opus
-- through bin/buddy-opus, which the footer of every message tells it about.

local G = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local OPUS = DIR .. "/bin/buddy-opus"

local DEFAULTS = { bot = "Grok Bot", app = "Grok Bot", opus_daily_cap = 10, approve_timeout = 600,
                   wait = 900, poll = 10 } -- wait: seconds to wait for a reply; poll: seconds between looks

function G.configure(cfg, owner)
  G.cfg = {}
  for k, v in pairs(DEFAULTS) do G.cfg[k] = v end
  for k, v in pairs(cfg or {}) do G.cfg[k] = v end
  G.owner = (owner or "") ~= "" and owner or "the owner"
  return G
end

-- Does this chat message ask for Grok? "ask/have/tell Grok…", "get Grok to…" or "Grok, …".
-- Frontier patterns keep "task grokking" and "grokking" out.
function G.isFor(text)
  local s = (text or ""):lower()
  if s:find("^%s*grok%s*,") then return true end
  for _, verb in ipairs({ "ask", "have", "tell" }) do
    if s:find("%f[%a]" .. verb .. "%s+grok%f[%A]") then return true end
  end
  return s:find("%f[%a]get%s+grok%s+to%f[%A]") ~= nil
end

-- The message Grok gets: a header with the marker, the owner's words untouched, and how to
-- borrow Opus.
function G.wrap(text, marker)
  local o = G.owner
  return string.format("[buddy:%s] From Buddy, the Claude that lives on %s's Mac. %s asks:\n%s\n"
    .. "(Need Claude Opus 5.5 for this? On %s's Mac run: %s ask \"<your request>\". It reads and thinks freely; "
    .. "anything that changes files, runs commands or sends something waits for %s's OK. Daily cap applies. "
    .. "Long jobs: add --async, then %s result <id>.)", marker, o, o, text, o, OPUS, o, OPUS)
end

-- The bot's answer in a gbot thread: the earliest bot message after the send, or the
-- earliest one that quotes the marker if there is one.
function G.pickReply(entries, sentAtMs, marker)
  local tag, first, tagged = "[buddy:" .. marker .. "]", nil, nil
  for _, e in ipairs(entries or {}) do
    local text = e.text or e.content
    if e.kind == "message" and e.role ~= "user" and (e.timestampMs or 0) > sentAtMs and type(text) == "string" then
      if not first or e.timestampMs < first.timestampMs then first = e end
      if text:find(tag, 1, true) and (not tagged or e.timestampMs < tagged.timestampMs) then tagged = e end
    end
  end
  local pick = tagged or first
  return pick and (pick.text or pick.content) or nil
end

-- The first sentence, at most 120 bytes, for the speech bubble.
function G.short(text)
  local s = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local stop = s:find("[%.!?]%s")
  if stop then s = s:sub(1, stop) end
  if #s <= 120 then return s end
  local cut = s:sub(1, 117)
  local space = cut:match("^.*()%s")
  if space and space > 60 then cut = cut:sub(1, space - 1) end
  return cut .. "…"
end

-- Asking ------------------------------------------------------------------------------

local HOME = os.getenv("HOME") or ""
local PATH = HOME .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" -- gbot needs node

local function firstLine(s) return ((s or ""):match("[^\n]+") or ""):sub(1, 120) end

-- gbot's thread JSON as a list of entries, whatever it wraps them in.
local function entriesOf(out)
  local ok, v = pcall(hs.json.decode, out or "")
  if not ok or type(v) ~= "table" then return {} end
  return v.messages or v.entries or v.items or v.thread or v
end

local SEND_LIMIT, READ_LIMIT = 110, 30 -- seconds a gbot send or thread read may take

-- Run gbot; done(code, out, err) exactly once. Stops it after `limit` seconds (code -2).
-- A gbot that can't be started at all gives code -1 and says where it looked.
local function run(args, limit, done)
  local called = false
  local function once(code, out, err)
    if called then return end
    called = true
    if G.killTimer then G.killTimer:stop(); G.killTimer = nil end
    done(code, out or "", err or "")
  end
  local missing = "can't run gbot at " .. tostring(G.cfg.gbot)
  local ok, task = pcall(hs.task.new, G.cfg.gbot, function(code, out, err) once(code, out, err) end, args)
  if not ok or not task then return once(-1, "", missing) end
  task:setEnvironment({ HOME = HOME, PATH = PATH, -- keychain lookups need USER
    USER = os.getenv("USER"), LOGNAME = os.getenv("LOGNAME"), TMPDIR = os.getenv("TMPDIR") })
  G.task = task -- keep it from being garbage collected
  if not task:start() then return once(-1, "", missing) end
  G.killTimer = hs.timer.doAfter(limit, function()
    if task:isRunning() then task:terminate() end
    once(-2, "", "gbot didn't answer in " .. limit .. " s")
  end)
end

-- gbot --json output as a table, or nil.
local function decode(out)
  local ok, v = pcall(hs.json.decode, out or "")
  return ok and type(v) == "table" and v or nil
end

-- Why gbot said no, from its JSON error or its stderr.
local function whyOf(res, err)
  local e = res and res.error
  return firstLine(tostring(type(e) == "table" and e.message or e or err))
end

-- The newest message time in a thread, so replies from before this ask don't count.
local function newestMs(entries)
  local n = 0
  for _, e in ipairs(entries) do if (e.timestampMs or 0) > n then n = e.timestampMs end end
  return n
end

function G.busy() return G.inflight == true end

-- Send the owner's words to Grok once, then look for the reply every cfg.poll seconds,
-- giving up cfg.wait seconds after the ask. hooks.status(kind, detail): sending, waiting,
-- reply (detail = the reply), unknown (no reply in time, maybe not delivered), error
-- (detail = why; nothing was sent). Never sends twice: a send that fails without saying
-- what happened may still have gone, so it only waits for a reply. Returns false if busy.
function G.ask(text, hooks)
  if G.inflight then return false end
  local cfg = G.cfg
  if not cfg.gbot then
    hooks.status("error", "Grok's not hooked up yet: config.lua grok.gbot is missing.")
    return true
  end
  G.inflight = true
  G.gen = (G.gen or 0) + 1
  local gen = G.gen
  G.marker = string.format("%x%03d", os.time(), math.random(0, 999))
  local marker = G.marker
  local function live() return G.gen == gen and G.inflight end
  local function finish(kind, detail)
    if not live() then return end -- a late callback after the ask ended
    G.inflight = false
    for _, k in ipairs({ "pollTimer", "deadlineTimer", "killTimer" }) do
      if G[k] then G[k]:stop(); G[k] = nil end
    end
    if G.task and G.task:isRunning() then G.task:terminate() end
    hooks.status(kind, detail)
  end
  G.deadlineTimer = hs.timer.doAfter(cfg.wait, function() finish("unknown") end)

  local function later(fn) G.pollTimer = hs.timer.doAfter(cfg.poll, function() if live() then fn() end end) end

  local function look(after)
    run({ "thread", "--json", "--limit", "10", "--", cfg.bot }, READ_LIMIT, function(_, out)
      if not live() then return end
      local reply = G.pickReply(entriesOf(out), after, marker)
      if reply then return finish("reply", reply) end
      later(function() look(after) end)
    end)
  end

  local function send(after)
    hooks.status("sending")
    run({ "send", "--json", "--reply-mode", "manual", "--", cfg.bot, G.wrap(text, marker) }, SEND_LIMIT,
      function(code, out, err)
        if not live() then return end
        local res = decode(out)
        if code == -1 or (res and res.error and not res.delivery) then -- definitely not sent
          return finish("error", "Couldn't reach Grok: " .. whyOf(res, err))
        end
        hooks.status("waiting", res and res.delivery or "unknown")
        later(function() look(after) end)
      end)
  end

  -- Read the thread first: only messages newer than what's already there can be the reply.
  local function start()
    run({ "thread", "--json", "--limit", "10", "--", cfg.bot }, READ_LIMIT, function(code, out, err)
      if not live() then return end
      local res = decode(out)
      if code == -1 or (res and res.error) then
        return finish("error", "Couldn't reach Grok: " .. whyOf(res, err))
      end
      send(math.max(newestMs(entriesOf(out)), (os.time() - 5) * 1000))
    end)
  end

  if cfg.app and not hs.application.get(cfg.app) then -- open it in the background first
    hs.task.new("/usr/bin/open", nil, { "-g", "-a", cfg.app }):start()
    G.pollTimer = hs.timer.doAfter(8, function() if live() then start() end end)
  else
    start()
  end
  return true
end

return G
