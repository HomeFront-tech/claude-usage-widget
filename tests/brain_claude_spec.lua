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

  local O = dofile(dir .. "/brain.lua").configure({}, "Sam", false)
  t.eq(O.engine(), "ollama", "no engine = ollama")
end
