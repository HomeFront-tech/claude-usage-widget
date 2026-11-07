-- usage_report.lua: the plain-text report behind the menu's "Buddy's usage".
return function(t, dir)
  local R = dofile(dir .. "/usage_report.lua")
  local zero = { calls = 0, tokens = 0, cost = 0, local_calls = 0, models = {}, kinds = {} }
  local report = { ok = true, periods = {
    today = { calls = 3, tokens = 1000, cost = 0.01, local_calls = 0,
              models = { ["claude-haiku-5-5"] = { tokens = 810, cost = 0.002 }, ["claude-opus-5-5"] = { tokens = 190, cost = 0.008 } },
              kinds = { chat = { tokens = 700, cost = 0.008 }, quip = { tokens = 300, cost = 0.002 } } },
    week = zero, month = zero,
  } }
  local text = R.format(report)
  t.ok(text:find("Today: 3 calls", 1, true), "today's calls")
  t.ok(text:find("Haiku 5.5", 1, true), "model label")
  t.ok(text:find("81%", 1, true), "model share")
  t.ok(text:find("19%", 1, true), "second share")
  t.ok(text:find("≈$0.01", 1, true), "cost")
  t.ok(text:find("chat 70%", 1, true), "kinds line")
  t.ok(not text:find("Last 7 days", 1, true), "empty periods are left out")
  t.eq(R.format({ ok = true, periods = { today = zero, week = zero, month = zero } }),
       "I haven't used any Claude yet.", "all zero")
  t.eq(R.format(nil), "I can't read my usage right now.", "no report")
  t.eq(R.label("claude-haiku-5-5"), "Haiku 5.5", "haiku label")
  t.eq(R.label("claude-opus-5-5"), "Opus 5.5", "opus label")
  t.eq(R.label("ollama:gemma3:4b"), "gemma3:4b (this Mac)", "ollama label")
  t.eq(R.label("unknown"), "Claude (older)", "unknown label")
  local local_only = { ok = true, periods = { today = { calls = 2, tokens = 50, cost = 0, local_calls = 2,
    models = { ["ollama:gemma3:4b"] = { tokens = 50, cost = 0 } }, kinds = {} }, week = zero, month = zero } }
  t.ok(R.format(local_only):find("gemma3:4b (this Mac)", 1, true), "local only still reports")
  local tasks = R.format({ ok = true, periods = {
    today = { calls = 1, tokens = 10, cost = 0.01, local_calls = 0, models = {}, kinds = {},
              tasks = { sessions = 2, tokens = 412000000, cost = 180.5 } },
    week = { calls = 0, tokens = 0, cost = 0, local_calls = 0, models = {}, kinds = {},
             tasks = { sessions = 1, tokens = 5, cost = 1.25 } },
    month = zero } })
  t.ok(tasks:find("Task sessions I started: 2, ≈$180.50 (already in your Claude Code numbers)", 1, true), "task sessions shown apart")
  t.ok(tasks:find("Last 7 days:\n  Task sessions I started: 1", 1, true), "a period with only task sessions still shows")
  t.ok(not R.format(report):find("Task sessions", 1, true), "no task sessions, no line")
end
