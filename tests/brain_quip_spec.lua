-- brain.lua quips: made-up lines that don't all sound alike. A log of real ones showed a
-- formula: a visit count, their name, and the same news item, line after line.
return function(t, dir)
  local B = dofile(dir .. "/brain.lua").configure({ engine = "ollama",
    agent_dir = t.tmpdir() .. "/agent" }, "Sam", false)
  local watching = true
  B.setPrivacy({ watching = function() return watching end, private = function() return false end })
  local sent, reply = {}, "Nice."
  local post, random = hs.http.asyncPost, math.random
  hs.http.asyncPost = function(_, body, _, done)
    sent[#sent + 1] = hs.json.decode(body)
    done(200, hs.json.encode({ message = { content = reply } }))
  end
  local function ask() return sent[#sent].messages[2].content end
  local function screen() return B.quip({ kind = "screen", app = "Finder", title = "Docs" }, function() end) end
  local ok, err = pcall(function()
    math.random = function(m) return m or 0.99 end -- no news, the last angle

    -- their name: fine now and then, not in every line
    reply = "Tidy folders."
    screen()
    t.ok(not ask():find("Don't use their name", 1, true), "no name rule before he has said anything")
    reply = "Finder again, Sam?"
    screen()
    t.ok(not ask():find("Don't use their name", 1, true), "nor while his recent lines don't have it")
    reply = "Another one."
    screen()
    t.ok(ask():find("Don't use their name", 1, true), "after a line with their name, the next one leaves it out")
    for _ = 1, 4 do screen() end
    t.ok(not ask():find("Don't use their name", 1, true), "four lines later the name is allowed again")

    -- it's told its last ten lines, and not to open the same way
    for i = 1, 12 do
      reply = "line number " .. i .. "."
      screen()
    end
    reply = "Nice."
    screen()
    t.ok(ask():find("line number 12.", 1, true) and ask():find("line number 3.", 1, true), "the last ten lines are in the ask")
    t.ok(not ask():find("line number 2.", 1, true), "older ones are not")
    t.ok(ask():find("open the same way", 1, true), "and it's told not to start the same way")

    -- the news: one topic at a time, and not the same one twice running
    B.setTopics(function() return "A comeback tour; Robot vacuums; A chess final" end)
    math.random = function() return 1 end -- the news is picked, the first topic, the first angle
    screen()
    t.ok(ask():find("A comeback tour", 1, true), "one topic is in the ask")
    t.ok(not ask():find("Robot vacuums", 1, true) and not ask():find("chess", 1, true), "only one")
    screen()
    t.ok(ask():find("Robot vacuums", 1, true) and not ask():find("comeback", 1, true), "the next line gets a different topic")
    B.quip({ kind = "session", topic = "Fix login", state = "wait" }, function() end)
    t.ok(not ask():find("Robot vacuums", 1, true), "and so does the one after")

    -- a line about a count doesn't get the news, and isn't a recital of numbers
    t.ok(B.quip({ kind = "fact", facts = "YouTube: 5th time today, 47 min so far", unprompted = true }, function() end), "a fact line starts")
    t.ok(ask():find("YouTube: 5th time today", 1, true), "with the facts")
    t.ok(not ask():find("comeback", 1, true) and not ask():find("vacuums", 1, true) and not ask():find("chess", 1, true), "and no news")
    t.ok(ask():find("one number at most", 1, true), "and it's told to go easy on the numbers")

    -- two windows, one job
    local wf = { kind = "workflow", a = "Editor (window: main.lua)", b = "Localhost (window: My page)",
      mins = 12, flips = 9, times = 4, days = 3, unprompted = true }
    t.ok(B.quip(wf, function() end), "a workflow line starts")
    t.ok(ask():find("Editor (window: main.lua)", 1, true) and ask():find("Localhost (window: My page)", 1, true), "both windows are in the ask")
    t.ok(ask():find("12 minutes", 1, true) and ask():find("one job", 1, true), "as one job, with how long")
    t.ok(ask():find("4 times", 1, true) and ask():find("3 days", 1, true), "and that it has seen the pair before")
    t.ok(not ask():find("comeback", 1, true) and not ask():find("vacuums", 1, true) and not ask():find("chess", 1, true), "and no news")
    wf.times, wf.days, wf.mins = 1, 1, 0
    B.quip(wf, function() end)
    t.ok(not ask():find("before", 1, true), "a first-time pair isn't called a habit")
    local n = #sent
    watching = false
    t.eq(B.quip(wf, function() end), false, "with watching off there is no workflow line")
    t.eq(#sent, n, "and nothing about the windows is sent")
    watching = true
  end)
  hs.http.asyncPost, math.random = post, random
  t.ok(ok, "brain quips: " .. tostring(err))
end
