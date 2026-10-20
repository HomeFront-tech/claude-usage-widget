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

local function run(args, done)
  local task = hs.task.new(G.cfg.gbot, function(code, out, err) done(code, out, err) end, args)
  task:setEnvironment({ HOME = HOME, PATH = PATH })
  G.task = task -- keep it from being garbage collected
  if not task:start() then done(-1, "", "couldn't start gbot") end
end

function G.busy() return G.inflight == true end

-- Send the owner's words to Grok once, then look for the reply every cfg.poll seconds for
-- up to cfg.wait seconds. hooks.status(kind, detail): sending, waiting, reply (detail = the
-- reply), unknown (no reply in time), error (detail = why). Never sends twice: a send
-- whose delivery is unknown still only waits for a reply. Returns false if busy.
function G.ask(text, hooks)
  if G.inflight then return false end
  local cfg = G.cfg
  if not cfg.gbot then
    hooks.status("error", "Grok's not hooked up yet: config.lua grok.gbot is missing.")
    return true
  end
  G.inflight = true
  G.marker = string.format("%x%03d", os.time(), math.random(0, 999))
  local marker = G.marker
  local function finish(kind, detail)
    G.inflight = false
    if G.pollTimer then G.pollTimer:stop(); G.pollTimer = nil end
    hooks.status(kind, detail)
  end

  local function look(sentAtMs, deadline)
    run({ "thread", "--json", "--limit", "10", "--", cfg.bot }, function(_, out)
      local reply = G.pickReply(entriesOf(out), sentAtMs, marker)
      if reply then return finish("reply", reply) end
      if os.time() >= deadline then return finish("unknown") end
      G.pollTimer = hs.timer.doAfter(cfg.poll, function() look(sentAtMs, deadline) end)
    end)
  end

  local function send()
    hooks.status("sending")
    local sentAtMs = (os.time() - 5) * 1000
    run({ "send", "--json", "--reply-mode", "manual", "--", cfg.bot, G.wrap(text, marker) }, function(code, out, err)
      local ok, res = pcall(hs.json.decode, out or "")
      local delivery = ok and type(res) == "table" and res.delivery or nil
      if code ~= 0 and not delivery then
        return finish("error", "Couldn't reach Grok: " .. firstLine(err ~= "" and err or out))
      end
      hooks.status("waiting", delivery)
      G.pollTimer = hs.timer.doAfter(cfg.poll, function() look(sentAtMs, os.time() + cfg.wait) end)
    end)
  end

  if cfg.app and not hs.application.get(cfg.app) then -- open it in the background first
    hs.task.new("/usr/bin/open", nil, { "-g", "-a", cfg.app }):start()
    G.pollTimer = hs.timer.doAfter(8, send)
  else
    send()
  end
  return true
end

return G
