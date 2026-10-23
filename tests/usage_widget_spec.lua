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
end
