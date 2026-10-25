-- The API value row's arithmetic: money, the plan multiple, when a new comparison is due,
-- and filling a comparison's number in.
return function(t, dir)
  local V = dofile(dir .. "/value.lua")

  t.eq(#V.PERIODS, 6, "six periods")
  t.eq(V.PERIODS[4].key, "month", "month is fourth")
  t.eq(V.PERIODS[5].label, "Year to date", "year to date label")

  t.eq(V.figure({ value = 10, buddy = 2 }, true), 12, "figure includes Buddy")
  t.eq(V.figure({ value = 10, buddy = 2 }, false), 10, "figure leaves Buddy out")

  t.eq(V.money(26.4), "$26.40", "money under 100")
  t.eq(V.money(0), "$0.00", "money zero")
  t.eq(V.money(1284.2), "$1,284", "money with commas")
  t.eq(V.money(1234567.8), "$1,234,568", "money in millions")

  t.eq(V.multiple({ paid = 200 }, 1284), "6.4× your plan", "multiple")
  t.eq(V.multiple({ paid = nil }, 1284), nil, "no multiple without paid")
  t.eq(V.multiple({ paid = 0 }, 1284), nil, "no multiple when nothing was paid")

  t.eq(V.threshold({ spread = 12 }, 50), 12, "spread wins")
  t.eq(V.threshold({}, 2), 1, "floor of $1")
  t.eq(V.threshold({}, 400), 100, "25% without history")

  t.eq(V.due(nil, { from = 10, spread = 5 }, 6), "new", "first one when figure passes threshold")
  t.eq(V.due(nil, { from = 10, spread = 5 }, 4), nil, "nothing below threshold")
  t.eq(V.due({ from = 10, at = 20 }, { from = 10, spread = 5 }, 24), nil, "small move keeps the line")
  t.eq(V.due({ from = 10, at = 20 }, { from = 10, spread = 5 }, 25), "new", "one spread moves it")
  t.eq(V.due({ from = 10, at = 20 }, { from = 10, spread = 5 }, 15), "new", "a drop of one spread moves it too")
  t.eq(V.due({ from = 10, at = 20 }, { from = 10 + 86400, spread = 5 }, 2), "rollover", "due on rollover")
  t.eq(V.due({ from = 10, at = 20 }, { from = 99, spread = 5, rolling = true }, 22), nil, "a rolling window never rolls over")
  t.eq(V.due({ from = 1000, at = 20 }, { from = 1001, spread = 5 }, 22), nil, "a reset a second off is the same period")
  t.eq(V.due({ from = 1000, at = 20 }, { from = 1000 + 3600, spread = 5 }, 22), "rollover", "an hour off is a new period")
  t.eq(V.due({ from = 10, at = 20 }, { from = 10, spread = 5 }, 0), nil, "nothing to compare at $0")
  t.eq(V.due(nil, { from = 10 }, 0), nil, "nothing at $0 even with no line yet")
  t.eq(V.due({ from = 10, at = 20 }, { from = 99, spread = 5, rolling = true }, 14), "rebase", "a draining rolling window lowers its baseline")
  t.eq(V.due({ from = 10, at = 20 }, { from = 99, spread = 5, rolling = true }, 26), "new", "a rolling window still moves up")
  t.ok(V.same(1000, 1001) and not V.same(1000, 1000 + 3600), "same period within minutes")

  local latte = { emoji = "☕", thing = "latte", price = 6, count = "That's {n} lattes", part = "{n} of a latte" }
  t.eq(V.fill(latte, 1284), "☕ That's 214 lattes", "count")
  t.eq(V.fill(latte, 60000), "☕ That's 10,000 lattes", "count with commas")
  t.eq(V.fill(latte, 0.03), "☕ 0.50% of a latte", "fill formats extremes: tiny")
  t.eq(V.fill({ emoji = "🏙️", thing = "skyscraper", price = 1e9, count = "{n} skyscrapers", part = "{n} of a skyscraper" }, 41),
    "🏙️ 0.0000041% of a skyscraper", "fill formats extremes: huge price")
  t.eq(V.fill({ emoji = "🚗", thing = "car", price = 40000, count = "{n} cars", part = "{n} of a car" }, 25000),
    "🚗 63% of a car", "two significant digits")
  t.eq(V.fill(latte, 0), nil, "fill rejects: nothing spent")
  t.eq(V.fill(latte, 10), "☕ 167% of a latte", "one and a bit is a percentage, not 1 lattes")
  t.eq(V.fill(latte, 12), "☕ That's 2 lattes", "two or more is a count")
  t.eq(V.fill({ emoji = "x", thing = "x", price = 6, count = "no placeholder", part = "{n}" }, 100), nil, "fill rejects: no {n}")
  t.eq(V.fill({ emoji = "x", thing = "x", price = 0, count = "{n}", part = "{n}" }, 100), nil, "fill rejects: zero price")
  t.eq(V.fill({ emoji = "x", thing = "x", price = "6", count = "{n}", part = "{n}" }, 100), nil, "fill rejects: price not a number")
  t.eq(V.fill({ emoji = "x", thing = "x", price = 1, count = "{n} " .. string.rep("long ", 30), part = "{n}" }, 100), nil,
    "fill rejects: too long")

  t.ok(V.emojiOk("🍕") and V.emojiOk("🏙️"), "emoji pass")
  t.ok(not V.emojiOk("pizza"), "letters aren't an emoji")
  t.ok(not V.emojiOk(string.rep("🍕", 10)), "too long for an emoji")
end
