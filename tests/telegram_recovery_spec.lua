-- Failed previews and deleted topics use held replies, never the real Bot API.
return function(t, dir)
  local oldShutdown = hs.shutdownCallback
  for _, failure in ipairs({ "send", "edit", "draft" }) do
    local T = dofile(dir .. "/telegram.lua")
    T.offsetKey = "claudeBuddy.test.recovery." .. hs.host.uuid()
    local api = dofile(dir .. "/tests/fakes/telegram_api.lua")(T)
    T.start({ chat_id = 42, status = false }, function() end)
    local count, nextDone = 0, false
    local s = T.stream(failure == "draft" and "draft" or true)
    s:update(string.rep("x", 40))
    if failure == "draft" then api.reply(api.named("sendMessageDraft")[1], 400) end
    if failure == "edit" then
      api.reply(api.named("sendMessage")[1], 200, { message_id = 10 })
      s.lastAt = s.lastAt - 2
      s:update(" more")
      api.reply(api.named("editMessageText")[1], 400)
    else
      api.reply(api.named("sendMessage")[1], 400)
    end
    s:update(" still writing")
    s:finish("Finished answer", function(ok) if ok then count = count + 1 end end)
    local final = api.named("sendMessage")[2]
    t.eq(final and final.params.text, "Finished answer", failure .. " preview failure before finish still sends final")
    -- Re-entering after final delivery starts cannot enqueue a second final.
    s:update("late")
    s:finish("duplicate", function() count = count + 100 end)
    T.send("next answer", function(ok) nextDone = ok end)
    if final then api.reply(final, 200, { message_id = 11 }) end
    local nextCall = api.named("sendMessage")[3]
    t.eq(nextCall and nextCall.params.text, "next answer", failure .. " failure frees the queue")
    if nextCall then api.reply(nextCall, 200, { message_id = 12 }) end
    t.eq(count, 1, failure .. " final completes once")
    t.ok(nextDone, failure .. " later answer completes")
    if s.timer then s.timer:stop() end
    T.stop()
  end

  for _, description in ipairs({ "Bad Request: message thread not found", "Bad Request: TOPIC_DELETED" }) do
    local T = dofile(dir .. "/telegram.lua")
    local api = dofile(dir .. "/tests/fakes/telegram_api.lua")(T)
    T.start({ chat_id = 42, status = false }, function() end)
    local cleared, delivered = nil, 0
    T.send("Permission", function(ok) if ok then delivered = delivered + 1 end end,
      { thread = 77, reply_to = 8, onMissingThread = function(thread) cleared = thread end,
        buttons = { { { text = "Deny", data = "p:abcdef012345:d" } } } })
    api.reply(api.named("sendMessage")[1], 400, nil, hs.json.encode({ ok = false, description = description }))
    local retry = api.named("sendMessage")[2]
    t.eq(cleared, 77, "deleted topic invalidates stored task thread")
    t.ok(retry ~= nil, "deleted topic retries in main chat")
    if retry then
      t.eq(retry.params.message_thread_id, nil, "retry drops deleted thread")
      t.eq(retry.params.reply_parameters, nil, "retry drops deleted reply target")
      t.eq(retry.params.reply_markup.inline_keyboard[1][1].callback_data, "p:abcdef012345:d", "fallback retains buttons")
      api.reply(retry, 200, { message_id = 13 })
    end
    t.eq(delivered, 1, "fallback completes once")
    T.stop()
  end
  hs.shutdownCallback = oldShutdown
end
