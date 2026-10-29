-- How the buddy uses voice.lua: which lines are answers, his own lines wait while he talks,
-- a click cuts him off, and spoken lines start his mouth when the audio starts.
return function(t, dir)
  local V = { talking = false, spoken = {}, stops = 0 }
  function V.configure() return V end
  function V.settings() return { listen = false, answers = false, outLoud = 0 } end
  function V.speaking() return V.talking end
  function V.hold(fn) V.held = fn end
  function V.speak(text, kind, cb) V.spoken[#V.spoken + 1] = { text = text, kind = kind, cb = cb } end
  function V.stopSpeech() V.stops = V.stops + 1 end
  function V.command() return nil end
  function V.start() end
  function V.pause() end
  function V.resume() end
  local S = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, { name = "Sam" }, { stubs = { ["voice.lua"] = V } })
  local hello
  for _, s in ipairs(V.spoken) do if s.text:match("^Hi Sam") then hello = s end end
  t.ok(hello and hello.text:match("^Hi Sam"), "the hello goes through voice.lua")
  t.eq(hello and hello.kind, "line", "his own line, not an answer")

  V.talking = true
  local saidBefore = #S.said
  S.M.test("love", 2)
  t.eq(#S.said, saidBefore, "his own line waits while he's talking")
  t.ok(V.held ~= nil, "it's held for later")
  V.talking = false
  if V.held then V.held() end
  t.eq(#S.said, saidBefore + 1, "and is said once he's done")

  V.talking = true
  local before = S.M.dragTimer
  S.click()
  t.eq(V.stops, 1, "a click while he talks cuts him off")
  t.eq(S.M.dragTimer, before, "and doesn't start a drag")
  V.talking = false

  -- a spoken line keeps the mouth still until the audio starts, then the bubble outlasts it
  local spoken = V.spoken[#V.spoken]
  t.ok(spoken and spoken.cb and spoken.cb.onStart and spoken.cb.onEnd and spoken.cb.onSkip, "speak gets the sync callbacks")
  if spoken then
    spoken.cb.onStart(2)
    S.step(2, 0.25)
    t.eq(#S.errors, 0, "frames draw while he talks")
    spoken.cb.onEnd(false)
  end
  S.done()

  -- Right-click > Voice shows the settings, with an in-between slider value as its own row
  local V2 = setmetatable({ calls = {} }, { __index = V })
  function V2.configure() return V2 end
  function V2.settings() return { listen = true, answers = true, outLoud = 30, bubbles = true, phrase = "okay Buddy", voice = { engine = "system" } } end
  function V2.set(k, v) V2.calls[#V2.calls + 1] = { k, v } end
  local S2 = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, { name = "Sam" }, { stubs = { ["voice.lua"] = V2 } })
  local function voiceMenu()
    for _, item in ipairs(S2.rightClick() or {}) do if item.title == "Voice" then return item.menu end end
  end
  local menu = voiceMenu()
  t.ok(menu ~= nil, "the right-click menu has Voice")
  if menu then
    t.eq(menu[1].checked, true, "listening is checked")
    local loud
    for _, item in ipairs(menu) do if item.menu and item.title:match("^Talk out loud") then loud = item end end
    t.eq(loud and loud.title, "Talk out loud: 30%", "the slider's value")
    local rows, checked = {}, nil
    for _, row in ipairs(loud and loud.menu or {}) do rows[#rows + 1] = row.title; if row.checked then checked = row.title end end
    t.eq(table.concat(rows, " "), "0% 25% 30% 50% 75% 100%", "30% gets its own row")
    t.eq(checked, "30%", "and it's the checked one")
    local bubbles
    for _, item in ipairs(menu) do if item.title == "Say my bubble lines out loud" then bubbles = item end end
    t.ok(bubbles ~= nil, "the menu has the bubble lines switch")
    t.eq(bubbles and bubbles.checked, true, "checked when bubble lines are on")
    if bubbles then bubbles.fn() end
    t.ok(V2.calls[#V2.calls] and V2.calls[#V2.calls][1] == "bubbles" and V2.calls[#V2.calls][2] == false, "clicking it switches bubble lines off")
  end
  S2.M.voiceTrouble = "Voice needs macOS 26 or later."
  menu = voiceMenu()
  t.eq(menu and menu[1].title, "Voice needs macOS 26 or later.", "voice that can't run says why")
  t.eq(menu and menu[1].disabled, true, "in a disabled line")
  local off
  for _, item in ipairs(menu or {}) do if item.title == "Turn voice off" then off = item end end
  t.ok(off ~= nil, "with voice still on, the menu can turn it off")
  if off then off.fn() end
  local set = {}
  for _, c in ipairs(V2.calls) do set[c[1]] = c[2] end
  t.ok(set.listen == false and set.answers == false and set.outLoud == 0, "which switches all of it off")
  t.eq(S2.M.voiceTrouble, nil, "and clears the trouble")

  -- the automatic skin change follows Quiet for an hour: it changes, silently (outside the
  -- Halloween week, when a costume would stay on)
  S2.M.halloween(false)
  for _, item in ipairs(S2.rightClick() or {}) do if item.title == "Quiet for an hour" then item.fn() end end
  local said = #S2.said
  S2.settings["claudeBuddy.skinShuffleHours"], S2.settings["claudeBuddy.skinShuffleAt"] = 1, 0
  S2.M.skinShuffleTick()
  t.ok((S2.settings["claudeBuddy.skinShuffleAt"] or 0) > 0, "the shuffle changed the skin")
  t.eq(#S2.said, said, "and said nothing while he's quiet")
  S2.done()
end
