-- tasks.lua: the yes-or-no gate, proposals, reading the sessions' events, Telegram reply
-- routing, and running bin/buddy-task (here a fake shell script). Each case uses temp
-- folders and its own settings keys, so the live buddy's sessions are never touched.
return function(t, dir)
  local tmp = t.tmpdir()
  local keys = { seen = "claudeBuddy.test.taskSeen." .. hs.host.uuid(), msg = "claudeBuddy.test.taskMsgs." .. hs.host.uuid() }
  local function load(o)
    local K = dofile(dir .. "/tasks.lua")
    o = o or {}
    o.dir, o.seenKey, o.msgKey = o.dir or tmp, keys.seen, keys.msg
    o.bot = o.bot or "123"
    return K.configure(o)
  end
  local K = load()

  -- yes, no and their own words
  for _, s in ipairs({ "yes", "Yes!", "  yep ", "OK.", "go ahead", "do it", "👍" }) do t.ok(K.isYes(s), "yes: " .. s) end
  for _, s in ipairs({ "no", "Nope.", "cancel", "don't", "never mind" }) do t.ok(K.isNo(s), "no: " .. s) end
  for _, s in ipairs({ "yes but call it Meals", "sure, after lunch", "", "no idea what that is" }) do
    t.ok(not K.isYes(s) and not K.isNo(s), "neither: " .. s)
  end
  t.ok(K.ownWords("use a new file", "Tell it: Use a new file!"), "their own words, any case and punctuation")
  t.ok(not K.ownWords("delete everything", "tell it to use a new file"), "words they never said")
  t.ok(not K.ownWords("", "anything"), "nothing isn't their words")
  t.eq(K.nameFor("build a meal tracker for Buddy please"), "Build a meal tracker", "a name from the first words")
  t.eq(K.clip(string.rep("é", 10), 6), "éé…", "clip never cuts a character in half")

  -- a proposal from the brain: taken once, only when fresh
  local now = hs.timer.secondsSinceEpoch()
  t.writeJson(tmp .. "/pending.json", { kind = "start", task = "Build a meal tracker", name = "Meal tracker",
    folder = "/tmp", at = now })
  local p = K.takeProposal(now - 1)
  t.eq(p and p.name, "Meal tracker", "the brain's proposal")
  t.eq(K.takeProposal(now - 1), nil, "taking it removes it")
  t.writeJson(tmp .. "/pending.json", { kind = "start", task = "x", name = "y", at = now - 600 })
  t.eq(K.takeProposal(now), nil, "one from before this message doesn't count")
  t.writeJson(tmp .. "/pending.json", { kind = "launch", task = "x", name = "y", at = now })
  t.eq(K.takeProposal(now), nil, "an unknown kind doesn't count")
  t.writeJson(tmp .. "/pending.json", { kind = "start", task = "x", name = "y", at = now })
  t.eq(K.takeProposal(now).folder, os.getenv("HOME"), "no folder means home")
  t.writeJson(tmp .. "/pending.json", { kind = "start", task = "x", name = "y", model = "claude-sonnet-5-5", at = now })
  t.eq(K.takeProposal(now).model, "claude-sonnet-5-5", "the model they asked for")
  t.writeJson(tmp .. "/pending.json", { kind = "start", task = "x", name = "y", model = "opus; rm -rf /", at = now })
  t.eq(K.takeProposal(now).model, nil, "a model that isn't a model name is dropped")

  -- the question, then their answer
  local q = K.ask({ kind = "start", task = "Build a meal tracker", name = "Meal tracker", folder = os.getenv("HOME") .. "/dev/app" })
  t.ok(q:find("Meal tracker, in ~/dev/app", 1, true) and q:find("Reply yes or no", 1, true), "asks with the name and folder")
  t.ok(not q:find(", on ", 1, true), "no model set: no model on the card")
  local verdict, held = K.answer("yes please")
  t.eq(verdict, "yes", "yes")
  t.eq(held and held.name, "Meal tracker", "and what it was about")
  t.eq(K.answer("yes"), nil, "asked once, answered once")
  K.ask({ kind = "send", id = "a-1", name = "Meal tracker", text = "add water" })
  t.eq(K.answer("no"), "no", "no")
  local sendQ = K.ask({ kind = "send", id = "pid-7", name = "Auction hunt", folder = os.getenv("HOME") .. "/work",
    confirm = true, text = "try the other site" })
  t.ok(sendQ:find("Auction hunt (in ~/work)", 1, true), "a send to another session names its folder: " .. sendQ)
  K.answer("no")
  K.ask({ kind = "start", task = "x", name = "y", folder = "/" })
  local buttonId = K.pending.id
  t.eq(K.answerButton("older", true), nil, "old task button cannot answer a newer question")
  t.eq(K.answerButton(buttonId, true), "yes", "task button accepts the current question")
  t.eq(K.answerButton(buttonId, false), nil, "task button cannot answer twice")
  K.ask({ kind = "start", task = "x", name = "y", folder = "/" })
  t.eq(K.answer("actually, what's the weather?"), nil, "anything else drops the question")
  t.eq(K.pending, nil, "and it's gone")
  -- the model it starts on: the one they asked for, else the configured default
  local M = load({ model = "claude-opus-5-5" })
  t.ok(M.ask({ kind = "start", task = "x", name = "Tidy", folder = "/" }):find("Tidy, in /, on Opus 5.5:", 1, true),
    "the default model is on the card")
  t.ok(M.ask({ kind = "start", task = "x", name = "Tidy", folder = "/", model = "claude-haiku-5-5" })
    :find("Tidy, in /, on Haiku 5.5:", 1, true), "the model they asked for is on the card")
  t.ok(M.ask({ kind = "start", task = "x", name = "Tidy", folder = "/", model = "claude-opus-4-1" })
    :find("on claude-opus-4-1:", 1, true), "a model without a short name shows its id")
  M.answer("no")
  K.ask({ kind = "start", task = "x", name = "y", folder = "/" })
  K.pending.at = now - 3600
  t.eq(K.answer("yes"), nil, "a yes long after the question doesn't count")

  -- the sessions on file
  local function task(id, fields)
    local base = { id = id, name = id, state = "working", folder = os.getenv("HOME"), created = os.time(), tmux = true }
    for k, v in pairs(fields or {}) do base[k] = v end
    t.writeJson(tmp .. "/" .. id .. "/task.json", base)
  end
  local function events(id, lines, mode)
    local f = assert(io.open(tmp .. "/" .. id .. "/events.jsonl", mode or "a"))
    f:write(lines)
    f:close()
  end
  task("meal-1a2b", { name = "Meal tracker", created = os.time() - 60, url = "https://claude.ai/code/s1", state = "waiting" })
  task("fix-3c4d", { name = "Fix build", model = "claude-sonnet-5-5" })
  task("old-5e6f", { name = "Old one", state = "ended", ended = os.time() - 3 * 86400 })
  local list = K.list()
  t.eq(#list, 2, "running sessions listed, long-ended ones not")
  t.eq(list[1].name, "Meal tracker", "oldest first")
  t.eq(K.find("2").name, "Fix build", "by number")
  t.eq(K.find("meal").id, "meal-1a2b", "by part of the name")
  t.eq(K.find("fix-3c4d").name, "Fix build", "by id")
  t.eq(K.find("9"), nil, "no such number")
  t.ok(K.summary():find("Meal tracker (id meal-1a2b, waiting on you", 1, true), "summary for the brain")
  t.ok(K.listText():find("1. Meal tracker: waiting on you\nhttps://claude.ai/code/s1", 1, true), "/tasks with the phone link")
  t.ok(K.listText():find("2. Fix build (Sonnet 5.5): working", 1, true), "/tasks names a session's model")
  t.ok(K.summary():find("Fix build (id fix-3c4d, working, in ~, on Sonnet 5.5)", 1, true), "and so does the brain's summary")

  -- reading what the hooks wrote: each event once, half-written lines wait
  events("meal-1a2b", '{"kind":"done","text":"Which file?","at":1}\n{"kind":"ask', "w")
  events("fix-3c4d", "", "w")
  events("old-5e6f", '{"kind":"ended","text":"","at":1}\n', "w")
  local got = {}
  local function collect(tk, ev) got[#got + 1] = tk.id .. ":" .. ev.kind end
  K.poll(collect)
  t.eq(table.concat(got, ","), "meal-1a2b:done", "a running session's events from the start; an old ended one skipped")
  K.poll(collect)
  t.eq(#got, 1, "nothing twice")
  events("meal-1a2b", 'ing","text":"Bash?","at":2}\n')
  K.poll(collect)
  t.eq(got[2], "meal-1a2b:asking", "the finished line is read once it's whole")
  local again = load()
  again.poll(collect)
  t.eq(#got, 2, "a reload remembers how far it read")
  local errors = 0
  events("fix-3c4d", '{"kind":"done","text":"ok","at":3}\n')
  again.poll(function() errors = errors + 1; error("boom") end)
  t.eq(errors, 1, "a failing handler doesn't stop the poll")

  -- Telegram replies find their session, across a reload
  K.remember(901, "meal-1a2b")
  t.eq(load().forMessage(901), "meal-1a2b", "a reply to an update goes to its session")
  t.eq(K.forMessage(902), nil, "other messages belong to no session")
  t.eq(K.forMessage(nil), nil, "no reply at all")

  -- A topic and a permit message survive reloads; unrelated messages cannot answer it.
  task("meal-1a2b", { thread = 77, thread_bot = "123" })
  t.eq(K.forThread(77), "meal-1a2b", "topic routes to its task")
  t.eq(K.forThread(78), nil, "another topic stays with Buddy")
  t.eq(K.forThread(nil), nil, "main chat stays with Buddy")
  task("old-5e6f", { thread = 79, thread_bot = "123", state = "ended", ended = os.time() - 3 * 86400 })
  t.eq(K.forThread(79), nil, "ended topic stays with Buddy")
  local rid = "abcdef012345"
  local permit = { task_id = "meal-1a2b", rid = rid, state = "open", expires = now + 570 }
  task("meal-1a2b", { thread = 77, thread_bot = "123", open_permits = { rid } })
  t.writeJson(tmp .. "/meal-1a2b/permits/" .. rid .. ".json", permit)
  K.remember(903, "meal-1a2b", rid, "Run a tool?")
  local reloaded = load()
  t.eq(reloaded.permitMessage(903, rid).id, "meal-1a2b", "permit ownership survives reload")
  t.eq(reloaded.permitMessage(901, rid), nil, "an ordinary update cannot answer a permit")
  t.eq(reloaded.permitMessage(903, "000000000000"), nil, "a different rid cannot answer the message")
  t.eq(#reloaded.permitMessages("meal-1a2b", rid), 1, "find the message to remove its buttons")
  t.ok(reloaded.permitOpen("meal-1a2b", rid), "fresh open permit")
  t.eq(reloaded.permit("../escape", rid), nil, "reject task traversal")
  t.eq(reloaded.permit("meal-1a2b", "../escape"), nil, "reject permit traversal")
  permit.state = "closed"
  t.writeJson(tmp .. "/meal-1a2b/permits/" .. rid .. ".json", permit)
  t.ok(not reloaded.permitOpen("meal-1a2b", rid), "closed permit cannot be offered again")
  events("meal-1a2b", hs.json.encode({ kind = "permit", rid = rid }) .. "\n"
    .. hs.json.encode({ kind = "permit_closed", rid = rid, reason = "Timed out" }) .. "\n")
  local permits = {}
  reloaded.poll(function(_, ev) permits[#permits + 1] = ev end)
  t.eq(permits[1] and permits[1].rid, rid, "poll preserves permit id")
  t.eq(permits[2] and permits[2].reason, "Timed out", "poll preserves closure reason")

  task("quick-1234", { state = "ended", ended = now, created = reloaded.startedAt + 1 })
  events("quick-1234", '{"kind":"ended"}\n')
  local ended
  reloaded.poll(function(tk, ev) if tk.id == "quick-1234" then ended = ev.kind end end)
  t.eq(ended, "ended", "new task ending before first poll still closes its topic")

  -- running bin/buddy-task: a fake that writes down its arguments and stdin
  local fake = tmp .. "/fake-task"
  local f = assert(io.open(fake, "w"))
  f:write('#!/bin/sh\necho "$@" > "$BUDDY_TASKS_DIR/args"\ncase "$1" in start|send) cat > "$BUDDY_TASKS_DIR/stdin-$1";; esac\n'
    .. 'echo "-- noise"\necho \'{"ok": true, "task": {"id": "x-1", "name": "X"}}\'\n')
  f:close()
  local R = load({ python = "/bin/sh", bin = fake, terminal = "iTerm", owner = "Owner",
    model = "sonnet", effort = "high", approvals = function() return true end })
  local started, sent, failed, answered
  R.start({ task = "Do X", name = "X", folder = "/tmp", thread = 77, thread_bot = "123",
    model = "opus", effort = "medium" }, "telegram", function(info) started = info end)
  local B = load({ python = "/nonexistent/python", bin = fake })
  B.stop("x-1", function(info) failed = info end)

  return function()
    if not started then return false end
    if not sent then
      sent = true
      R.send("x-1", "use a new file", function() sent = "done" end)
      return false
    end
    if sent ~= "done" then return false end
    if not answered then
      answered = true
      R.answerPermit("x-1", rid, "allow", function() answered = "done" end)
      return false
    end
    if answered ~= "done" then return false end
    t.ok(started.ok and started.task.id == "x-1", "start's answer comes back")
    local req = t.readJson(tmp .. "/stdin-start")
    t.eq(req and req.origin, "telegram", "start says where it came from")
    t.eq(req and req.terminal, "iTerm", "and which terminal to use")
    t.eq(req and req.model, "opus", "task model overrides the configured model")
    t.eq(req and req.effort, "medium", "task effort overrides the configured effort")
    t.eq(req and req.approvals, true, "paired approval switch reaches the helper")
    t.eq(req and req.thread, 77, "new task topic reaches the helper")
    t.eq(req and req.thread_bot, "123", "topic bot reaches the helper")
    t.eq(io.open(tmp .. "/args"):read("a"), "answer x-1 " .. rid .. " allow\n", "answer names the task, permit and one-call decision")
    t.eq(io.open(tmp .. "/stdin-send"):read("a"), "use a new file", "and types the message from stdin")
    t.ok(failed and failed.ok == false and failed.error, "a missing helper is an error, not a crash")
    hs.settings.set(keys.seen, nil)
    hs.settings.set(keys.msg, nil)
    return true
  end
end
