-- A hidden test Buddy: buddy.lua loaded with a stand-in hs, for specs and tools/skit-snapshots.
-- Its canvas is never shown, its timers never fire (step() drives frame() by hand), its
-- settings live in memory (nothing is read from or written to hs.settings), and chat,
-- events and the brain are stubs. Skins, the Halloween theme and the skit engine load for
-- real. The running buddy is left alone.
--   local S = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, { halloween = true })
-- opts.settings: settings to start with, e.g. a store from an earlier sandbox (a reload).
-- opts.real: draw on a real (hidden) hs.canvas, for pictures; otherwise frame() hands its
-- elements to a plain table, which is much faster: S.canvas:canvasElements() reads them back.
return function(dir, cfg, opts)
  opts = opts or {}
  local S = { said = {}, errors = {}, personas = {}, mods = {}, buttons = { left = true }, idle = 0,
    settings = opts.settings or {} }
  local clock = hs.timer.secondsSinceEpoch()
  local function timer(fn) return { fn = fn, stop = function() end, start = function(self) return self end } end
  local function stub(real) return setmetatable({ new = function() return timer() end }, { __index = real }) end
  local fake = setmetatable({
    timer = setmetatable({ doEvery = function(_, fn) return timer(fn) end, doAfter = function(_, fn) return timer(fn) end,
      secondsSinceEpoch = function() return clock end }, { __index = hs.timer }),
    settings = { get = function(k) return S.settings[k] end, set = function(k, v) S.settings[k] = v end,
      clear = function(k) S.settings[k] = nil end },
    host = setmetatable({ idleTime = function() return S.idle end }, { __index = hs.host }),
    canvas = setmetatable({ new = function(fr)
      if fr.w ~= 200 or fr.h ~= 170 then return hs.canvas.new(fr) end -- skins.lua's emoji canvases
      if not opts.real then
        local at, els = { x = 0, y = 0 }, {}
        S.canvas = { canvasElements = function() return els end, delete = function() end }
        local c = {}
        function c:replaceElements(e) els = e; return self end
        function c:topLeft(p) if p then at = p; return self end return at end
        function c:frame() return { x = at.x, y = at.y, w = fr.w, h = fr.h } end
        function c:mouseCallback(fn) S.mouseFn = fn; return self end
        function c:level() return self end
        function c:behavior() return self end
        function c:clickActivating() return self end
        function c:show() return self end
        function c:delete() end
        return c
      end
      S.canvas = hs.canvas.new(fr)
      return setmetatable({}, { __index = function(_, k)
        if k == "show" then return function(self) return self end end
        if k == "mouseCallback" then return function(self, fn) S.mouseFn = fn; return self end end
        local v = S.canvas[k]
        if type(v) ~= "function" then return v end
        return function(_, ...) return v(S.canvas, ...) end
      end })
    end }, { __index = hs.canvas }),
    -- no front app, so the mood stays idle whatever is open on this Mac
    application = setmetatable({ watcher = stub(hs.application.watcher), frontmostApplication = function() return nil end },
      { __index = hs.application }),
    screen = setmetatable({ watcher = stub(hs.screen.watcher) }, { __index = hs.screen }),
    caffeinate = setmetatable({ watcher = stub(hs.caffeinate.watcher) }, { __index = hs.caffeinate }),
    eventtap = setmetatable({ checkKeyboardModifiers = function() return S.mods end,
      checkMouseButtons = function() return S.buttons end }, { __index = hs.eventtap }),
    menubar = { new = function() return { setMenu = function(_, items) S.menu = items end, popupMenu = function() end } end },
    task = { new = function() error("sandbox: hs.task") end },
  }, { __index = hs })
  local Brain = setmetatable({}, { __index = function(B, k)
    if k == "addPersona" then return function(fn) S.personas[#S.personas + 1] = fn end end
    if k == "busy" or k == "private" then return function() return true end end
    if k == "configure" then return function() return B end end
    return function() return nil end
  end })
  local env
  local tasks = { poll = function() end, sweep = function() end, summary = function() end,
    list = function() return {} end } -- tasks.lua: no sessions
  tasks.configure = function() return tasks end
  local stubs = {
    ["tasks.lua"] = tasks,
    ["chat.lua"] = { said = function(s) S.said[#S.said + 1] = s end, isOpen = function() return false end,
      open = function() end, close = function() end, post = function() end, forget = function() end,
      voice = function() end, sendVoice = function() return false end },
    ["events.lua"] = { start = function() return {} end, test = function() end },
    ["job_line.lua"] = function() return "" end,
    ["brain.lua"] = Brain,
  }
  for name, mod in pairs(opts.stubs or {}) do stubs[name] = mod end
  -- the real skins, theme, engine, watching and wizard modules; the ones that keep files
  -- (facts, learning, health) keep them in a scratch folder, not the running buddy's
  local data = (os.getenv("TMPDIR") or "/tmp/"):gsub("/$", "") .. "/buddy-sandbox-" .. hs.host.uuid()
  hs.fs.mkdir(data)
  local real = { ["skins.lua"] = true, ["halloween.lua"] = true, ["skits.lua"] = true,
    ["privacy.lua"] = true, ["personality.lua"] = true, ["setup.lua"] = true, ["voice.lua"] = true, ["speech.lua"] = true,
    ["facts.lua"] = function(K) return function() return K.new(data .. "/facts.json") end end,
    ["learn.lua"] = function(K) return function(_, moods) return K.new(data .. "/learn.json", moods) end end,
    ["health.lua"] = function(K) return function(_, o) return K.new(data .. "/health", o) end end }
  env = setmetatable({ hs = fake,
    loadfile = function(p) if p:match("/config%.lua$") then return function() return cfg end end return loadfile(p) end,
    dofile = function(p)
      local name = p:match("([^/]+)$")
      if real[name] and not (opts.stubs or {})[name] then -- a spec's own stub wins
        local K = assert(loadfile(p, "t", env))()
        if real[name] == true then return K end
        return setmetatable({ new = real[name](K) }, { __index = K })
      end
      return assert(stubs[name], "sandbox: dofile " .. p)
    end }, { __index = _G })
  S.M = assert(loadfile(dir .. "/buddy.lua", "t", env))()
  S.M.start()

  -- frames, dt seconds apart (default 0.25)
  function S.step(n, dt)
    for _ = 1, n do
      clock = clock + (dt or 0.25)
      local ok, err = pcall(S.M.frameTimer.fn)
      if not ok then S.errors[#S.errors + 1] = err end
    end
  end
  function S.poll()
    local ok, err = pcall(S.M.pollTimer.fn)
    if not ok then S.errors[#S.errors + 1] = err end
  end
  function S.mouse(msg, id) S.mouseFn(nil, msg, id) end
  -- a plain click on Buddy: press, then let go without moving
  function S.click()
    S.mods, S.buttons = {}, { left = true }
    S.mouse("mouseDown")
    S.buttons = { left = false }
    if S.M.dragTimer then S.M.dragTimer.fn() end
  end
  function S.rightClick()
    S.mods, S.buttons = { ctrl = true }, { left = true }
    S.mouse("mouseDown")
    S.M.menuTimer.fn()
    S.mods = {}
    return S.menu
  end
  function S.done() if S.canvas then S.canvas:delete() end end
  return S
end
