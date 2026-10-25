-- health.lua: sitting nudges, meal check-ins, spotting food and fitness, goals and plans.
return function(t, dir)
  local H = dofile(dir .. "/health.lua")
  local function at(h, m, day) return os.time({ year = 2026, month = 3, day = day or 10, hour = h, min = m or 0 }) end
  local function fresh(cfg) return H.new(t.tmpdir() .. "/health", cfg or {}) end

  -- sitting: 59 minutes of activity is nothing, 60 is a nudge
  local h = fresh()
  local t0 = at(10, 15) -- between the breakfast and lunch windows
  t.eq(h:tick(t0, 0, false), nil, "streak starts quietly")
  t.eq(h:tick(t0 + 59 * 60, 0, false), nil, "59 minutes active: nothing")
  local ev = h:tick(t0 + 60 * 60, 0, false)
  t.eq(ev and ev.kind, "sit", "60 minutes active: a sit event")
  t.eq(ev and ev.minutes, 60, "it says how many minutes")
  t.eq(h:tick(t0 + 61 * 60, 0, false), nil, "not again right away")
  t.eq(h:tick(t0 + 89 * 60, 0, false), nil, "not within 30 minutes")
  t.ok(h:tick(t0 + 91 * 60, 0, false), "again after 30 minutes")

  -- a 5 minute break resets the streak
  h = fresh()
  h:tick(t0, 0, false)
  h:tick(t0 + 40 * 60, 0, false)
  h:tick(t0 + 41 * 60, 6 * 60, false) -- 6 minutes idle
  h:tick(t0 + 42 * 60, 0, false)
  t.eq(h:tick(t0 + 100 * 60, 0, false), nil, "6 minutes away resets the streak")
  t.ok(h:tick(t0 + 102 * 60, 0, false), "and 60 minutes after it counts again")

  -- sleep is a break
  h = fresh()
  h:tick(t0, 0, false)
  h:tick(t0 + 50 * 60, 0, false)
  h:tick(t0 + 51 * 60, 12 * 3600, false)
  t.eq(h:tick(t0 + 61 * 60, 0, false), nil, "a long sleep resets the streak")

  -- rest() (the caller saw a gap in polling) resets too
  h = fresh()
  h:tick(t0, 0, false)
  h:rest()
  t.eq(h:tick(t0 + 61 * 60, 0, false), nil, "rest() starts the streak over")

  -- busy: no event, and the event waits instead of being used up
  h = fresh()
  h:tick(t0, 0, false)
  t.eq(h:tick(t0 + 61 * 60, 0, true), nil, "no nudge while busy")
  t.eq(h:tick(t0 + 62 * 60, 0, function() return true end), nil, "busy can be a function")
  local called = 0
  h:tick(t0 + 30 * 60, 0, function() called = called + 1 return false end)
  t.eq(called, 0, "a busy function is only asked when an event is due")
  t.ok(h:tick(t0 + 63 * 60, 0, false), "the nudge comes once it is free")

  -- sit_minutes from the config
  h = fresh({ sit_minutes = 30 })
  h:tick(t0, 0, false)
  t.ok(h:tick(t0 + 30 * 60, 0, false), "sit_minutes is honoured")

  -- meals: inside the window, when not logged, once a day
  h = fresh()
  local noon = at(12, 30)
  ev = h:tick(noon, 0, false)
  t.eq(ev and ev.kind, "meal", "lunch event at 12:30")
  t.eq(ev and ev.meal, "lunch", "it is lunch")
  t.eq(h:tick(noon + 60, 0, false), nil, "a second lunch event never comes the same day")
  t.eq(fresh():tick(at(11, 59), 0, false), nil, "none at 11:59")
  t.eq(fresh():tick(at(14, 1), 0, false), nil, "none at 14:01")
  t.eq(fresh():tick(noon, 0, true), nil, "none while busy")
  t.eq(fresh():tick(noon, 90, false), nil, "none when away from the keyboard")
  h = fresh()
  h:ate("lunch", noon)
  t.eq(h:tick(noon + 60, 0, false), nil, "none after ate(\"lunch\")")
  h = fresh()
  h:tick(noon, 0, false)
  ev = h:tick(at(12, 30, 11), 0, false)
  t.eq(ev and ev.meal, "lunch", "the next day it asks again")
  ev = fresh():tick(at(8, 15), 0, false)
  t.eq(ev and ev.meal, "breakfast", "breakfast window")
  ev = fresh():tick(at(18, 0), 0, false)
  t.eq(ev and ev.meal, "dinner", "dinner window")
  ev = fresh({ meals = { lunch = { 11, 12 } } }):tick(at(11, 30), 0, false)
  t.eq(ev and ev.meal, "lunch", "meal windows come from the config")

  -- a meal the tools logged counts as eaten
  h = fresh()
  h:log("meal", "had lunch: soup", noon)
  t.eq(h:tick(noon + 60, 0, false), nil, "a logged meal named lunch is eaten")
  h = fresh()
  h:log("meal", "a sandwich", at(13, 0))
  t.eq(h:tick(at(13, 5), 0, false), nil, "an unnamed meal counts for the window it was in")

  -- the daily cap
  local function events(cfg)
    local e = fresh(cfg)
    e:tick(t0, 0, false)
    local count = 0
    for i = 1, 20 do
      if e:tick(t0 + (60 + 30 * (i - 1)) * 60, 0, false) then count = count + 1 end
    end
    return count, e
  end
  t.eq((events({ daily_cap = 3 })), 3, "daily_cap limits the events a day")
  local count, capped = events()
  t.eq(count, 8, "the default cap is 8 a day")
  t.eq(capped:tick(at(23, 55), 0, false), nil, "the 9th event of a day is nil")
  t.eq(capped:spot("Safari", "Order from Skip The Dishes", at(23, 56)), nil, "spotting counts toward the cap")

  -- spotting food and fitness on screen
  h = fresh()
  ev = h:spot("Safari", "Order from Skip The Dishes", t0)
  t.eq(ev and ev.kind, "food", "skip the dishes is food")
  t.eq(ev and ev.what, "Order from Skip The Dishes", "what is the title")
  t.eq(h:spot("Safari", "Order from Skip The Dishes", t0 + 3600), nil, "not again within 2 hours")
  t.ok(h:spot("Safari", "Order from Skip The Dishes", t0 + 7300), "again after 2 hours")
  ev = h:spot("Safari", "20 minute HIIT workout", t0)
  t.eq(ev and ev.kind, "fitness", "a workout page is fitness")
  t.eq(h:spot("Safari", "Quarterly report", t0), nil, "other titles are nothing")
  t.ok(fresh():spot("Chrome", "UberEats - Burgers", t0), "ubereats without a space")
  t.ok(fresh():spot("Chrome", "Pushup form tips", t0), "pushup")
  t.eq(fresh():spot("Chrome", "Order from Skip The Dishes", t0, function() return true end), nil, "busy blocks spotting")
  h = fresh()
  h:spot("Chrome", "Order from Skip The Dishes", t0, function() return true end)
  t.ok(h:spot("Chrome", "Order from Skip The Dishes", t0 + 60), "a blocked spot does not use up the 2 hours")

  -- goals, plans and the tools' file
  local folder = t.tmpdir() .. "/health"
  h = H.new(folder, {})
  hs.fs.mkdir(folder)
  local f = assert(io.open(folder .. "/health-new.jsonl", "w"))
  f:write(hs.json.encode({ kind = "goal", text = "Run 5k by June", at = t0 }) .. "\n")
  f:write(hs.json.encode({ kind = "plan", text = "Mon: easy run\nTue: rest", at = t0 }) .. "\n")
  f:write(hs.json.encode({ kind = "shell", text = "rm -rf /", at = t0 }) .. "\n")
  f:write("not json\n")
  f:write(hs.json.encode({ kind = "break", text = "walked around the block", at = t0 }) .. "\n")
  f:close()
  t.eq(h:absorb(), 3, "absorb takes the valid lines")
  t.eq(hs.fs.attributes(folder .. "/health-new.jsonl"), nil, "and empties the file")
  local s = h:summary(t0)
  t.ok(s:find("Run 5k by June", 1, true), "summary has the goal")
  t.ok(s:find("Mon: easy run", 1, true) and not s:find("Tue: rest", 1, true), "summary has the plan's first line only")
  t.ok(s:find("1 break", 1, true), "summary counts today's breaks")
  t.ok(not s:find("rm -rf", 1, true), "an unknown kind is dropped")
  t.eq(h:absorb(), 0, "nothing left to absorb")
  t.ok(not h:askGoal(t0), "no goal question once a goal is stored")

  -- the goal question: once a day, three times in all
  h = fresh()
  t.ok(h:askGoal(at(9)), "asks when there is no goal")
  t.ok(not h:askGoal(at(15)), "not twice in a day")
  t.ok(h:askGoal(at(9, 0, 11)), "the next day it asks again")
  t.ok(h:askGoal(at(9, 0, 12)), "a third time")
  t.ok(not h:askGoal(at(9, 0, 13)), "never a fourth")

  -- what each brain lets health do: plain rules nudge only, a brain adds questions, Claude adds goals
  for _, kind in ipairs({ "sit", "meal", "food", "fitness", "goal", "plan", "progress", "nonsense" }) do
    local want = {
      [""] = { sit = true },
      ollama = { sit = true, meal = true, food = true, fitness = true },
      claude = { sit = true, meal = true, food = true, fitness = true, goal = true, plan = true, progress = true },
    }
    t.eq(H.allowed(nil, kind), want[""][kind] == true, "plain rules, " .. kind)
    t.eq(H.allowed("ollama", kind), want.ollama[kind] == true, "ollama, " .. kind)
    t.eq(H.allowed("claude", kind), want.claude[kind] == true, "claude, " .. kind)
  end
  local function gated(engine)
    local g = fresh()
    g:setAllow(function(kind) return H.allowed(engine, kind) end)
    return g
  end
  local plain = gated(nil)
  t.eq(plain:tick(at(12, 30), 0, false), nil, "plain rules: no meal question at lunchtime")
  t.eq(plain.events[os.date("%Y-%m-%d", at(12))] or 0, 0, "a refused meal costs nothing")
  local ev2 = plain:tick(at(13, 31), 0, false)
  t.ok(ev2 and ev2.kind == "sit", "plain rules: the sitting nudge still comes")
  t.eq(plain:spot("Safari", "Uber Eats - dinner", at(12), false), nil, "plain rules: no food remark")
  t.eq(plain:spot("Safari", "HIIT workout", at(12), false), nil, "plain rules: no fitness remark")
  t.ok(not plain:askGoal(at(9)), "plain rules: no goal question")
  local ol = gated("ollama")
  local mealEv = ol:tick(at(12, 30), 0, false)
  t.ok(mealEv and mealEv.kind == "meal", "ollama: a meal check-in is asked")
  t.ok(ol:spot("Safari", "Uber Eats - dinner", at(12), false), "ollama: food remark")
  t.ok(not ol:askGoal(at(9)), "ollama: no goal question")
  t.ok(gated("claude"):askGoal(at(9)), "claude: asks for a goal")
  local before = fresh()
  t.ok(before:askGoal(at(9)), "no gate set: nothing is refused (as before)")

  -- goal progress: at most once a day, with goals, Claude, a free moment
  local function withGoal(engine)
    local g = gated(engine)
    g:log("goal", "Walk 8000 steps", at(8))
    return g
  end
  local pg = withGoal("claude")
  t.eq(pg:progress(at(15), true), nil, "busy: not now, and nothing used up")
  local what = pg:progress(at(15), false)
  t.ok(what and what:find("Walk 8000 steps", 1, true), "it asks about the goal")
  t.eq(pg:progress(at(16), false), nil, "not twice in a day")
  t.ok(pg:progress(at(15, 0, 11), false), "again the next day")
  t.eq(withGoal("ollama"):progress(at(15), false), nil, "not with Ollama")
  t.eq(withGoal(nil):progress(at(15), false), nil, "not with plain rules")
  t.eq(gated("claude"):progress(at(15), false), nil, "not without goals")
  local capped = H.new(t.tmpdir() .. "/health", { daily_cap = 1 })
  capped:setAllow(function(kind) return H.allowed("claude", kind) end)
  capped:log("goal", "Sleep 8 hours", at(8))
  capped:tick(at(10), 0, false); capped:tick(at(11, 5), 0, false) -- the day's one event is a sitting nudge
  t.eq(capped:progress(at(15), false), nil, "the daily cap applies")
  local pf = t.tmpdir() .. "/health"
  local saver = H.new(pf, {})
  saver:setAllow(function(kind) return H.allowed("claude", kind) end)
  saver:log("goal", "Stretch daily", at(8))
  saver:progress(at(15), false)
  saver:save()
  local reloaded = H.new(pf, {})
  reloaded:setAllow(function(kind) return H.allowed("claude", kind) end)
  t.eq(reloaded:progress(at(17), false), nil, "once-a-day survives a reload")

  -- save, reload, garbage, wipe
  h = H.new(folder, {})
  h:log("goal", "Sleep 8 hours", t0)
  h:log("meal", "oats", t0)
  h:save()
  local h2 = H.new(folder, {})
  t.ok(h2:summary(t0):find("Sleep 8 hours", 1, true), "reloads the goal")
  t.ok(h2:summary(t0):find("oats", 1, true), "reloads the meal")
  local disk = t.readJson(folder .. "/health.json")
  t.ok(type(disk.goals) == "table" and type(disk.plans) == "table", "health.json has goals and plans for the tools")
  local bad = t.tmpdir() .. "/health"
  hs.fs.mkdir(bad)
  local fh = io.open(bad .. "/health.json", "w"); fh:write("{nope not json"); fh:close()
  local h3 = H.new(bad, {})
  t.ok(not h3:summary(t0):find("Goals", 1, true), "corrupt health.json loads empty")
  h3:log("goal", "x", t0)
  t.ok(h3:save(), "and can be saved over")
  h2:wipe()
  t.eq(hs.fs.attributes(folder .. "/health.json"), nil, "wipe deletes health.json")
  t.ok(not h2:summary(t0):find("Sleep 8 hours", 1, true), "wipe empties memory")
  fh = io.open(folder .. "/health-new.jsonl", "w"); fh:write("{}\n"); fh:close()
  h2:wipe()
  t.eq(hs.fs.attributes(folder .. "/health-new.jsonl"), nil, "wipe deletes health-new.jsonl")

  -- delivery gates: checked again when a brain reply lands
  local g = { muted = false, quietFor = 4, busy = false, watching = true }
  t.ok(H.mayDeliver({ muted = false, quietFor = 4, busy = false, watching = true, kind = "sit" }), "free: a line may be said")
  t.ok(not H.mayDeliver({ muted = true, quietFor = 4, busy = false, watching = true, kind = "sit" }), "muted: dropped")
  t.ok(not H.mayDeliver({ muted = false, quietFor = -1, busy = false, watching = true, kind = "sit" }), "only when clicked: dropped")
  t.ok(not H.mayDeliver({ muted = false, quietFor = 4, busy = true, watching = true, kind = "sit" }), "busy: dropped")
  t.ok(H.mayDeliver({ muted = false, quietFor = 4, busy = false, watching = false, kind = "sit" }), "a sit nudge does not need watching")
  t.ok(not H.mayDeliver({ muted = false, quietFor = 4, busy = false, watching = false, kind = "food" }), "food needs watching")
  t.ok(not H.mayDeliver({ muted = false, quietFor = 4, busy = false, watching = false, kind = "fitness" }), "fitness needs watching")
  local said = {}
  local function late(kind) return H.late(kind, function() return { muted = g.muted, quietFor = g.quietFor, busy = g.busy, watching = g.watching } end,
    function(text) said[#said + 1] = text end) end
  local deliver = late("food")
  deliver("one")                      -- nothing changed since the request
  g.busy = true; deliver("two")       -- a call started meanwhile
  g.busy = false; g.muted = true; deliver("three")
  g.muted = false; g.quietFor = -1; deliver("four")
  g.quietFor = 4; g.watching = false; deliver("five")
  late("sit")("six")                  -- same state, but a sit nudge needs no watching
  g.watching = true; deliver("seven")
  t.eq(table.concat(said, ","), "one,six,seven", "only lines whose gates still pass when they arrive are said")

  -- the agent is told whether health is on, so chat gets the health tools only then
  for _, case in ipairs({ { true, true }, { false, false }, { nil, false } }) do
    local folder = t.tmpdir()
    dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "haiku", agent_dir = folder }, "Sam", false, case[1])
    t.eq(t.readJson(folder .. "/config.json").health, case[2], "config.json health flag for " .. tostring(case[1]))
  end

  -- the new moods reach every list that offers moods
  local S = dofile(dir .. "/setup.lua")
  local labelled = {}
  for _, m in ipairs(S.MOOD_LABELS) do labelled[m[1]] = true end
  t.ok(labelled.health and labelled.food, "the wizard offers health and food")
  local sf = assert(io.open(dir .. "/buddy.lua"))
  local src = sf:read("a")
  sf:close()
  t.ok(src:find("\n  health +=  *{ eyes"), "MOODS has health")
  t.ok(src:find("\n  food +=  *{ eyes"), "MOODS has food")
  local L = dofile(dir .. "/learn.lua")
  local list = L.moodList({ "health", "food", "coding" })
  t.ok(list.health and list.food, "the learner's mood list has health and food")

  local savedTask = hs.task.new
  local savedDay = hs.settings.get("claudeBuddy.agentDay")
  local ok, err = pcall(function()
    local B = dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "auto", agent_dir = t.tmpdir() }, "Sam", false)
    local finish, sent
    hs.task.new = function(_, callback)
      finish = callback
      return { setEnvironment = function() end, setInput = function(_, input) sent = hs.json.decode(input) end,
               start = function() return true end }
    end
    local got = "unset"
    B.classify({ label = "Gym Timer", moods = list }, function(r) got = r end)
    finish(0, hs.json.encode({ ok = true, text = '{"mood":"health"}' }), "")
    t.eq(got and got.mood, "health", "classify may answer health")
    B.classify({ label = "Menu", moods = list }, function(r) got = r end)
    finish(0, hs.json.encode({ ok = true, text = '{"mood":"food"}' }), "")
    t.eq(got and got.mood, "food", "classify may answer food")

    -- chat gets the summary (and the tool hint) only when the caller has health on
    local history = { { role = "user", content = "what should I eat?" } }
    -- the summary changes, so it rides with the newest message; the tool hint is fixed and stays in the system prompt
    local HB = dofile(dir .. "/brain.lua").configure({ engine = "claude", model = "auto", agent_dir = t.tmpdir() }, "Sam", false, true)
    HB.chat(history, { health = "Goals: Run 5k by June." }, function() end)
    t.ok(sent.prompt:find("Run 5k by June", 1, true), "the chat prompt carries the health summary")
    t.ok(not sent.system:find("Run 5k by June", 1, true), "but not in the system prompt")
    t.ok(sent.system:find("health_log", 1, true), "and tells Claude about the health tools")
    finish(0, hs.json.encode({ ok = true, text = "Oats." }), "")
    B.chat(history, {}, function() end)
    t.ok(not sent.system:find("health", 1, true), "no health text without it")
    finish(0, hs.json.encode({ ok = true, text = "Oats." }), "")

    -- a health quip says what the caller asked; without text it does not start
    t.ok(B.quip({ kind = "health", what = "They have sat for 60 minutes. Nudge them to stretch." }, function() end), "health quip starts")
    t.ok(sent.prompt:find("Nudge them to stretch", 1, true), "the quip carries the caller's text")
    finish(0, hs.json.encode({ ok = true, text = "Stand up!" }), "")
    t.eq(B.quip({ kind = "health" }, function() end), false, "a health quip needs text")
  end)
  hs.task.new = savedTask
  hs.settings.set("claudeBuddy.agentDay", savedDay)
  if not ok then error(err, 0) end

  -- the new props stay inside the canvas grid (cols -13..26, rows -19..14)
  for _, name in ipairs({ "dumbbell", "apple" }) do
    local body = src:match("\n  " .. name .. " = (function%(px.-\n  end),")
    t.ok(body ~= nil, name .. " prop is in PROPS")
    if body then
      local colors = setmetatable({}, { __index = function() return "c" end })
      local outside
      for frame = 0, 1 do
        local draw = load("local C = ...; return " .. body, "=" .. name)(colors)
        draw(function(x, y, w, hh)
          if x < -13 or y < -19 or x + (w or 1) - 1 > 26 or y + (hh or 1) - 1 > 14 then outside = x .. "," .. y end
        end, frame)
      end
      t.ok(outside == nil, name .. " pixels are inside the grid " .. tostring(outside))
    end
  end
end
