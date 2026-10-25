-- buddy.lua's frame(), driven by hand for every skin, so the call sites into skins.lua stay
-- honest. buddy.lua loads in a sandbox: a stand-in hs with a canvas that's never shown,
-- timers that never fire, settings that are never written and no chat or events, so
-- nothing appears on screen and the running buddy is left alone. Also checks {name}
-- filling, word particles and the Skin menu.
return function(t, dir)
  local fixtures = t.tmpdir()
  t.writeJson(fixtures .. "/words.json", { id = "words", name = "Words", group = "memes",
    reactions = { love = { glyphs = { "SMASH" }, rate = 4 }, shaken = { glyphs = { "so tired" } } },
    lines = { click = { "Arr, {name}!", "Hi {name}!" } } })
  t.writeJson(fixtures .. "/dash.json", { id = "dash", name = "-", group = "memes" })

  local function sandbox(cfg)
    local S = { said = {}, writes = {}, costumes = {}, errors = {}, mods = {}, buttons = { left = true } }
    local clock = hs.timer.secondsSinceEpoch()
    local function timer(fn) return { fn = fn, stop = function() end, start = function(self) return self end } end
    local function stub(real) return setmetatable({ new = function() return timer() end }, { __index = real }) end
    local fake = setmetatable({
      timer = setmetatable({ doEvery = function(_, fn) return timer(fn) end, doAfter = function(_, fn) return timer(fn) end,
        secondsSinceEpoch = function() return clock end }, { __index = hs.timer }),
      settings = setmetatable({ get = function(k) if k ~= "claudeBuddy.skin" then return hs.settings.get(k) end end,
        set = function(k) S.writes[#S.writes + 1] = k end, clear = function() end }, { __index = hs.settings }),
      canvas = setmetatable({ new = function(fr)
        if fr.w ~= 200 or fr.h ~= 170 then return hs.canvas.new(fr) end -- skins.lua's emoji canvases
        S.canvas = hs.canvas.new(fr)
        return setmetatable({}, { __index = function(_, k)
          if k == "show" then return function(self) return self end end
          if k == "mouseCallback" then return function(self, fn) S.mouse = fn; return self end end
          local v = S.canvas[k]
          if type(v) ~= "function" then return v end
          return function(_, ...) return v(S.canvas, ...) end
        end })
      end }, { __index = hs.canvas }),
      application = setmetatable({ watcher = stub(hs.application.watcher) }, { __index = hs.application }),
      screen = setmetatable({ watcher = stub(hs.screen.watcher) }, { __index = hs.screen }),
      caffeinate = setmetatable({ watcher = stub(hs.caffeinate.watcher) }, { __index = hs.caffeinate }),
      eventtap = setmetatable({ checkKeyboardModifiers = function() return S.mods end,
        checkMouseButtons = function() return S.buttons end }, { __index = hs.eventtap }),
      menubar = { new = function() return { setMenu = function(_, items) S.menu = items end, popupMenu = function() end } end },
      task = { new = function() error("sandbox: hs.task") end },
    }, { __index = hs })
    local Brain = setmetatable({}, { __index = function(B, k)
      if k == "costume" then return function(n) S.costumes[#S.costumes + 1] = tostring(n) end end
      if k == "busy" or k == "private" then return function() return true end end
      if k == "configure" then return function() return B end end
      return function() return nil end
    end })
    local env
    local stubs = {
      ["chat.lua"] = { said = function(s) S.said[#S.said + 1] = s end, isOpen = function() return false end,
        open = function() end, close = function() end, post = function() end, forget = function() end },
      ["events.lua"] = { start = function() return {} end, test = function() end },
      ["job_line.lua"] = function() return "" end,
      ["brain.lua"] = Brain,
    }
    env = setmetatable({ hs = fake,
      loadfile = function(p) if p:match("/config%.lua$") then return function() return cfg end end return loadfile(p) end,
      dofile = function(p)
        local name = p:match("([^/]+)$")
        if name ~= "skins.lua" then return assert(stubs[name], "sandbox: dofile " .. p) end
        local K = assert(loadfile(p, "t", env))()
        return { new = function(opts) -- the fixture skins load last, as a user folder would
          local dirs = {}
          for i, d in ipairs(opts.dirs) do dirs[i] = d end
          dirs[#dirs + 1] = fixtures
          opts.dirs = dirs
          return K.new(opts)
        end }
      end }, { __index = _G })
    S.M = assert(loadfile(dir .. "/buddy.lua", "t", env))()
    S.M.start()
    function S.step(n)
      for _ = 1, n do
        clock = clock + 0.25
        local ok, err = pcall(S.M.frameTimer.fn)
        if not ok then S.errors[#S.errors + 1] = err end
      end
    end
    function S.last() return S.said[#S.said] end
    function S.done() if S.canvas then S.canvas:delete() end end
    return S
  end

  -- no name, no brain: every skin in a few poses
  local A = sandbox({ lines = { jealous = { "Arr, {name}!" }, mail = { "Hi {name}!" } } })
  local ok, err = pcall(function()
    local K = A.M.skins
    for _, s in ipairs(K.list()) do
      K.wear(s.id)
      A.M.test("love", 8); A.step(2)
      A.M.test("idle", 8, "shaken"); A.step(2)
      A.M.test("sleep", 8, "dizzy"); A.step(1)
      A.M.test("tinker", 8); A.step(1)
    end
    t.ok(#K.list() >= 3, "skins loaded in the sandbox")
    t.eq(#A.errors, 0, "frame() runs for every skin" .. (A.errors[1] and (": " .. tostring(A.errors[1])) or ""))

    -- word particles get a box as wide as the word
    K.wear("words")
    A.M.test("love", 8)
    local word, fits = 0, true
    for _ = 1, 8 do
      A.step(1)
      for _, el in ipairs(A.canvas:canvasElements()) do
        if el.type == "text" and el.text and el.text:getString() == "SMASH" then
          word = word + 1
          fits = fits and el.frame.w >= hs.drawing.getTextDrawingSize(el.text).w
        end
      end
    end
    t.ok(word > 0 and fits, "word particles are drawn whole")

    -- {name} with no name set
    A.M.test("jealous", 8); t.eq(A.last(), "Arr!", "no name: the comma before {name} goes too")
    A.M.test("mail", 8); t.eq(A.last(), "Hi!", "no name: Hi {name}! reads Hi!")

    -- the Skin menu
    K.wear(nil)
    A.mods = { ctrl = true }
    A.mouse(nil, "mouseDown")
    A.M.menuTimer.fn()
    local skin, before = nil, nil
    for i, it in ipairs(A.menu or {}) do
      if it.title == "Skin" then skin = it end
      if it.title == "Setup…" then before = A.menu[i - 1] and A.menu[i - 1].title end
    end
    t.ok(skin and before == "Skin", "Skin sits just before Setup…")
    local titles = {}
    for _, g in ipairs(skin and skin.menu or {}) do
      for _, x in ipairs(g.menu or {}) do titles[x.title] = x end
    end
    t.ok(titles["–"] and not titles["-"], "a skin called - isn't a separator")
    if titles.Words then titles.Words.fn() end
    t.eq(K.current().id .. "|" .. tostring(A.last()), "words|Arr!", "picking a skin says its first click line")
    t.ok(skin.menu[1].title == "Surprise me", "Surprise me comes first")
    skin.menu[1].fn()
    t.ok(K.current().id ~= "words", "Surprise me picks another skin")
    A.step(1)
    t.eq(#A.errors, 0, "no frame errors after picking")
  end)
  A.done()
  t.ok(ok, "sandbox A: " .. tostring(err))

  -- a name and a brain
  local B = sandbox({ name = "Sam", ai = {}, lines = { jealous = { "Arr, {name}!" } } })
  ok, err = pcall(function()
    B.M.test("jealous", 8); t.eq(B.last(), "Arr, Sam!", "with a name, {name} fills in")
    B.M.skins.wear("words"); B.step(1); B.M.skins.wear(nil); B.step(1)
    t.eq(table.concat(B.costumes, ","), "nil,Words,nil", "the brain hears each costume change")
    local saved = false
    for _, k in ipairs(B.writes) do saved = saved or k == "claudeBuddy.skin" end
    t.ok(not saved, "wear never saves")
  end)
  B.done()
  t.ok(ok, "sandbox B: " .. tostring(err))
end
