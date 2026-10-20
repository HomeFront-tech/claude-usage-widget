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
end
