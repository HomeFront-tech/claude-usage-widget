-- Telegram for the Claude buddy (Hammerspoon module)
--
-- Text Buddy from your phone. You make your own bot with @BotFather and the setup wizard
-- pairs it with your Telegram account: only that one private chat gets answers, and
-- everything else sent to the bot is ignored. Buddy keeps a long poll open to Telegram's
-- Bot API, so there's no server and nothing listening on this Mac, but the Mac has to be
-- awake to answer. buddy.lua answers each message through the brain, in the same
-- conversation as the chat panel. The bot token lives in the macOS Keychain, never in
-- config.lua. Off unless config.lua has a telegram table with a chat_id; see
-- config.example.lua. Check on it: hs -c 'return ClaudeBuddy.telegramStatus()'

local T = {}

T.api = "https://api.telegram.org"
T.security = "/usr/bin/security"
T.http = function(url, method, body, headers, done) hs.http.doAsyncRequest(url, method, body, headers, done) end

local SERVICE = "claude-buddy-telegram" -- the Keychain item that holds the bot token
local ACCOUNT = (os.getenv("USER") or ""):match("^[%w._-]+$") or "buddy"
T.offsetKey = "claudeBuddy.telegramOffset" -- { bot = id, offset = next update }, so a reload doesn't answer twice
local LONG_POLL = 25    -- seconds Telegram holds each getUpdates open
local PAIR_FOR = 600    -- seconds the wizard waits for the pairing code
local MAX_TEXT = 4096   -- Telegram's limit for one message
local MAX_FILE = 10 * 1024 * 1024 -- the biggest voice note it downloads

local token, chatId, onMessage, onTrouble
local gen = 0           -- each polling loop runs while gen still matches; bumping it stops the loop
local offset, since = 0, 0
local backoff, lastOk, lastError = 0, 0, nil
local tasks = {}        -- running Keychain tasks, kept from garbage collection

local function now() return hs.timer.secondsSinceEpoch() end

function T.validToken(s) return type(s) == "string" and s:match("^%d+:[%w_%-]+$") ~= nil end
function T.botId(tok) return (tok or ""):match("^(%d+):") end

-- One Bot API call: done(result), or done(nil, why, status).
local function call(tok, method, params, done)
  local body = params and hs.json.encode(params) or nil
  T.http(T.api .. "/bot" .. tok .. "/" .. method, body and "POST" or "GET", body,
    body and { ["Content-Type"] = "application/json" } or {}, function(status, resp)
      local ok, d = pcall(hs.json.decode, resp or "")
      if ok and type(d) == "table" and d.ok then return done(d.result) end
      done(nil, ok and type(d) == "table" and d.description or ("HTTP " .. tostring(status)), status)
    end)
end

-- What an update means for Buddy: nil unless it's a message in the private chat with
-- `chat`, else { text = ... }, { voice = file_id }, or { other = true } for photos,
-- stickers and the rest. date: when it was sent (seconds since 1970). reply_to: the id of
-- the message it answers, when you swiped to reply to one.
function T.parse(update, chat)
  local m = type(update) == "table" and update.message
  if type(m) ~= "table" or type(m.chat) ~= "table" then return nil end
  if m.chat.type ~= "private" or math.tointeger(m.chat.id) ~= chat then return nil end
  local date = tonumber(m.date) or 0
  local r = type(m.reply_to_message) == "table" and math.tointeger(m.reply_to_message.message_id) or nil
  if type(m.text) == "string" then return { text = m.text, date = date, reply_to = r } end
  local v = type(m.voice) == "table" and m.voice or type(m.audio) == "table" and m.audio
  if v and type(v.file_id) == "string" then return { voice = v.file_id, secs = tonumber(v.duration), date = date, reply_to = r } end
  return { other = true, date = date }
end

