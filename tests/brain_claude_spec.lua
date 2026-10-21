-- Claude requests keep the conversation and respect the daily unprompted cap.
return function(t, dir)
  local saved = hs.settings.get("claudeBuddy.agentDay")
  local B = dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "haiku", agent_dir = t.tmpdir() }, "Sam", false)
  t.ok(B.assistant():find("never send, post or message anything", 1, true), "assistant rules in the prompt")
  local r = B.request("chat", {
    { role = "system", content = "SYS" },
    { role = "assistant", content = "Nice tabs." },
    { role = "user", content = "find the deck quote", images = { "QUJD" } },
  })
  t.eq(r.kind, "chat", "kind")
  t.eq(r.system, "SYS", "system kept")
  t.ok(r.prompt:find("You: Nice tabs.", 1, true), "assistant turn labelled")
  t.ok(r.prompt:sub(-19) == "find the deck quote", "latest user turn last")
  t.eq(r.image, "QUJD", "image passed")

  hs.settings.set("claudeBuddy.agentDay", { day = os.date("%Y-%m-%d"), n = 300 })
  t.eq(B.quip({ kind = "event", what = "x", unprompted = true }, function() end), false, "capped unprompted quip refused")
  hs.settings.set("claudeBuddy.agentDay", saved)

  local savedNotes = hs.settings.get("claudeBuddy.notes")
  local originalTaskNew = hs.task.new
  local function failedNotes(label, makeTask)
    hs.settings.set("claudeBuddy.notes", { text = "", at = 0 })
    local agentDir = t.tmpdir()
    local file = assert(io.open(agentDir .. "/notes-new.jsonl", "w"))
    file:write(hs.json.encode({ note = "first note" }) .. "\n")
    file:write(hs.json.encode({ note = "second note" }) .. "\n")
    file:close()
    local brain = dofile(dir .. "/brain.lua").configure({ engine = "claude", agent_dir = agentDir }, "Sam", false)
    local calls = 0
    hs.task.new = function(...)
      calls = calls + 1
      return makeTask(...)
    end
    local ok, err = pcall(function()
      brain.remember({ { role = "user", content = "hello", at = 1 } })
      brain.remember({ { role = "user", content = "hello", at = 1 } })
    end)
    hs.task.new = originalTaskNew
    t.ok(ok, label .. " reports failure through callback: " .. tostring(err))
    t.eq(calls, 2, label .. " clears noting for retry")
    t.eq(brain.busy(), false, label .. " clears inflight")
    local lines = {}
    for line in io.lines(agentDir .. "/notes-new.jsonl") do
      lines[#lines + 1] = hs.json.decode(line).note
    end
    t.eq(#lines, 2, label .. " preserves both notes")
    t.eq(lines[1], "first note", label .. " preserves first note")
    t.eq(lines[2], "second note", label .. " preserves second note")
  end
  failedNotes("runner creation failure", function() return nil end)
  failedNotes("environment failure", function()
    return { setEnvironment = function() error("environment failed") end }
  end)
  failedNotes("input failure", function()
    return { setEnvironment = function() end, setInput = function() error("input failed") end }
  end)
  hs.settings.set("claudeBuddy.notes", savedNotes)

  -- Claude looks up your login in the keychain by USER; without it, it says the session expired
  local env
  local originalNew = hs.task.new
  hs.task.new = function()
    return { setEnvironment = function(_, e) env = e end, setInput = function() end, start = function() return true end }
  end
  B.agent().run({ kind = "chat", system = "s", prompt = "p" }, function() end)
  hs.task.new = originalNew
  t.eq(env and env.USER, os.getenv("USER"), "runner passes USER")
  t.eq(env and env.LOGNAME, os.getenv("LOGNAME"), "runner passes LOGNAME")
  t.ok(env and env.BUDDY_AGENT_DIR, "runner keeps agent dir")

  local O =dofile(dir .. "/brain.lua").configure({}, "Sam", false)
  t.eq(O.engine(), "ollama", "no engine = ollama")
end
