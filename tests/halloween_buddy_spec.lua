-- buddy.lua with the Halloween theme forced on, in the hidden test Buddy (tests/buddy_sandbox.lua):
-- the costume, every shipped skit through frame(), clicks ending a skit, the menu, and a skin
-- pick that sticks. Nothing is shown and no real settings are read or written.
return function(t, dir)
  local sandbox = dofile(dir .. "/tests/buddy_sandbox.lua")
  local WEB = 70 -- the web is one 70-point picture in the top-left corner

  local ids = {}
  for name in hs.fs.dir(dir .. "/skits") do
    local id = name:match("^([^.].*)%.json$")
    if id and id ~= "sprites" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local function length(id)
    local f = assert(io.open(dir .. "/skits/" .. id .. ".json"))
    local d = hs.json.decode(f:read("a"))
    f:close()
    return d.length
  end
  local function texts(S)
    local out = {}
    for _, el in ipairs(S.canvas:canvasElements()) do
      if el.type == "text" and el.text then
        out[#out + 1] = type(el.text) == "string" and el.text or el.text:getString()
      end
    end
    return table.concat(out, "\n")
  end
  local function hasWeb(S)
    for _, el in ipairs(S.canvas:canvasElements()) do
      local f = el.frame
      if el.type == "image" and f and f.x == 0 and f.y == 0 and f.w == WEB and f.h == WEB then return true end
    end
    return false
  end
  local function find(items, title)
    for i, it in ipairs(items or {}) do if it.title == title then return it, i end end
  end

  local A = sandbox(dir, { halloween = true })
  local ok, err = pcall(function()
    local K, T = A.M.skins, A.M.theme
    A.step(2)
    t.eq(K.current().id, "witch", "wears the witch")
    t.ok(hasWeb(A), "the web is drawn")
    t.eq(#A.personas, 0, "no brain, no persona hook")

    -- every skit, start to finish
    for _, id in ipairs(ids) do
      t.ok(A.M.skit(id), "plays " .. id)
      A.step(math.ceil((length(id) + 1) / 0.25))
      t.ok(not T.busy(), id .. " finishes")
      t.eq(T.offset(), 0, id .. " leaves Buddy home")
    end
    t.eq(#A.errors, 0, "every skit plays through frame()" .. (A.errors[1] and (": " .. tostring(A.errors[1])) or ""))

    -- skit lines go in the bubble, not the chat
    local said = #A.said
    A.M.skit("hat-perch")
    local shown = false
    for _ = 1, 40 do
      A.step(1)
      local s = texts(A)
      shown = shown or s:find("Hello?", 1, true) or s:find("bat on me", 1, true) or s:find("Shoo!", 1, true)
        or s:find("Off my hat!", 1, true)
    end
    t.ok(shown, "a skit line shows in the bubble")
    t.eq(#A.said, said, "skit lines stay out of the chat")

    -- a click ends a skit, and the pail comes back
    A.M.skit("pail-heist")
    A.step(9)
    t.ok(T.busy() and not T.status().pail, "the bat has the pail")
    A.click()
    t.ok(not T.busy(), "a click ends the skit")
    t.ok(T.status().pail and T.status().offset == 0, "pail back, Buddy home")

    -- the menu: Halloween right after Skin, every skit once
    local items = A.rightClick()
    local _, si = find(items, "Skin")
    local hw = items[si + 1]
    t.eq(hw and hw.title, "Halloween", "Halloween sits right after Skin")
    local skits, count, seen, dup = find(hw and hw.menu, "Skits"), 0, {}, false
    for _, g in ipairs(skits and skits.menu or {}) do
      for _, it in ipairs(g.menu or {}) do
        count = count + 1
        dup = dup or seen[it.title]
        seen[it.title] = true
      end
    end
    t.eq(count, #ids, "the Skits menu lists every skit")
    t.ok(not dup, "each skit once")

    -- picking a skin from the menu declines the witch for the season
    local classic
    for _, g in ipairs(find(items, "Skin").menu) do classic = classic or find(g.menu, "Classic") end
    t.ok(classic, "Classic is in the Skin menu")
    if classic then classic.fn() end
    A.poll()
    local dressed = A.settings["claudeBuddy.halloweenDressed"]
    t.ok(type(dressed) == "table" and dressed.declined, "a menu pick is remembered")

    -- off for the session: the world goes and the costume comes off
    A.M.halloween(false)
    A.step(1)
    t.ok(not hasWeb(A), "no web when off")
    t.eq(#A.errors, 0, "no frame errors")
  end)
  local store = A.settings
  A.done()
  t.ok(ok, "sandbox A: " .. tostring(err))

  -- a reload with the same settings keeps the pick
  local B = sandbox(dir, { halloween = true }, { settings = store })
  ok, err = pcall(function()
    B.step(1)
    t.eq(B.M.skins.current().id, "classic", "a menu pick sticks across a reload")
  end)
  B.done()
  t.ok(ok, "sandbox B: " .. tostring(err))

  -- with a brain, the theme adds its persona sentence
  local C = sandbox(dir, { halloween = true, ai = {} })
  ok, err = pcall(function() t.eq(#C.personas, 1, "persona hook registered with a brain") end)
  C.done()
  t.ok(ok, "sandbox C: " .. tostring(err))
end
