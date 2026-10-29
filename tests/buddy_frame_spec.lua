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
    local S = { said = {}, writes = {}, costumes = {}, errors = {}, mods = {}, buttons = { left = true },
      sent = {}, voice = {}, notes = {}, history = {}, brainTurns = {}, remembered = {} }
    local clock = hs.timer.secondsSinceEpoch()
    local function timer(fn) return { fn = fn, stop = function() end, start = function(self) return self end } end
    local function stub(real) return setmetatable({ new = function() return timer() end }, { __index = real }) end
    local fake = setmetatable({
      timer = setmetatable({ doEvery = function(_, fn) return timer(fn) end, doAfter = function(_, fn) return timer(fn) end,
        secondsSinceEpoch = function() return clock end }, { __index = hs.timer }),
      settings = setmetatable({ get = function(k)
        -- never the running buddy's voice keys: its switches would start a real helper, and its
        -- helper's PID (claudeBuddy.voicePid) would have V.start kill the helper it's using
        if k ~= "claudeBuddy.skin" and k ~= "claudeBuddy.watchPausedUntil" and not k:find("^claudeBuddy%.voice") then
          return hs.settings.get(k)
        end
        return nil -- an explicit nil, like hs.settings.get: tonumber() with no value at all is an error
      end,
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
      image = setmetatable({ imageFromPath = function() return {
        size = function() return { w = 320, h = 240 } end,
        encodeAsURLString = function() return "data:image/jpeg;base64,cGhvdG8=" end,
      } end }, { __index = hs.image }),
    }, { __index = hs })
    local Brain = setmetatable({}, { __index = function(B, k)
      if k == "costume" then return function(n) S.costumes[#S.costumes + 1] = tostring(n) end end
      if k == "busy" or k == "private" then return function() return true end end
      if k == "configure" then return function() return B end end
      if k == "chat" then return function(history, ctx, done)
        S.brainTurns[#S.brainTurns + 1] = history[#history] and history[#history].content
        S.brainCtx, S.brainDone = ctx, done
      end end
      if k == "command" then return function(text)
        S.notes[#S.notes + 1] = text
        return "notes reply"
      end end
      return function() return nil end
    end })
    local env
    local tasks = { poll = function() end, sweep = function() end, summary = function() end,
      list = function() return {} end, remember = function(id, task) S.remembered[id] = task end,
      answer = function() end, forMessage = function() end, takeProposal = function() end,
      forThread = function() end, find = function() end, thread = function() end } -- tasks.lua: no sessions
    tasks.configure = function() return tasks end
    local telegram = {
      start = function(_, onMessage) S.onTelegram = onMessage; return true end,
      running = function() return true end,
      command = function(text) local c = (text or ""):match("^%s*/(%a+)"); return c and c:lower() end,
      affection = function() return false end,
      send = function(text, done, opts)
        S.sent[#S.sent + 1] = { text = text, opts = opts }
        if done then done(true, { 100 + #S.sent }) end
      end,
      react = function(id, reaction) S.reactions = S.reactions or {}; S.reactions[id] = reaction end,
      voiceReply = function(text, thread) S.voice[#S.voice + 1] = { text = text, thread = thread } end,
      download = function(_, _, done) S.downloadDone = done end,
      typing = function() end,
    }
    local stubs = {
      ["tasks.lua"] = tasks,
      ["chat.lua"] = { said = function(s) S.said[#S.said + 1] = s end, isOpen = function() return false end,
        open = function(opts) S.chatOpts = opts end, close = function() end,
        post = function(role, content) S.history[#S.history + 1] = { role = role, content = content } end,
        history = function() return S.history end, forget = function() end },
      ["events.lua"] = { start = function() return {} end, test = function() end },
      ["job_line.lua"] = function() return "" end,
      ["brain.lua"] = Brain,
      ["telegram.lua"] = telegram,
    }
    -- the real watching, counting, learning, health and wizard modules; the ones that keep
    -- files keep them in a temp folder, not the running buddy's
    local data = t.tmpdir()
    local real = { ["privacy.lua"] = true, ["personality.lua"] = true, ["setup.lua"] = true, ["voice.lua"] = true, ["speech.lua"] = true, ["providers.lua"] = true, ["keys.lua"] = true, ["usage_poll.lua"] = true,
      ["facts.lua"] = function(K) return function() return K.new(data .. "/facts.json") end end,
      ["learn.lua"] = function(K) return function(_, moods) return K.new(data .. "/learn.json", moods) end end,
      ["health.lua"] = function(K) return function(_, opts) return K.new(data .. "/health", opts) end end }
    env = setmetatable({ hs = fake,
      loadfile = function(p) if p:match("/config%.lua$") then return function() return cfg end end return loadfile(p) end,
      dofile = function(p)
        local name = p:match("([^/]+)$")
        if real[name] then
          local K = assert(loadfile(p, "t", env))()
          if real[name] == true then return K end
          return setmetatable({ new = real[name](K) }, { __index = K })
        end
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
      for _, a in ipairs({ "yawn", "doze", "carried", "landed", "powerup" }) do A.M.test("idle", 2, a); A.step(2) end
      A.M.voice.active, A.M.voice.live = true, true; A.step(2); A.M.voice.active, A.M.voice.live = false, false; A.step(3)
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

    -- the live-voice halo: an image behind Buddy while a live chat is on, gone after it fades
    local function halos()
      local n = 0
      for _, el in ipairs(A.canvas:canvasElements()) do if el.type == "image" and el.imageScaling == "none" then n = n + 1 end end
      return n
    end
    K.wear("classic")
    A.step(1)
    local none = halos() -- images the skin itself draws
    A.step(1); t.eq(halos(), none, "no halo with no live voice chat")
    A.M.voice.active, A.M.voice.live = true, true
    A.step(1); t.eq(halos(), none + 1, "a live voice chat draws the halo")
    A.step(6); t.eq(halos(), none + 1, "the halo stays on for the whole chat")
    A.M.voice.active, A.M.voice.live = false, false
    A.step(4); t.eq(halos(), none, "the halo fades away when the chat ends")

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

  -- Telegram uses the same command handlers and chat queue as the desktop panel.
  local C = sandbox({ ai = {}, telegram = { voice_replies = "voice" } })
  ok, err = pcall(function()
    C.M.chat()
    C.chatOpts.ask({ { role = "user", content = "hello" } }, function() end)
    t.ok(C.brainCtx and C.brainCtx.status:find("Claude Code sessions:", 1, true),
      "desktop chat can build its watched status")
    C.brainDone("hello")
    C.brainTurns, C.history = {}, {}

    t.eq(C.M.tgCommandText("  /NOTES@BuddyBot   "), "/notes", "Telegram note command is canonical")
    t.eq(C.M.tgCommandText(" /WATCH@BuddyBot 30m rain  "), "/watch 30m rain", "Telegram watch command is canonical")
    C.onTelegram({ text = "  /NOTES@BuddyBot   ", message_id = 1 })
    t.eq(C.notes[#C.notes], "/notes", "shared note handler receives canonical command")
    C.onTelegram({ text = " /FORGET@BuddyBot 2 ", message_id = 2 })
    t.eq(C.notes[#C.notes], "/forget 2", "shared forget handler receives canonical command")
    for _, command in ipairs({ " /WATCH@BuddyBot 30m rain ", " /WATCHES@BuddyBot ", " /UNWATCH@BuddyBot 1 " }) do
      C.onTelegram({ text = command, message_id = 2 })
      t.ok(C.sent[#C.sent].text:find("Watches need", 1, true), "shared watch handler receives canonical command")
    end

    local photo = { photo = "file-id", caption = "first", message_id = 3 }
    C.onTelegram(photo)
    C.onTelegram({ text = "second", message_id = 4 })
    t.eq(#C.brainTurns, 0, "later text waits for photo download")
    C.downloadDone("/tmp/buddy-test-photo.img")
    t.eq(C.brainTurns[1], "first", "photo takes first chat turn")
    C.brainDone("first answer")
    t.eq(C.brainTurns[2], "second", "later text takes next chat turn")
    C.brainDone("second answer")
    C.onTelegram({ photo = "bad-file", message_id = 6 })
    C.onTelegram({ text = "after failure", message_id = 7 })
    C.downloadDone(nil, "Download failed")
    t.eq(C.sent[#C.sent].text, "Download failed", "photo failure is answered before later text")
    t.eq(C.brainTurns[3], "after failure", "photo failure releases later messages")
    C.brainDone("okay")
    C.onTelegram({ photo = "caption-file", caption = "/notes", message_id = 8 })
    C.downloadDone("/tmp/buddy-test-caption.img")
    t.eq(C.brainTurns[4], "/notes", "a command-like caption still belongs to the photo")
    t.eq(C.brainCtx.image, "cGhvdG8=", "the caption turn carries the photo bytes")
    C.brainDone("caption answer")

    C.M.tasks.tell("telegram", "task reply", "task-1", { incoming = { voice = true, message_id = 5, thread = 7 } })
    t.eq(C.remembered[100 + #C.sent], "task-1", "task reply keeps its message id")
    t.eq(C.voice[#C.voice].thread, 7, "voice note's task reply follows voice policy")
  end)
  C.done()
  t.ok(ok, "sandbox C: " .. tostring(err))

  local D = sandbox({ ai = {}, telegram = { voice_replies = "always" } })
  ok, err = pcall(function()
    D.M.tasks.tell("telegram", "update", "task-2")
    t.eq(D.voice[1].text, "update", "always speaks task updates")
    D.M.tasks.relay({ id = "task-2", name = "Task", origin = "telegram" }, { kind = "ended" })
    t.eq(D.voice[2].text, "🛠 Task has ended.", "always speaks relayed task updates")
  end)
  D.done()
  t.ok(ok, "sandbox D: " .. tostring(err))
end
