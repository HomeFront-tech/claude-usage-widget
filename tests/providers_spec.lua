-- providers.lua: the provider list, the usage settings from config.lua, colour levels, the
-- tightest limit, the short figures and the fetcher's arguments.
return function(t, dir)
  local P = dofile(dir .. "/providers.lua")
  local function list(x) return table.concat(x, ",") end

  local s = P.settings({})
  t.eq(list(s.order), "claude", "no usage table: Claude only")
  t.ok(s.claudeOnly and s.claudeOn, "Claude-only flags")
  t.eq(s.lead, "claude", "Claude leads")
  t.eq(#s.rest, 0, "nothing else")
  t.eq(s.warn_at .. "/" .. s.hot_at, "70/90", "default levels")
  t.eq(s.alert_red, false, "alert off by default")
  t.eq(s.providers.claude.refresh, 300, "Claude every 5 min")
  t.eq(s.providers.openrouter.refresh, 900, "OpenRouter default")
  t.eq(#P.LIST, 5, "five providers")
  t.eq(P.byId("codex").name, "Codex", "lookup by id")
  t.eq(P.byId("nope"), nil, "unknown id")

  s = P.settings({ usage = { order = { "codex", "claude", "nope", "codex" }, warn_at = 60, hot_at = 80, providers = {
    claude = { refresh = 60, hide = { "Week · Sonnet" } }, codex = { refresh = 10 }, openrouter = { refresh = "120", budget = -5 },
    grok_plan = { plan = "SuperGrok", renews_day = 14 } } } })
  t.eq(list(s.order), "codex,claude", "unknown and repeated ids dropped")
  t.eq(s.lead, "claude", "Claude on leads")
  t.eq(list(s.rest), "codex", "the rest in order")
  t.ok(not s.claudeOnly, "not Claude only")
  t.eq(s.warn_at .. "/" .. s.hot_at, "60/80", "the user's levels")
  t.eq(s.providers.claude.refresh, 300, "Claude no faster than 5 min")
  t.eq(s.providers.codex.refresh, 60, "nothing faster than 1 min")
  t.eq(s.providers.openrouter.refresh, 900, "a non-number refresh is the default")
  t.eq(s.providers.openrouter.budget, nil, "bad budget dropped")
  t.ok(s.providers.claude.hide["Week · Sonnet"], "hide is a set of labels")
  t.eq(s.providers.grok_plan.renews_day, 14, "renewal day")
  t.eq(s.providers.grok_plan.plan, "SuperGrok", "plan name")

  -- bad config: each field falls back alone
  s = P.settings({ usage = { order = "codex", warn_at = 95, hot_at = 80, providers = { grok_plan = { renews_day = 0 } } } })
  t.eq(list(s.order), "claude", "order that isn't a list")
  t.eq(s.warn_at .. "/" .. s.hot_at, "70/90", "yellow above red falls back")
  t.eq(s.providers.grok_plan.renews_day, nil, "day 0 dropped")
  t.eq(P.settings({ usage = { providers = { grok_plan = { renews_day = 14.5 } } } }).providers.grok_plan.renews_day, nil,
    "a fractional day is dropped")
  t.eq(P.settings({ usage = { providers = "junk" } }).providers.codex.refresh, 300, "providers that isn't a table")
  t.eq(P.settings({ usage = "junk" }).lead, "claude", "usage that isn't a table")
  t.eq(list(P.settings({ usage = { order = {} } }).order), "claude", "nothing on means Claude")
  t.eq(P.settings({ usage = { warn_at = 80 } }).warn_at .. "/" .. P.settings({ usage = { warn_at = 80 } }).hot_at, "80/90",
    "only yellow moved (red at its default isn't saved)")
  t.eq(P.settings({ usage = { hot_at = 95 } }).warn_at .. "/" .. P.settings({ usage = { hot_at = 95 } }).hot_at, "70/95", "only red moved")
  t.eq(P.visible({ limits = { { label = "Week", pct = 5, resets_at = "soon" } } }, {})[1].resets_at, nil, "a junk reset time is dropped")
  local off = P.settings({ usage = { order = { "openrouter", "codex" } } })
  t.eq(off.lead, "openrouter", "Claude off: first in order leads")
  t.eq(list(off.rest), "codex", "rest without lead")
  t.ok(not off.claudeOn, "Claude off")

  -- levels: API severity wins when higher
  local d = P.settings({})
  t.eq(P.level(69.9, "normal", d), "ok", "under yellow")
  t.eq(P.level(70, nil, d), "warn", "yellow at 70")
  t.eq(P.level(90, nil, d), "hot", "red at 90")
  t.eq(P.level(10, "critical", d), "hot", "critical is red")
  t.eq(P.level(10, "warning", d), "warn", "warning is yellow")
  t.eq(P.level(95, "warning", d), "hot", "percent wins when higher")
  t.eq(P.level(60, nil, P.settings({ usage = { warn_at = 50, hot_at = 80 } })), "warn", "the user's levels apply")

  -- tightest and visible
  local res = { limits = { { label = "5-hour", pct = 20 }, { label = "Week", pct = 41 }, { label = "bad" }, { pct = 99 }, "junk" },
    credits = { { label = "This month", used = 18.4, limit = 50, pct = 36.8 } }, facts = { "12,000 credits left" } }
  t.eq(P.tightest(res, {}).label, "Week", "highest percent")
  t.eq(P.tightest(res, { Week = true }).label, "This month", "hidden skipped; credits count")
  t.eq(#P.visible(res, { Week = true }), 2, "junk and hidden dropped")
  t.eq(P.visible(res, {})[3].kind, "credit", "credits after limits")
  t.eq(P.visible(res, {})[1].kind, "limit", "limits first")
  t.eq(P.tightest({ facts = { "x" } }, {}), nil, "facts are never tightest")
  t.eq(#P.visible(nil, {}), 0, "no result, nothing visible")
  t.eq(#P.visible({ limits = "junk", credits = 5 }, nil), 0, "junk lists, nothing visible")

  -- figures
  t.eq(P.figure({ pct = 41.4 }), "41%", "limit figure")
  t.eq(P.figure({ used = 3.2, limit = 20, pct = 16 }), "$3.20 / $20", "credit figure as today")
  t.eq(P.figure({ used = 18.4, pct = 0 }), "$18.40", "credit without a cap")
  t.eq(P.short({ label = "Week", pct = 41 }), "41% wk", "short week")
  t.eq(P.short({ label = "5-hour", pct = 7 }), "7% 5h", "short 5-hour")
  t.eq(P.short({ label = "Gizmo", pct = 7 }), "7%", "no suffix")
  t.eq(P.short({ used = 18.4, limit = 50, pct = 36.8 }), "$18 / $50", "short dollars")
  t.eq(P.short({ used = 3.2, limit = 20, pct = 16 }), "$3.20 / $20", "cents under $10")

  -- stale and argv
  local now = os.time()
  t.ok(P.isStale(now - 901, 300, now) and not P.isStale(now - 899, 300, now), "stale after 3x refresh")
  t.eq(list(P.args("codex", {}, false)), "codex", "codex argv")
  t.eq(list(P.args("openrouter", { budget = 50 }, true)), "openrouter,--budget,50,--key-stdin", "budget and stdin key")
  t.eq(list(P.args("xai", { team_id = "team-test", budget = 12.5 }, false)), "xai,--team-id,team-test,--budget,12.5", "team id")
  t.eq(list(P.args("openrouter", { budget = "50", team_id = "" }, false)), "openrouter", "only real values are passed")

  -- the Grok subscription's renewal: a day of the month, the last day when it's short
  local function at(y, m, dd, h) return os.time({ year = y, month = m, day = dd, hour = h or 12 }) end
  local function day(y, m, dd) return os.time({ year = y, month = m, day = dd, hour = 0 }) end
  t.eq(P.nextRenewal(14, at(2026, 10, 28)), day(2026, 11, 14), "next month")
  t.eq(P.nextRenewal(28, at(2026, 10, 28, 15)), day(2026, 10, 28), "renews today")
  t.eq(P.nextRenewal(31, at(2026, 11, 5)), day(2026, 11, 30), "30-day month")
  t.eq(P.nextRenewal(31, at(2027, 2, 1)), day(2027, 2, 28), "February")
  t.eq(P.nextRenewal(29, at(2028, 2, 10)), day(2028, 2, 29), "leap year")
  t.eq(P.nextRenewal(31, at(2026, 12, 31, 23)), day(2026, 12, 31), "late on the day itself")
  t.eq(P.nextRenewal(5, at(2026, 12, 20)), day(2027, 1, 5), "across the new year")
  local g = P.grokPlan({ plan = "SuperGrok", renews_day = 14 }, at(2026, 10, 28))
  t.eq(g.ok and g.plan .. "|" .. g.facts[1], "SuperGrok|Renews Nov 14", "Grok plan facts")
  t.eq(g.provider, "grok_plan", "Grok plan provider")
  t.eq(P.grokPlan({ renews_day = 28 }, at(2026, 10, 28, 9)).facts[1], "Renews today", "renewal today")
  t.eq(#P.grokPlan({}, at(2026, 10, 28)).facts, 0, "no day, no facts")

  -- a Claude-only text is exactly today's
  local only = P.settings({})
  local claude = { limits = { { label = "Current session", pct = 55.4 }, { label = "Week · all models", pct = 20 } } }
  t.eq(P.usageText(claude, {}, only), "Session 55%, week 20%. Halfway there.", "Claude text unchanged")
  t.eq(P.usageText({ limits = { { label = "Current session", pct = 85 } } }, {}, only), "Session 85%. Running hot!", "hot")
  t.eq(P.usageText({ limits = { { label = "Current session", pct = 10 } } }, {}, only), "Session 10%. Plenty left!", "plenty")
  t.eq(P.usageText({ limits = { { label = "Week · all models", pct = 95 } } }, {}, only), "week 95%. Plenty left!",
    "only the week, exactly as before")
  t.eq(P.usageText(nil, {}, only), "I can't see your usage right now.", "no numbers")
  local hideSession = P.settings({ usage = { providers = { claude = { hide = { "Current session" } } } } })
  t.eq(P.usageText(claude, {}, hideSession), "week 20%. Plenty left!", "a hidden Claude limit is left out")

  -- several providers
  local many = P.settings({ usage = { order = { "claude", "codex", "openrouter", "grok_plan" } } })
  local others = { { id = "codex", name = "Codex", res = { ok = true, limits = { { label = "Week", pct = 41 } } } },
    { id = "openrouter", name = "OpenRouter", err = "Key not accepted" },
    { id = "grok_plan", name = "Grok", res = g } }
  t.eq(P.usageText(claude, others, many), "Session 55%, week 20%. Halfway there. Codex: Week 41%. OpenRouter: Key not accepted. "
    .. "Grok: SuperGrok, renews Nov 14.", "every provider in order")
  t.eq(P.usageText(nil, { others[1] }, P.settings({ usage = { order = { "codex" } } })), "Codex: Week 41%.", "Claude off")
  t.eq(P.summary("Codex", { ok = true, blocked = true, limits = {} }, nil, {}), "Codex: blocked right now.", "blocked")
  t.eq(P.summary("Codex", nil, nil, {}), "Codex: no numbers yet.", "nothing yet")
  t.eq(P.summary("OpenRouter", { ok = true, credits = { { label = "This month", used = 18.4, limit = 50, pct = 36.8 } } }, nil, {}),
    "OpenRouter: This month $18.40 / $50.", "credit summary")
  t.eq(P.summary("Codex", { ok = true, limits = { { label = "Week", pct = 41 } } }, nil, { Week = true }), "Codex: no numbers yet.",
    "hidden limits left out")
  t.eq(P.summary("Codex", { ok = true, facts = { "12,000 credits left" } }, nil, {}), "Codex: 12,000 credits left.", "facts")
  t.eq(P.checkText({ ok = true, limits = { { label = "Week", pct = 41 } } }, {}), "Working · Week 41%", "check: tightest")
  t.eq(P.checkText({ ok = true, facts = { "12,000 credits left" } }, {}), "Working · 12,000 credits left", "check: fact")
  t.eq(P.checkText({ ok = true }, {}), "Working", "check: nothing to show")
  t.eq(P.checkText({ ok = false, error = "Key not accepted" }, {}), "Key not accepted", "check: error")
  t.eq(P.checkText(nil, {}), "Couldn't run the check", "check: nothing")
  t.eq(P.statusLabel(only) .. "|" .. P.statusLabel(many), "Claude plan usage: |AI usage: ", "status label")
end
