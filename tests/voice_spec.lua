-- Wake and turn rules use supplied time, so they need no live microphone.
return function(t, dir)
  local key = "claudeBuddy.voice"
  local saved = hs.settings.get(key)
  hs.settings.set(key, nil)
  local V = dofile(dir .. "/voice.lua")

  t.eq(V.matchWake("OK, Buddy. What's the weather?", "okay Buddy"),
    "what's the weather", "wake normalizes punctuation and ok")
  t.eq(V.matchWake("thank you buddy", "okay Buddy"), nil, "no mid-sentence wake")
  t.eq(V.matchWake("Okay Buddy", "okay Buddy"), "", "bare wake has empty rest")

  local one = V.turns({ phrase = "okay Buddy", timeout = 6 })
  t.eq(#one:event({ ev = "start", utt = 1 }, 0), 0, "start waits for words")
  local a = one:event({ ev = "words", utt = 1, text = "Okay Buddy what's" }, 0.2)
  t.eq(#a, 1, "wake once on first words")
  t.eq(a[1][1], "wake", "wake action")
  t.eq(a[1].rest, "what's", "first rest")
  a = one:event({ ev = "words", utt = 1, text = "Okay Buddy what's the weather" }, 0.5)
  t.eq(#a, 1, "later partial has one action")
  t.eq(a[1][1], "words", "later partial is words")
  t.eq(a[1].text, "what's the weather", "later rest")
  a = one:event({ ev = "end", utt = 1 }, 1)
  t.eq(a[1][1], "send", "one breath sends at end")
  t.eq(a[1].text, "what's the weather", "one breath sends final rest")

  local pause = V.turns({ phrase = "okay Buddy", timeout = 6 })
  a = pause:event({ ev = "end", utt = 1, text = "Okay Buddy" }, 10)
  t.eq(a[1][1], "wake", "final-only wake")
  t.eq(a[1].rest, "", "pause wake has empty rest")
  t.eq(#pause:event({ ev = "start", utt = 2 }, 12), 0, "next start opens turn")
  a = pause:event({ ev = "words", utt = 2, text = "tell me a joke" }, 12.2)
  t.eq(a[1][1], "words", "next utterance streams words")
  t.eq(a[1].text, "tell me a joke", "next utterance text")
  a = pause:event({ ev = "end", utt = 2 }, 13)
  t.eq(a[1][1], "send", "next utterance sends")
  t.eq(a[1].text, "tell me a joke", "next utterance sends text")

  local timeout = V.turns({ phrase = "okay Buddy", timeout = 6 })
  timeout:event({ ev = "end", utt = 1, text = "Okay Buddy" }, 20)
  t.eq(#timeout:tick(25.9), 0, "waits through timeout")
  a = timeout:tick(26.1)
  t.eq(a[1][1], "nothing", "no next start times out")
  t.eq(#timeout:tick(27), 0, "timeout fires once")

  local middle = V.turns({ phrase = "okay Buddy" })
  t.eq(#middle:event({ ev = "words", utt = 1, text = "thank you buddy" }, 0),
    0, "mid-sentence has no actions")
  local barge = V.turns({ phrase = "okay Buddy" })
  barge:event({ ev = "speaking", id = 1 }, 0)
  t.eq(barge.speaking, true, "speaking state on")
  a = barge:event({ ev = "words", utt = 1, text = "Okay Buddy" }, 1)
  t.eq(a[1][1], "stop", "barge stops audio first")
  t.eq(a[2][1], "wake", "barge still wakes")
  barge:event({ ev = "spoken", id = 1 }, 1.1)
  t.eq(barge.speaking, false, "spoken state off")
  local busy = V.turns({ phrase = "okay Buddy" })
  busy:event({ ev = "busy", on = true }, 0)
  t.eq(#busy:event({ ev = "words", utt = 1, text = "Okay Buddy" }, 1),
    0, "busy ignores wake")

  t.eq(V.decide("answer", { answers = true, muted = false }), true, "answer aloud")
  t.eq(V.decide("answer", { answers = false, muted = false }), false, "answers off")
  t.eq(V.decide("answer", { answers = true, muted = true, voiceTurn = false }), false, "mute typed answer")
  t.eq(V.decide("answer", { answers = true, muted = true, voiceTurn = true }), true, "voice turn overrides mute")
  t.eq(V.decide("answer", { answers = true, voiceTurn = true, busy = true }), false, "busy mutes answer")
  t.eq(V.decide("line", { outLoud = 0, roll = 0 }), false, "zero percent lines")
  t.eq(V.decide("line", { outLoud = 40, roll = 0.39 }), true, "line inside percentage")
  t.eq(V.decide("line", { outLoud = 40, roll = 0.4 }), false, "line at percentage edge")
  t.eq(V.decide("line", { outLoud = 100, roll = 0.5, muted = true }), false, "mute lines")
  t.eq(V.decide("line", { outLoud = 100, roll = 0.5, busy = true }), false, "busy mutes lines")

  local initial = V.settings()
  t.eq(initial.listen, false, "listening defaults off")
  t.eq(initial.answers, false, "answers default off")
  t.eq(initial.outLoud, 0, "lines default off")
  t.eq(initial.voice.engine, "system", "system voice default")
  t.eq(initial.phrase, "okay Buddy", "wake phrase default")
  V.configure({ voice = { phrase = "hello Buddy" } })
  t.eq(V.settings().phrase, "hello Buddy", "config phrase default")
  V.set("listen", true)
  t.eq(V.settings().answers, true, "first listen enables answers")
  V.set("phrase", "okay Buddy")
  t.eq(V.settings().phrase, "okay Buddy", "saved phrase overrides config")
  t.eq(V.command("talk out loud 140 percent"), "Talk out loud: 100%.", "command clamps high")
  t.eq(V.settings().outLoud, 100, "command saves percentage")
  t.eq(V.command("talk out loud 40%"), "Talk out loud: 40%.", "percent sign command")
  t.eq(V.command("out loud 40"), "Talk out loud: 40%.", "short command")
  t.eq(V.command("other words"), nil, "unrelated text is no command")
  t.eq(V.command("Talk out loud, 60%."), "Talk out loud: 60%.", "dictated punctuation")
  t.eq(V.command("set talk out loud to 20 percent"), "Talk out loud: 20%.", "set ... to")
  t.eq(V.command("can you talk out loud 5 times"), nil, "not a setting")
  local again = V.turns({ phrase = "okay Buddy", timeout = 6 })
  again:event({ ev = "start", utt = 1 }, 0)
  again:event({ ev = "end", utt = 1, text = "Okay Buddy" }, 1)
  again:event({ ev = "start", utt = 2 }, 2)
  local sent = again:event({ ev = "end", utt = 2, text = "Okay Buddy, tell me a joke" }, 3)
  t.eq(sent[#sent] and sent[#sent].text, "tell me a joke", "the phrase said twice counts once")

  hs.settings.set(key, saved)

  -- Exercise the live path with a short-lived script instead of opening the microphone.
  local root = t.tmpdir()
  local log = root .. "/ear.log"
  local made = {}
  local trouble, started, ended, skipped = {}, nil, nil, 0
  local held = {}
  local broken = false
  local serial = 0
  local speech = {
    speakable = function(text) return text end,
    render = function(_, _, done)
      if broken then return done(nil, "renderer failed") end
      serial = serial + 1
      local path = root .. "/spoken-" .. serial .. ".aiff"
      local file = assert(io.open(path, "w"))
      file:write("fake audio")
      file:close()
      made[#made + 1] = path
      done(path)
    end,
  }
  -- a copy in this run's own folder, so a helper left over from another run can't be counted
  local fake = root .. "/fake-ear"
  os.execute("/bin/cp '" .. dir .. "/tests/fakes/fake-ear' '" .. fake .. "' && /bin/chmod 755 '" .. fake .. "'")
  local opts = { dir = dir, bin = fake, speech = speech,
    env = { FAKE_EAR_LOG = log },
    muted = function() return false end,
    onTrouble = function(message) trouble[#trouble + 1] = message end }
  local function countFake()
    local output = hs.execute("/usr/bin/pgrep -f '" .. fake:gsub("fake%-ear$", "[f]ake-ear") .. "' 2>/dev/null") or ""
    local n = 0
    for _ in output:gmatch("%d+") do n = n + 1 end
    return n
  end
  local function countCommands(name)
    local file = io.open(log)
    if not file then return 0 end
    local count = 0
    for line in file:lines() do
      local ok, item = pcall(hs.json.decode, line)
      if ok and item and item.cmd == name then count = count + 1 end
    end
    file:close()
    return count
  end
  local function fileExists(path)
    local file = io.open(path, "r")
    if file then file:close(); return true end
    return false
  end
  local finished, stage, since = false, "ready", hs.timer.secondsSinceEpoch()
  local suiteStarted = since
  local function cleanup()
    V.stop()
    hs.settings.set(key, saved)
    for _, path in ipairs(made) do os.remove(path) end
    os.remove(log)
  end
  local ok, err = pcall(function()
    hs.settings.set(key, { listen = false, answers = true, outLoud = 0,
      voice = { engine = "system" } })
    V.start(opts)
  end)
  if not ok then
    cleanup()
    t.ok(false, "fake helper setup: " .. tostring(err))
    return
  end
  local function advance(nextStage)
    stage, since = nextStage, hs.timer.secondsSinceEpoch()
  end
  return function()
    if finished then return true end
    local safe, why = pcall(function()
      local elapsed = hs.timer.secondsSinceEpoch() - since
      if hs.timer.secondsSinceEpoch() - suiteStarted > 8 then error("fake helper suite timed out") end
      if elapsed > 2.5 then error("fake helper stage timed out: " .. stage) end
      if stage == "ready" and V.ready then
        V.speak("Hello there.", "answer", {
          onStart = function(secs) started = secs end,
          onEnd = function(cut) ended = cut end,
          onSkip = function() skipped = skipped + 1 end,
        })
        advance("spoken")
      elseif stage == "spoken" and ended ~= nil then
        t.eq(started, 0.2, "fake helper starts speech with duration")
        t.eq(ended, false, "answer finishes without a cut")
        t.eq(fileExists(made[1]), false, "played speech file is deleted")
        local before = countCommands("speak")
        V.speak("Quiet line.", "line", { onSkip = function() skipped = skipped + 1 end })
        t.eq(skipped, 1, "zero outLoud skips a line")
        t.eq(countCommands("speak"), before, "skipped line sends no speak command")
        V.speak("Second answer.", "answer", {
          onStart = function()
            V.hold(function() held[#held + 1] = "first" end)
            V.hold(function() held[#held + 1] = "second" end)
          end,
          onEnd = function() ended = "held" end,
        })
        advance("held")
      elseif stage == "held" and ended == "held" then
        t.eq(#held, 1, "only one held function runs")
        t.eq(held[1], "second", "newest held function runs")
        broken = true
        V.set("voice", { engine = "broken", name = "missing" })
        V.speak("Broken one.", "answer", { onSkip = function() skipped = skipped + 1 end })
        V.speak("Broken two.", "answer", { onSkip = function() skipped = skipped + 1 end })
        t.eq(skipped, 3, "both failed renders skip")
        t.eq(#trouble, 1, "renderer trouble is reported once")
        t.ok(trouble[1] and trouble[1]:find("My voice isn't working:", 1, true),
          "renderer trouble uses the voice message")
        V.start(opts)
        advance("restarted")
      elseif stage == "restarted" and V.ready and elapsed > 0.4 then
        t.eq(countFake(), 1, "starting twice leaves one fake helper")
        V.stop()
        advance("stopped")
      elseif stage == "stopped" and elapsed > 0.7 then
        t.eq(countFake(), 0, "stop leaves no fake helper")
        cleanup()
        finished = true
      end
    end)
    if not safe then
      t.ok(false, "fake helper: " .. tostring(why))
      cleanup()
      finished = true
    end
    return finished
  end
end
