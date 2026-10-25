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
local sendQueue, sending = {}, false
local sendGen = 0       -- stopped sends must not advance a later queue
local options = {}
local awake
local commandKey = "claudeBuddy.telegramCommands"
local voiceSerial = 0

local function now() return hs.timer.secondsSinceEpoch() end

local function resetSends()
  sendGen = sendGen + 1
  if T.sendTimer then T.sendTimer:stop(); T.sendTimer = nil end
  sendQueue, sending = {}, false
end

function T.validToken(s) return type(s) == "string" and s:match("^%d+:[%w_%-]+$") ~= nil end
function T.botId(tok) return (tok or ""):match("^(%d+):") end

-- One Bot API call: done(result), or done(nil, why, status, retryAfter).
local function call(tok, method, params, done)
  local body = params and hs.json.encode(params) or nil
  T.http(T.api .. "/bot" .. tok .. "/" .. method, body and "POST" or "GET", body,
    body and { ["Content-Type"] = "application/json" } or {}, function(status, resp)
      local ok, d = pcall(hs.json.decode, resp or "")
      if ok and type(d) == "table" and d.ok then return done(d.result) end
      local retry = ok and type(d) == "table" and type(d.parameters) == "table"
        and tonumber(d.parameters.retry_after) or nil
      done(nil, ok and type(d) == "table" and d.description or ("HTTP " .. tostring(status)), status, retry)
    end)
end

-- What an update means for Buddy: nil unless it's a message in the private chat with
-- `chat`, else { text = ... }, { voice = file_id }, or { other = true } for photos,
-- stickers and the rest. date: when it was sent (seconds since 1970). reply_to: the id of
-- the message it answers, when you swiped to reply to one.
function T.parse(update, chat)
  local q = type(update) == "table" and update.callback_query
  if type(q) == "table" then
    local m = q.message
    if type(q.from) == "table" and math.tointeger(q.from.id) == chat
      and type(m) == "table" and type(m.chat) == "table"
      and m.chat.type == "private" and math.tointeger(m.chat.id) == chat
      and type(q.id) == "string" and type(q.data) == "string" then
      return { callback = q.data, query = q.id, message_id = math.tointeger(m.message_id), thread = math.tointeger(m.message_thread_id) }
    end
    return nil
  end
  local m = type(update) == "table" and update.message
  if type(m) ~= "table" or type(m.chat) ~= "table" then return nil end
  if m.chat.type ~= "private" or math.tointeger(m.chat.id) ~= chat then return nil end
  local date = tonumber(m.date) or 0
  local r = type(m.reply_to_message) == "table" and math.tointeger(m.reply_to_message.message_id) or nil
  local common = { date = date, reply_to = r, message_id = math.tointeger(m.message_id), thread = math.tointeger(m.message_thread_id) }
  if type(m.text) == "string" then common.text = m.text; return common end
  local v = type(m.voice) == "table" and m.voice or type(m.audio) == "table" and m.audio
  if v and type(v.file_id) == "string" then common.voice, common.secs = v.file_id, tonumber(v.duration); return common end
  local photos = type(m.photo) == "table" and m.photo
  if photos then
    local chosen, area = nil, -1
    for _, p in ipairs(photos) do
      local size = math.max(tonumber(p.width) or 0, tonumber(p.height) or 0)
      local a = (tonumber(p.width) or 0) * (tonumber(p.height) or 0)
      if type(p.file_id) == "string" and ((size <= 1600 and (not chosen or chosen.big or a > area))
          or (not chosen and a > area) or (chosen and chosen.big and a > area)) then
        chosen, area = { file_id = p.file_id, big = size > 1600 }, a
      end
    end
    if chosen then common.photo, common.caption = chosen.file_id, m.caption; return common end
  end
  local doc = type(m.document) == "table" and m.document
  if doc and type(doc.file_id) == "string" and type(doc.mime_type) == "string"
    and doc.mime_type:match("^image/") then common.photo, common.caption = doc.file_id, m.caption; return common end
  common.other = true
  return common
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

