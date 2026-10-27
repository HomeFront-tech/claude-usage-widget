-- Wake words, turn boundaries and speaking choices for the voice helper.
local V = {}

-- where the switches are saved; a spec points its own copy of this module elsewhere
V.settingsKey = "claudeBuddy.voice"
local defaults = { listen = false, answers = false, outLoud = 0, live = true,
  voice = { engine = "system", name = nil }, phrase = "okay Buddy" }
local config = {}

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

local function normalized(s)
  s = (s or ""):lower()
  s = s:gsub("[^%w%s']", " "):gsub("%s+", " ")
  s = trim(s)
  s = s:gsub("^ok(%s)", "okay%1")
  if s == "ok" then s = "okay" end
  return s
end

function V.matchWake(text, phrase)
  local heard, wake = normalized(text), normalized(phrase or defaults.phrase)
  if wake == "" or heard:sub(1, #wake) ~= wake then return nil end
  if #heard > #wake and heard:sub(#wake + 1, #wake + 1) ~= " " then return nil end
  return trim(heard:sub(#wake + 1))
end

-- Live voice chat: "okay Buddy" opens it, and it stays open until you say you're done.
local ENDERS = {}
for _, p in ipairs({ "we're done", "we are done", "were done", "we're done here", "we're all done",
    "i'm done", "i am done", "i'm done talking", "we're finished", "i'm finished", "stop listening",
    "stop listening to me", "stop listening now", "that's all", "that is all", "that'll be all",
    "that's it", "goodbye", "good bye", "bye", "bye bye", "end voice chat", "end the voice chat",
    "stop the voice chat", "end live mode", "stop live mode", "end the conversation" }) do
  ENDERS[p] = true
end
local FILLER = {}
for _, w in ipairs({ "okay", "alright", "well", "so", "yeah", "buddy", "thanks", "thank", "you", "please",
    "hey", "right", "ok" }) do FILLER[w] = true end
local NOISE = { um = true, uh = true, hmm = true, mm = true, mhm = true, ah = true, oh = true, eh = true,
  huh = true, er = true }

-- Words that end the live chat: the whole sentence, give or take "okay" and "thanks buddy".
function V.isEnd(text)
  local words = {}
  for w in normalized((text or ""):gsub("\226\128\153", "'")):gmatch("%S+") do words[#words + 1] = w end
  while words[1] and FILLER[words[1]] do table.remove(words, 1) end
  while words[#words] and FILLER[words[#words]] do table.remove(words) end
  return ENDERS[table.concat(words, " ")] == true
end

-- Nothing to act on: silence, a cough that came out as "uh", a lone letter.
function V.isNoise(text)
  local s = normalized(text)
  return s == "" or NOISE[s] == true or #s < 2
end

-- Is this only Buddy's own voice coming back in? (Everything heard is inside what he's saying.)
function V.isEcho(text, saying)
  local heard, said = normalized(text), normalized(saying)
  if heard == "" or said == "" then return false end
  return (" " .. said .. " "):find(" " .. heard .. " ", 1, true) ~= nil
end

function V.turns(opts)
  opts = opts or {}
  local phrase, timeout = opts.phrase or defaults.phrase, opts.timeout or 6
  local turn = { speaking = false, busy = false, live = false, liveOn = opts.live and true or false,
    saying = nil, spokeAt = -99, busyOffAt = nil, lastHeard = 0 }
  local liveTimeout = tonumber(opts.liveTimeout) or 0
  local startAt, parts = {}, {} -- per utterance: when it began; what we know about it
  local phase = "idle"
  local wakeUtt, nextUtt, rest, deadline

  local function action(kind, value)
    if kind == "wake" then return { "wake", rest = value } end
    if kind == "words" or kind == "send" then return { kind, text = value } end
    return { kind }
  end

  local function reset()
    phase, wakeUtt, nextUtt, rest, deadline = "idle", nil, nil, nil, nil
  end

  function turn:event(ev, t)
    local actions = {}
    if ev.ev == "speaking" then self.speaking = true; return actions end
    if ev.ev == "spoken" then self.speaking, self.spokeAt, self.lastHeard = false, t, t; return actions end
    if ev.ev == "busy" then
      self.busy = ev.on and true or false
      if not self.busy then self.busyOffAt = t end
      if self.live then actions[1] = { "hold", on = self.busy } end -- another app has the mic
      return actions
    end
    if ev.ev == "start" then startAt[ev.utt] = t end
    if self.live and (ev.ev == "words" or ev.ev == "end") then return self:liveEvent(ev, t, actions) end
    if ev.ev == "start" then
      if phase == "waiting" then
        phase, nextUtt, deadline = "capture", ev.utt, nil
      end
      return actions
    end
    if ev.ev ~= "words" and ev.ev ~= "end" then return actions end
    local heard = trim(ev.text)
    if phase == "idle" and not self.busy then
      local matched = V.matchWake(heard, phrase)
      if matched ~= nil then
        if self.speaking then actions[#actions + 1] = action("stop") end
        actions[#actions + 1] = action("wake", matched)
        if self.liveOn then -- a live chat: no more wake words until you end it
          self.live, self.firstUtt, self.lastHeard = true, ev.utt, t
          actions[#actions + 1] = action("liveStart")
          return self:liveEvent(ev, t, actions)
        end
        phase, wakeUtt, rest = "wake", ev.utt, matched
      end
    elseif phase == "wake" and ev.utt == wakeUtt then
      local matched = V.matchWake(heard, phrase)
      if matched ~= nil then
        rest = matched
        if ev.ev == "words" then actions[#actions + 1] = action("words", rest) end
      end
    elseif phase == "capture" and ev.utt == nextUtt then
      if heard ~= "" then
        rest = V.matchWake(heard, phrase) or heard -- "okay Buddy" said again counts once
        if ev.ev == "words" then actions[#actions + 1] = action("words", rest) end
      end
    end
    if ev.ev == "end" then
      if phase == "wake" and ev.utt == wakeUtt then
        if rest and rest ~= "" then
          actions[#actions + 1] = action("send", rest)
          reset()
        else
          phase, deadline = "waiting", t + timeout
        end
      elseif phase == "capture" and ev.utt == nextUtt then
        if rest and rest ~= "" then actions[#actions + 1] = action("send", rest)
        else actions[#actions + 1] = action("nothing") end
        reset()
      end
    end
    return actions
  end


  -- While live, every utterance is for Buddy (unless another app has the mic): words go to
  -- the panel as you talk, a pause sends them, talking over him cuts him off, and an ending
  -- phrase closes the chat. His own voice coming back in is dropped.
  function turn:liveEvent(ev, t, actions)
    local utt = ev.utt
    if self.busy then return actions end
    if ev.ev == "end" and self.busyOffAt and startAt[utt] and self.busyOffAt >= startAt[utt] - 0.5 then
      startAt[utt], parts[utt] = nil, nil
      actions[#actions + 1] = action("drop") -- the mic was another app's while you spoke
      return actions
    end
    local heard = trim(ev.text)
    local said = V.matchWake(heard, phrase) or heard
    local u = parts[utt] or {}
    parts[utt] = u
    if V.isNoise(said) then
      if ev.ev == "end" then
        parts[utt], startAt[utt] = nil, nil
        if utt == self.firstUtt then self.firstUtt = nil; actions[#actions + 1] = action("ready") end
      end
      return actions
    end
    local talking = self.speaking or t - self.spokeAt < 1.5
    if talking and not u.real and V.isEcho(said, self.saying) then
      if ev.ev == "end" then parts[utt], startAt[utt] = nil, nil end
      return actions
    end
    u.real, self.lastHeard = true, t
    if self.speaking and not u.cut then
      u.cut = true
      actions[#actions + 1] = action("interrupt")
    end
    if ev.ev == "words" then
      actions[#actions + 1] = action("words", said)
    else
      parts[utt], startAt[utt] = nil, nil
      if utt == self.firstUtt then self.firstUtt = nil end
      actions[#actions + 1] = V.isEnd(said) and { "liveEnd", why = "voice" } or action("send", said)
    end
    return actions
  end

  function turn:endLive()
    self.live, self.firstUtt = false, nil
    startAt, parts = {}, {}
  end

  function turn:tick(t)
    if self.live and liveTimeout > 0 and not self.speaking and not self.busy
        and t - self.lastHeard >= liveTimeout then
      self.lastHeard = t
      return { { "liveEnd", why = "quiet" } }
    end
    if phase == "waiting" and t >= deadline then
      reset()
      return { action("nothing") }
    end
    return {}
  end

  return turn
end

function V.decide(kind, s)
  s = s or {}
  if s.busy then return false end
  if kind == "answer" then -- in a live chat he always answers out loud
    return ((s.answers or s.live) and (not s.muted or s.voiceTurn or s.live)) and true or false
  end
  if kind == "line" then
    return (not s.muted and (s.roll or 0) < (tonumber(s.outLoud) or 0) / 100) and true or false
  end
  return false
end

-- config.lua's voice table (gap, timeout, phrase): the defaults under the saved settings.
function V.configure(cfg)
  local v = type(cfg) == "table" and cfg.voice
  config = type(v) == "table" and v or {} -- "voice = true" in config.lua is no table: defaults
  return V
end

function V.settings()
  local saved = hs.settings.get(V.settingsKey) or {}
  local result = {}
  for key, value in pairs(defaults) do result[key] = value end
  for key, value in pairs(config) do
    if result[key] ~= nil then result[key] = value end
  end
  for key, value in pairs(saved) do result[key] = value end
  local voice = {}
  for key, value in pairs(defaults.voice) do voice[key] = value end
  if type(saved.voice) == "table" then
    for key, value in pairs(saved.voice) do voice[key] = value end
  end
  result.voice = voice
  return result
end

function V.set(key, value)
  local saved = hs.settings.get(V.settingsKey) or {}
  local wasListening = saved.listen == true
  saved[key] = value
  if key == "listen" and value == true and not wasListening and saved.answers == nil then
    saved.answers = true
  end
  hs.settings.set(V.settingsKey, saved)
  local settings = V.settings()
  if key == "live" and V.turn then
    V.turn.liveOn = value ~= false
    if value == false then V.endLive("off") end
  end
  if V.options and (key == "listen" or key == "answers" or key == "outLoud" or key == "phrase") then
    local needed = settings.listen or settings.answers or (tonumber(settings.outLoud) or 0) > 0
    if not needed then V.stop()
    elseif not V.active or key == "listen" or key == "phrase" then V.start(V.options)
    end
  end
  return settings
end

function V.command(text)
  -- dictation adds commas and full stops: "Talk out loud, 40%."
  local s = trim((text or ""):lower():gsub("[,%.!?]", " "):gsub("%s+", " "))
  local lead, n, tail = s:match("^(.-)out loud t?o? ?(%d+) ?(.-)$")
  if not n or not (lead == "" or lead == "talk " or lead == "set " or lead == "set talk ")
    or not (tail == "" or tail == "%" or tail == "percent") then return nil end
  n = math.max(0, math.min(100, tonumber(n)))
  V.set("outLoud", n)
  return string.format("Talk out loud: %d%%.", n)
end

-- where the helper's PID is kept between runs; specs pass their own (opts.pidKey) so a
-- spec never kills the running buddy's helper
V.pidKey = "claudeBuddy.voicePid"
local function now() return hs.timer.secondsSinceEpoch() end
local function needed(s)
  return s.listen or s.answers or (tonumber(s.outLoud) or 0) > 0
end
local function listening()
  if not V.settings().listen then return false end
  for _ in pairs(V.pauses or {}) do return false end
  return true
end
local function trouble(message)
  if V.options and V.options.onTrouble then V.options.onTrouble(message) end
end
-- This Mac can't run voice (old macOS, no Command Line Tools): switch it all back off, so
-- it isn't stuck on and saying why at every start. The voice and phrase stay.
local function unsupported(message)
  V.active = false
  if V.tickTimer then V.tickTimer:stop(); V.tickTimer = nil end
  local saved = hs.settings.get(V.settingsKey) or {}
  saved.listen, saved.answers, saved.outLoud = false, false, 0
  hs.settings.set(V.settingsKey, saved)
  trouble(message)
end
local function call(cb, name, ...)
  if cb and type(cb[name]) == "function" then cb[name](...) end
end
local function clearTimer(name)
  if V[name] then V[name]:stop(); V[name] = nil end
end
local function processComm(pid)
  return trim((hs.execute("/bin/ps -p " .. pid .. " -o comm= 2>/dev/null") or ""))
end
local function killSaved(pid)
  pid = tonumber(pid)
  if not pid or pid < 1 or pid % 1 ~= 0 then return end
  local comm = processComm(pid)
  local name = comm:match("([^/]+)$")
  if name == "buddy-ear" or name == "fake-ear" then
    hs.execute("/bin/kill -TERM " .. pid .. " 2>/dev/null")
    return pid
  end
end

local function command(cmd)
  if not V.task or not V.task:isRunning() then return end
  V.commands = V.commands or {}
  V.commands[#V.commands + 1] = hs.json.encode(cmd) .. "\n"
  if V.inputTimer then return end
  V.inputTimer = hs.timer.doAfter(0.01, function()
    V.inputTimer = nil
    local lines = table.concat(V.commands or {})
    V.commands = {}
    if lines ~= "" and V.task and V.task:isRunning() then V.task:setInput(lines) end
  end)
end

local function runActions(actions)
  for _, action in ipairs(actions) do
    local kind = action[1]
    if kind == "stop" then V.stopSpeech()
    elseif kind == "wake" then
      V.turnToken = (V.turnToken or 0) + 1
      V.voiceTurn = false
      if V.options.onWake then V.options.onWake(action.rest) end
    elseif kind == "words" then
      if V.options.onWords then V.options.onWords(action.text) end
    elseif kind == "send" then
      V.turnToken = (V.turnToken or 0) + 1
      V.voiceTurn = true
      if V.options.onSend then V.options.onSend(action.text) end
    elseif kind == "liveStart" then
      V.live = true
      call(V.options, "onLiveStart")
    elseif kind == "liveEnd" then V.endLive(action.why or "voice")
    elseif kind == "interrupt" then V.interrupt()
    elseif kind == "hold" then call(V.options, "onLiveHold", action.on)
    elseif kind == "drop" then call(V.options, "onLiveDrop")
    elseif kind == "ready" then call(V.options, "onLiveReady")
    elseif kind == "nothing" and V.options.onNothing then V.options.onNothing() end
  end
end

local function deliverPending()
  if not V.ready or not V.pending or not V.task or not V.task:isRunning() then return end
  local item = V.pending
  V.pending = nil
  V.speeches[item.id] = item
  V.currentId = item.id
  command({ cmd = "speak", id = item.id, file = item.file })
end

local function event(ev)
  if type(ev) ~= "table" or type(ev.ev) ~= "string" then return end
  if ev.ev == "ready" then
    V.ready = true
    command({ cmd = "listen", on = listening() })
    deliverPending()
  elseif ev.ev == "error" then
    local why = tostring(ev.why or "Voice helper error.")
    V.lastError = why
    if ev.fatal then V.fatal = why -- said once, when the helper exits
    elseif not V.reported[why] then -- the same error on every engine rebuild is said once
      V.reported[why] = true
      trouble(why)
    end
  end
  if V.turn then
    if ev.ev == "speaking" then V.turn.saying = V.speeches and V.speeches[ev.id] and V.speeches[ev.id].text end
    runActions(V.turn:event(ev, now()))
  end
  if ev.ev == "speaking" then
    local item = V.speeches and V.speeches[ev.id]
    if item then call(item.cb, "onStart", ev.secs) end
  elseif ev.ev == "spoken" then
    local item = V.speeches and V.speeches[ev.id]
    if item then
      V.speeches[ev.id] = nil
      if V.currentId == ev.id then V.currentId = nil end
      os.remove(item.file)
      call(item.cb, "onEnd", ev.cut and true or false)
      if item.kind == "answer" and item.turnToken == V.turnToken then V.voiceTurn = false end
    end
    local held = V.held
    V.held = nil
    if held then held() end
  end
end

local function firstLine(s)
  return trim((s or ""):match("([^\r\n]+)"))
end

local launch
launch = function(generation)
  if generation ~= V.generation or not needed(V.settings()) then return end
  if V.waitPid then
    if processComm(V.waitPid) ~= "" then
      V.waitChecks = (V.waitChecks or 0) + 1
      if V.waitChecks > 40 then
        V.active = false
        clearTimer("tickTimer")
        trouble("Voice helper from the last run is still stopping.")
        return
      end
      V.waitTimer = hs.timer.doAfter(0.05, function()
        V.waitTimer = nil
        launch(generation)
      end)
      return
    end
    V.waitPid, V.waitChecks = nil, nil
  end
  local opts = V.options
  local args = {}
  if not listening() then args[#args + 1] = "--no-listen" end
  local cfg = config
  if cfg.gap then
    args[#args + 1] = "--gap"
    args[#args + 1] = tostring(cfg.gap)
  end
  V.ready, V.commands, V.stdoutBuffer = false, {}, ""
  V.reported, V.fatal, V.voiceFailed = {}, nil, nil -- a new run reports its own trouble
  V.turn = V.turns({ phrase = V.settings().phrase, timeout = cfg.timeout or 6,
    live = V.settings().live ~= false, liveTimeout = cfg.liveTimeout })
  local task, exited
  -- complete JSON lines from the helper; the rest waits for more
  local function consume(out, err)
    if err and err ~= "" then V.lastError = firstLine(err) end
    V.stdoutBuffer = (V.stdoutBuffer or "") .. (out or "")
    while true do
      local at = V.stdoutBuffer:find("\n", 1, true)
      if not at then break end
      local line = V.stdoutBuffer:sub(1, at - 1)
      V.stdoutBuffer = V.stdoutBuffer:sub(at + 1)
      local ok, decoded = pcall(hs.json.decode, line)
      if ok then event(decoded) end
    end
  end
  task = hs.task.new(opts.bin or (opts.dir .. "/ear/buddy-ear"), function(code, out, err)
    if V.task ~= task or generation ~= V.generation then
      if tonumber(hs.settings.get(V.pidKey)) == task:pid() then hs.settings.set(V.pidKey, nil) end
      return
    end
    consume(out) -- its last lines (a fatal error) can arrive with the exit
    -- or just after it: hs.task may report the exit before the last streamed lines, so
    -- decide what to do a moment later, once they're in
    clearTimer("exitTimer")
    V.exitTimer = hs.timer.doAfter(0.25, function()
      V.exitTimer = nil
      if V.task ~= task or generation ~= V.generation then return end
      exited(code, err)
    end)
  end, function(_, out, err)
    if V.task ~= task or generation ~= V.generation then return true end
    consume(out, err)
    return true
  end, args)
  -- after the exit callback above: what a helper's exit means
  function exited(code, err)
    V.task, V.ready = nil, false
    if V.turn then V.turn.speaking = false end -- it isn't talking any more
    if tonumber(hs.settings.get(V.pidKey)) == task:pid() then hs.settings.set(V.pidKey, nil) end
    for id, item in pairs(V.speeches or {}) do
      os.remove(item.file)
      call(item.cb, "onEnd", true)
      V.speeches[id] = nil
    end
    V.currentId = nil
    V.endLive("trouble") -- the new helper starts out waiting for the wake word
    if not V.active or not needed(V.settings()) then return end
    local t = now()
    local exits = V.exits or {}
    exits[#exits + 1] = t
    while exits[1] and t - exits[1] > 300 do table.remove(exits, 1) end
    V.exits = exits
    -- a fatal error (no dictation, no assets offline) or a third exit in 5 minutes: stop
    -- trying until the next start, and say why once
    if V.fatal or #exits >= 3 then
      V.active = false
      clearTimer("tickTimer")
      trouble(V.fatal or ("Voice helper keeps stopping: " .. (V.lastError
        or firstLine((err and err ~= "") and err or ("exit " .. tostring(code))))))
      return
    end
    local delay = ({ 2, 10 })[#exits]
    V.restartTimer = hs.timer.doAfter(delay, function()
      V.restartTimer = nil
      launch(generation)
    end)
  end
  if task and opts.env then
    local env = task:environment()
    for key, value in pairs(opts.env) do env[key] = value end
    task:setEnvironment(env)
  end
  if not task or not task:start() then
    V.active = false
    clearTimer("tickTimer")
    trouble("Voice helper couldn't start.")
    return
  end
  V.task = task
  hs.settings.set(V.pidKey, task:pid())
end

function V.start(opts)
  opts = opts or V.options or {}
  assert(opts.dir, "voice.start needs dir")
  if V.task == nil then V.pidKey = opts.pidKey or "claudeBuddy.voicePid" end
  local oldPid = hs.settings.get(V.pidKey)
  local currentPid = V.task and V.task:pid()
  V.stop()
  local killedPid = killSaved(oldPid)
  hs.settings.set(V.pidKey, nil)
  V.waitPid = currentPid or killedPid
  V.waitChecks = nil
  V.options = opts
  if opts.cfg then V.configure(opts.cfg) end
  V.speech = opts.speech or dofile(opts.dir .. "/speech.lua")
  V.pauses = V.pauses or {}
  V.speeches = {}
  V.exits = {}
  V.voiceTurn = false
  if not needed(V.settings()) then return V end
  V.active = true
  local generation = V.generation
  V.tickTimer = hs.timer.doEvery(0.5, function()
    if V.turn then runActions(V.turn:tick(now())) end
  end)
  if opts.bin then launch(generation); return V end
  if (hs.host.operatingSystemVersion().major or 0) < 26 then
    V.active = false
    clearTimer("tickTimer")
    unsupported("Voice needs macOS 26 or later.")
    return V
  end
  local build
  build = hs.task.new(opts.dir .. "/ear/build.sh", function(code, out, err)
    if V.buildTask ~= build or generation ~= V.generation then return end
    V.buildTask = nil
    if code == 0 then launch(generation)
    else
      V.active = false
      clearTimer("tickTimer")
      if code == 3 then unsupported("Voice needs Apple's Command Line Tools: xcode-select --install")
      else trouble(firstLine((err and err ~= "") and err or out)) end
    end
  end, { "--if-stale" })
  if not build or not build:start() then
    V.active = false
    clearTimer("tickTimer")
    trouble("Voice helper build couldn't start.")
  else V.buildTask = build end
  return V
end

function V.stop()
  V.generation = (V.generation or 0) + 1
  V.renderSerial = (V.renderSerial or 0) + 1
  V.active, V.ready = false, false
  clearTimer("tickTimer")
  clearTimer("restartTimer")
  clearTimer("inputTimer")
  clearTimer("waitTimer")
  clearTimer("exitTimer")
  V.waitPid, V.waitChecks = nil, nil
  V.commands = {}
  if V.buildTask and V.buildTask:isRunning() then V.buildTask:terminate() end
  V.buildTask = nil
  local task = V.task
  V.task = nil
  if task and task:isRunning() then
    local pid = task:pid()
    task:setInput(hs.json.encode({ cmd = "quit" }) .. "\n")
    task:closeInput()
    V.stopping = V.stopping or {}
    V.stopping[task] = hs.timer.doAfter(0.5, function()
      V.stopping[task] = nil
      if task:isRunning() then task:terminate() end
      if not task:isRunning() and tonumber(hs.settings.get(V.pidKey)) == pid then
        hs.settings.set(V.pidKey, nil)
      end
    end)
  elseif task and tonumber(hs.settings.get(V.pidKey)) == task:pid() then
    hs.settings.set(V.pidKey, nil)
  end
  for id, item in pairs(V.speeches or {}) do
    os.remove(item.file)
    call(item.cb, "onEnd", true)
    V.speeches[id] = nil
  end
  if V.pending then os.remove(V.pending.file); call(V.pending.cb, "onSkip") end
  V.pending, V.currentId, V.held, V.turn = nil, nil, nil, nil
  V.voiceTurn = false
  V.endLive("stopped")
  return V
end

-- The live chat is over: you said so, you walked away, or the helper had trouble. He says
-- goodbye out loud even when spoken answers are off (V.goodbye lets that one line through).
function V.endLive(why)
  if not V.live then return end
  V.live = false
  if V.turn then V.turn:endLive() end
  V.goodbye = true
  call(V.options, "onLiveEnd", why)
  V.goodbye = nil
end

-- Talking over him: cut the audio, and drop an answer that's still being made.
function V.interrupt()
  V.stopSpeech()
  V.renderSerial = (V.renderSerial or 0) + 1
  V.renderKind, V.held = nil, nil
  if V.pending then os.remove(V.pending.file); call(V.pending.cb, "onSkip"); V.pending = nil end
end

function V.pause(reason)
  if reason ~= "dictate" then V.endLive("away") end -- screen off or locked: nobody to talk to
  V.pauses = V.pauses or {}
  V.pauses[reason] = true
  if V.ready then command({ cmd = "listen", on = false }) end
end

function V.resume(reason)
  if V.pauses then V.pauses[reason] = nil end
  if V.ready then command({ cmd = "listen", on = listening() }) end
end

function V.speaking()
  return V.turn and V.turn.speaking or false
end

function V.hold(fn)
  V.held = fn
end

function V.stopSpeech()
  if V.currentId and V.task and V.task:isRunning() then command({ cmd = "stop" }) end
end

function V.speak(text, kind, cb)
  cb = cb or {}
  local s = V.settings()
  local muted = V.options and V.options.muted
  if not V.decide(kind, { answers = s.answers, outLoud = s.outLoud,
      muted = type(muted) == "function" and muted() or false,
      busy = V.turn and V.turn.busy, voiceTurn = V.voiceTurn, roll = math.random(),
      live = V.live or V.goodbye }) then
    call(cb, "onSkip")
    return
  end
  local speech = V.speech
  local spoken = speech and speech.speakable(text)
  if not spoken or not V.active then call(cb, "onSkip"); return end
  -- one of his own lines never pushes aside an answer that's still being made
  if kind == "line" and V.renderKind == "answer" then call(cb, "onSkip"); return end
  if kind == "answer" then V.stopSpeech() end
  V.renderKind = kind
  V.renderSerial = (V.renderSerial or 0) + 1
  local serial = V.renderSerial
  local function rendered(path, why)
    if serial == V.renderSerial then V.renderKind = nil end
    if serial ~= V.renderSerial or not V.active then
      if path then os.remove(path) end
      call(cb, "onSkip")
      return
    end
    if path then
      if V.pending then os.remove(V.pending.file); call(V.pending.cb, "onSkip") end
      V.nextId = (V.nextId or 0) + 1
      V.pending = { id = V.nextId, file = path, kind = kind, cb = cb,
        turnToken = V.turnToken, text = spoken }
      deliverPending()
      return
    end
    local choice = s.voice or {}
    if choice.engine ~= "system" or choice.name then
      return speech.render(spoken, { engine = "system" }, function(fallback, finalWhy)
        if serial ~= V.renderSerial or not V.active then
          if fallback then os.remove(fallback) end
          call(cb, "onSkip")
          return
        end
        if fallback then return rendered(fallback) end
        if not V.voiceFailed then
          V.voiceFailed = true
          trouble("My voice isn't working: " .. tostring(finalWhy or why or "unknown error"))
        end
        call(cb, "onSkip")
      end)
    end
    if not V.voiceFailed then
      V.voiceFailed = true
      trouble("My voice isn't working: " .. tostring(why or "unknown error"))
    end
    call(cb, "onSkip")
  end
  speech.render(spoken, s.voice, rendered)
end

return V
