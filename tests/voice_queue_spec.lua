-- One line for everything he says out loud (voice.lua's V.waiting): nothing cuts off what
-- he's saying, only one message is made at a time, and a stop empties the line. Uses the
-- fake helper (tests/fakes/fake-ear: every speech plays for 0.2 s), never the microphone.
return function(t, dir)
  local key = "claudeBuddy.voice.spec-" .. hs.host.uuid() -- never the running buddy's switches
  local pidKey = "claudeBuddy.voicePid.spec-queue"
  local V = dofile(dir .. "/voice.lua")
  V.settingsKey = key
  local root = t.tmpdir()
  local made, renders, log = {}, {}, {}
  local holdText, deferred, mutedNow = nil, nil, false
  local speech = {
    speakable = function(text) if text:find("secret", 1, true) then return nil end return text end,
    cancel = function() end,
    render = function(text, _, done)
      renders[#renders + 1] = text
      if text == holdText then deferred = done; return { text = text } end
      local path = root .. "/q-" .. hs.host.uuid() .. ".aiff"
      local file = assert(io.open(path, "w")); file:write("fake audio"); file:close()
      made[#made + 1] = path
      done(path)
    end,
  }
  local function audio()
    local path = root .. "/held-" .. hs.host.uuid() .. ".aiff"
    local file = assert(io.open(path, "w")); file:write("fake audio"); file:close()
    made[#made + 1] = path
    return path
  end
  local function finishHeld(path)
    local finish = deferred
    deferred, holdText = nil, nil
    if finish then finish(path) end
  end
  local function cb(name, extra)
    return {
      onTurn = function() log[#log + 1] = "turn " .. name end,
      onStart = function(secs)
        log[#log + 1] = "start " .. name
        if extra then extra(secs) end
      end,
      onEnd = function(cut) log[#log + 1] = "end " .. name .. (cut and " cut" or "") end,
      onSkip = function(dropped) log[#log + 1] = (dropped and "drop " or "skip ") .. name end,
    }
  end
  local function has(entry)
    for _, e in ipairs(log) do if e == entry then return true end end
    return false
  end
  local function count(entry)
    local n = 0
    for _, e in ipairs(log) do if e == entry then n = n + 1 end end
    return n
  end
  local function played() -- the log without the drops
    local out = {}
    for _, e in ipairs(log) do if not e:match("^drop ") then out[#out + 1] = e end end
    return table.concat(out, ", ")
  end

  local fake = root .. "/fake-ear"
  os.execute("/bin/cp '" .. dir .. "/tests/fakes/fake-ear' '" .. fake .. "' && /bin/chmod 755 '" .. fake .. "'")
  local opts = { dir = dir, bin = fake, speech = speech, pidKey = pidKey,
    muted = function() return mutedNow end, onTrouble = function() end }
  local function cleanup()
    V.stop()
    hs.settings.set(pidKey, nil)
    hs.settings.set(key, nil)
    for _, path in ipairs(made) do os.remove(path) end
  end
  local ok, err = pcall(function()
    hs.settings.set(key, { listen = false, answers = true, outLoud = 100, bubbles = true,
      voice = { engine = "system" } })
    V.start(opts)
  end)
  if not ok then
    cleanup()
    t.ok(false, "speech queue setup: " .. tostring(err))
    return
  end

  local finished, stage, since = false, "ready", hs.timer.secondsSinceEpoch()
  local suiteStarted = since
  local function move(nextStage) -- same test, next step: keeps the log
    stage, since = nextStage, hs.timer.secondsSinceEpoch()
  end
  local function advance(nextStage) -- a new test: a fresh log
    move(nextStage)
    log, renders = {}, {}
  end
  return function()
    if finished then return true end
    local safe, why = pcall(function()
      local elapsed = hs.timer.secondsSinceEpoch() - since
      if hs.timer.secondsSinceEpoch() - suiteStarted > 9 then error("speech queue suite timed out at " .. stage) end
      if elapsed > 3 then error("speech queue stage timed out: " .. stage .. " (" .. played() .. ")") end
      if stage == "ready" and V.ready then
        holdText = "First."
        V.speak("First.", "answer", cb("first"))
        V.speak("Second.", "answer", cb("second"))
        V.speak("Third.", "line", cb("third"))
        V.speak("Second.", "answer", cb("second again"))
        V.speak("Reply.", "answer", cb("reply"), { first = true })
        V.speak("Idle one.", "line", cb("idle one"), { key = "chatter" })
        V.speak("Idle two.", "line", cb("idle two"), { key = "chatter" })
        V.speak("A secret thing.", "answer", cb("silent"))
        V.speak("First.", "answer", cb("first again"))
        t.eq(table.concat(renders, ", "), "First.", "only the first message is being made")
        t.ok(has("drop second again"), "the same words already waiting aren't said twice")
        t.ok(has("drop first again"), "nor the words he's saying")
        t.ok(has("drop idle one"), "only the newest chatter waits")
        t.eq(has("skip silent"), false, "a line that isn't said out loud waits its turn too")
        t.eq(#V.waiting, 5, "reply, second, third, idle two and the silent one wait")
        t.eq(V.waiting[1] and V.waiting[1].text, "Reply.", "an answer to what you asked goes first")
        t.eq(V.speaking(), true, "he counts as speaking while lines wait")
        local before = #log
        finishHeld(audio())
        t.eq(#log, before, "nothing else starts the moment the first is made")
        move("fifo")
      elseif stage == "fifo" and has("skip silent") then
        t.eq(played(), "turn first, start first, end first, turn reply, start reply, end reply, "
          .. "turn second, start second, end second, turn third, start third, end third, "
          .. "turn idle two, start idle two, end idle two, skip silent",
          "each message plays to its end before the next one starts")
        t.eq(table.concat(renders, ", "), "First., Reply., Second., Third., Idle two.",
          "and each is made only when its turn comes")
        t.eq(V.speaking(), false, "the line is empty afterwards")
        advance("stale")
        holdText = "Long one."
        V.speak("Long one.", "answer", cb("long"))
        V.speak("Old news.", "answer", cb("old"), { maxWait = 0.2 })
        V.speak("Still fresh.", "answer", cb("fresh"))
      elseif stage == "stale" and elapsed > 0.4 and deferred then
        finishHeld(audio())
        move("stale-done")
      elseif stage == "stale-done" and has("end fresh") then
        t.ok(has("drop old"), "a message whose moment passed while it waited is left out")
        t.eq(has("turn old"), false, "and never made")
        t.eq(played(), "turn long, start long, end long, turn fresh, start fresh, end fresh", "the rest still play in order")
        advance("cap")
        V.maxWaiting = 3
        holdText = "Busy."
        V.speak("Busy.", "answer", cb("busy"))
        V.speak("Chatter.", "line", cb("chatter"))
        V.speak("Answer one.", "answer", cb("a1"))
        V.speak("Answer two.", "answer", cb("a2"))
        V.speak("Answer three.", "answer", cb("a3"))
        t.ok(has("drop chatter"), "too many waiting: his own line goes first")
        V.speak("Answer four.", "answer", cb("a4"))
        t.ok(has("drop a1"), "then the oldest")
        t.eq(#V.waiting, 3, "the line keeps its limit")
        V.maxWaiting = 8
        V.interrupt() -- talking over him, the screen locking, the panel closing
        t.ok(has("drop a2") and has("drop a3") and has("drop a4"), "an interruption drops what waits")
        t.ok(has("end busy cut"), "and cuts the message being made")
        t.eq(#V.waiting, 0, "the line is empty")
        finishHeld(nil) -- the stopped render reports back with no audio
        t.eq(table.concat(renders, ", "), "Busy.", "nothing that waited was made")
        advance("mute")
        holdText = "Hold on."
        V.speak("Hold on.", "answer", cb("hold"))
        V.speak("My own line.", "line", cb("own"))
        V.speak("Typed answer.", "answer", cb("typed"))
        mutedNow = true -- quiet for an hour, while they wait
        finishHeld(audio())
        move("mute-done")
      elseif stage == "mute-done" and (has("skip typed") or has("drop typed")) then
        t.ok(has("drop own"), "muted while it waited: his own line goes")
        t.ok(has("skip typed"), "an answer shows, without a word")
        t.eq(table.concat(renders, ", "), "Hold on.", "neither is made")
        mutedNow = false
        advance("stuck")
        V.speak("Stuck one.", "answer", cb("stuck", function()
          -- the helper never says this one ended: past its length, it counts as over
          local item = V.currentId and V.speeches[V.currentId]
          if item then item.deadline = 0 end
          V.checkStuck()
        end))
        V.speak("Behind it.", "answer", cb("behind"))
      elseif stage == "stuck" and has("end behind") then
        t.eq(played(), "turn stuck, start stuck, end stuck, turn behind, start behind, end behind",
          "a speech the helper never ends doesn't stop the line")
        t.eq(count("end stuck"), 1, "and ends only once when the helper's own end comes late")
        t.eq(#V.waiting, 0, "nothing left waiting")
        -- a stop (a click) drops the line along with what he's saying
        advance("stop")
        holdText = "Stop me."
        V.speak("Stop me.", "answer", cb("stopme"))
        V.speak("Never said.", "answer", cb("never"))
        V.stopSpeech()
        t.ok(has("drop never"), "a stop drops what waits")
        t.ok(has("end stopme cut"), "and ends the message being made")
        finishHeld(nil)
        V.speak("After the stop.", "answer", cb("after"))
        move("stop-done")
      elseif stage == "stop-done" and has("end after") then
        t.eq(played(), "turn stopme, end stopme cut, turn after, start after, end after", "the next line after a stop plays")
        cleanup()
        finished = true
      end
    end)
    if not safe then
      t.ok(false, "speech queue: " .. tostring(why))
      cleanup()
      finished = true
    end
    return finished
  end
end
