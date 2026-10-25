-- The card's comparison flow: when it asks Buddy, what it saves, what Buddy says, and when
-- it leaves the line alone. Uses a stand-in ClaudeBuddy and restores the real one after.
return function(t, dir)
  local COMPARE, THINGS = "claudeUsageWidget.comparisons", "claudeUsageWidget.comparedThings"
  local KEYS = { COMPARE, THINGS, "claudeUsageWidget.valuePeriod", "claudeUsageWidget.valueBuddy" }
  local savedKeys, realBuddy = {}, ClaudeBuddy
  for _, k in ipairs(KEYS) do savedKeys[k] = hs.settings.get(k) end
  local PIZZA = { emoji = "🍕", thing = "large pizza", price = 18, count = "That's {n} large pizzas", part = "{n} of a large pizza" }
  local said, asked, pending

  -- mode: how the stand-in Buddy answers ("sync", "false", "nil", "hold"), or "none" for a card without Buddy
  local function fresh(mode, period, list, comparisons)
    for _, k in ipairs(KEYS) do hs.settings.clear(k) end
    hs.settings.set("claudeUsageWidget.valuePeriod", period or "month")
    if comparisons then hs.settings.set(COMPARE, comparisons) end
    said, asked, pending = {}, 0, nil
    ClaudeBuddy = mode ~= "none" and {
      say = function(text) said[#said + 1] = text end,
      compare = function(_, done)
        asked = asked + 1
        if mode == "false" then return false end
        if mode == "sync" then done(PIZZA) elseif mode == "nil" then done(nil) elseif mode == "hold" then pending = done end
        return true
      end,
    } or nil
    local W = dofile(dir .. "/usage_widget.lua")
    W.tokens = { periods = { first = 0, list = list } }
    return W
  end
  local function saved(period) return (hs.settings.get(COMPARE) or {})[period or "month"] end

  local ok, err = pcall(function()
    local W = fresh("sync", "month", { month = { from = 100, value = 180, buddy = 0, spread = 50 } })
    W.checkComparison()
    t.eq(saved() and saved().text, "🍕 That's 10 large pizzas", "the brain's comparison is saved")
    t.eq(saved() and saved().at, 180, "with the dollars it was made at")
    t.eq(said[1], "🍕 That's 10 large pizzas", "Buddy says it")
    t.eq((hs.settings.get(THINGS) or {})[1], "large pizza", "and remembers the thing")
    W.checkComparison()
    t.eq(asked, 1, "no new comparison without a move")
    W.tokens.periods.list.month.from = 101
    W.checkComparison()
    t.eq(asked, 1, "a reset a second off is not a rollover")
    t.eq(#said, 1, "nothing said on jitter")
    W.tokens.periods.list.month.value = 240
    W.checkComparison()
    t.eq(asked, 2, "a move of one spread asks again")

    fresh("false", "month", { month = { from = 100, value = 180, buddy = 0, spread = 50 } }).checkComparison()
    t.ok(saved() and saved().text, "the built-in list covers when the brain can't ask")
    t.eq(#said, 1, "and Buddy says that one too")

    fresh("nil", "month", { month = { from = 100, value = 180, buddy = 0, spread = 50 } }).checkComparison()
    t.ok(saved() and saved().text, "the built-in list covers an unusable reply")

    W = fresh("hold", "month", { month = { from = 100, value = 180, buddy = 0, spread = 50 } })
    W.checkComparison()
    W.checkComparison()
    t.eq(asked, 1, "one request in flight")
    pending(nil)
    t.ok(saved() and saved().text, "the late answer still lands")

    fresh("sync", "month", { month = { from = 100, value = 0, buddy = 0 } }).checkComparison()
    t.eq(asked, 0, "never asks at $0")
    t.eq(saved(), nil, "nothing saved at $0")

    fresh("sync", "month", { month = { from = 100, value = 180, buddy = 0, spread = 50 } },
      { month = { from = 100 - 86400, at = 900, text = "old" } }).checkComparison()
    t.eq(saved() and saved().from, 100, "a new period gets its own comparison")
    t.eq(saved() and saved().text, "🍕 That's 10 large pizzas", "made fresh after the rollover")

    fresh("sync", "month", { month = { from = 100, value = 10, buddy = 0, spread = 50 } },
      { month = { from = 100 - 86400, at = 900, text = "old" } }).checkComparison()
    t.eq(saved(), nil, "last period's line is cleared")
    t.eq(asked, 0, "and nothing asked until the new period has moved enough")

    fresh("sync", "session", { session = { from = 999, value = 12, buddy = 0, spread = 10, rolling = true } },
      { session = { from = 1, at = 40, text = "🌮 That's 13 tacos" } }).checkComparison()
    t.eq(asked, 0, "a draining rolling window doesn't ask")
    t.eq(saved("session") and saved("session").at, 12, "it lowers the baseline")
    t.eq(saved("session") and saved("session").text, "🌮 That's 13 tacos", "and keeps the line")

    fresh("none", "month", { month = { from = 100, value = 180, buddy = 0, spread = 50 } }).checkComparison()
    t.ok(saved() and saved().text, "a card without Buddy uses the built-in list")
    t.eq(#said, 0, "and nobody says it")
  end)
  ClaudeBuddy = realBuddy
  for _, k in ipairs(KEYS) do
    if savedKeys[k] == nil then hs.settings.clear(k) else hs.settings.set(k, savedKeys[k]) end
  end
  t.ok(ok, "flow ran: " .. tostring(err))
end
