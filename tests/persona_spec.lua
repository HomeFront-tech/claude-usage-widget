-- brain.lua: Grok is a teammate, not a rival, when config.lua has a grok table.
return function(t, dir)
  local B1 = dofile(dir .. "/brain.lua").configure({}, "Sam", true)
  t.ok(not B1.persona():find("Codex, Grok", 1, true), "Grok not in the roast list")
  t.ok(B1.persona():find("Grok Bot is your teammate", 1, true), "teammate line")
  t.ok(B1.persona():find("Gemini", 1, true), "still roasts the others")
  local B2 = dofile(dir .. "/brain.lua").configure({}, "Sam", false)
  t.ok(B2.persona():find("Grok", 1, true) and not B2.persona():find("teammate", 1, true), "unchanged without grok")

  -- Grok's replies reach the model as things Buddy passed on, never as a third role
  local turns = B1.turns({
    { role = "user", content = "ask Grok what's 2+2" },
    { role = "assistant", content = "Passing it to Grok…" },
    { role = "grok", content = "4" },
    { role = "user", content = "nice" },
  })
  t.eq(#turns, 3, "grok reply merges into the assistant turn")
  t.eq(turns[2].role, "assistant", "assistant role")
  t.ok(turns[2].content:find("(Grok Bot's reply, which you passed on: 4)", 1, true), "labelled as Grok's")

  -- a Claude Code session's update reaches the model as something Buddy passed on, under its name
  local taskTurns = B1.turns({
    { role = "user", content = "build me a meal tracker" },
    { role = "task", content = "Which file should meals go in?", name = "Meal tracker" },
  })
  t.eq(taskTurns[2].role, "assistant", "a session's update is an assistant turn")
  t.ok(taskTurns[2].content:find("Claude Code session Meal tracker, which you passed on: Which file", 1, true), "labelled with the session")

  -- the task tools are mentioned only when tasks are on
  t.ok(not B2.assistant():find("task_start", 1, true), "no task tools by default")
  local B4 = dofile(dir .. "/brain.lua").configure({}, "Sam", false, false, { tasks = true })
  t.ok(B4.assistant():find("task_start", 1, true) and B4.assistant():find("task_send", 1, true), "task tools with tasks on")
  t.ok(B4.assistant():find("Sessions run on their Claude Code default model unless", 1, true), "no default model set")
  local B5 = dofile(dir .. "/brain.lua").configure({}, "Sam", false, false, { tasks = true, task_model = "claude-opus-5-5" })
  t.ok(B5.assistant():find("Sessions run on claude-opus-5-5 unless they ask for another Claude model", 1, true)
    and B5.assistant():find("task_start's model", 1, true), "the brain knows the default model and that it can pick one")
  local post, sent = hs.http.asyncPost, nil
  hs.http.asyncPost = function(_, body) sent = hs.json.decode(body) end
  pcall(B4.chat, { { role = "user", content = "spawn a session", at = os.time() } }, { telegram = true }, function() end)
  hs.http.asyncPost = post
  t.ok(sent and sent.messages[1].content:find("send /task", 1, true), "a local model points them at /task")

  -- the longer Buddy has known them, the more candid it gets
  local B3 = dofile(dir .. "/brain.lua").configure({}, "Sam", false)
  t.ok(B3.persona():find("You only just met them: friendly and a little cheeky.", 1, true), "new friend by default")
  B3.setKnown(2)
  t.ok(B3.persona():find("You only just met them", 1, true), "under 3 days is still new")
  B3.setKnown(3)
  t.ok(B3.persona():find("You've known them 3 days: be candid and familiar.", 1, true), "3 days is candid")
  t.ok(not B3.persona():find("just met", 1, true), "only one sentence at a time")
  B3.setKnown(29)
  t.ok(B3.persona():find("You've known them 29 days: be candid and familiar.", 1, true), "29 days is still candid")
  B3.setKnown(30)
  t.ok(B3.persona():find("You're old friends (30 days): blunt, honest and affectionate, and you bring up their habits.", 1, true), "30 days is old friends")

  -- Forget makes them strangers again (the notes setting is put back: the specs run in the live Hammerspoon)
  local savedNotes = hs.settings.get("claudeBuddy.notes")
  local forgot = pcall(B3.forget)
  hs.settings.set("claudeBuddy.notes", savedNotes)
  t.ok(forgot, "forget runs")
  t.ok(B3.persona():find("You only just met them", 1, true), "after Forget the persona is new again")
  t.ok(not B3.persona():find("old friends", 1, true), "and no longer old friends")

  -- facts reach no prompt when watching is off
  local off = { watching = function() return false end, private = function() return false end }
  B3.setPrivacy(off)
  local scrubbed = B3.scrub({ kind = "fact", facts = "YouTube: 2nd time today", app = "Chrome", title = "x" })
  t.eq(scrubbed.facts, nil, "facts dropped while not watching")
  t.eq(scrubbed.kind, "fact", "kind kept")
  t.eq(B3.quip({ kind = "fact", facts = "YouTube: 2nd time today", unprompted = true }, function() end), false,
    "a fact quip is not asked for while not watching")
end
