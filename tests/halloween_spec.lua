-- halloween.lua: dates, dress-up, skit state and the pixel world.
return function(t, dir)
  local H = dofile(dir .. "/halloween.lua")
  local tmp = t.tmpdir()
  local fixture = tmp .. "/skits"
  hs.fs.mkdir(fixture)
  local source = io.open(dir .. "/skits/sprites.json")
  if source then
    local text = source:read("a")
    source:close()
    local out = assert(io.open(fixture .. "/sprites.json", "w"))
    out:write(text)
    out:close()
  else
    local function sprite(pixel, colors, rows)
      return { pixel = pixel, colors = colors, anims = { idle = { frames = { rows } } } }
    end
    t.writeJson(fixture .. "/sprites.json", {
      spider = { pixel = 3, colors = { X = "#0d0b12", r = "#e04646" },
        anims = { hang = { fps = 2, frames = { { ".X.XXX.X.", "X.XrXrX.X", "XX.XXX.XX", "........." } } },
          climb = { fps = 8, frames = { { ".X.XXX.X.", "X.XrXrX.X", "XX.XXX.XX", "........." } } } } },
      pail = sprite(5, { g = "#8a8f99", O = "#f59a23", s = "#c76a12" },
        { ".ggg.", "ggggg", "OOOOO", "OOOOO", "OOOOO", "sssss" }),
    })
  end
  local dot = { dot = { pixel = 3, colors = { X = "#f59a23" },
    anims = { idle = { frames = { { "XX", "XX" } } } } } }
  local function skit(id, length, buddy, actors, extra)
    local s = { id = id, name = id, group = "bats", length = length, weight = 2,
      actors = actors or {}, buddy = buddy or {} }
    for k, v in pairs(extra or {}) do s[k] = v end
    t.writeJson(fixture .. "/" .. id .. ".json", s)
  end
  skit("a", 4, { { t = 0.5, run = -60, ["for"] = 1 }, { t = 1, say = "Boo." },
    { t = 2, run = 0, ["for"] = 1 } }, {}, { sprites = dot })
  skit("b", 2)
  skit("c", 2)
  skit("heist", 2, { { t = 1, pail = "gone" }, { t = 1, spider = "away" } }, {},
    { weight = 0, needs = { "pail" }, next = { skit = "back", after = 30 } })
  skit("back", 2, { { t = 1, pail = "back" }, { t = 1, spider = "home" } }, {}, { weight = 0 })
  skit("layers", 3, {}, {
    { sprite = "dot", layer = "behind", keys = { { t = 0, x = 20, y = 30, anim = "idle" }, { t = 3 } } },
    { sprite = "dot", layer = "front", keys = { { t = 0, x = 170, y = 30, anim = "idle" }, { t = 3 } } },
  }, { weight = 0, sprites = dot })
  skit("hat", 3, {}, { { sprite = "dot", layer = "front", keys = {
    { t = 0, at = "top", anim = "idle" }, { t = 3, at = "top" } } } }, { weight = 0, sprites = dot })

  local function fake(args)
    args = args or {}
    local clock = { t = args.t or 0, d = { year = 2026, month = 10, day = args.day or 25,
      hour = args.hour or 12, min = 0, sec = 0 } }
    local memory = args.memory or {}
    local calls, logs, said, acts = {}, {}, {}, {}
    local cur = args.skin or { id = "classic", group = "classic" }
    local rows = args.rows or 8
    local skins = {}
    function skins.current() return cur end
    function skins.wear(id)
      calls[#calls + 1] = id or "nil"
      if id then cur = { id = id, group = "halloween" }
      else cur = { id = "classic", group = "classic" } end
    end
    function skins.topRows() return rows end
    local function pick(id)
      cur = { id = id, group = id == "vampire" and "halloween" or "classic" }
    end
    local nums = args.nums or { 0.2 }
    local index = 0
    local opts = { cfg = args.cfg or {}, skins = skins, palette = {}, dirs = args.dirs or { fixture },
      S = 5, ground = 158,
      settings = { get = function(key) return memory[key] end,
        set = function(key, value) memory[key] = value end },
      now = function() return clock.t end, date = function(fmt)
        if fmt == "*t" then return clock.d end
      end,
      random = function()
        index = index + 1
        return nums[(index - 1) % #nums + 1]
      end,
      log = function(message) logs[#logs + 1] = message end,
      hooks = { say = args.say or function(line) said[#said + 1] = line end,
        act = function(name, secs) acts[#acts + 1] = { name, secs } end,
        look = function() end, burst = function() end },
    }
    local theme = H.configure(opts)
    return { theme = theme, clock = clock, memory = memory, calls = calls, logs = logs,
      said = said, acts = acts, pick = pick, opts = opts }
  end
  local function state(over)
    local s = { away = "active", idle = 0, mood = "idle", event = false, action = false, dragging = false }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local function draw(f, layer, at)
    local out = {}
    local function add(el, key) out[#out + 1] = { el = el, key = key } end
    f.theme[layer](add, 65, 98, 100, at or f.clock.t)
    return out
  end
  local function count(lines, needle)
    local n = 0
    for _, line in ipairs(lines) do if line:find(needle, 1, true) then n = n + 1 end end
    return n
  end
  local function advance(f, seconds, withFrame)
    f.clock.t = f.clock.t + seconds
    if withFrame then draw(f, "behind", f.clock.t) end
  end

  -- The date and override rules are independent of files or timers.
  local d = { year = 2026, month = 10, day = 23, hour = 23, min = 59 }
  t.eq(H.active(d), false, "date rule")
  d.day, d.hour, d.min = 24, 0, 0
  t.eq(H.active(d), true, "date rule: Oct 24 00:00")
  d.day, d.hour, d.min = 31, 23, 59
  t.eq(H.active(d), true, "date rule: Oct 31 23:59")
  d.month, d.day, d.hour = 11, 1, 0
  t.eq(H.active(d), false, "date rule: Nov 1 00:00")
  d.month, d.day = 10, 26
  t.eq(H.active(d, { halloween = false }), false, "config wins")
  d.month = 7
  t.eq(H.active(d, { halloween = true }), true, "config wins: true")
  d.month = 10
  t.eq(H.active(d, {}, { year = 2026, on = false }), false, "menu toggle counts for its year in season")
  d.year = 2027
  t.eq(H.active(d, {}, { year = 2026, on = false }), true, "menu toggle expires next year")
  d.year, d.month, d.day = 2026, 11, 1
  t.eq(H.active(d, {}, { year = 2026, on = true }), false, "menu on in October does not carry into November")

  local f = fake()
  t.eq(f.calls[1], "witch", "dresses as the witch")
  t.eq(#f.calls, 1, "dresses once")
  local h = fake({ skin = { id = "vampire", group = "halloween" } })
  t.eq(#h.calls, 0, "keeps a Halloween skin")
  h.pick("classic")
  h.theme.tick(1, state())
  t.eq(h.memory["claudeBuddy.halloweenDressed"] and h.memory["claudeBuddy.halloweenDressed"].declined, true,
    "a pick sticks even when the theme didn't dress Buddy")
  t.eq(#fake({ memory = h.memory }).calls, 0, "a pick sticks even when the theme didn't dress Buddy: reload")
  local renamed = tmp .. "/renamed"
  t.writeJson(renamed .. "/copy.json", { id = "original", name = "Copy", group = "bats", length = 2 })
  local r = fake({ dirs = { renamed } })
  t.eq(count(r.logs, "id must match the file name"), 1, "a file whose id isn't its name is skipped")
  t.eq(r.theme.skit("original"), false, "a file whose id isn't its name is skipped: not playable")
  local dec = fake({ cfg = { halloween = true } })
  dec.clock.d.month, dec.clock.d.day = 12, 31
  t.ok(dec.theme.persona():find("Halloween week", 1, true), "Halloween day is October 31 only")
  f.pick("classic")
  f.theme.tick(1, state())
  t.eq(f.memory["claudeBuddy.halloweenDressed"].declined, true, "a menu pick sticks across a reload")
  local reload = fake({ memory = f.memory })
  t.eq(#reload.calls, 0, "a menu pick sticks across a reload: no redress")
  reload.clock.d.month, reload.clock.d.day = 11, 1
  reload.theme.tick(2, state())
  t.eq(reload.theme.on(), false, "undresses at the end")
  t.eq(reload.calls[#reload.calls], "nil", "undresses at the end: wear nil")
  local quietOff = fake({ cfg = { halloween = false }, dirs = { tmp .. "/bad" } })
  t.writeJson(tmp .. "/bad/invalid.json", { bad = true })
  for i = 1, 5 do quietOff.theme.tick(i, state()) end
  t.eq(count(quietOff.logs, "[buddy skits]"), 0, "off costs nothing")
  quietOff.clock.d.month = 11
  t.eq(quietOff.theme.menu(), nil, "off costs nothing: no menu")

  local persona = fake()
  t.eq(persona.theme.persona(), "It's Halloween week and you love it. Now and then, slip in a spooky pun or a nod to a classic horror movie.", "persona")
  persona.clock.d.day = 31
  t.eq(persona.theme.persona(), "Today is Halloween, your favourite day of the year. Now and then, slip in a spooky pun or a nod to a classic horror movie.", "persona: day")
  persona.clock.d.month, persona.clock.d.day = 11, 1
  persona.theme.tick(1, state())
  t.eq(persona.theme.persona(), nil, "persona: off")
  local B = dofile(dir .. "/brain.lua").configure({}, "", false)
  local original = B.persona()
  B.addPersona(function() return "Boo." end)
  t.eq(B.persona(), original .. " Boo.", "brain hook")
  B.addPersona(function() return nil end)
  t.eq(B.persona(), original .. " Boo.", "brain hook: nil ignored")

  local normal = fake({ cfg = { chatter = "normal" } })
  t.ok(normal.theme.status().nextIn >= 180 and normal.theme.status().nextIn <= 300, "schedules by chatter")
  local lastDay = fake({ day = 31, cfg = { chatter = "normal" } })
  t.ok(lastDay.theme.status().nextIn >= 90 and lastDay.theme.status().nextIn <= 150, "schedules by chatter: Oct 31")
  t.eq(fake({ cfg = { chatter = "silent" } }).theme.status().nextIn, nil, "schedules by chatter: silent")

  for _, case in ipairs({ { "bored", { away = "bored" } }, { "idle 61", { idle = 61 } },
      { "coding", { mood = "coding" } }, { "event", { event = true } },
      { "action", { action = true } }, { "dragging", { dragging = true } } }) do
    local g = fake()
    g.clock.t = g.theme.status().nextIn + 1
    g.theme.tick(g.clock.t, state(case[2]))
    t.eq(g.theme.busy(), false, "start rules: " .. case[1])
    g.theme.tick(g.clock.t + 1, state())
    t.eq(g.theme.busy(), true, "start rules: passes after " .. case[1])
  end

  local cue = fake()
  t.eq(cue.theme.skit("a"), true, "cues fire through behind")
  draw(cue, "behind")
  advance(cue, 1.2, true)
  advance(cue, 0.1, true)
  t.eq(#cue.said, 1, "cues fire through behind: once")
  local run = fake()
  run.theme.skit("a")
  draw(run, "behind")
  advance(run, 1, true)
  t.eq(run.theme.offset(), -30, "run offset returns home")
  advance(run, 0.5, true)
  t.eq(run.theme.offset(), -60, "run offset returns home: out")
  advance(run, 1.6, true)
  t.eq(run.theme.offset(), 0, "run offset returns home: home")

  local bad = tmp .. "/badskits"
  t.writeJson(bad .. "/sprites.json", {})
  local raw = assert(io.open(bad .. "/unreadable.json", "w"))
  raw:write("{oops")
  raw:close()
  t.writeJson(bad .. "/unknown.json", { id = "unknown", name = "Unknown", group = "bats", length = 2,
    actors = { { sprite = "missing", layer = "front", keys = { { t = 0, x = 0, y = 0 }, { t = 2 } } } } })
  local loader = fake({ dirs = { fixture, bad } })
  t.eq(count(loader.logs, "[buddy skits] skipped"), 2, "loader skips bad files")
  t.eq(loader.theme.skit("a"), true, "loader skips bad files: good plays")
  local stopped = fake()
  stopped.theme.skit("a")
  stopped.clock.t = 10
  stopped.theme.tick(10, state())
  t.eq(stopped.theme.busy(), false, "tick ends a skit whose frames stopped")
  t.eq(stopped.theme.offset(), 0, "tick ends a skit whose frames stopped: home")

  local interrupted = fake()
  interrupted.theme.skit("heist")
  advance(interrupted, 1.2, true)
  t.eq(interrupted.theme.status().pail, false, "interrupt restores pail, spider and offset")
  interrupted.theme.interrupt()
  t.eq(interrupted.theme.status().pail, true, "interrupt restores pail, spider and offset: pail")
  t.eq(interrupted.theme.status().spider, true, "interrupt restores pail, spider and offset: spider")
  t.eq(interrupted.theme.status().offset, 0, "interrupt restores pail, spider and offset: offset")
  t.eq(interrupted.theme.status().chain, nil, "interrupt restores pail, spider and offset: chain")
  local follow = fake()
  follow.theme.skit("heist")
  advance(follow, 2.1, true)
  t.eq(follow.theme.status().chain, "back", "chains play their follow-up")
  t.eq(follow.theme.status().pail, false, "chains play their follow-up: pail gone")
  follow.clock.t = 33
  follow.theme.tick(33, state())
  t.eq(follow.theme.status().playing, "back", "chains play their follow-up: started")
  advance(follow, 1.2, true)
  t.eq(follow.theme.status().pail, true, "chains play their follow-up: pail back")
  local deadline = fake()
  deadline.theme.skit("heist")
  advance(deadline, 2.1, true)
  deadline.clock.t = 184
  deadline.theme.tick(184, state({ away = "asleep" }))
  t.eq(deadline.theme.status().chain, nil, "chain deadline brings the pail back")
  t.eq(deadline.theme.status().pail, true, "chain deadline brings the pail back: restored")
  for _, over in ipairs({ { event = true }, { away = "asleep" } }) do
    local ev = fake()
    ev.theme.skit("a")
    ev.theme.tick(1, state(over))
    t.eq(ev.theme.busy(), false, "events interrupt")
  end

  local repeats = fake({ cfg = { chatter = "chatty" } })
  local previous
  for i = 1, 30 do
    repeats.clock.t = repeats.clock.t + (repeats.theme.status().nextIn or 151) + 1
    repeats.theme.tick(repeats.clock.t, state())
    local id = repeats.theme.status().playing
    t.ok(id and id ~= previous, i == 1 and "no repeats" or "no repeats: start " .. i)
    previous = id
    repeats.clock.t = repeats.clock.t + 5
    repeats.theme.tick(repeats.clock.t, state())
  end
  local lines = fake({ nums = { 0.1 } }) -- always under one half
  t.ok(type(lines.theme.line("idle")) == "string", "lines")
  local never = fake({ nums = { 0.7 } })
  t.eq(never.theme.line("idle"), nil, "lines: half the time")
  local lengths = { idle = 40, sleepy = 40, morning = 40, click = 40, joke = 80 }
  for kind, max in pairs(lengths) do
    local pool = {}
    for i = 1, 40 do
      local line = lines.theme.line(kind)
      if line then pool[line] = true end
    end
    for line in pairs(pool) do t.ok(utf8.len(line) <= max, "lines: " .. kind .. " limit") end
  end
  lines.theme.set(false)
  t.eq(lines.theme.line("idle"), nil, "lines: off")
  local menu = fake()
  local item = menu.theme.menu()
  t.eq(item.title, "Halloween", "menu")
  t.eq(#item.menu[4].menu, 4, "menu: four groups")
  item.menu[1].fn()
  t.eq(menu.memory["claudeBuddy.halloween"].on, false, "menu: toggle saved")
  t.eq(menu.theme.on(), false, "menu: toggle off")
  local forced = fake({ cfg = { halloween = true } })
  t.eq(forced.theme.menu().menu[1].disabled, true, "menu: config disables toggle")

  local throwing = fake({ say = function() error("draw boom") end })
  throwing.theme.skit("a")
  throwing.clock.t = 1.2
  local ok = pcall(function() draw(throwing, "behind") end)
  t.eq(ok, true, "an error while drawing turns the theme off")
  t.eq(throwing.theme.on(), false, "an error while drawing turns the theme off: off")
  t.eq(count(throwing.logs, "switched off"), 1, "an error while drawing turns the theme off: logged once")
  t.eq(throwing.calls[#throwing.calls], "nil", "an error while drawing turns the theme off: undressed")

  local world = fake()
  local first, second = draw(world, "behind", 0), draw(world, "behind", 0.1)
  local w1, w2 = {}, {}
  for _, entry in ipairs(first) do if entry.key == "web" then w1[#w1 + 1] = entry.el end end
  for _, entry in ipairs(second) do if entry.key == "web" then w2[#w2 + 1] = entry.el end end
  t.eq(#w1, 8, "web draws 8 elements")
  local same = #w2 == 8
  for i = 1, #w1 do same = same and w1[i] == w2[i] end
  t.ok(same, "web draws 8 elements: reused")
  local ys, climbed = {}, nil
  for at = 0, 4, 0.5 do
    local drawn = draw(world, "behind", at)
    for _, entry in ipairs(drawn) do
      if entry.key:match("^spider:hang:") and entry.el.type == "rectangle" then
        ys[#ys + 1] = entry.el.frame.y
        break
      end
    end
  end
  for _, y in ipairs(ys) do t.ok(y >= 92 and y <= 100, "resting spider bobs") end
  for _, entry in ipairs(draw(world, "behind", 27.6)) do
    if entry.key:match("^spider:climb:") and entry.el.type == "rectangle" then
      climbed = entry.el.frame.y
      break
    end
  end
  t.ok(climbed and climbed <= 46, "resting spider climbs")
  local pail = {}
  world.theme.pail(function(el) pail[#pail + 1] = el end, 65, 98)
  local orange = false
  for _, el in ipairs(pail) do
    if el.frame.x == 140 and el.fillColor and math.abs(el.fillColor.red - 0xf5 / 255) < 0.01
      and math.abs(el.fillColor.green - 0x9a / 255) < 0.01 then orange = true end
  end
  t.ok(orange, "pail draws at the hand")
  local gone = fake()
  gone.theme.skit("heist")
  advance(gone, 1.2, true)
  t.eq(gone.theme.pail(function() end, 65, 98), false, "pail draws at the hand: gone")
  local layered = fake()
  layered.theme.skit("layers")
  local behind, front = draw(layered, "behind"), draw(layered, "front")
  local left, right = false, false
  for _, entry in ipairs(behind) do
    if entry.el.type == "rectangle" and entry.el.frame.x < 30 then left = true end
  end
  for _, entry in ipairs(front) do
    if entry.el.type == "rectangle" and entry.el.frame.x > 150 then right = true end
  end
  t.ok(left and right, "actors split by layer")
  local hat = fake({ rows = 8 })
  hat.theme.skit("hat")
  local bottom
  for _, entry in ipairs(draw(hat, "front")) do
    if entry.el.type == "rectangle" then bottom = entry.el.frame.y + entry.el.frame.h end
  end
  t.eq(bottom, 98 - 40, "top anchor uses the hat")
  local off = fake({ cfg = { halloween = false } })
  local drawn = 0
  local function record() drawn = drawn + 1 end
  off.theme.behind(record, 65, 98, 100, 0)
  off.theme.pail(record, 65, 98)
  off.theme.front(record, 65, 98, 100, 0)
  t.eq(drawn, 0, "nothing drawn when off")
end
