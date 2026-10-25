-- skits.lua: sprite runs, keyed motion, cues and the shipped Halloween skits.
return function(t, dir)
  local K = dofile(dir .. "/skits.lua")
  local function color(s) return K.hex(s) or ({ dark = "DARK", eye = "EYE" })[s] end
  local warnings = {}
  local function warnf(m) warnings[#warnings + 1] = m end
  local A = { top = { x = 100, y = 58 }, head = { x = 100, y = 98 }, face = { x = 100, y = 123 },
    hand = { x = 150, y = 118 }, feet = { x = 100, y = 158 }, web = { x = 39, y = 39 }, spider = { x = 39, y = 108 } }

  t.eq(table.concat(K.GROUPS, ","), "bats,spider,visitors,movies", "group order")
  t.eq(table.concat(K.ANCHORS, ","), "top,head,face,hand,feet,web,spider", "anchor names")
  t.eq(K.hex("#ff0000").red, 1, "hex red")
  t.eq(K.hex("#00000080").alpha, 128 / 255, "hex alpha")
  t.eq(K.hex("red"), nil, "names aren't hex")
  t.eq(K.ease("linear", 0.5), 0.5, "linear")
  t.eq(K.ease("in", 0.5), 0.25, "in")
  t.eq(K.ease("out", 0.5), 0.75, "out")
  t.eq(K.ease("inout", 0.5), 0.5, "inout mid")
  t.eq(K.ease("in", 2), 1, "clamped")

  -- Lit pixels become horizontal runs; a broken sprite is skipped with a warning.
  local lib = K.sprites({ s = { pixel = 3, colors = { X = "dark", e = "eye" },
    anims = { a = { fps = 2, frames = { { "XX.e", "...." }, { "X..e", "...." } } },
      b = { frames = { { "eeee", "...." } } } } },
    bad = { colors = { X = "dark" }, anims = { a = { frames = { { "X?" } } } } } }, color, warnf)
  local f1 = lib.s.anims.a.frames[1]
  t.eq(#f1.runs, 2, "runs merge same-colour spans")
  t.eq(f1.runs[1].n, 2, "first run is 2 wide")
  t.eq(f1.w .. "x" .. f1.h, "4x2", "frame size")
  t.eq(lib.bad, nil, "bad sprite skipped")
  t.ok(#warnings >= 1, "and warned")
  t.eq(K.sprites({ bad = { colors = { X = "dark" }, anims = { a = { frames = { { "X", "XX" } } } } } },
    color, warnf).bad, nil, "uneven rows skipped")
  local tall = {}
  for i = 1, 25 do tall[i] = "X" end
  t.eq(K.sprites({ bad = { colors = { X = "dark" }, anims = { a = { frames = { tall } } } } },
    color, warnf).bad, nil, "25 rows skipped")

  -- Keys use bottom-centre positions and step fields only change at their own time.
  local sk = assert(K.compile({ id = "x", name = "X", group = "bats", length = 4, actors = {
    { sprite = "s", layer = "front", keys = {
      { t = 1, x = 100, y = 50, anim = "a" },
      { t = 3, x = 140, y = 50, ease = "in", flip = true },
      { t = 3.5, at = "head", dy = -2, anim = "b" } } } },
    buddy = { { t = 0, say = "hi" }, { t = 2, action = "hop", ["for"] = 1 },
      { t = 2, say = { "a", "b" } } } }, lib, color))
  t.eq(#K.sample(sk, 0.5, A), 0, "hidden before its first key")
  local it = K.sample(sk, 1, A)[1]
  t.eq(it.x .. "," .. it.y, (100 - 6) .. "," .. (50 - 6), "bottom-centre to top-left")
  t.eq(K.sample(sk, 2, A)[1].x, math.floor(100 + 40 * 0.25 - 6 + 0.5), "arriving key eases")
  t.eq(K.sample(sk, 2, A)[1].flip, false, "flip waits for its key")
  t.eq(K.sample(sk, 3.2, A)[1].flip, true, "then flip holds")
  t.eq(K.sample(sk, 3.5, A)[1].frame, lib.s.anims.b.frames[1], "anim switches at its key")
  t.eq(K.sample(sk, 3.6, A)[1], nil, "gone after its last key")
  A.head = { x = 120, y = 90 }
  local a1 = K.sample(sk, 3.5, A)[1].x
  A.head = { x = 130, y = 90 }
  t.eq(K.sample(sk, 3.5, A)[1].x, a1 + 10, "anchor follows Buddy")

  -- A key without a position retains the live position from an earlier anchor.
  local held = assert(K.compile({ id = "held", name = "Held", group = "bats", length = 2, actors = {
    { sprite = "s", layer = "front", keys = { { t = 0, at = "head", anim = "a" }, { t = 1, hide = true },
      { t = 1.5, hide = false }, { t = 2 } } } } }, lib, color))
  t.eq(K.sample(held, 1.2, A)[1], nil, "hide steps on")
  t.eq(K.sample(held, 1.5, A)[1].x, 130 - 6, "positionless key keeps a live anchor")
  A.head = { x = 140, y = 90 }
  t.eq(K.sample(held, 1.5, A)[1].x, 140 - 6, "held anchor moves")

  local bt = assert(K.compile({ id = "z", name = "Z", group = "spider", length = 2, actors = {
    { sprite = "s", layer = "behind", bob = { amp = 3, hz = 0.25 }, thread = "web",
      keys = { { t = 0, x = 50, y = 80, anim = "a" }, { t = 2 } } } } }, lib, color))
  t.eq(K.sample(bt, 0, A)[1].y - K.sample(bt, 1, A)[1].y, 3, "bob quarter cycle rises 3 pt")
  local th = K.sample(bt, 0, A)[1].thread
  t.eq(th.x1 .. "," .. th.y1 .. "," .. th.x2 .. "," .. th.y2, "39,39,50,74", "thread to top centre")
  t.eq(K.sample(bt, 0.6, A)[1].frame, lib.s.anims.a.frames[2], "animation uses floor(time * fps)")

  t.eq(#K.cues(sk, -1, 0), 1, "t = 0 cue fires on first step")
  t.eq(#K.cues(sk, 0, 1.9), 0, "nothing in between")
  local cues = K.cues(sk, 1.9, 2.5)
  t.eq(#cues, 2, "both t = 2 cues")
  t.eq(cues[1].action, "hop", "same-time cues keep file order")
  t.eq(#K.cues(sk, -1, 4), 3, "slow frame fires all three once")

  -- Bad input gets a reason instead of reaching the frame loop.
  local function bad(d, name)
    local compiled, why = K.compile(d, lib, color)
    t.eq(compiled, nil, name .. " rejected")
    t.ok(type(why) == "string" and #why > 0, name .. " has a reason")
  end
  local function base() return { id = "y", name = "Y", group = "bats", length = 4, actors = {} } end
  local d = base(); d.length = 40; bad(d, "length > 30")
  d = base(); d.group = "unknown"; bad(d, "unknown group")
  d = base(); d.actors = { { sprite = "missing", layer = "front", keys = { { t = 0, x = 1, y = 2 } } } }; bad(d, "unknown sprite")
  d = base(); d.actors = { { sprite = "s", layer = "front", keys = { { t = 0, at = "missing", anim = "a" } } } }; bad(d, "unknown anchor")
  d = base(); d.actors = { { sprite = "s", layer = "front", keys = { { t = 1, x = 1, y = 2, anim = "a" },
    { t = 0.5 } } } }; bad(d, "keys out of order")
  d = base(); d.actors = { { sprite = "s", layer = "front", keys = { { t = 5, x = 1, y = 2, anim = "a" } } } }; bad(d, "key past length")
  d = base(); d.buddy = { { t = 0, say = "hi", action = "hop", ["for"] = 1 } }; bad(d, "two cue kinds")
  d = base(); d.extra = true; bad(d, "unknown skit field")
  d = base(); d.buddy = { { t = 1, run = 20, ["for"] = 1 } }; bad(d, "run left away from home")
  d = base(); d.buddy = { { t = 1, pail = "gone" } }; bad(d, "pail left gone without a chain")
  d = base(); d.actors = { { sprite = "s", layer = "front", keys = { { t = 0, x = 1, y = 2, anim = "single" } } } }
  d.sprites = { s = { pixel = 3, colors = { e = "eye" }, anims = { single = { frames = { { "e" } } } } } }
  t.eq(assert(K.compile(d, lib, color)).actors[1].art.default, "single", "local sprite replaces library sprite")
  d = base(); d.needs = { "pail", "evening" }; d.next = { skit = "later", after = { 40, 60 } }
  local chained = assert(K.compile(d, lib, color))
  t.ok(chained.needs.pail and chained.needs.evening, "needs become a set")
  t.eq(chained.next.after[1] .. "," .. chained.next.after[2] .. "," .. chained.next.chance,
    "40,60,1", "chain range and default chance")

  -- Recent ids are excluded until all choices are recent; chain-only weight is zero.
  local P = { { id = "a", weight = 1, needs = {} }, { id = "b", weight = 0, needs = {} },
    { id = "c", weight = 5, needs = { pail = true } }, { id = "d", weight = 1, eveningWeight = 9, needs = {} } }
  t.eq(K.pick(P, { pail = false, recent = { "d" } }, function() return 0 end).id, "a", "skips chain-only, needs, recent")
  t.eq(K.pick(P, { pail = true, recent = {} }, function() return 0.3 end).id, "c", "weighted choice")
  t.eq(K.pick(P, { pail = false, evening = true, recent = { "a" } }, function() return 0.99 end).id, "d", "evening weight")
  t.eq(K.pick(P, { pail = false, recent = { "d", "a" } }, function() return 0 end).id, "d", "all recent avoids last")
  t.eq(K.pick({ P[1] }, { recent = { "a" } }, function() return 0 end), nil, "one recent skit waits")

  -- Read every shipped file, then check chain targets and sustained face coverage.
  local folder = dir .. "/skits"
  local names = {}
  if hs.fs.attributes(folder, "mode") == "directory" then
    for name in hs.fs.dir(folder) do -- the loop needs the dir object hs.fs.dir returns, too
      if name:match("%.json$") and name ~= "sprites.json" then names[#names + 1] = name end
    end
  end
  table.sort(names)
  if #names == 0 then
    t.ok(true, "shipped skits skipped: no skit files yet")
    return
  end
  local function read(path)
    local file = assert(io.open(path, "r"))
    local raw = file:read("a")
    file:close()
    return assert(hs.json.decode(raw))
  end
  local sharedWarnings = {}
  local shared = K.sprites(read(folder .. "/sprites.json"), function(s)
    return K.hex(s) or ({ body = "body", shade = "shade", shine = "shine", eye = "eye", white = "white",
      grey = "grey", dark = "dark", red = "red", yellow = "yellow", gold = "gold", brown = "brown",
      blue = "blue", pink = "pink" })[s]
  end, function(msg) sharedWarnings[#sharedWarnings + 1] = msg end)
  t.eq(#sharedWarnings, 0, "shipped sprites compile without warnings")
  local shipped, ids = {}, {}
  for _, name in ipairs(names) do ids[name:sub(1, -6)] = true end
  local function shippedColor(s)
    return K.hex(s) or ({ body = "body", shade = "shade", shine = "shine", eye = "eye", white = "white",
      grey = "grey", dark = "dark", red = "red", yellow = "yellow", gold = "gold", brown = "brown",
      blue = "blue", pink = "pink" })[s]
  end
  for _, name in ipairs(names) do
    local skit, why = K.compile(read(folder .. "/" .. name), shared, shippedColor)
    t.ok(skit ~= nil, name .. " compiles" .. (why and ": " .. why or ""))
    if skit then
      shipped[#shipped + 1] = skit
      t.eq(skit.id, name:sub(1, -6), name .. " id matches filename")
      if skit.next then t.ok(ids[skit.next.skit], name .. " chain target exists") end
    end
  end
  local home = { top = { x = 100, y = 58 }, head = { x = 100, y = 98 }, face = { x = 100, y = 123 },
    hand = { x = 150, y = 118 }, feet = { x = 100, y = 158 }, web = { x = 39, y = 39 }, spider = { x = 39, y = 108 } }
  local faceArea = (125 - 75) * (143 - 108)
  for _, scene in ipairs(shipped) do
    local started, longest = nil, 0
    for step = 0, math.floor(scene.length * 10 + 0.5) do
      local at = step / 10
      local covered = {}
      local count = 0
      for _, item in ipairs(K.sample(scene, at, home)) do
        if item.layer == "front" then
          local x0, x1 = math.max(75, item.x), math.min(125, item.x + item.frame.w * item.pixel)
          local y0, y1 = math.max(108, item.y), math.min(143, item.y + item.frame.h * item.pixel)
          for y = y0, y1 - 1 do
            for x = x0, x1 - 1 do
              local key = y * 200 + x
              if not covered[key] then covered[key] = true; count = count + 1 end
            end
          end
        end
      end
      if count > faceArea / 2 then
        if not started then started = at end
        longest = math.max(longest, at - started)
      else started = nil end
    end
    t.ok(longest <= 1.5, scene.id .. " does not cover most of Buddy's face for over 1.5 s")
  end
end
