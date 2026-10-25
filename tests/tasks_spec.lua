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

  -- the question, then their answer
  local q = K.ask({ kind = "start", task = "Build a meal tracker", name = "Meal tracker", folder = os.getenv("HOME") .. "/dev/app" })
  t.ok(q:find("Meal tracker, in ~/dev/app", 1, true) and q:find("Reply yes or no", 1, true), "asks with the name and folder")
  local verdict, held = K.answer("yes please")
  t.eq(verdict, "yes", "yes")
  t.eq(held and held.name, "Meal tracker", "and what it was about")
  t.eq(K.answer("yes"), nil, "asked once, answered once")
  K.ask({ kind = "send", id = "a-1", name = "Meal tracker", text = "add water" })
  t.eq(K.answer("no"), "no", "no")
  K.ask({ kind = "start", task = "x", name = "y", folder = "/" })
  t.eq(K.answer("actually, what's the weather?"), nil, "anything else drops the question")
  t.eq(K.pending, nil, "and it's gone")
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
  task("fix-3c4d", { name = "Fix build" })
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

  -- running bin/buddy-task: a fake that writes down its arguments and stdin
  local fake = tmp .. "/fake-task"
  local f = assert(io.open(fake, "w"))
  f:write('#!/bin/sh\necho "$@" > "$BUDDY_TASKS_DIR/args"\ncat > "$BUDDY_TASKS_DIR/stdin-$1"\n'
    .. 'echo "-- noise"\necho \'{"ok": true, "task": {"id": "x-1", "name": "X"}}\'\n')
  f:close()
  local R = load({ python = "/bin/sh", bin = fake, terminal = "iTerm", owner = "Sam", effort = "high" })
  local started, sent, failed
  R.start({ task = "Do X", name = "X", folder = "/tmp" }, "telegram", function(info) started = info end)
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
    t.ok(started.ok and started.task.id == "x-1", "start's answer comes back")
    local req = t.readJson(tmp .. "/stdin-start")
    t.eq(req and req.origin, "telegram", "start says where it came from")
    t.eq(req and req.terminal, "iTerm", "and which terminal to use")
    t.eq(req and req.effort, "high", "and config.lua's effort")
    t.eq(io.open(tmp .. "/args"):read("a"), "send x-1\n", "send names the session")
    t.eq(io.open(tmp .. "/stdin-send"):read("a"), "use a new file", "and types the message from stdin")
    t.ok(failed and failed.ok == false and failed.error, "a missing helper is an error, not a crash")
    hs.settings.set(keys.seen, nil)
    hs.settings.set(keys.msg, nil)
    return true
  end
end