-- "/usage", "/usage@MyBuddyBot" or "/start hi" -> "usage" / "start"; nil when it isn't a command.
function T.command(text)
  local c = (text or ""):match("^%s*/(%a+)")
  return c and c:lower() or nil
end

-- Does a message carry the pairing code? "/start 123456", "123456" and "it's 123456" do.
function T.hasCode(text, code)
  for digits in (text or ""):gmatch("%d+") do
    if digits == code then return true end
  end
  return false
end

-- Text in pieces Telegram takes, cut at a line break or a space when there's one in the
-- second half of the piece, and never inside a UTF-8 character.
function T.chunks(text, max)
  max = max or MAX_TEXT
  text = text or ""
  local out = {}
  while #text > max do
    local cut = max
    while cut > 1 and (text:byte(cut + 1) or 0) >= 0x80 and text:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    local piece = text:sub(1, cut)
    local at = piece:match("^.*()\n") or piece:match("^.*() ")
    if at and at > max / 2 then cut = at end
    out[#out + 1] = (text:sub(1, cut):gsub("%s+$", ""))
    text = (text:sub(cut + 1):gsub("^%s+", ""))
  end
  if text:match("%S") then out[#out + 1] = text end
  return out
end

-- Keychain ----------------------------------------------------------------------------

local function security(args, input, done)
  local task
  local ok, created = pcall(hs.task.new, T.security, function(code, out)
    tasks[task] = nil
    done(code == 0, out or "")
  end, args)
  if not ok or not created then return done(false, "") end
  task = created
  if input then task:setInput(input) end
  tasks[task] = true
  if not task:start() then
    tasks[task] = nil
    done(false, "")
  end
end

-- done(token) or done(nil)
function T.loadToken(done)
  security({ "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w" }, nil, function(ok, out)
    local tok = ok and out:gsub("%s+$", "") or nil
    done(T.validToken(tok) and tok or nil)
  end)
end

-- Saved through security's own prompt on stdin, so the token never shows up in the
-- process list. done(true) once it reads back the same.
function T.saveToken(tok, done)
  if not T.validToken(tok) then return done(false) end
  security({ "-i" }, string.format("add-generic-password -U -s %s -a %s -w %s\n", SERVICE, ACCOUNT, tok), function()
    T.loadToken(function(back) done(back == tok) end)
  end)
end

function T.forgetToken(done)
  security({ "delete-generic-password", "-s", SERVICE, "-a", ACCOUNT }, nil, function()
    if done then done() end
  end)
end

-- Answering the paired chat -----------------------------------------------------------

local function saveOffset()
  hs.settings.set(T.offsetKey, { bot = T.botId(token), offset = offset })
end

local function deliver(m)
  local ok, err = pcall(onMessage, m)
  if not ok then print("ClaudeBuddy telegram: " .. tostring(err)) end
end

local function poll(g)
  if g ~= gen then return end
  call(token, "getUpdates", { offset = offset, timeout = LONG_POLL, allowed_updates = { "message" } }, function(updates, why, status)
    if g ~= gen then return end
    if type(updates) == "table" then
      backoff, lastOk, lastError = 0, now(), nil
      local got = {}
      for _, u in ipairs(updates) do
        local id = math.tointeger(u.update_id)
        if id and id >= offset then offset = id + 1 end
        local m = T.parse(u, chatId)
        if m and m.date >= since then got[#got + 1] = m end
      end
      if #updates > 0 then saveOffset() end
      for _, m in ipairs(got) do deliver(m) end
      return poll(g)
    end
    lastError = why
    if status == 401 or status == 404 then -- the token was revoked or the bot deleted
      gen = gen + 1
      print("ClaudeBuddy telegram: " .. tostring(why))
      if onTrouble then onTrouble("token") end
      return
    end
    -- 409: something else is polling this bot (another Mac, or a webhook)
    backoff = status == 409 and 30 or math.min(60, backoff > 0 and backoff * 2 or 2)
    T.retryTimer = hs.timer.doAfter(backoff, function() poll(g) end)
  end)
end

-- Start (or restart) the live loop right away.
function T.resume()
  if T.retryTimer then T.retryTimer:stop(); T.retryTimer = nil end
  if not (token and chatId and onMessage) then return end
  gen = gen + 1
  backoff = 0
  poll(gen)
end

-- Answer the chat in cfg (config.lua's telegram table). message(m) gets each message
-- from it (see T.parse); trouble(why) hears "keychain" (no token saved) or "token"
-- (Telegram turned it down) when it can't go on.
function T.start(cfg, message, trouble)
  chatId = math.tointeger(tonumber(type(cfg) == "table" and cfg.chat_id or nil))
  onMessage, onTrouble = message, trouble
  if not chatId then return T end
  local tries = 0
  local function load()
    T.loadToken(function(tok)
      tries = tries + 1
      if not tok and tries < 4 then T.keyTimer = hs.timer.doAfter(30, load); return end -- the Keychain can lag right after login
      if not tok then
        if onTrouble then onTrouble("keychain") end
        return
      end
      token = tok
      local saved = hs.settings.get(T.offsetKey)
      if type(saved) == "table" and saved.bot == T.botId(tok) and math.tointeger(saved.offset) then
        offset, since = math.tointeger(saved.offset), 0
      else
        offset, since = 0, os.time() - 60 -- no record of what was answered: skip the backlog
      end
      T.resume()
    end)
  end
  load()
  -- a long poll doesn't survive sleep; start a fresh one on wake instead of waiting out the retry
  T.wakeWatcher = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake then T.resume() end
  end):start()
  return T
end

function T.running() return token ~= nil and chatId ~= nil end

-- Stop everything: polling, pairing, the typing dots and the wake watcher.
function T.stop()
  gen = gen + 1
  for _, k in ipairs({ "retryTimer", "keyTimer", "typingTimer", "pairTimer", "wakeWatcher" }) do
    if T[k] then T[k]:stop(); T[k] = nil end
  end
end

-- Send text to the paired chat, piece by piece in order; done(ok, ids) after the last one,
-- ids being the message id of each piece (so a reply to one of them can be traced back).
function T.send(text, done)
  if not T.running() then return done and done(false, {}) end
  local parts, i, ids = T.chunks(text), 0, {}
  local function nextPart(ok)
    i = i + 1
    if not ok or i > #parts then return done and done(ok, ids) end
    call(token, "sendMessage", { chat_id = chatId, text = parts[i] }, function(r, why)
      if not r then print("ClaudeBuddy telegram: couldn't send: " .. tostring(why)) end
      local id = type(r) == "table" and math.tointeger(r.message_id)
      if id then ids[#ids + 1] = id end
      nextPart(r ~= nil)
    end)
  end
  nextPart(true)
end

-- "typing…" at the top of the chat while the brain thinks (Telegram shows it ~5 s per ping).
function T.typing(on)
  if T.typingTimer then T.typingTimer:stop(); T.typingTimer = nil end
  if not on or not T.running() then return end
  local pings = 0
  local function ping()
    pings = pings + 1
    if pings > 40 then return T.typing(false) end -- 3 minutes is long enough to look busy
    call(token, "sendChatAction", { chat_id = chatId, action = "typing" }, function() end)
  end
  ping()
  T.typingTimer = hs.timer.doEvery(4.5, ping)
end

-- Save a file someone sent (a voice note) to path: done(path) or done(nil, why).
function T.download(fileId, path, done)
  if not T.running() then return done(nil, "Telegram isn't connected.") end
  call(token, "getFile", { file_id = fileId }, function(f, why)
    if type(f) ~= "table" or type(f.file_path) ~= "string" then return done(nil, why or "Telegram didn't hand over the file.") end
    if (tonumber(f.file_size) or 0) > MAX_FILE then return done(nil, "That one's too long for me. Keep it under a few minutes?") end
    T.http(T.api .. "/file/bot" .. token .. "/" .. f.file_path, "GET", nil, {}, function(status, body)
      if status ~= 200 or type(body) ~= "string" or body == "" then
        return done(nil, "Couldn't download it (HTTP " .. tostring(status) .. ").")
      end
      local fh = io.open(path, "wb")
      if not fh then return done(nil, "Couldn't save it.") end
      fh:write(body)
      fh:close()
      done(path)
    end)
  end)
end

-- One line for hs -c 'return ClaudeBuddy.telegramStatus()'.
function T.status()
  if not chatId then return "Telegram: off" end
  if not token then return "Telegram: no token (set it up again in the wizard)" end
  local ago = lastOk > 0 and string.format("last answer from Telegram %d s ago", math.floor(now() - lastOk)) or "not reached Telegram yet"
  return "Telegram: on, " .. ago .. (lastError and (", last error: " .. lastError) or "")
end

-- Pairing (the setup wizard) ----------------------------------------------------------

-- Check tok, then wait up to 10 minutes for a private message carrying code. While it
-- waits, the live loop is stopped: Telegram allows one poller per bot.
-- report(kind, info): "bot" { username, name } once the token works, then "paired"
-- { chat_id, name, username } or "error" (text). T.cancelPair() stops waiting.
function T.pair(tok, code, report)
  if T.retryTimer then T.retryTimer:stop(); T.retryTimer = nil end
  gen = gen + 1
  local g = gen
  if not T.validToken(tok) then return report("error", "That doesn't look like a bot token. It's a number, a colon, then letters, like 123456789:AAH…") end
  call(tok, "getMe", nil, function(me, why, status)
    if g ~= gen then return end
    if type(me) ~= "table" then
      return report("error", (status == 401 or status == 404) and "Telegram doesn't know that token. Copy it again from BotFather."
        or ("Couldn't reach Telegram: " .. tostring(why)))
    end
    report("bot", { username = me.username, name = me.first_name })
    local started, deadline, at, misses = os.time() - 300, now() + PAIR_FOR, nil, 0 -- 300: room for a slow clock
    local function wait()
      if g ~= gen then return end
      if now() > deadline then
        gen = gen + 1
        return report("error", "I didn't get the code in 10 minutes. Press Connect to try again.")
      end
      call(tok, "getUpdates", { offset = at, timeout = 20, allowed_updates = { "message" } }, function(updates, err)
        if g ~= gen then return end
        if type(updates) ~= "table" then
          misses = misses + 1
          if misses >= 5 then gen = gen + 1; return report("error", "Lost Telegram while waiting: " .. tostring(err)) end
          T.pairTimer = hs.timer.doAfter(3, wait)
          return
        end
        misses = 0
        for _, u in ipairs(updates) do
          local id = math.tointeger(u.update_id)
          if id then at = id + 1 end
          local m = type(u.message) == "table" and u.message or {}
          local chat, from = type(m.chat) == "table" and m.chat or {}, type(m.from) == "table" and m.from or {}
          if chat.type == "private" and (tonumber(m.date) or 0) >= started and T.hasCode(m.text, code) then
            gen = gen + 1
            hs.settings.set(T.offsetKey, { bot = T.botId(tok), offset = at })
            local who = math.tointeger(chat.id)
            call(tok, "sendMessage", { chat_id = who, text = "Paired! It's Buddy, on your Mac. Text me anytime it's awake. "
              .. "/usage and /sessions are quick checks." }, function() end)
            return report("paired", { chat_id = who, name = from.first_name, username = from.username })
          end
        end
        wait()
      end)
    end
    wait()
  end)
end

-- Stop waiting for a pairing code, and pick the live chat back up if there is one.
function T.cancelPair()
  if T.pairTimer then T.pairTimer:stop(); T.pairTimer = nil end
  gen = gen + 1
  T.resume()
end

return T
