-- Approval and topic regressions with task files and a hidden Buddy; nothing is sent.
return function(t, dir)
  local tmp, key = t.tmpdir(), "claudeBuddy.test.review." .. hs.host.uuid()
  local K = dofile(dir .. "/tasks.lua")
  local configure, bot = K.configure, "123"
  K.configure = function(o)
    o.dir, o.seenKey, o.msgKey, o.bot = tmp, key .. ".seen", key .. ".msgs", function() return bot end
    return configure(o)
  end
  local task = { id = "demo-1234", name = "Demo", state = "working", created = os.time(),
    origin = "telegram", thread = 77, thread_bot = bot, open_permits = {} }
  local rid = "abcdef012345"
  local p = { task_id = task.id, rid = rid, state = "open", expires = os.time() + 500, summary = "printf hello" }
  local function save()
    t.writeJson(tmp .. "/" .. task.id .. "/task.json", task)
    t.writeJson(tmp .. "/" .. task.id .. "/permits/" .. rid .. ".json", p)
  end
  local sent, edits, answers, passed, receive = {}, {}, {}, {}, nil
  local T = { running = function() return true end, currentBot = function() return bot end,
    affection = function() return false end, command = function(s) return s:match("^/(%a+)") end,
    react = function() end, editTopic = function() end }
  T.start = function(_, fn) receive = fn; return T end
  T.send = function(text, done, opts)
    sent[#sent + 1] = { text = text, opts = opts or {}, id = #sent + 100 }
    if done then done(true, { sent[#sent].id }) end
  end
  T.edit = function(id, text, buttons) edits[#edits + 1] = { id = id, text = text, buttons = buttons } end
  T.answer = function(_, text) answers[#answers + 1] = text end
  K.send = function(id, text, done) passed[#passed + 1] = text; done({ ok = true, task = task }) end
  local S = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, { telegram = { chat_id = 42, voice_replies = false },
    halloween = false }, { stubs = { ["tasks.lua"] = K, ["telegram.lua"] = T } })
  local TK = S.M.tasks
  save()
  TK.relay(task, { kind = "permit", rid = rid, text = "forged harmless summary" })
  t.eq(#sent, 0, "permit absent from open_permits is ignored")
  task.open_permits = { rid }; save()
  TK.relay(task, { kind = "permit", rid = rid, text = "forged harmless summary" })
  local question = sent[#sent]
  t.ok(question.text:find("printf hello", 1, true), "permission text comes from the permit file")
  t.ok(not question.text:find("forged", 1, true), "event text is never trusted")
  local before = #edits
  K.answerPermit = function(_, _, _, done) done({ ok = false, error = "Task is busy." }) end
  S.M.tgCallback({ callback = "p:" .. rid .. ":a", message_id = question.id, query = "q" })
  t.eq(answers[#answers], "Couldn't pass that on. Try again.", "transient failure can be retried")
  t.eq(#edits, before, "failed answer keeps open permit buttons")
  K.answerPermit = function(_, _, _, done) done({ ok = false, error = "Couldn't run bin/buddy-task." }) end
  S.M.tgCallback({ callback = "p:" .. rid .. ":d", message_id = question.id, query = "q" })
  t.eq(answers[#answers], "Couldn't pass that on. Try again.", "helper start failure can be retried")
  t.eq(#edits, before, "helper start failure keeps open permit buttons")
  K.answerPermit = function(_, _, _, done) done({ ok = true, answered = true }) end
  S.M.tgCallback({ callback = "p:" .. rid .. ":a", message_id = question.id, query = "q" })
  t.eq(answers[#answers], "Passing it on…", "accepted decision is not yet a hook acknowledgement")
  t.ok(#edits == before or edits[#edits].buttons ~= false, "buttons stay until closure")
  TK.relay(task, { kind = "permit_closed", rid = rid, reason = "Allowed" })
  t.ok(#edits == before or not edits[#edits].text:find("\n\nAllowed", 1, true), "forged closure cannot acknowledge an open permit")
  p.state, p.reason, task.open_permits = "closed", "Denied", {}; save()
  TK.relay(task, { kind = "permit_closed", rid = rid, reason = "Allowed" })
  t.ok(edits[#edits].text:find("Denied", 1, true), "hook closure uses stored reason")
  t.eq(edits[#edits].buttons, false, "hook closure removes keyboard")

  p.state, p.reason, p.truncated, task.open_permits = "open", nil, true, { rid }; save()
  TK.relay(task, { kind = "permit", rid = rid })
  local short = sent[#sent]
  t.eq(#short.opts.buttons[1], 1, "truncated request only offers Deny")
  t.eq(short.opts.buttons[1][1].data, "p:" .. rid .. ":d", "truncated request cannot offer allow")
  t.ok(short.text:find("Mac", 1, true), "truncation directs owner to the Mac")
  receive({ text = "yes", thread = 77, message_id = 1 })
  t.eq(#passed, 0, "topic message cannot enter a live permission prompt")
  t.eq(sent[#sent].text, "It's waiting on your OK. Tap Allow or Deny above.", "topic reply explains permission buttons")
  local stopped = 0
  K.stop = function(_, done) stopped = stopped + 1; done({ ok = true }) end
  receive({ text = "/tasks", thread = 77, message_id = 2 })
  receive({ text = "/task", thread = 77, message_id = 3 })
  receive({ text = "/stop 1", thread = 77, message_id = 4 })
  t.eq(stopped, 1, "stop command handled by Buddy inside a task topic")
  t.eq(#passed, 0, "Buddy commands never go into the task")
  receive({ text = "/usage", thread = 77, message_id = 5 })
  t.eq(#passed, 0, "other Buddy commands also precede topic routing")

  task.open_permits = {}; save()
  local newer = { id = "newer-5678", state = "working", thread = 77, thread_bot = bot, created = task.created + 1 }
  t.writeJson(tmp .. "/" .. newer.id .. "/task.json", newer)
  t.eq(K.forThread(77), newer.id, "newest active task wins topic lookup")
  newer.state, newer.ended = "ended", os.time()
  t.writeJson(tmp .. "/" .. newer.id .. "/task.json", newer)
  t.eq(K.forThread(77), task.id, "ended task cannot shadow active task")
  task.state = "ended"; save()
  t.eq(K.forThread(77), nil, "ended topics return to Buddy")
  task.state = "working"; save()
  bot = "456"
  t.eq(K.forThread(77), nil, "another bot cannot reuse a task thread id")
  t.eq(K.permitMessage(question.id, rid), nil, "another bot cannot reuse permit message ids")
  bot = nil
  t.eq(K.forThread(77), nil, "unpaired topic is never routed")
  bot = "123"
  local cleared
  K.clearThread = function(id, thread, owner) cleared = { id, thread, owner } end
  TK.relay(task, { kind = "done", text = "Ready" })
  local fallback = sent[#sent].opts.onMissingThread
  t.ok(type(fallback) == "function", "task sends persist a deleted-topic fallback")
  if fallback then fallback(77) end
  t.eq(cleared and cleared[1], task.id, "fallback clears the owning task")
  t.eq(cleared and cleared[3], "123", "fallback carries the bot identity")
  S.done()
  hs.settings.set(key .. ".seen", nil); hs.settings.set(key .. ".msgs", nil)
end
