-- Buddy's brain writes money comparisons as JSON; anything unusable is dropped so the card
-- falls back to the built-in list. Comparisons count against the daily unprompted cap.
return function(t, dir)
  local savedDay = hs.settings.get("claudeBuddy.agentDay")
  local B = dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "haiku", agent_dir = t.tmpdir() }, "", false)
  local ok = '{"emoji":"🍕","thing":"large pizza","price":18,"count":"That\'s {n} large pizzas","part":"{n} of a large pizza"}'

  local r = B.parseComparison("Sure! " .. ok .. " Enjoy.")
  t.eq(r and r.thing, "large pizza", "JSON found inside prose")
  t.eq(r and r.price, 18, "price kept")
  t.eq(B.parseComparison("That's a lot of pizza"), nil, "parseComparison rejects prose")
  t.eq(B.parseComparison((ok:gsub('"price":18', '"price":0'))), nil, "parseComparison rejects zero price")
  t.eq(B.parseComparison((ok:gsub('"price":18', '"price":"18"'))), nil, "parseComparison rejects a price that isn't a number")
  t.eq(B.parseComparison((ok:gsub("{n} of a", "half of a"))), nil, "parseComparison rejects missing {n}")
  t.eq(B.parseComparison((ok:gsub("That's {n} large pizzas", "That's {n} " .. string.rep("very ", 20) .. "large pizzas"))), nil,
    "parseComparison rejects an overlong line")
  t.eq(B.parseComparison(nil), nil, "parseComparison takes nothing")
  t.eq(B.parseComparison((ok:gsub('"price":18', '"price":1e999'))), nil, "parseComparison rejects an infinite price")
  t.eq(B.parseComparison((ok:gsub('"price":18', '"price":5e12'))), nil, "parseComparison rejects an absurd price")
  t.eq(B.parseComparison((ok:gsub('"price":18', '"price":0.001'))), nil, "parseComparison rejects a sub-cent price")
  t.eq(B.parseComparison((ok:gsub('"emoji":"🍕"', '"emoji":"pizza"'))), nil, "parseComparison rejects words as the emoji")

  hs.settings.set("claudeBuddy.agentDay", { day = os.date("%Y-%m-%d"), n = 300 })
  t.eq(B.compare({ figure = 26, period = "Today", avoid = {} }, function() end), false, "capped compare refused")

  hs.settings.set("claudeBuddy.agentDay", { day = os.date("%Y-%m-%d"), n = 0 })
  local originalNew, sent, got = hs.task.new, nil, "never"
  hs.task.new = function(_, callback)
    local task = {}
    function task.setEnvironment() end
    function task.setInput(_, input) sent = hs.json.decode(input) end
    function task.start()
      callback(0, hs.json.encode({ ok = true, text = ok }) .. "\n", "")
      return true
    end
    return task
  end
  local started = B.compare({ figure = 26, period = "Today", avoid = { "taco", "donut" } }, function(reply) got = reply end)
  hs.task.new = originalNew
  hs.settings.set("claudeBuddy.agentDay", savedDay)
  t.eq(started, true, "compare starts a request")
  t.eq(type(got) == "table" and got.thing, "large pizza", "done gets the parsed comparison")
  t.eq(sent and sent.kind, "quip", "sent as a one-turn, no-tools request")
  t.ok(sent and sent.prompt:find("$26.00", 1, true), "prompt carries the amount")
  t.ok(sent and sent.prompt:find("taco", 1, true), "prompt carries the avoid list")
  t.ok(sent and sent.system:find("politics", 1, true), "system prompt carries the content rule")
  t.ok(sent and sent.system:find("weapons", 1, true), "system prompt rules out weapons and the military")
  t.eq(B.busy(), false, "nothing left in flight")
end
