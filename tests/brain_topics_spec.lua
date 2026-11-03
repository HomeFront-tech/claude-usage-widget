-- brain.lua topics: the batch of topics and lines it writes from headlines, and current
-- topics turning up in some of its made-up lines. The brain is Ollama with a fake reply.
return function(t, dir)
  local B = dofile(dir .. "/brain.lua").configure({ engine = "ollama",
    agent_dir = t.tmpdir() .. "/agent" }, "Sam", false)
  B.setPrivacy({ watching = function() return true end, private = function() return false end })
  local sent, reply = {}, nil
  local post, random = hs.http.asyncPost, math.random
  hs.http.asyncPost = function(_, body, _, done)
    sent[#sent + 1] = hs.json.decode(body)
    done(200, hs.json.encode({ message = { content = reply } }))
  end
  local ok, err = pcall(function()
    reply = 'Sure! {"topics": ["A comeback tour"], "lines": {"idle": ["Hi there."]}} Hope that helps.'
    local got
    local started = B.topics({ "Band's comeback tour sells out" }, { idle = "nothing special going on" },
      function(r) got = r end)
    t.ok(started, "topics: starts")
    t.ok(got and got.topics[1] == "A comeback tour" and got.lines.idle[1] == "Hi there.",
      "topics: the JSON is pulled out of the reply")
    local ask = sent[1].messages[2].content
    t.ok(ask:find("Band's comeback tour sells out", 1, true), "topics: headlines in the ask")
    t.ok(ask:find("idle: nothing special going on", 1, true), "topics: moods in the ask")
    t.ok(ask:find("politics", 1, true) and ask:find("deaths", 1, true), "topics: the content rule is in the ask")
    t.ok(sent[1].messages[1].content:find("You are Buddy", 1, true), "topics: written in Buddy's own voice")

    reply = "no json here"
    got = "unset"
    B.topics({ "x" }, { idle = "y" }, function(r) got = r end)
    t.eq(got, nil, "topics: a reply without JSON gives nil")

    -- made-up lines sometimes bring up what's going on
    reply = "Nice line."
    B.setTopics(function() return "A comeback tour; Robot vacuums" end)
    math.random = function() return 1 end -- the topics are picked, and the first angle
    B.quip({ kind = "screen", app = "Finder", title = "Docs" }, function() end)
    t.ok(sent[#sent].messages[2].content:find("A comeback tour; Robot vacuums", 1, true), "quip: topics in the ask when picked")
    B.quip({ kind = "joke", app = "Finder", title = "Docs" }, function() end)
    t.ok(sent[#sent].messages[2].content:find("A comeback tour; Robot vacuums", 1, true), "joke: topics in the ask when picked")
    B.quip({ kind = "health", what = "Time for water." }, function() end)
    t.ok(not sent[#sent].messages[2].content:find("comeback", 1, true), "health lines leave the news out")
    math.random = function(m) return m or 0.99 end -- not picked
    B.quip({ kind = "screen", app = "Finder", title = "Docs" }, function() end)
    t.ok(not sent[#sent].messages[2].content:find("comeback", 1, true), "quip: no topics when not picked")
    math.random = function() return 1 end
    B.setTopics(nil)
    B.quip({ kind = "screen", app = "Finder", title = "Docs" }, function() end)
    t.ok(not sent[#sent].messages[2].content:find("comeback", 1, true), "quip: no topics without a source")
  end)
  hs.http.asyncPost, math.random = post, random
  t.ok(ok, "brain topics: " .. tostring(err))
end
