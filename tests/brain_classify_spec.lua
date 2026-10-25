-- B.classify: one JSON answer about an app, from either engine, checked against the mood list.
return function(t, dir)
  -- the stubs on hs.task.new and hs.http.asyncPost are put back even if a check throws
  local savedTask, savedPost = hs.task.new, hs.http.asyncPost
  local ok, err = pcall(function()
    local moods = { watching = "videos and shows", reading = "documents" }
    local req = { label = "YouTube", titles = { "cats", "dogs" }, facts = "YouTube: 2nd time today", moods = moods, image = "QUJD" }

    -- Claude: kind learn, prompt carries the label, titles and moods; the first {…} is the answer
    local savedDay = hs.settings.get("claudeBuddy.agentDay")
    local B = dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "auto", agent_dir = t.tmpdir() }, "Sam", false)
    local sent, finish
    hs.task.new = function(_, callback)
      finish = callback
      return { setEnvironment = function() end, setInput = function(_, s) sent = hs.json.decode(s) end,
               start = function() return true end }
    end
    local got = "unset"
    t.ok(B.classify(req, function(r) got = r end), "claude classify starts")
    hs.task.new = savedTask
    t.eq(sent.kind, "learn", "kind learn")
    t.ok(sent.prompt:find("YouTube", 1, true) and sent.prompt:find("cats", 1, true), "label and titles in the prompt")
    t.ok(sent.prompt:find("watching", 1, true) and sent.prompt:find("videos and shows", 1, true), "moods in the prompt")
    t.ok(sent.prompt:find("2nd time today", 1, true), "facts in the prompt")
    t.eq(sent.image, "QUJD", "snapshot passed")
    finish(0, hs.json.encode({ ok = true, text = 'Sure! {"mood":"watching","dayparts":{"evening":"reading","night":"bogus"},"question":"Is this a show?"} done {"mood":"reading"}' }), "")
    t.eq(got.mood, "watching", "first object wins")
    t.eq(got.dayparts.evening, "reading", "valid daypart kept")
    t.eq(got.dayparts.night, nil, "unknown daypart mood dropped")
    t.eq(got.question, "Is this a show?", "question kept")

    hs.task.new = function(_, callback)
      finish = callback
      return { setEnvironment = function() end, setInput = function() end, start = function() return true end }
    end
    B.classify(req, function(r) got = r end)
    finish(0, hs.json.encode({ ok = true, text = '{"mood":"party"}' }), "")
    t.eq(got, nil, "unknown mood gives nil")
    B.classify(req, function(r) got = r end)
    finish(0, hs.json.encode({ ok = true, text = "I think it is a show." }), "")
    t.eq(got, nil, "no JSON gives nil")
    B.classify(req, function(r) got = r end)
    finish(0, hs.json.encode({ ok = true, text = '{"mood": "reading", "note": "a } in a string"}' }), "")
    t.eq(got and got.mood, "reading", "braces inside strings don't end the object")
    hs.task.new = savedTask

    hs.settings.set("claudeBuddy.agentDay", { day = os.date("%Y-%m-%d"), n = 300 })
    t.eq(B.classify(req, function() end), false, "the daily cap on unprompted calls applies")
    local before = hs.settings.get("claudeBuddy.agentDay").n
    t.eq(B.canClassify(), false, "canClassify is false at the cap")
    t.eq(hs.settings.get("claudeBuddy.agentDay").n, before, "and asking does not count a call")
    hs.settings.set("claudeBuddy.agentDay", { day = os.date("%Y-%m-%d"), n = 5 })
    t.eq(B.canClassify(), true, "canClassify is true under the cap")
    t.eq(hs.settings.get("claudeBuddy.agentDay").n, 5, "and still counts nothing")
    hs.settings.set("claudeBuddy.agentDay", savedDay)

    -- Ollama: same prompt, the screenshot rides on the user message
    local O = dofile(dir .. "/brain.lua").configure({ model = "gemma3:4b", agent_dir = t.tmpdir() }, "Sam", false)
    local body, reply
    hs.http.asyncPost = function(_, b, _, cb) body, reply = hs.json.decode(b), cb end
    got = "unset"
    t.ok(O.classify(req, function(r) got = r end), "ollama classify starts")
    hs.http.asyncPost = savedPost
    local user = body.messages[#body.messages]
    t.ok(user.content:find("YouTube", 1, true) and user.content:find("videos and shows", 1, true), "same prompt for Ollama")
    t.eq(user.images[1], "QUJD", "image on the user message")
    reply(200, hs.json.encode({ message = { content = 'Here: {"mood":"reading"}' }, prompt_eval_count = 1, eval_count = 1 }))
    t.eq(got.mood, "reading", "ollama answer parsed")
    t.eq(O.busy(), false, "no request left running")
  end)
  hs.task.new, hs.http.asyncPost = savedTask, savedPost
  if not ok then error(err, 0) end
end
