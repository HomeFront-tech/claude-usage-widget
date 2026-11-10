-- How the buddy uses voice.lua: which lines are answers, his own lines wait while he talks,
-- a click cuts him off, and spoken lines start his mouth when the audio starts.
return function(t, dir)
  local V = { talking = false, spoken = {}, stops = 0 }
  function V.configure() return V end
  function V.settings() return { listen = false, answers = false, outLoud = 0 } end
  function V.speaking() return V.talking end
  function V.hold(fn) V.held = fn end
  function V.speak(text, kind, cb, opts) V.spoken[#V.spoken + 1] = { text = text, kind = kind, cb = cb, opts = opts or {} } end
  function V.stopSpeech() V.stops = V.stops + 1 end
  function V.command() return nil end
  function V.start(opts) V.opts = opts end
  function V.isDumping() return V.dumping == true end
  function V.dumpText() return "so far" end
  function V.pause() end
  function V.resume() end
  local S = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, { name = "Sam" }, { stubs = { ["voice.lua"] = V } })
  local hello
  for _, s in ipairs(V.spoken) do if s.text:match("^Hi Sam") then hello = s end end
  t.ok(hello and hello.text:match("^Hi Sam"), "the hello goes through voice.lua")
  t.eq(hello and hello.kind, "line", "his own line, not an answer")

  -- every line waits its turn in voice.lua's line: the bubble and the chat show it then
  V.talking = true
  local saidBefore, spokenBefore = #S.said, #V.spoken
  S.step(24, 0.25) -- past the gap between lines of his own chatter
  S.M.test("proud", 2)
  local mine, chatter
  for i = spokenBefore + 1, #V.spoken do
    if V.spoken[i].opts.key == "chatter" then chatter = V.spoken[i] else mine = V.spoken[i] end
  end
  t.ok(mine ~= nil, "a line he was asked for goes to voice.lua even while he's talking")
  t.eq(mine and mine.kind, "line", "as his own line")
  t.eq(#S.said, saidBefore, "and waits for its turn before it shows")
  t.eq(V.held, nil, "nothing is held on the side any more")
  t.ok(chatter ~= nil, "the mood change's own line is chatter")
  if chatter then
    t.ok((chatter.opts.maxWait or 99) <= 30, "and chatter doesn't wait long")
    chatter.cb.onSkip(true)
    t.eq(#S.said, saidBefore, "a line dropped before its turn never shows")
  end
  V.talking = false
  if mine then mine.cb.onTurn() end
  t.eq(#S.said, saidBefore + 1, "a line shows once its turn comes")
  if mine then mine.cb.onStart(1); mine.cb.onEnd(false) end
  t.eq(#S.said, saidBefore + 1, "and only once")
  S.M.test("love", 2)
  local silent = V.spoken[#V.spoken]
  if silent then silent.cb.onSkip(false) end
  t.eq(#S.said, saidBefore + 2, "a line that isn't said out loud shows when its turn comes")

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

  -- a brain dump: he hops, the chat shows it, he says how to finish (voice.lua keeps that
  -- silent), and the display stays awake until it's over
  local o = V.opts or {}
  t.ok(o.onDumpStart and o.onDumpEnd, "voice.lua gets the brain dump callbacks")
  if o.onDumpStart then
    local spokenBefore = #V.spoken
    o.onDumpStart("")
    t.eq(S.awake.displayIdle, true, "the display stays awake")
    t.eq(S.chatVoice[#S.chatVoice][1], "dump", "the chat shows the dump")
    local hint = V.spoken[#V.spoken]
    t.ok(#V.spoken == spokenBefore + 1 and hint.text:match("send it"), "he says how to finish")
    V.dumping = true
    o.onLiveHold(true)
    t.eq(S.chatVoice[#S.chatVoice][1], "hold", "paused while another app has the mic")
    o.onLiveHold(false)
    t.eq(S.chatVoice[#S.chatVoice][1], "dump", "after the hold the chat is back to the dump")
    t.eq(S.chatVoice[#S.chatVoice][2], "so far", "with its words")
    o.onDumpEnd(true)
    V.dumping = false
    t.eq(S.awake.displayIdle, false, "the display may sleep again")
    t.eq(S.chatVoice[#S.chatVoice][1], "live", "back to the live chat")
    o.onDumpStart("")
    o.onLiveEnd("away", "unsent words")
    t.eq(S.awake.displayIdle, false, "a dump cut short lets the display sleep too")
    t.eq(S.drafts[#S.drafts], "unsent words", "and is kept as a draft")
    local line = V.spoken[#V.spoken]
    t.ok(line and line.text:match("waiting in the chat box"), "and he says where it is")
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
