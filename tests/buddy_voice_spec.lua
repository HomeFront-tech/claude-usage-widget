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
end
