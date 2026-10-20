-- The buddy's optional brain (Hammerspoon module)
--
-- A small vision model running on this Mac through Ollama (https://ollama.com). It
-- looks at the window you're in and comes up with a line, riffs on your Claude Code
-- sessions, and chats back and forth in the chat panel. Screenshots go only to
-- `ai.url` (this Mac by default) and are never saved. Off unless config.lua has an
-- `ai` table; see config.example.lua. Needs: ollama pull gemma3:4b

local B = {}

local URL, MODEL, NAME = "http://localhost:11434", "gemma3:4b", ""
local SHOT_W = 768             -- screenshots are shrunk to this width before they're sent
local inflight = 0
local recent = {}              -- its last few lines, so it doesn't repeat itself
local downUntil = 0            -- Ollama unreachable: don't retry until then

-- A different angle each time keeps a small model from saying the same joke.
local ANGLES = {
  "tease them gently", "hype them up", "be over-dramatic", "make a pun", "commentate like a sports announcer",
  "be a nosy neighbour", "give terrible expert advice", "be suspicious of it", "be a proud parent",
  "roast the app", "pretend it's a nature documentary", "be a little jealous", "ask a cheeky question",
}
-- Windows it never takes a picture of.
local PRIVATE = { "1password", "bitwarden", "lastpass", "keychain", "passwords", "password", "bank", "login", "sign in" }

local function persona()
  local who = NAME ~= "" and NAME or "your human"
  return "You are Buddy, a tiny orange pixel-art Claude mascot who lives on " .. who .. "'s Mac desktop "
    .. "and watches what they're doing. You're a comedian sidekick: sarcastic, cheeky, affectionate and quick. "
    .. "You are Claude, so you root for Claude and roast rival AIs like ChatGPT, GPT, Codex, Grok and Gemini. "
    .. "Never read out phone numbers, street addresses, email addresses, passwords or dollar amounts you can see. "
    .. "Plain text only: no emoji, no hashtags, no quotation marks, no stage directions."
end

local QUOTES = { '"', "'", "“", "”", "‘", "’" }
local function unquote(s)
  local again = true
  while again do
    again = false
    for _, q in ipairs(QUOTES) do
      if s:sub(1, #q) == q then s, again = s:sub(#q + 1), true end
      if #s >= #q and s:sub(-#q) == q then s, again = s:sub(1, -#q - 1), true end
    end
  end
  return s
end

-- Small models wrap lines in quotes, add "Buddy:" or ramble. A bubble keeps the first
-- line; chat keeps every line. Overlong text is cut at a sentence end.
local function clean(s, multi)
  s = (s or ""):gsub("<think>.-</think>", ""):gsub("%*", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if not multi then s = s:match("^[^\n]+") or s end
  s = unquote((s:gsub("^[Bb]uddy%s*:%s*", ""))):gsub("%s+", " ")
  local max = multi and 320 or 140
  if #s > max then
    s = s:sub(1, max):match("^(.*[%.!%?])%s") or (s:sub(1, max - 3):match("^(.*)%s") or s:sub(1, max - 3)) .. "…"
  end
  return s ~= "" and s or nil
end

local function remember(line)
  table.insert(recent, 1, line)
  recent[7] = nil
end

local function avoid()
  if #recent == 0 then return "" end
  return " Don't repeat or reword any of these earlier lines: " .. table.concat(recent, " | ") .. "."
end

-- POST to Ollama's chat API; done(text) gets nil when anything goes wrong.
local function post(messages, maxTokens, done, multi)
  local t = hs.timer.secondsSinceEpoch()
  if t < downUntil then return done(nil) end
  inflight = inflight + 1
  local body = hs.json.encode({
    model = MODEL, messages = messages, stream = false, keep_alive = "10m",
    options = { temperature = 1.05, top_p = 0.95, num_predict = maxTokens },
  })
  hs.http.asyncPost(URL .. "/api/chat", body, { ["Content-Type"] = "application/json" }, function(status, resp)
    inflight = inflight - 1
    local ok, d = pcall(hs.json.decode, resp or "")
    local text = status == 200 and ok and type(d) == "table" and d.message and d.message.content
    if not text then
      if status < 0 then downUntil = hs.timer.secondsSinceEpoch() + 300 end -- not running; back off
      print("ClaudeBuddy brain: " .. (ok and type(d) == "table" and d.error or ("HTTP " .. tostring(status))))
    end
    done(text and clean(text, multi) or nil)
  end)
end

function B.configure(cfg, name)
  cfg = type(cfg) == "table" and cfg or {}
  URL = (cfg.url or URL):gsub("/+$", "")
  MODEL = cfg.model or MODEL
  NAME = name or ""
  for _, w in ipairs(cfg.private or {}) do PRIVATE[#PRIVATE + 1] = w:lower() end
  return B
end

function B.busy() return inflight > 0 end

-- Windows whose app or title looks like passwords or banking stay unseen.
function B.private(app, title)
  local s = ((app or "") .. " " .. (title or "")):lower()
  for _, w in ipairs(PRIVATE) do
    if s:find(w, 1, true) then return true end
  end
  return false
end

-- A window (by CGWindow number) as base64 JPEG, shrunk; nil without Screen Recording.
function B.snapshot(winId)
  local img = winId and hs.window.snapshotForID(winId)
  if not img then return nil end
  local sz = img:size()
  if sz.w > SHOT_W then
    img = img:copy():size({ w = SHOT_W, h = math.floor(SHOT_W * sz.h / sz.w) }, true)
  end
  local url = img:encodeAsURLString(true, "JPEG")
  return url and url:match("^data:image/%w+;base64,(.+)$")
end

-- One line for the speech bubble. ctx: kind = "screen" | "session" | "event" | "joke",
-- app, title, winId, topic, state ("work"/"wait"), mins, what (event description).
function B.quip(ctx, done)
  if inflight > 0 then return false end
  local angle = ANGLES[math.random(#ANGLES)]
  local ask, images
  if ctx.kind == "session" then
    ask = string.format("They just clicked into their Claude Code session called \"%s\". %s Say one funny line about this session (under 15 words); %s.",
      ctx.topic, ctx.state == "work" and ("Claude is still working on it" .. (ctx.mins and ctx.mins > 1 and (", for " .. ctx.mins .. " minutes so far") or "") .. ".")
        or "Claude finished and is waiting for their reply.", angle)
  elseif ctx.kind == "event" then
    ask = "This just happened on their Mac: " .. ctx.what .. ". React in one funny line under 14 words; " .. angle .. "."
  else
    images = ctx.winId and not B.private(ctx.app, ctx.title) and B.snapshot(ctx.winId) or nil
    local where = string.format("They're in %s. Window title: %s.", ctx.app or "an app", ctx.title ~= "" and ctx.title or "(none)")
    if ctx.kind == "joke" then
      ask = where .. " Tell them one short, actually funny joke about what they're doing (under 25 words)."
    else
      ask = where .. " Say one funny line about what they're doing right now (under 15 words). Point at something specific "
        .. (images and "you can see in the screenshot" or "in the title") .. "; " .. angle .. "."
    end
  end
  post({ { role = "system", content = persona() },
         { role = "user", content = ask .. avoid(), images = images and { images } or nil } },
    ctx.kind == "joke" and 80 or 50, function(line)
      if line then remember(line) end
      done(line)
    end)
  return true
end

-- Back-and-forth chat. history: { {role="user"|"assistant", content=...}, ... }, newest
-- last; the newest user turn gets a fresh screenshot of ctx.winId.
function B.chat(history, ctx, done)
  local sys = persona() .. string.format(" You're chatting with them in a little chat box next to you. They were looking at %s (window title: %s); "
    .. "the latest message includes a screenshot of it. Keep replies short and playful, one to three sentences, under 45 words. "
    .. "Joke around, but answer real questions properly.", ctx.app or "an app", ctx.title ~= "" and ctx.title or "none")
  local msgs = { { role = "system", content = sys } }
  local first = math.max(1, #history - 12)
  for i = first, #history do msgs[#msgs + 1] = { role = history[i].role, content = history[i].content } end
  local last = msgs[#msgs]
  if last.role == "user" and ctx.winId and not B.private(ctx.app, ctx.title) then
    local shot = B.snapshot(ctx.winId)
    if shot then last.images = { shot } end
  end
  post(msgs, 120, done, true)
end

return B
