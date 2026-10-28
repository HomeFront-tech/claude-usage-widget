-- usage_alerts.lua: "Tell me when one turns red" says each limit once, and again only after
-- it drops back below yellow (a new window, or a raised cap).
return function(t, dir)
  local P, A = dofile(dir .. "/providers.lua"), dofile(dir .. "/usage_alerts.lua")
  local on, state = P.settings({ usage = { alert_red = true } }), {}
  local fires
  fires, state = A.check(state, "codex", { { label = "Week", pct = 91 } }, on)
  t.eq(#fires, 1, "turning red fires")
  t.eq(fires[1].label, "Week", "the item that fired")
  t.ok(state["codex|Week"], "remembered")
  t.eq(#A.check(state, "codex", { { label = "Week", pct = 95 } }, on), 0, "no repeat while red")
  t.eq(#A.check(state, "codex", { { label = "Week", pct = 80 } }, on), 0, "yellow doesn't re-arm")
  t.ok(state["codex|Week"], "still fired")
  A.check(state, "codex", { { label = "Week", pct = 10 } }, on)
  t.eq(state["codex|Week"], nil, "a drop below yellow re-arms")
  t.eq(#A.check(state, "codex", { { label = "Week", pct = 92 } }, on), 1, "fires again next window")
  t.eq(#A.check({}, "codex", { { label = "Week", pct = 40, severity = "critical" } }, on), 1, "critical fires below red")
  t.eq(#A.check({}, "openrouter", { { label = "This month", used = 46, limit = 50, pct = 92 } }, on), 1, "credits fire")
  local two = {}
  t.eq(#A.check(two, "codex", { { label = "Week", pct = 95 }, { label = "5-hour", pct = 99 } }, on), 2, "each limit on its own")
  t.eq(#A.check(two, "claude", { { label = "Week", pct = 95 } }, on), 1, "the same label on another AI is its own")
  local quiet = {}
  t.eq(#A.check(quiet, "codex", { { label = "Week", pct = 99 } }, P.settings({})), 0, "off by default")
  t.eq(next(quiet), nil, "nothing stored")
  t.eq(A.line("Codex", { label = "Week", pct = 91.4 }, "Resets Mon 9:00 AM"), "Heads up: Codex Week is at 91%. Resets Mon 9:00 AM.", "line")
  t.eq(A.line("OpenRouter", { label = "This month", used = 46, limit = 50, pct = 92 }, ""), "Heads up: OpenRouter This month is at 92%.",
    "no reset")
end
