-- Buddy's built-in comparisons, for when there's no brain: everyday, filled for any amount, no repeats.
return function(t, dir)
  local C = dofile(dir .. "/comparisons.lua")
  local V = dofile(dir .. "/value.lua")

  t.ok(#C.LIST >= 75, "about 80 things")
  local seen, bad = {}, {}
  for _, c in ipairs(C.LIST) do
    if not (c.count:find("{n}", 1, true) and c.part:find("{n}", 1, true)) then bad[#bad + 1] = c.thing end
    if type(c.price) ~= "number" or c.price <= 0 or seen[c.thing] then bad[#bad + 1] = c.thing end
    seen[c.thing] = true
  end
  t.eq(table.concat(bad, ", "), "", "every thing has both placeholders, a price and a unique name")

  for _, fig in ipairs({ 0.02, 3, 26, 1284, 25000, 250000, 5e7 }) do
    t.ok(V.fill(C.pick(fig, {}), fig) ~= nil, "fills at $" .. fig)
  end

  local r1 = C.pick(26, {})
  local r2 = C.pick(26, { r1.thing })
  t.ok(r1.thing ~= r2.thing, "avoids recent")

  local all = {}
  for i = #C.LIST, 1, -1 do all[#all + 1] = C.LIST[i].thing end
  local again = C.pick(26, all)
  t.ok(again ~= nil, "reuses when all are recent")
  -- every candidate is recent: the one used longest ago (furthest back in the list) comes back
  local oldest
  for i = #all, 1, -1 do
    for _, c in ipairs(C.LIST) do
      if c.thing == all[i] and (26 / 500 <= c.price and c.price <= 13 or (c.price >= 2600 and c.price <= 26e8)) then oldest = oldest or c.thing end
    end
  end
  t.eq(again.thing, oldest, "the least recently used candidate")
end
