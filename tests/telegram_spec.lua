-- telegram.lua: reading updates, commands, the pairing code, splitting long replies; then
-- the live loop and pairing against a fake Bot API, and the Keychain through a fake
-- security tool. Each case uses its own copy of the module and its own settings key, so
-- the live buddy's Telegram is never touched. Also: the brain's prompt for a phone message.
return function(t, dir)
  local oldShutdown = hs.shutdownCallback
  local function load()
    local T = dofile(dir .. "/telegram.lua")
    T.offsetKey = "claudeBuddy.test.telegramOffset." .. hs.host.uuid()
    return T
  end
  local T = load()

  -- reading updates
  local function upd(id, chat, fields)
    local m = { chat = chat, date = os.time(), from = { id = chat.id, first_name = "Sam" } }
    for k, v in pairs(fields or {}) do m[k] = v end
    return { update_id = id, message = m }
  end
  local mine, stranger = { id = 42, type = "private" }, { id = 43, type = "private" }
  t.eq(T.parse(upd(1, mine, { text = "hi" }), 42).text, "hi", "text from the paired chat")
  t.eq(T.parse(upd(1, stranger, { text = "hi" }), 42), nil, "a stranger is ignored")
  t.eq(T.parse(upd(1, { id = 42, type = "group" }, { text = "hi" }), 42), nil, "only the private chat counts")
  t.eq(T.parse({ update_id = 1, edited_message = { chat = mine, text = "x" } }, 42), nil, "edits are ignored")
  t.eq(T.parse(upd(1, mine, { voice = { file_id = "v1", duration = 3 } }), 42).voice, "v1", "voice note")
  t.eq(T.parse(upd(1, mine, { photo = { { file_id = "small", width = 320, height = 240 },
    { file_id = "large", width = 1280, height = 960 }, { file_id = "huge", width = 2048, height = 1536 } },
    caption = "Look", message_id = 8 }), 42).photo, "large", "largest photo under 1600 pixels")
  t.eq(T.parse(upd(1, mine, { photo = { { file_id = "big", width = 2000, height = 1000 },
    { file_id = "bigger", width = 3000, height = 2000 } } }), 42).photo, "bigger", "largest when all photos are big")
  t.eq(T.parse(upd(1, mine, { document = { file_id = "png", mime_type = "image/png" } }), 42).photo, "png", "image document")
  t.ok(T.parse(upd(1, mine, { document = { file_id = "pdf", mime_type = "application/pdf" } }), 42).other, "non-image document")
  t.eq(T.parse(upd(1, mine, { text = "hi", message_id = 9 }), 42).message_id, 9, "messages keep their id")
  local callback = { callback_query = { id = "query", data = "t:1:y", from = { id = 42 },
    message = { chat = mine, message_id = 19 } } }
  t.eq(T.parse(callback, 42).callback, "t:1:y", "paired callback data")
  t.eq(T.parse(callback, 42).query, "query", "callback query id")
  t.eq(T.parse(callback, 42).message_id, 19, "callback message id")
  callback.callback_query.from.id = 43
  t.eq(T.parse(callback, 42), nil, "stranger's callback is ignored")
  callback.callback_query.from.id = 42
  callback.callback_query.message.chat = { id = 42, type = "group" }
  t.eq(T.parse(callback, 42), nil, "group callback is ignored")
  t.eq(T.parse(upd(1, mine, { text = "ok", reply_to_message = { message_id = 55 } }), 42).reply_to, 55, "a swipe reply says which message it answers")
  t.eq(T.parse(upd(1, mine, { voice = { file_id = "v2" }, reply_to_message = { message_id = 56 } }), 42).reply_to, 56, "so does a voice note")
  t.eq(T.parse(upd(1, mine, { text = "hi" }), 42).reply_to, nil, "a plain message answers nothing")

  -- commands and the pairing code
  t.eq(T.command("/usage"), "usage", "command")
  t.eq(T.command("/Usage@MyBuddyBot"), "usage", "command addressed to the bot")
  t.eq(T.command("/start 123"), "start", "command with words after it")
  t.eq(T.command("what's /usage?"), nil, "not a command mid-sentence")
  t.ok(T.hasCode("/start 004211", "004211"), "code from the start link")
  t.ok(T.hasCode("it's 004211!", "004211"), "code in a sentence")
  t.ok(not T.hasCode("0042110", "004211"), "longer number isn't the code")
  t.ok(not T.hasCode(nil, "004211"), "no text")
  t.ok(T.affection("Thanks, Buddy!"), "thanks count as affection")
  t.ok(T.affection("ty"), "short thanks count")
  t.ok(not T.affection("city"), "ty inside another word does not count")
  t.ok(T.affection("ily"), "ily on its own counts")
  t.ok(not T.affection("what's my daily usage?"), "ily inside another word does not count")
  t.ok(not T.affection(string.rep("hello ", 20) .. "thanks"), "long messages without Buddy do not count")
  t.ok(T.validToken("123456:AA-b_c"), "token")
  t.ok(not T.validToken("123456"), "token needs the colon")
  t.ok(not T.validToken("abc:def"), "token starts with the bot's number")
  t.ok(not T.validToken("1:a b"), "no spaces in a token")

  -- splitting long replies
  local parts = T.chunks(string.rep("word ", 2000))
  local fits, words = true, 0
  for _, p in ipairs(parts) do
    fits = fits and #p <= 4096
    for _ in p:gmatch("word") do words = words + 1 end
  end
  t.eq(#parts, 3, "10,000 characters in three messages")
  t.ok(fits, "each piece fits Telegram")
  t.eq(words, 2000, "no words lost")
  local accents = T.chunks(string.rep("é", 3000))
  t.ok(#accents == 2 and utf8.len(accents[1]) and utf8.len(accents[2]), "never cuts inside a character")
  t.eq(T.chunks(string.rep("a", 3000) .. "\n" .. string.rep("b", 3000))[1], string.rep("a", 3000), "cuts at the line break")
  t.eq(#T.chunks(""), 0, "nothing to send")
  t.eq(T.chunks("hi")[1], "hi", "short text as is")

  -- Bot API methods against a held fake: queue order, buttons, status and reactions.
  local transport = load()
  local api = dofile(dir .. "/tests/fakes/telegram_api.lua")(transport)
  local menuKey = "claudeBuddy.telegramCommands.123"
  local previousMenu = hs.settings.get(menuKey)
  hs.settings.set(menuKey, nil)
  transport.start({ chat_id = 42, commands = { { command = "help", description = "Help" } } }, function() end)
  t.eq(api.named("getUpdates")[1].params.allowed_updates[2], "callback_query", "poll includes callbacks")
  t.eq(#api.named("setMyShortDescription"), 1, "awake status on start")
  transport.setAwake(true)
  t.eq(#api.named("setMyShortDescription"), 1, "unchanged status is not sent again")
  transport.setAwake(false)
  t.eq(#api.named("setMyShortDescription"), 2, "asleep status on change")
  transport.react(17, "👀")
  t.eq(api.named("setMessageReaction")[1].params.reaction[1].emoji, "👀", "reaction payload")
  local oversized, mediaTmp = nil, t.tmpdir()
  transport.download("large-file", mediaTmp .. "/image", function(path, why) oversized = why end)
  api.reply(api.named("getFile")[1], 200, { file_path = "photos/image.jpg", file_size = 10 * 1024 * 1024 + 1 })
  t.ok(oversized and #api.named("file") == 0, "oversized photo is rejected before download")
  transport.answer("q1", "Done")
  t.eq(api.named("answerCallbackQuery")[1].params.callback_query_id, "q1", "answers callback")
  transport.edit(18, "Done", false)
  t.eq(#api.named("editMessageText")[1].params.reply_markup.inline_keyboard, 0, "edit removes keyboard")
  local oneDone, twoDone = nil, nil
  transport.send("first", function(ok, ids) oneDone = { ok, ids } end,
    { buttons = { { { text = "Go", data = "t:1:y" } } }, thread = 5, reply_to = 6 })
  transport.send("second", function(ok) twoDone = ok end)
  t.eq(#api.named("sendMessage"), 1, "second reply waits behind first")
  local firstSend = api.named("sendMessage")[1]
  t.eq(firstSend.params.reply_markup.inline_keyboard[1][1].callback_data, "t:1:y", "inline button")
  t.eq(firstSend.params.message_thread_id, 5, "thread id")
  t.eq(firstSend.params.reply_parameters.message_id, 6, "reply target")
  api.reply(firstSend, 200, { message_id = 70 })
  t.ok(oneDone and oneDone[1], "first reply finishes")
  t.eq(#api.named("sendMessage"), 2, "second reply begins after first")
  api.reply(api.named("sendMessage")[2], 200, { message_id = 71 })
  t.ok(twoDone, "second reply finishes")
  local multi = load()
  local multiApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(multi)
  multi.start({ chat_id = 42, status = false }, function() end)
  local multiIds, afterMulti = nil, nil
  multi.send(string.rep("x", 5000), function(ok, ids) multiIds = ok and ids end)
  multi.send("after", function(ok) afterMulti = ok end)
  t.eq(#multiApi.named("sendMessage"), 1, "long reply owns the queue")
  multiApi.reply(multiApi.named("sendMessage")[1], 200, { message_id = 80 })
  t.eq(#multiApi.named("sendMessage"), 2, "second piece precedes next reply")
  t.ok(multiApi.named("sendMessage")[2].params.text ~= "after", "long reply pieces stay together")
  multiApi.reply(multiApi.named("sendMessage")[2], 200, { message_id = 81 })
  t.eq(multiApi.named("sendMessage")[3].params.text, "after", "next reply starts after all pieces")
  multiApi.reply(multiApi.named("sendMessage")[3], 200, { message_id = 82 })
  t.eq(table.concat(multiIds or {}, ","), "80,81", "delivered pieces are recorded once")
  t.ok(afterMulti, "queued reply completes")

  local preview = load()
  local previewApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(preview)
  preview.start({ chat_id = 42, status = false }, function() end)
  local stopped, finished = 0, nil
  local stream = preview.stream(true, 7, function() stopped = stopped + 1 end)
  stream:update(string.rep("a", 40))
  t.eq(#previewApi.named("sendMessage"), 1, "40 characters start an editable preview")
  t.eq(previewApi.named("sendMessage")[1].params.message_thread_id, 7, "preview stays in the thread")
  previewApi.reply(previewApi.named("sendMessage")[1], 200, { message_id = 91 })
  t.eq(stopped, 1, "typing stops at the first preview")
  stream.lastAt = stream.lastAt - 2
  stream:finish("Clean answer", function(ok) finished = ok end)
  t.eq(previewApi.named("editMessageText")[1].params.text, "Clean answer", "final replaces raw preview")
  previewApi.reply(previewApi.named("editMessageText")[1], 200, { message_id = 91 })
  t.ok(finished, "edited preview finishes")
  t.eq(#previewApi.named("sendMessage"), 1, "edit path has one final copy")
  preview.stop()

  local threshold = load()
  local thresholdApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(threshold)
  threshold.start({ chat_id = 42, status = false }, function() end)
  local measured = threshold.stream(true)
  measured:update(string.rep("é", 20))
  t.eq(#thresholdApi.named("sendMessage"), 0, "threshold counts characters, not UTF-8 bytes")
  measured:update(string.rep("é", 20))
  t.eq(#thresholdApi.named("sendMessage"), 1, "40 characters start the preview")
  threshold.stop()

  local paced = load()
  local pacedApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(paced)
  paced.start({ chat_id = 42, status = false }, function() end)
  local rate = paced.stream(true)
  rate:update(string.rep("p", 40))
  pacedApi.reply(pacedApi.named("sendMessage")[1], 200, { message_id = 98 })
  rate:update("more")
  t.eq(#pacedApi.named("editMessageText"), 0, "preview edits wait 1.5 seconds")
  rate.lastAt = rate.lastAt - 2
  rate:update("")
  t.eq(#pacedApi.named("editMessageText"), 1, "later preview can be edited")
  pacedApi.reply(pacedApi.named("editMessageText")[1], 200, { message_id = 98 })
  paced.stop()

  local elapsed = load()
  local elapsedApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(elapsed)
  elapsed.start({ chat_id = 42, status = false }, function() end)
  local short = elapsed.stream(true)
  short.started = short.started - 2
  short:update("Hi")
  t.eq(elapsedApi.named("sendMessage")[1].params.text, "Hi", "time threshold starts a short preview")
  elapsed.stop()

  local overflow = load()
  local overflowApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(overflow)
  overflow.start({ chat_id = 42, status = false }, function() end)
  local overflowDone = nil
  local longStream = overflow.stream(true)
  longStream:update(string.rep("e", 40))
  overflowApi.reply(overflowApi.named("sendMessage")[1], 200, { message_id = 96 })
  longStream.lastAt = longStream.lastAt - 2
  longStream:finish(string.rep("f", 5000), function(ok) overflowDone = ok end)
  local firstFinal = overflowApi.named("editMessageText")[1]
  t.ok(firstFinal and #firstFinal.params.text <= 4096, "final first piece fits Telegram")
  overflowApi.reply(firstFinal, 200, { message_id = 96 })
  t.ok(overflowApi.named("sendMessage")[2] and #overflowApi.named("sendMessage")[2].params.text <= 4096,
    "overflow goes out as another piece")
  overflowApi.reply(overflowApi.named("sendMessage")[2], 200, { message_id = 97 })
  t.ok(overflowDone, "overflow finishes after the extra piece")
  t.eq(#overflowApi.named("sendMessage"), 2, "overflow adds one final piece")
  overflow.stop()

  local failedEdit = load()
  local failedApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(failedEdit)
  failedEdit.start({ chat_id = 42, status = false }, function() end)
  local failedDone = nil
  local broken = failedEdit.stream(true)
  broken:update(string.rep("b", 40))
  failedApi.reply(failedApi.named("sendMessage")[1], 200, { message_id = 92 })
  broken.lastAt = broken.lastAt - 2
  broken:finish("The final answer", function(ok) failedDone = ok end)
  failedApi.reply(failedApi.named("editMessageText")[1], 400)
  t.eq(failedApi.named("sendMessage")[2].params.text, "The final answer", "failed edit sends final normally")
  failedApi.reply(failedApi.named("sendMessage")[2], 200, { message_id = 93 })
  t.ok(failedDone, "fallback completes")
  t.eq(#failedApi.named("sendMessage"), 2, "failed edit produces only one final send")
  failedEdit.stop()

  local midEdit = load()
  local midApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(midEdit)
  midEdit.start({ chat_id = 42, status = false }, function() end)
  local midDone = nil
  local mid = midEdit.stream(true)
  mid:update(string.rep("m", 40))
  midApi.reply(midApi.named("sendMessage")[1], 200, { message_id = 99 })
  mid.lastAt = mid.lastAt - 2
  mid:update(" more")
  t.eq(#midApi.named("editMessageText"), 1, "later preview edit starts")
  mid:finish("One final", function(ok) midDone = ok end)
  midApi.reply(midApi.named("editMessageText")[1], 400)
  t.eq(midApi.named("sendMessage")[2].params.text, "One final", "failed in-flight preview sends pending final")
  midApi.reply(midApi.named("sendMessage")[2], 200, { message_id = 100 })
  t.ok(midDone, "pending final finishes after preview edit failure")
  midEdit.stop()

  local drafts = load()
  local draftApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(drafts)
  drafts.start({ chat_id = 42, status = false }, function() end)
  local draftDone = nil
  local draft = drafts.stream("draft", 8)
  draft:update(string.rep("c", 40))
  t.eq(draftApi.named("sendMessageDraft")[1].params.message_thread_id, 8, "draft uses the thread")
  t.ok(type(draftApi.named("sendMessageDraft")[1].params.draft_id) == "number", "draft id is numeric")
  draftApi.reply(draftApi.named("sendMessageDraft")[1], 200, true)
  draft:finish("Draft final", function(ok) draftDone = ok end)
  t.eq(draftApi.named("sendMessage")[1].params.text, "Draft final", "draft ends with a regular message")
  draftApi.reply(draftApi.named("sendMessage")[1], 200, { message_id = 94 })
  t.ok(draftDone, "draft finishes")
  drafts.stop()

  local noDraft = load()
  local noDraftApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(noDraft)
  noDraft.start({ chat_id = 42, status = false }, function() end)
  local fallback = noDraft.stream("draft")
  fallback:update(string.rep("d", 40))
  noDraftApi.reply(noDraftApi.named("sendMessageDraft")[1], 400)
  t.eq(noDraftApi.named("sendMessage")[1].params.text, string.rep("d", 40), "failed draft falls back to edits")
  noDraftApi.reply(noDraftApi.named("sendMessage")[1], 200, { message_id = 95 })
  fallback.lastAt = fallback.lastAt - 2
  fallback:finish("Edited final", function() end)
  t.eq(noDraftApi.named("editMessageText")[1].params.text, "Edited final", "draft fallback edits its preview")
  noDraftApi.reply(noDraftApi.named("editMessageText")[1], 200, { message_id = 95 })
  noDraft.stop()

  transport.send("retry this", function(ok) transport.retryDone = ok end)
  api.reply(api.named("sendMessage")[3], 429, nil,
    hs.json.encode({ ok = false, description = "flood", parameters = { retry_after = 1 } }))
  t.eq(transport.retryDone, nil, "429 waits for retry")
  local commands = api.named("setMyCommands")
  t.eq(#commands, 1, "command menu registered")
  api.reply(commands[1], 200, true)
  transport.commands({ { command = "help", description = "Help" } })
  t.eq(#api.named("setMyCommands"), 1, "unchanged command menu is not registered again")

  -- Stopping during a flood wait must free the queue for a new start.
  local restarted = load()
  local restartApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(restarted)
  restarted.start({ chat_id = 42, status = false }, function() end)
  local oldDone, freshDone = nil, nil
  restarted.send("before stop", function(ok) oldDone = ok end)
  restartApi.reply(restartApi.named("sendMessage")[1], 429, nil,
    hs.json.encode({ ok = false, description = "flood", parameters = { retry_after = 10 } }))
  restarted.stop()
  restarted.start({ chat_id = 42, status = false }, function() end)
  restarted.send("after restart", function(ok) freshDone = ok end)
  t.eq(restartApi.named("sendMessage")[2] and restartApi.named("sendMessage")[2].params.text,
    "after restart", "restart frees a send queue held by a flood retry")
  if restartApi.named("sendMessage")[2] then
    restartApi.reply(restartApi.named("sendMessage")[2], 200, { message_id = 73 })
  end
  t.ok(freshDone, "the new reply finishes after restart")
  t.eq(oldDone, nil, "stopped reply does not complete later")
  restarted.send("in flight", function(ok) oldDone = ok end)
  local stale = restartApi.named("sendMessage")[3]
  restarted.stop()
  restarted.start({ chat_id = 42, status = false }, function() end)
  freshDone = nil
  restarted.send("current", function(ok) freshDone = ok end)
  local current = restartApi.named("sendMessage")[4]
  if stale then restartApi.reply(stale, 200, { message_id = 74 }) end
  t.eq(oldDone, nil, "callback from a stopped generation is ignored")
  t.eq(#restartApi.named("sendMessage"), 4, "stale callback cannot advance the new queue")
  if current then restartApi.reply(current, 200, { message_id = 75 }) end
  t.ok(freshDone, "new generation sends normally")
  restarted.stop()

  -- Hammerspoon tears down Lua before asynchronous shutdown requests can finish.
  local shutdown = load()
  local shutdownApi = dofile(dir .. "/tests/fakes/telegram_api.lua")(shutdown)
  local priorShutdown, priorRequest = hs.shutdownCallback, hs.http.doRequest
  local synchronous = {}
  hs.shutdownCallback = nil
  hs.http.doRequest = function(url, method, body, headers)
    synchronous[#synchronous + 1] = { url = url, method = method, params = hs.json.decode(body), headers = headers }
    return 200, '{}', {}
  end
  shutdown.start({ chat_id = 42 }, function() end)
  local asyncBefore = #shutdownApi.named("setMyShortDescription")
  hs.shutdownCallback()
  t.eq(#shutdownApi.named("setMyShortDescription"), asyncBefore, "shutdown uses no asynchronous status request")
  t.eq(#synchronous, 1, "shutdown makes one synchronous status request")
  t.eq(synchronous[1] and synchronous[1].method, "POST", "shutdown posts the status")
  t.ok(synchronous[1] and synchronous[1].url:find("/setMyShortDescription", 1, true), "shutdown uses the status method")
  t.eq(synchronous[1] and synchronous[1].params.short_description,
    "💤 The Mac is asleep. I'll answer when it wakes.", "shutdown uses the asleep status text")
  shutdown.stop()
  hs.http.doRequest, hs.shutdownCallback = priorRequest, priorShutdown

  -- Capture the speech pipeline's argv and stdin. No process is started.
  local oldTask = hs.task.new
  local voiceCalls, voiceDone = {}, nil
  transport.ffmpeg = function() return "/fake/ffmpeg" end
  hs.task.new = function(path, callback, argv)
    local task = { path = path, argv = argv }
    voiceCalls[#voiceCalls + 1] = task
    function task:setInput(input) self.input = input end
    function task:start()
      callback(0, path == "/usr/bin/curl" and '{"ok":true}' or "", "")
      return true
    end
    return task
  end
  local speechOk, speechErr = pcall(function()
    transport.voiceReply("**Hello** https://example.com", 9, function(ok) voiceDone = ok end)
  end)
  hs.task.new = oldTask
  t.ok(speechOk and voiceDone, "voice reply pipeline: " .. tostring(speechErr))
  t.eq(voiceCalls[1] and voiceCalls[1].path, "/usr/bin/say", "macOS speech default")
  t.eq(voiceCalls[2] and voiceCalls[2].path, "/fake/ffmpeg", "ffmpeg conversion")
  t.eq(voiceCalls[3] and voiceCalls[3].path, "/usr/bin/curl", "curl upload")
  local argv = table.concat(voiceCalls[3] and voiceCalls[3].argv or {}, " ")
  t.ok(argv:find("-K -", 1, true) and argv:find("message_thread_id=9", 1, true), "curl config on stdin and thread in form")
  t.ok(not argv:find("123:test-token", 1, true) and voiceCalls[3].input:find("123:test-token", 1, true),
    "voice token is in stdin only")

  -- a fake Keychain: security -i reads the add command from stdin, so the token never
  -- shows up in its arguments (which the fake writes down)
  local tmp = t.tmpdir()
  local sec = tmp .. "/security"
  local f = assert(io.open(sec, "w"))
  f:write([[#!/bin/sh
D=$(dirname "$0")
echo "$@" >> "$D/args"
case "$1" in
  -i) read -r line; printf '%s' "${line##* -w }" > "$D/keychain" ;;
  find-generic-password) [ -f "$D/keychain" ] && cat "$D/keychain" && exit 0; exit 44 ;;
  delete-generic-password) rm -f "$D/keychain" ;;
esac
]])
  f:close()
  hs.execute("/bin/chmod +x '" .. sec .. "'")

  -- a fake Bot API: replies[method] is a list of { status, result } used in turn; when it
  -- runs out the call is left hanging, like a long poll with nothing new
  local timers = {} -- an unreferenced timer can be garbage-collected before it fires
  local function fakeApi(mod, replies)
    local calls = {}
    mod.http = function(url, method, body, _, done)
      local name = url:find("/file/bot", 1, true) and "file" or url:match("/bot[^/]+/(%w+)$")
      calls[#calls + 1] = { name = name, params = body and hs.json.decode(body) or {} }
      local list = replies[name] or {}
      local r = table.remove(list, 1)
      if not r then return end
      local resp = r[1] == 200 and hs.json.encode({ ok = true, result = r[2] }) or r[3] or hs.json.encode({ ok = false, description = "nope" })
      timers[#timers + 1] = hs.timer.doAfter(0.01, function() done(r[1], resp) end)
    end
    return calls
  end
  local function named(calls, name)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name then out[#out + 1] = c end end
    return out
  end

  -- the live loop
  local live = load()
  live.security = sec
  local heard, liveCalls = {}, nil
  local keychainOk = false
  live.saveToken("111:abc", function(ok)
    keychainOk = ok
    liveCalls = fakeApi(live, {
      getUpdates = { { 200, { upd(10, stranger, { text = "let me in" }), upd(11, mine, { text = "hello" }),
                              upd(12, mine, { voice = { file_id = "v9" } }) } } },
      sendMessage = { { 200, { message_id = 501 } }, { 200, { message_id = 502 } }, { 200, { message_id = 503 } } },
    })
    live.start({ chat_id = 42 }, function(m) heard[#heard + 1] = m end)
  end)

  -- a revoked token stops the loop and says so
  local revoked, trouble = load(), nil
  revoked.security = sec
  fakeApi(revoked, { getUpdates = { { 401 } } })

  -- pairing a new bot
  local pairing, reports = load(), {}
  local pairCalls = fakeApi(pairing, {
    getMe = { { 200, { username = "MyBuddyBot", first_name = "Buddy" } } },
    getUpdates = { { 200, { upd(5, { id = 77, type = "private" }, { text = "/start 999999" }),
                            upd(6, { id = 77, type = "private" }, { text = "/start 123456", from = { id = 77, first_name = "Alex", username = "alex" } }) } } },
    sendMessage = { { 200, {} } },
  })
  pairing.pair("222:xyz", "123456", function(kind, info) reports[#reports + 1] = { kind = kind, info = info } end)

  -- a bad token never reaches Telegram's updates
  local badPair, badReport = load(), nil
  fakeApi(badPair, { getMe = { { 401 } } })
  badPair.pair("333:nope", "123456", function(kind, info) badReport = { kind = kind, info = info } end)

  -- the brain knows a phone message has no screen behind it
  local post, sent = hs.http.asyncPost, nil
  hs.http.asyncPost = function(_, body) sent = hs.json.decode(body) end
  local ok, err = pcall(function()
    local B = dofile(dir .. "/brain.lua").configure({ url = "http://127.0.0.1:9" }, "Sam", false)
    B.chat({ { role = "assistant", content = "Your turn!", said = true, at = os.time() },
             { role = "user", content = "what's up?", at = os.time() } }, { telegram = true, status = "2 cooking." }, function() end)
  end)
  hs.http.asyncPost = post
  t.ok(ok, "brain chat from the phone runs: " .. tostring(err))
  local sys = sent and sent.messages[1].content or ""
  t.ok(sys:find("Telegram", 1, true), "prompt says it's Telegram")
  t.ok(not sys:find("screenshot of it", 1, true), "prompt doesn't promise a screenshot")
  local newest = sent and sent.messages[#sent.messages].content or ""
  t.ok(newest:find("2 cooking.", 1, true), "prompt carries how the sessions look")
  t.ok(not sys:find("2 cooking.", 1, true), "in the newest message, not the system prompt")
  t.ok(newest:sub(-#"what's up?") == "what's up?" and not newest:find("speech-bubble line", 1, true), "not taken as an answer to the bubble")

  local started = hs.timer.secondsSinceEpoch()
  local revokedStarted, sendOk, sentIds = false, nil, nil
  return function()
    if not revokedStarted and keychainOk then
      revokedStarted = true
      revoked.start({ chat_id = 42 }, function() end, function(why) trouble = why end)
    end
    local liveDone = #heard >= 2 and liveCalls and #named(liveCalls, "getUpdates") >= 2
    if liveDone and sendOk == nil then
      sendOk = false
      live.send(string.rep("word ", 2000), function(r, ids) sendOk, sentIds = r, ids end)
    end
    local retried = #api.named("sendMessage") >= 4
    if retried and transport.retryDone == nil then api.reply(api.named("sendMessage")[4], 200, { message_id = 72 }) end
    local pairDone = #reports >= 2
    if not (liveDone and sendOk and pairDone and trouble and badReport and retried) and hs.timer.secondsSinceEpoch() - started < 8 then return false end
    t.ok(transport.retryDone, "429 retries the same piece")
    t.eq(api.named("sendMessage")[4].params.text, "retry this", "retry keeps the piece")

    t.ok(keychainOk, "token saved and read back")
    local args = io.open(tmp .. "/args"):read("a")
    t.ok(not args:find("111:abc", 1, true), "token never in security's arguments")

    t.eq(#heard, 2, "two messages from the paired chat, the stranger's dropped")
    t.eq(heard[1] and heard[1].text, "hello", "text first")
    t.eq(heard[2] and heard[2].voice, "v9", "then the voice note")
    local polls = named(liveCalls or {}, "getUpdates")
    t.eq(polls[1] and polls[1].params.offset, 0, "first poll from the start")
    t.eq(polls[2] and polls[2].params.offset, 13, "next poll after the last update")
    t.eq(hs.settings.get(live.offsetKey).offset, 13, "where it got to is saved for a reload")

    local sends = named(liveCalls or {}, "sendMessage")
    t.ok(sendOk, "long reply sent")
    t.eq(#sends, 3, "in three messages")
    t.eq(sends[1] and sends[1].params.chat_id, 42, "to the paired chat")
    t.ok(sends[1] and sends[1].params.text:sub(1, 4) == "word", "first piece first")
    t.eq(sentIds and table.concat(sentIds, ","), "501,502,503", "each piece's message id comes back")

    t.eq(trouble, "token", "revoked token reported")
    t.eq(reports[1] and reports[1].kind, "bot", "token checked first")
    t.eq(reports[1] and reports[1].info.username, "MyBuddyBot", "bot name")
    t.eq(reports[2] and reports[2].kind, "paired", "paired by the right code")
    t.eq(reports[2] and reports[2].info.chat_id, 77, "the chat that sent it")
    t.eq(reports[2] and reports[2].info.name, "Alex", "their first name")
    t.eq(#named(pairCalls, "sendMessage"), 1, "says hello once paired")
    t.eq(hs.settings.get(pairing.offsetKey).offset, 7, "pairing messages won't be answered later")
    t.eq(badReport and badReport.kind, "error", "bad token turned down")
    t.ok(badReport and tostring(badReport.info):find("BotFather", 1, true), "and says where to get a good one")

    live.forgetToken(function() end)
    for _, m in ipairs({ live, revoked, pairing, badPair }) do
      m.stop()
      hs.settings.set(m.offsetKey, nil)
    end
    transport.stop()
    multi.stop()
    hs.settings.set(menuKey, previousMenu)
    hs.shutdownCallback = oldShutdown
    return true
  end
end
