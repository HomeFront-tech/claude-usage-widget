-- Topic calls use a held Bot API fake; no real Telegram chat is changed.
return function(t, dir)
  local oldShutdown = hs.shutdownCallback
  local T = dofile(dir .. "/telegram.lua")
  T.offsetKey = "claudeBuddy.test.topics." .. hs.host.uuid()
  local api = dofile(dir .. "/tests/fakes/telegram_api.lua")(T)
  T.start({ chat_id = 42, status = false }, function() end)
  local thread
  T.createTopic("Build demo", function(id) thread = id end)
  local create = api.named("createForumTopic")[1]
  t.eq(create.params.chat_id, 42, "topic created in paired private chat")
  t.eq(create.params.name, "Build demo", "topic uses the task name")
  api.reply(create, 200, { message_thread_id = 77 })
  t.eq(thread, 77, "topic id returned to the task")
  T.editTopic(77, "✔ Build demo")
  local edit = api.named("editForumTopic")[1]
  t.eq(edit.params.message_thread_id, 77, "rename uses message_thread_id")
  t.eq(edit.params.name, "✔ Build demo", "ended topic gets a check mark")
  T.createTopic("Unavailable", function(id) thread = id end)
  api.reply(api.named("createForumTopic")[2], 400)
  t.eq(thread, nil, "creation failure falls back")
  T.createTopic("Again", function(id) thread = id end)
  t.eq(#api.named("createForumTopic"), 2, "failed chat isn't retried immediately")
  local key = T.offsetKey .. ".noTopics.123.42"
  t.ok(hs.settings.get(key) > hs.timer.secondsSinceEpoch() + 86390, "failure remembered for a day")
  hs.settings.set(key, hs.timer.secondsSinceEpoch() - 1)
  T.createTopic("Tomorrow", function() end)
  t.eq(#api.named("createForumTopic"), 3, "retry after a day")
  T.stop()
  T.start({ chat_id = 42, status = false, topics = false }, function() end)
  T.createTopic("Off", function(id) thread = id end)
  t.eq(#api.named("createForumTopic"), 3, "topics false never calls the API")
  T.stop()
  T.createTopic("Unpaired", function(id) thread = id end)
  t.eq(#api.named("createForumTopic"), 3, "unpaired never calls the API")
  local message = { chat = { id = 42, type = "private" }, message_id = 9, message_thread_id = 77, text = "hi" }
  t.eq(T.parse({ message = message }, 42).thread, 77, "text retains topic id")
  local query = { callback_query = { from = { id = 42 }, id = "q", data = "p:abcdef012345:a", message = message } }
  t.eq(T.parse(query, 42).thread, 77, "callback retains topic id")
  query.callback_query.from.id = 43
  t.eq(T.parse(query, 42), nil, "stranger cannot approve in paired chat")
  query.callback_query.from.id = 42
  message.chat.id = 43
  t.eq(T.parse(query, 42), nil, "paired user cannot approve in another chat")
  message.chat = { id = 42, type = "group" }
  t.eq(T.parse(query, 42), nil, "paired user's group tap cannot approve")
  query.callback_query.message = nil
  t.eq(T.parse(query, 42), nil, "inline callback without private message cannot approve")
  hs.settings.set(key, nil)
  hs.settings.set(T.offsetKey, nil)
  hs.shutdownCallback = oldShutdown
end
