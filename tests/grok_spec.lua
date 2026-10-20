-- grok.lua: routing, message wrapping, reply picking, bubble text.
return function(t, dir)
  local G = dofile(dir .. "/grok.lua").configure({}, "Sam")

  -- routing
  t.ok(G.isFor("ask Grok what's 2+2"), "ask grok")
  t.ok(G.isFor("Grok, check the forecast"), "leading grok comma")
  t.ok(G.isFor("Have grok look at this"), "have grok")
  t.ok(G.isFor("can you tell Grok Bot hi"), "tell grok bot")
  t.ok(G.isFor("get GROK to plan it"), "get grok to, caps")
  t.ok(not G.isFor("I hate grok"), "mention only")
  t.ok(not G.isFor("that task grokking thing"), "task grokking")
  t.ok(not G.isFor("grokking is fun"), "grokking")

  -- wrapping
  local w = G.wrap("what's 2+2?", "b1")
  t.ok(w:find("[buddy:b1]", 1, true), "marker")
  t.ok(w:find("what's 2+2?", 1, true), "owner words verbatim")
  t.ok(w:find("buddy-opus ask", 1, true), "opus footer")
  t.ok(w:find("Sam", 1, true), "owner name")

  -- reply picking
  local e = {
    { kind = "message", role = "user", timestampMs = 2000, text = "[buddy:b1] q" },
    { kind = "message", role = "assistant", timestampMs = 1000, text = "old" },
    { kind = "message", role = "assistant", timestampMs = 3000, content = "first new" },
    { kind = "message", role = "assistant", timestampMs = 4000, text = "re [buddy:b1]: 4" },
  }
  t.eq(G.pickReply(e, 1500, "b1"), "re [buddy:b1]: 4", "prefers marker")
  e[4] = nil
  t.eq(G.pickReply(e, 1500, "b1"), "first new", "first bot message after send")
  t.eq(G.pickReply(e, 5000, "b1"), nil, "nothing newer")

  -- bubble text
  t.eq(G.short("Four. Also, hi!"), "Four.", "first sentence")
  t.ok(#G.short(string.rep("x", 400)) <= 120, "capped at 120")
end
