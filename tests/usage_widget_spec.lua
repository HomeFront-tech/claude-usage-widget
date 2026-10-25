-- How the card words the age of its numbers and their resets, so old numbers look old.
return function(t, dir)
  local W = dofile(dir .. "/usage_widget.lua")
  local function at(day, hour, min) return os.time({ year = 2026, month = 10, day = day, hour = hour, min = min }) end
  local now = at(22, 22, 0)

  t.eq(W.ageText(now - 30, now), "just now", "age under a minute")
  t.eq(W.ageText(now - 25 * 60, now), "25 min ago", "age in minutes")
  t.eq(W.ageText(at(22, 9, 5), now), "at 9:05 AM", "earlier today shows the time")
  t.eq(W.ageText(at(20, 23, 35), now), "Oct 20, 11:35 PM", "another day shows the date")

  t.eq(W.resetText(now + 90 * 60, now), "Resets in 1 hr 30 min", "upcoming reset")
  t.eq(W.resetText(now - 60, now), "Resetting now", "reset a moment ago")
  t.eq(W.resetText(at(22, 4, 10), now), "Reset at 4:10 AM", "reset long ago today")
  t.eq(W.resetText(at(21, 4, 10), now), "Reset Oct 21, 4:10 AM", "reset on another day")

  t.ok(not W.isStale(now - 5 * 60, now), "a 5-minute-old check is fresh")
  t.ok(W.isStale(now - 20 * 60, now), "a 20-minute-old check is stale")

  -- The API value row
  local P = { first = os.time({ year = 2026, month = 6, day = 1, hour = 12 }), has_buddy = false, list = {
    month = { from = 100, value = 1284.2, buddy = 0, paid = 200, spread = 300 },
    today = { from = 200, value = 26.4, buddy = 1, paid = nil, spread = nil },
    session = { from = 300, value = 3, buddy = 0, rolling = true },
    all = { from = 0, value = 5000, buddy = 0, paid = 500 } } }
  local saved = { month = { from = 100, at = 1200, text = "☕ That's 214 lattes" } }
  local l = W.valueLines(P, "month", true, saved, true)
  t.eq(l.label, "API value", "row label")
  t.eq(l.period, "Month", "row period")
  t.eq(l.figure, "$1,284", "row figure")
  t.eq(l.multiple, "6.4× your plan", "row multiple")
  t.eq(l.comparison, "☕ That's 214 lattes", "saved comparison shown")
  t.eq(W.valueLines(P, "month", true, { month = { from = 100 - 86400, at = 1, text = "old" } }, true).comparison, nil,
    "last period's line hidden")
  t.eq(W.valueLines(P, "session", true, { session = { from = 1, at = 1, text = "☕ moving" } }, true).comparison, "☕ moving",
    "a rolling window keeps its line")
  local today = W.valueLines(P, "today", true, nil, true)
  t.eq(today.figure, "$27.40", "Buddy included")
  t.eq(today.multiple, nil, "row lines with nothing but hourly tallies: no multiple")
  t.eq(W.valueLines(P, "today", false, nil, true).figure, "$26.40", "Buddy left out")
  t.eq(W.valueLines(P, "all", true, nil, false).multiple, "10.0× your plan · since Jun 1", "logs only says since when")
  t.eq(W.valueLines(P, "all", true, nil, true).multiple, "10.0× your plan", "older history needs no note")
  t.eq(W.valueLines({ first = P.first, list = { all = { from = 0, value = 5, buddy = 0 } } }, "all", true, nil, false).multiple,
    "Since Jun 1", "the note stands alone without a multiple")
  t.eq(W.valueLines(P, "week", true, nil, true), nil, "a period with no numbers has no row")
  t.eq(W.valueLines(nil, "month", true, nil, true), nil, "no periods, no row")

  t.eq(W.planStarts({ limits = { { label = "Current session", resets_at = now + 3600 },
    { label = "Week · all models", resets_at = now + 86400 } } }, now), now + 3600 - 5 * 3600, "session start from its reset")
  local _, week = W.planStarts({ limits = { { label = "Week · all models", resets_at = now + 86400 } } }, now)
  t.eq(week, now + 86400 - 7 * 86400, "week start from its reset")
  t.eq(W.planStarts({ limits = { { label = "Current session", resets_at = now - 60 } } }, now), nil, "a past reset is no start")
  local _, newWeek = W.planStarts({ limits = { { label = "Week · all models", resets_at = now - 120 } } }, now)
  t.eq(newWeek, now - 120, "a week reset that just passed starts the new week")
  t.eq(W.planStarts(nil, now), nil, "no plan data, no starts")

  W.demoValue(true)
  for _, period in ipairs({ "session", "today", "week", "month", "ytd", "all" }) do
    local d = W.valueLines(W.demoPeriods, period, true, W.demoComparisons, true)
    t.ok(d and d.multiple and d.comparison, "demo fills the row: " .. period)
  end
  t.ok(W.demoPeriods.has_buddy, "demo shows the Buddy toggle")
  W.demoValue(false)
  t.eq(W.demoPeriods, nil, "demo off")
end
