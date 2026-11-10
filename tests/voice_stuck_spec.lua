-- The Mac's audio service stops answering (it happens: every app's sound hangs): speeches the
-- helper never starts mustn't hold his lines back one by one. No helper runs here.
return function(t, dir)
  local V = dofile(dir .. "/voice.lua")
  V.settingsKey = "claudeBuddy.voiceStuckSpec"
  hs.settings.set(V.settingsKey, { answers = true })
  local troubles, shown = {}, {}
  V.options = { onTrouble = function(msg) troubles[#troubles + 1] = msg end }
  V.active, V.speeches, V.waiting = true, {}, {}
  V.speech = { speakable = function(s) return s end }
  local function stuck(id, started)
    V.speeches[id] = { id = id, file = t.tmpdir() .. "/none-" .. id, cb = {}, deadline = 0, started = started }
    V.currentId = id
    V.checkStuck()
  end
  stuck(1, true)
  t.eq(#troubles, 0, "a speech that started and never ended is only skipped")
  t.eq(V.audioStuck, nil, "the audio isn't called stuck for that")
  stuck(2)
  t.eq(#troubles, 0, "one speech that never started could be a slow start")
  stuck(3)
  t.eq(#troubles, 1, "two in a row: he says the Mac's sound isn't answering")
  t.ok(troubles[1] and troubles[1]:match("sound isn't answering"), "in those words")
  stuck(4)
  t.eq(#troubles, 1, "and says it once")
  V.speak("An answer while it's stuck.", "answer", { onSkip = function(dropped) shown[#shown + 1] = dropped end })
  t.eq(shown[1], false, "an answer shows at once, without a sound")
  t.eq(#V.waiting, 0, "and nothing waits in line")
  hs.settings.set(V.settingsKey, nil)
end