-- Short thanks and hearts need no model call; longer messages count when they name Buddy.
function T.affection(text)
  local s = (text or ""):lower()
  if #s >= 60 and not s:find("buddy", 1, true) then return false end
  for _, word in ipairs({ "good bot", "good buddy", "thank you", "thanks", "ily", "love you", "<3",
    "❤️", "🥰", "😍", "💕", "💖" }) do
    if s:find(word, 1, true) then return true end
  end
  return s:match("%f[%a]ty%f[%A]") ~= nil
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
  call(token, "getUpdates", { offset = offset, timeout = LONG_POLL, allowed_updates = { "message", "callback_query" } }, function(updates, why, status)
    if g ~= gen then return end
    if type(updates) == "table" then
      backoff, lastOk, lastError = 0, now(), nil
      local got = {}
      for _, u in ipairs(updates) do
        local id = math.tointeger(u.update_id)
        if id and id >= offset then offset = id + 1 end
        local m = T.parse(u, chatId)
        if m and (m.callback or m.date >= since) then got[#got + 1] = m end
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
  resetSends()
  gen = gen + 1
  local startGen = gen
  options = type(cfg) == "table" and cfg or {}
  awake = nil
  token = nil
  chatId = math.tointeger(tonumber(options.chat_id))
  onMessage, onTrouble = message, trouble
  if not chatId then return T end
  local tries = 0
  local function load()
    T.loadToken(function(tok)
      if startGen ~= gen then return end
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
      T.setAwake(true)
      if options.commands then T.commands(options.commands) end
    end)
  end
  load()
  -- a long poll doesn't survive sleep; start a fresh one on wake instead of waiting out the retry
  T.wakeWatcher = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake then T.resume(); T.setAwake(true)
    elseif ev == hs.caffeinate.watcher.systemWillSleep then T.setAwake(false) end
  end):start()
  local previous = hs.shutdownCallback
  hs.shutdownCallback = function() T.setAwake(false, true); if previous then previous() end end
  return T
end

function T.running() return token ~= nil and chatId ~= nil end

-- Stop everything: polling, pairing, the typing dots and the wake watcher.
function T.stop()
  gen = gen + 1
  resetSends()
  for _, k in ipairs({ "retryTimer", "keyTimer", "typingTimer", "pairTimer", "wakeWatcher", "sendTimer" }) do
    if T[k] then T[k]:stop(); T[k] = nil end
  end
  token, chatId, onMessage, onTrouble = nil, nil, nil, nil
end

-- Send text to the paired chat, piece by piece in order; done(ok, ids) after the last one,
-- ids being the message id of each piece (so a reply to one of them can be traced back).
local function buttons(rows)
  if rows == false then return { inline_keyboard = {} } end
  if type(rows) ~= "table" then return nil end
  local out = {}
  for _, row in ipairs(rows) do
    local r = {}
    for _, b in ipairs(row) do
      if type(b.text) == "string" and type(b.data) == "string" and #b.data <= 64 then
        r[#r + 1] = { text = b.text, callback_data = b.data }
      end
    end
    if #r > 0 then out[#out + 1] = r end
  end
  return { inline_keyboard = out }
end

local function pump()
  if sending or #sendQueue == 0 then return end
  sending = true
  local g = sendGen
  local item = sendQueue[1]
  local i, ids = 1, {}
  local function finish(ok)
    if g ~= sendGen then return end
    table.remove(sendQueue, 1)
    sending = false
    if item.done then item.done(ok, ids) end
    pump()
  end
  local function piece()
    if g ~= sendGen then return end
    if i > #item.parts then return finish(true) end
    local params = { chat_id = chatId, text = item.parts[i] }
    if item.opts.thread then params.message_thread_id = item.opts.thread end
    if item.opts.reply_to and i == 1 then params.reply_parameters = { message_id = item.opts.reply_to } end
    if item.opts.buttons and i == #item.parts then params.reply_markup = buttons(item.opts.buttons) end
    local floods, network = 0, 0
    local function attempt()
      if g ~= sendGen then return end
      call(token, "sendMessage", params, function(r, why, status, retry)
        if g ~= sendGen then return end
        if r then
          local id = type(r) == "table" and math.tointeger(r.message_id)
          if id then ids[#ids + 1] = id end
          i = i + 1
          return piece()
        end
        if status == 429 and floods < 3 then
          floods = floods + 1
          T.sendTimer = hs.timer.doAfter(math.max(1, retry or 1), attempt)
        elseif (not status or status <= 0) and network < 2 then
          network = network + 1
          T.sendTimer = hs.timer.doAfter(network, attempt)
        else
          print("ClaudeBuddy telegram: couldn't send: " .. tostring(why))
          finish(false)
        end
      end)
    end
    attempt()
  end
  piece()
end

function T.send(text, done, opts)
  if not T.running() then return done and done(false, {}) end
  sendQueue[#sendQueue + 1] = { parts = T.chunks(text), done = done, opts = opts or {} }
  pump()
end

function T.sendParts(parts, done, opts)
  if not T.running() then return done and done(false, {}) end
  sendQueue[#sendQueue + 1] = { parts = parts, done = done, opts = opts or {} }
  pump()
end

function T.answer(id, text)
  if T.running() then call(token, "answerCallbackQuery", { callback_query_id = id, text = text }, function() end) end
end

function T.edit(id, text, rows, done)
  if not T.running() then return done and done(false) end
  local p = { chat_id = chatId, message_id = id, text = text }
  if rows ~= nil then p.reply_markup = buttons(rows) end
  call(token, "editMessageText", p, function(r) if done then done(r ~= nil and r ~= false) end end)
end

function T.draft(id, text, thread, done)
  if not T.running() then return done(false) end
  local p = { chat_id = chatId, draft_id = id, text = text }
  if thread then p.message_thread_id = thread end
  call(token, "sendMessageDraft", p, function(r) done(r ~= nil and r ~= false) end)
end

-- A chat answer owns one preview. A draft has no message id; an edited preview does.
-- Final delivery happens in one path, even if a preview request is still in flight.
function T.stream(mode, thread, onFirst)
  T.draftSerial = (T.draftSerial or 0) + 1
  local s = { mode = mode == "draft" and "draft" or "edit", thread = thread,
    raw = "", started = now(), lastAt = 0, lastText = "", busy = false,
    draftId = (math.floor(now() * 1000) + T.draftSerial) % 2147483647 }
  local function first()
    if not s.first then s.first = true; if onFirst then onFirst() end end
  end
  local function complete(ok)
    if s.finished then return end
    s.finished = true
    if s.timer then s.timer:stop(); s.timer = nil end
    if s.done then s.done(ok) end
  end
  local function sendFinal()
    if s.finished then return end
    first()
    T.send(s.final, function(ok) complete(ok) end, { thread = thread })
  end
  local flush
  local function schedule(delay)
    if s.timer then s.timer:stop() end
    s.timer = hs.timer.doAfter(delay, function() s.timer = nil; flush() end)
  end
  flush = function()
    if s.busy or s.finished then return end
    if s.final then
      if s.mode == "draft" or not s.id or s.failed then return sendFinal() end
      local parts = T.chunks(s.final)
      if #parts == 0 then return complete(false) end
      local function rest()
        if #parts == 1 then return complete(true) end
        table.remove(parts, 1)
        T.sendParts(parts, function(ok) complete(ok) end, { thread = thread })
      end
      if s.lastText == parts[1] then return rest() end
      if s.lastAt > 0 and now() - s.lastAt < 1.5 then return schedule(1.5 - (now() - s.lastAt)) end
      s.busy = true
      return T.edit(s.id, parts[1], nil, function(ok)
        s.busy = false
        if not ok then s.failed = true; return sendFinal() end
        rest()
      end)
    end
    if s.raw == "" or (not s.first and (utf8.len(s.raw) or #s.raw) < 40
      and now() - s.started < 1.5) then return end
    local preview = T.chunks(s.raw)[1]
    if not preview or preview == s.lastText then return end
    if s.lastAt > 0 and now() - s.lastAt < 1.5 then return schedule(1.5 - (now() - s.lastAt)) end
    s.busy = true
    if s.mode == "draft" then
      T.draft(s.draftId, preview, thread, function(ok)
        s.busy = false
        if not ok then s.mode = "edit"; return flush() end
        s.lastText, s.lastAt = preview, now()
        first()
        flush()
      end)
    elseif not s.id and not s.failed then
      T.send(preview, function(ok, ids)
        s.busy = false
        if ok and ids and ids[1] then
          s.id, s.lastText, s.lastAt = ids[1], preview, now()
          first()
        else s.failed = true end
        flush()
      end, { thread = thread })
    elseif s.id and not s.failed then
      T.edit(s.id, preview, nil, function(ok)
        s.busy = false
        if not ok then s.failed = true; return flush() end
        s.lastText, s.lastAt = preview, now()
        flush()
      end)
    end
  end
  function s:update(delta)
    if self.finished or self.final then return end
    self.raw = self.raw .. delta
    flush()
  end
  function s:finish(final, done)
    if self.finished or self.final then return end
    self.final, self.done = final, done
    if self.timer then self.timer:stop(); self.timer = nil end
    flush()
  end
  schedule(1.5)
  return s
end

-- Private-chat topics use the same Bot API fields as forums (also used by Hermes).
-- A chat without Topics enabled is tried again tomorrow, rather than on every task.
function T.createTopic(name, done)
  if not T.running() or options.topics == false then return done(nil) end
  local key = T.offsetKey .. ".noTopics." .. T.botId(token) .. "." .. chatId
  if (tonumber(hs.settings.get(key)) or 0) > now() then return done(nil) end
  call(token, "createForumTopic", { chat_id = chatId, name = name }, function(r)
    local thread = type(r) == "table" and math.tointeger(r.message_thread_id)
    if not thread or thread <= 0 then
      hs.settings.set(key, now() + 86400)
      return done(nil)
    end
    done(thread)
  end)
end

function T.editTopic(thread, name)
  if not T.running() then return end
  call(token, "editForumTopic", { chat_id = chatId, message_thread_id = thread, name = name }, function() end)
end

function T.react(id, emoji)
  if not T.running() or options.reactions == false or not id then return end
  call(token, "setMessageReaction", { chat_id = chatId, message_id = id,
    reaction = { { type = "emoji", emoji = emoji } } }, function() end)
end

function T.commands(entries)
  if not T.running() then return end
  local list, marks = {}, {}
  for _, e in ipairs(entries or {}) do
    if e.on ~= false and type(e.command) == "string" and type(e.description) == "string" then
      list[#list + 1] = { command = e.command, description = e.description }
      marks[#marks + 1] = e.command .. ":" .. e.description
    end
  end
  local signature = table.concat(marks, "\n")
  local key = commandKey .. "." .. T.botId(token)
  if hs.settings.get(key) == signature then return end
  call(token, "setMyCommands", { commands = list }, function(r)
    if r then hs.settings.set(key, signature) end
  end)
end

function T.setAwake(value, shutdown)
  if not T.running() or options.status == false or awake == value then return end
  awake = value
  local params = { short_description = value
    and "🟢 The Mac is awake. Text me!" or "💤 The Mac is asleep. I'll answer when it wakes." }
  if shutdown then
    -- Hammerspoon cannot finish asynchronous work once shutdownCallback returns.
    pcall(hs.http.doRequest, T.api .. "/bot" .. token .. "/setMyShortDescription", "POST",
      hs.json.encode(params), { ["Content-Type"] = "application/json" })
  else
    call(token, "setMyShortDescription", params, function() end)
  end
end

-- Speech is a second, optional reply. The token is in curl's stdin config, never argv.
function T.voiceReply(text, thread, done)
  done = done or function() end
  local function fail(why) print("ClaudeBuddy telegram voice: " .. why); done(false, why) end
  if not T.running() then return fail("Telegram isn't connected") end
  local ffmpeg = T.ffmpeg()
  if not ffmpeg then return fail("ffmpeg isn't installed") end
  local spoken = (text or ""):gsub("https?://%S+", ""):gsub("%b[]%b()", "")
    :gsub("[`*_#>]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #spoken > 1200 then
    local cut = spoken:sub(1, 1200):match("^.*()[.!?]%s")
    spoken = spoken:sub(1, cut or 1200)
  end
  if spoken == "" then return fail("nothing to say") end
  local tmp = hs.fs.temporaryDirectory() or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  voiceSerial = voiceSerial + 1
  local base = tmp .. "buddy-voice-" .. tostring(math.floor(now() * 1000)) .. "-" .. voiceSerial
  local input, output = base .. ".txt", base .. ".aiff"
  local ogg = base .. ".ogg"
  local files = { input, output, ogg }
  local function finish(ok, why)
    for _, p in ipairs(files) do os.remove(p) end
    if not ok then print("ClaudeBuddy telegram voice: " .. tostring(why)) end
    done(ok, why)
  end
  local file = io.open(input, "wb")
  if not file then return finish(false, "couldn't write speech input") end
  file:write(spoken); file:close()
  local cmd = type(options.tts) == "table" and options.tts or { "/usr/bin/say", "-f", "{in}", "-o", "{out}" }
  if type(cmd[1]) ~= "string" or cmd[1]:sub(1, 1) ~= "/" then return finish(false, "invalid speech command") end
  local args = {}
  for i = 2, #cmd do
    if type(cmd[i]) ~= "string" then return finish(false, "invalid speech argument") end
    args[#args + 1] = cmd[i]:gsub("{in}", input):gsub("{out}", output)
  end
  local function run(path, argv, stdin, callback)
    local task
    task = hs.task.new(path, function(code, stdout, stderr)
      tasks[task] = nil
      callback(code == 0, stdout, stderr)
    end, argv)
    if not task then return callback(false) end
    if stdin then task:setInput(stdin) end
    tasks[task] = true
    if not task:start() then tasks[task] = nil; callback(false) end
  end
  run(cmd[1], args, nil, function(ok)
    if not ok then return finish(false, "text to speech failed") end
    run(ffmpeg, { "-hide_banner", "-loglevel", "error", "-i", output,
      "-c:a", "libopus", "-b:a", "32k", "-ac", "1", "-y", ogg }, nil, function(converted)
      if not converted then return finish(false, "ffmpeg conversion failed") end
      local url = T.api .. "/bot" .. token .. "/sendVoice"
      local safeUrl = url:gsub("\\", "\\\\"):gsub('"', '\\"')
      local curlConfig = 'url = "' .. safeUrl .. '"\n'
      local argv = { "-sS", "-K", "-", "-F", "chat_id=" .. chatId, "-F", "voice=@" .. ogg }
      if thread then argv[#argv + 1] = "-F"; argv[#argv + 1] = "message_thread_id=" .. thread end
      run("/usr/bin/curl", argv, curlConfig, function(uploaded, body)
        local parsed, reply = pcall(hs.json.decode, body or "")
        local okay = uploaded and parsed and type(reply) == "table" and reply.ok == true
        finish(okay, okay and nil or "voice upload failed")
      end)
    end)
  end)
end

function T.ffmpeg()
  return dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/dictate.lua").ffmpeg()
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
      if status ~= 200 or type(body) ~= "string" or body == "" or #body > MAX_FILE then
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
