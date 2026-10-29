-- The card's drawn text: a Claude-only card stays exactly as it was before other AIs.
return function(t, dir)
  local W = dofile(dir .. "/usage_widget.lua")
  local function texts(els)
    local out = {}
    for _, e in ipairs(els) do
      if e.type == "text" then out[#out + 1] = e.text:getString() end
    end
    return out
  end
  local now = os.time()
  local CLAUDE = { ok = true, plan = "max", fetched_at = now - 30,
    limits = { { label = "Current session", pct = 72, severity = "normal", resets_at = now + 2 * 3600 + 13 * 60 + 30 },
               { label = "Week · all models", pct = 38, severity = "normal" } },
    credits = { { label = "Extra usage", used = 3.2, limit = 20, pct = 16 } },
    breakdown = { { name = "Opus", pct = 30 } } }
  local CLAUDE_TEXT = "Claude|Max · just now|Reading Claude Code's logs…|Tokens · 24h|Open chart ›|Current session|72%|"
    .. "Resets in 2 hr 13 min|Week · all models|38%||Extra usage|$3.20 / $20||This week: Opus 30%"
  local function claudeOnly(name)
    t.eq(table.concat(texts((W.elements(now))), "|"), CLAUDE_TEXT, name)
  end

  -- colour levels and Claude's settings come from config.lua's usage table; the spec
  -- starts from empty settings so a developer's own config.lua (other AIs on) can't leak in
  local P = dofile(dir .. "/providers.lua")
  W.inject({ settings = P.settings({}), data = CLAUDE, lastError = false, tokens = false })
  claudeOnly("Claude-only card text")

  t.ok(W.barColor(72) == W.C.warn and W.barColor(91) == W.C.hot and W.barColor(10) == W.C.ok, "default levels")
  t.ok(W.barColor(10, "critical") == W.C.hot, "API severity wins")
  W.inject({ settings = P.settings({ usage = { warn_at = 50, hot_at = 80 } }) })
  t.ok(W.barColor(60) == W.C.warn and W.barColor(85) == W.C.hot, "the user's levels")
  W.inject({ settings = P.settings({ usage = { providers = { claude = { hide = { "Week · all models" } } } } }), data = CLAUDE })
  t.ok(not table.concat(texts((W.elements(now))), "|"):find("Week · all models", 1, true), "hidden Claude limit left off")
  W.inject({ settings = P.settings({ usage = { providers = { claude = { refresh = 600 } } } }) })
  t.ok(not W.isStale(now - 20 * 60, now), "slower Claude refresh, later grey")
  W.inject({ settings = P.settings({}), data = CLAUDE })
  t.ok(W.isStale(now - 20 * 60, now), "default refresh, grey after 15 min")
  claudeOnly("Claude-only card text with the default settings")

  -- other AIs: small rows under Claude, each showing its tightest limit
  local function text() return table.concat(texts((W.elements(now))), "|") end
  local multi = P.settings({ usage = { order = { "claude", "codex", "openrouter", "grok_plan" },
    providers = { grok_plan = { plan = "SuperGrok", renews_day = 14 } } } })
  local CODEX = { ok = true, provider = "codex", fetched_at = now - 30,
    limits = { { label = "5-hour", pct = 12 }, { label = "Week", pct = 41 } } }
  W.inject({ settings = multi, data = CLAUDE, results = { codex = CODEX }, errors = { openrouter = "Key not accepted" } })
  local renew = P.grokPlan({ plan = "SuperGrok", renews_day = 14 }, now).facts[1]
  t.ok(text():find("This week: Opus 30%|Other AIs|Codex|41% wk|OpenRouter|—|Key not accepted|Grok|" .. renew, 1, true),
    "Other AIs under Claude")
  t.eq(#W.otherRows, 3, "one click band per row")
  t.eq(W.otherRows[2] and W.otherRows[2].id, "openrouter", "bands in order")
  t.ok(W.otherRows[1] and W.otherRows[2] and W.otherRows[1].bottom <= W.otherRows[2].top, "bands don't overlap")
  local items = W.providerMenuItems("codex")
  t.eq(items[1].title .. "|" .. items[2].title, "5-hour  12%|Week  41%", "menu lists every limit")
  t.eq(items[#items].title, "Check now", "check now last")
  t.eq(#W.others(), 3, "others for the buddy's text")
  t.eq(W.others()[1].res, CODEX, "with their numbers")
  t.eq(W.current(), CLAUDE, "Claude data while Claude is on")

  W.inject({ settings = P.settings({ usage = { order = { "codex", "grok_plan" } } }), data = CLAUDE, results = { codex = CODEX } })
  local s = text()
  t.ok(s:find("^Codex|") and s:find("5-hour|12%", 1, true) and s:find("Other AIs|Grok", 1, true), "Codex leads when Claude is off")
  t.ok(not s:find("Tokens · 24h", 1, true) and not s:find("Reading Claude", 1, true), "no Claude strip when Claude is off")
  t.eq(W.current(), nil, "no Claude data when Claude is off")

  W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, fetched_at = now - 905, limits = { { label = "Week", pct = 41 } } } } })
  t.ok(text():find("From ", 1, true), "a stale row says when it's from")
  W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, blocked = true, fetched_at = now, limits = {} } } })
  t.ok(text():find("Codex|Blocked", 1, true), "blocked says so")
  W.inject({ settings = multi, data = CLAUDE, results = { codex = { ok = true, fetched_at = now, limits = { { pct = "x" }, "junk" } } } })
  t.ok(pcall(W.elements, now), "a junk saved result still draws")
  W.inject({ settings = multi, data = CLAUDE, results = {
    codex = { ok = true, limits = { { label = "Week", pct = 41, resets_at = "soon" } } },
    openrouter = { ok = true, fetched_at = "yesterday", credits = { { label = "This month", used = 5, limit = 50, pct = 10 } } } } })
  local drew, out = pcall(W.elements, now)
  t.ok(drew, "results with junk times still draw")
  t.ok(drew and table.concat(texts(out), "|"):find(CLAUDE_TEXT, 1, true) == 1, "and Claude's section is untouched")
  t.ok(pcall(W.providerMenuItems, "codex"), "the menu copes with a junk reset time")
  W.inject({ settings = P.settings({ usage = { order = { "codex" } } }), results = { codex = { ok = true, fetched_at = "x", limits = {} } } })
  t.ok(pcall(W.elements, now), "a lead AI with a junk time still draws")
  -- a red alert whose say or Telegram send breaks never stops the card's redraw after a check
  local ALERTS, realBuddy, savedAlerts = "claudeUsageWidget.alerts", ClaudeBuddy, hs.settings.get("claudeUsageWidget.alerts")
  local alertOK = pcall(function()
    hs.settings.set(ALERTS, nil)
    ClaudeBuddy = { alert = function() error("telegram down") end }
    W.inject({ settings = P.settings({ usage = { order = { "claude", "codex" }, alert_red = true } }) })
    W.checkAlerts("codex", { ok = true, limits = { { label = "Week", pct = 95 } } })
  end)
  ClaudeBuddy = realBuddy
  hs.settings.set(ALERTS, savedAlerts)
  t.ok(alertOK, "a broken alert path is contained")

  W.inject({ settings = P.settings({}), data = CLAUDE, results = {}, errors = {} })
  claudeOnly("Claude-only card text after other AIs")
  t.eq(#W.otherRows, 0, "no Other AIs rows for Claude only")
end
