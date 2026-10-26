-- Buddy's task routing with real task files and fake Telegram and session helpers.
return function(t, dir)
  local tmp, keys = t.tmpdir(), "claudeBuddy.test.phone." .. hs.host.uuid()
  local K = dofile(dir .. "/tasks.lua")
  local configure, opts = K.configure, nil
  K.configure = function(o)
    opts = o
    o.dir, o.seenKey, o.msgKey = tmp, keys .. ".seen", keys .. ".msgs"
    return configure(o)
  end
  local task = { id = "demo-1234", name = "Demo", folder = "/tmp", origin = "telegram", state = "working", created = os.time() }
  local function save() t.writeJson(tmp .. "/" .. task.id .. "/task.json", task) end
  local sent, edits, answers, topics, passed = {}, {}, {}, {}, {}
  local enabled, hold, receive, startOptions = true, false, nil, nil
  local T = { running = function() return enabled end, affection = function() return false end,
    command = function(s) return s:match("^/(%a+)") end, react = function() end, currentBot = function() return "123" end }
  T.start = function(_, fn) receive = fn; return T end
  T.send = function(text, done, options)
    local m = { text = text, opts = options or {}, done = done, id = #sent + 100 }
    sent[#sent + 1] = m
    if done and not hold then done(true, { m.id }) end
  end
  T.edit = function(id, text, buttons) edits[#edits + 1] = { id = id, text = text, buttons = buttons } end
  T.answer = function(_, text) answers[#answers + 1] = text end
  T.createTopic = function(name, done) topics[#topics + 1] = name; done(77) end
  T.editTopic = function(thread, name) topics[#topics + 1] = { thread, name } end
  K.start = function(p, origin, done)
    startOptions = { approvals = opts.approvals(), thread = p.thread, thread_bot = p.thread_bot }
    task.thread, task.thread_bot, task.origin = p.thread, p.thread_bot, origin
    save()
    done({ ok = true, task = task })
  end
  K.send = function(id, text, done)
    passed[#passed + 1] = { id, text }
    done({ ok = true, task = task })
  end
  local cfg = { telegram = { chat_id = 42, voice_replies = false }, halloween = false }
  local S = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, cfg, { stubs = { ["tasks.lua"] = K, ["telegram.lua"] = T } })
  local TK = S.M.tasks
  t.ok(opts.approvals(), "paired tasks default to approvals on")
  cfg.telegram.approvals = false
  t.ok(not opts.approvals(), "approvals false disables the session hook")
  cfg.telegram.approvals = nil
  enabled = false
  t.ok(not opts.approvals(), "no paired transport disables the session hook")
  enabled = true
  TK.go({ kind = "start", name = "Demo", task = "Build demo", folder = "/tmp" }, "telegram", function() end)
  t.eq(topics[1], "Demo", "task creation asks for a topic")
  t.eq(startOptions.thread, 77, "topic created before launch")
  t.eq(startOptions.thread_bot, "123", "topic belongs to the paired bot")
  t.eq(sent[#sent].opts.thread, 77, "started link goes to the task topic")
  receive({ text = "Use blue", thread = 77, message_id = 1 })
  t.eq(passed[1][1], task.id, "topic text goes to the task")
  t.eq(passed[1][2], "Use blue", "topic text is unchanged")
  receive({ text = "Hello", thread = 78, message_id = 2 })
  t.eq(#passed, 1, "unrelated topic stays with Buddy")
  t.eq(sent[#sent].opts.thread, 78, "Buddy answers in unrelated topic")
  receive({ text = "Hello", message_id = 3 })
  t.eq(sent[#sent].opts.thread, nil, "main chat answer stays in main chat")
  TK.relay(task, { kind = "done", text = "Ready" })
  t.eq(sent[#sent].opts.thread, 77, "task update stays in topic")
  local rid, request = "abcdef012345", nil
  local function permit(state, reason)
    request = { task_id = task.id, rid = rid, state = state, reason = reason, expires = os.time() + 570, summary = "printf hello" }
    t.writeJson(tmp .. "/" .. task.id .. "/permits/" .. rid .. ".json", request)
    task.open_permits = state == "open" and { rid } or {}
    save()
  end
  permit("open")
  task.open_permits = { rid }
  TK.relay(task, { kind = "permit", rid = rid, text = "printf hello" })
  local question, count = sent[#sent], #sent
  t.eq(question.opts.thread, 77, "permission buttons in task topic")
  t.eq(question.opts.buttons[1][1].data, "p:" .. rid .. ":a", "Allow once payload")
  t.eq(question.opts.buttons[1][2].data, "p:" .. rid .. ":d", "Deny payload")
  TK.relay(task, { kind = "asking", text = "Permission" })
  t.eq(#sent, count, "old notification is suppressed")
  local decisions = 0
  K.answerPermit = function(id, r, choice, done)
    decisions = decisions + 1
    t.eq(id, task.id, "answer helper receives owning task")
    t.eq(r, rid, "answer helper receives rid")
    t.eq(choice, "allow", "tap means one-call allow")
    local open = request.state == "open"
    permit("closed", "Allowed")
    done({ ok = true, answered = open })
  end
  S.M.tgCallback({ callback = "p:" .. rid .. ":a", message_id = question.id, query = "q" })
  t.eq(answers[#answers], "Passing it on…", "tap waits for hook acknowledgement")
  TK.relay(task, { kind = "permit_closed", rid = rid, reason = "Allowed" })
  t.eq(edits[#edits].buttons, false, "answered keyboard removed")
  S.M.tgCallback({ callback = "p:" .. rid .. ":a", message_id = question.id, query = "q2" })
  t.eq(answers[#answers], "Already answered", "duplicate tap is harmless")
  for _, data in ipairs({ "p:bad:a", "p:" .. rid .. ":always", "p:../escape:a", "p:" .. rid .. ":a:extra" }) do
    S.M.tgCallback({ callback = data, message_id = question.id, query = "q3" })
    t.eq(answers[#answers], "That one's done.", "malformed tap is harmless")
  end
  S.M.tgCallback({ callback = "p:" .. rid .. ":a", message_id = 999, query = "q4" })
  t.eq(decisions, 2, "unknown or malformed callback never invokes answer helper")
  -- A closure arriving before Telegram finishes sending still removes the new keyboard.
  permit("open")
  hold = true
  TK.relay(task, { kind = "permit", rid = rid, text = "printf hello" })
  local delayed = sent[#sent]
  permit("closed", "Answered on the Mac")
  TK.relay(task, { kind = "permit_closed", rid = rid, reason = "Answered on the Mac" })
  delayed.done(true, { delayed.id })
  hold = false
  t.eq(edits[#edits].id, delayed.id, "late send removes its own stale keyboard")
  t.ok(edits[#edits].text:find("Answered on the Mac", 1, true), "Mac answer shown")
  permit("closed", "Timed out")
  TK.relay(task, { kind = "permit_closed", rid = rid, reason = "Timed out" })
  t.ok(edits[#edits].text:find("Timed out", 1, true), "timeout shown")
  TK.stopped[task.id] = true
  TK.relay(task, { kind = "ended" })
  t.eq(sent[#sent].opts.thread, 77, "ended line stays in topic even after manual stop")
  t.eq(topics[#topics][1], 77, "ended topic renamed")
  t.eq(topics[#topics][2], "✔ Demo", "ended topic is kept with check mark")
  cfg.telegram.topics = false
  TK.go({ kind = "start", name = "Demo", task = "Build demo" }, "telegram", function() end)
  t.eq(startOptions.thread, nil, "topics false keeps old start path")
  t.eq(sent[#sent].opts.thread, nil, "fallback starts in main chat")
  receive({ text = "Follow up", reply_to = question.id, message_id = 4 })
  t.eq(#passed, 2, "reply to an update still routes without topics")
  S.done()
  hs.settings.set(keys .. ".seen", nil)
  hs.settings.set(keys .. ".msgs", nil)
end
