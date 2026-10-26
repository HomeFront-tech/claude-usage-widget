-- Wake words, turn boundaries and speaking choices for the voice helper.
local V = {}

local KEY = "claudeBuddy.voice"
local defaults = { listen = false, answers = false, outLoud = 0,
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

function V.turns(opts)
  opts = opts or {}
  local phrase, timeout = opts.phrase or defaults.phrase, opts.timeout or 6
  local turn = { speaking = false, busy = false }
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
    if ev.ev == "spoken" then self.speaking = false; return actions end
    if ev.ev == "busy" then self.busy = ev.on and true or false; return actions end
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

  function turn:tick(t)
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
  if kind == "answer" then
    return (s.answers and (not s.muted or s.voiceTurn)) and true or false
  end
  if kind == "line" then
    return (not s.muted and (s.roll or 0) < (tonumber(s.outLoud) or 0) / 100) and true or false
  end
  return false
end

-- Task 5 connects these settings to the helper lifecycle.
function V.configure(cfg)
  config = cfg and (cfg.voice or cfg) or {}
  return V
end

function V.settings()
  local saved = hs.settings.get(KEY) or {}
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
  local saved = hs.settings.get(KEY) or {}
  local wasListening = saved.listen == true
  saved[key] = value
  if key == "listen" and value == true and not wasListening and saved.answers == nil then
    saved.answers = true
  end
  hs.settings.set(KEY, saved)
  return V.settings()
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

return V
