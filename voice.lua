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
  s = (s or ""):lower():gsub("\226\128\153", "'") -- dictation writes we’re with a curly apostrophe
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

-- Brain dumps: one long spoken message, minutes of it with pauses to think, sent only when
-- you say you're finished. The phrase that starts one, said first ("okay Buddy, brain dump"):
-- STRIP phrases are only the switch, KEEP phrases are part of what you're saying.
local DUMP_STRIP, DUMP_KEEP, FINISH, STRONG = {}, {}, {}, {}
local function phraseList(into, list)
  for _, p in ipairs(list) do
    local w = {}
    for x in p:gmatch("%S+") do w[#w + 1] = x end
    into[#into + 1] = w
    into[p] = true
  end
  table.sort(into, function(a, b) return #a > #b end) -- the longest match wins
end
phraseList(DUMP_STRIP, { "brain dump", "braindump", "braindom", "brain dom", "brain dumb", "brain dump mode", "brain dump time", "brain dumping",
  "start a brain dump", "start brain dump", "start the brain dump", "do a brain dump", "let's do a brain dump",
  "lets do a brain dump", "let's brain dump", "lets brain dump", "let me brain dump", "let me do a brain dump",
  "i want to brain dump", "i want to do a brain dump", "i need to brain dump", "i need to do a brain dump",
  "time for a brain dump", "here's a brain dump", "brainstorm mode", "brainstorming mode", "long message",
  "i have a long message", "i've got a long message", "take a long message" })
phraseList(DUMP_KEEP, { "let's brainstorm", "lets brainstorm", "let me brainstorm", "let's do some brainstorming",
  "i want to brainstorm", "help me brainstorm", "let's have a brainstorm", "let's have a brainstorming session",
  "brainstorming session", "let me think out loud", "let me think this through out loud", "i'm going to think out loud",
  "im going to think out loud", "i want to think out loud", "i'm thinking out loud", "thinking out loud" })
-- What finishes and sends it, said on its own (give or take "okay", "Buddy", "thanks").
phraseList(FINISH, { "send", "send it", "send that", "send this", "send it now", "send it off", "send it over",
  "go ahead and send it", "you can send it", "done", "i'm done", "im done", "i am done", "all done", "i'm all done",
  "i'm finished", "im finished", "i am finished", "finished", "that's all", "that is all", "thats all",
  "that's everything", "that is everything", "thats everything", "over to you", "your turn", "what do you think",
  "what are your thoughts", "submit", "submit it" })
-- These finish it even at the end of a longer utterance; the ones above need "Buddy" there.
phraseList(STRONG, { "end brain dump", "end the brain dump", "end of brain dump", "end of the brain dump",
  "end of my brain dump", "brain dump over", "brain dump done", "brain dump finished", "stop brain dump",
  "stop the brain dump", "done brain dumping", "i'm done brain dumping", "send the brain dump", "send my brain dump" })
for _, w in ipairs(STRONG) do FINISH[#FINISH + 1] = w; FINISH[table.concat(w, " ")] = true end
table.sort(FINISH, function(a, b) return #a > #b end)

local function wordsOf(s)
  local list = {}
  for w in normalized((s or ""):gsub("\226\128\153", "'")):gmatch("%S+") do
    list[#list + 1] = w == "ok" and "okay" or w
  end
  return list
end
-- Does w hold the phrase p (a word list) starting at word i?
local function at(w, i, p)
  if i < 1 or i + #p - 1 > #w then return false end
  for k = 1, #p do if w[i + k - 1] ~= p[k] then return false end end
  return true
end
-- The raw text after its first n words, or up to and including its first n words, so what's
-- kept has its capitals and punctuation.
local function afterWords(raw, n)
  local count = 0
  if n <= 0 then return trim(raw) end
  for tok, e in raw:gmatch("(%S+)()") do
    count = count + #wordsOf(tok)
    if count >= n then return trim((raw:sub(e):gsub("^[%s,;:%.!%?%-]+", ""))) end
  end
  return ""
end
local function beforeWords(raw, n)
  local count = 0
  if n <= 0 then return "" end
  for tok, e in raw:gmatch("(%S+)()") do
    count = count + #wordsOf(tok)
    if count >= n then return trim((raw:sub(1, e - 1):gsub("[%s,;:%-]+$", ""))) end
  end
  return trim(raw)
end
-- Where what's said starts: after the wake phrase and words like "okay" and "so".
local function lead(w, phrase)
  local i, wake = 1, wordsOf(phrase or defaults.phrase)
  if #wake > 0 and at(w, 1, wake) then i = #wake + 1 end
  while w[i] and FILLER[w[i]] do i = i + 1 end
  return i
end
-- The pieces (strings, nils, or lists of strings) with single spaces between them.
local function join(...)
  local out = {}
  local function add(s)
    s = trim(s)
    if s ~= "" then out[#out + 1] = s end
  end
  for i = 1, select("#", ...) do
    local piece = select(i, ...)
    if type(piece) == "table" then for _, s in ipairs(piece) do add(s) end
    elseif piece then add(piece) end
  end
  return table.concat(out, " ")
end

-- The text after the wake phrase, as it was said, or nil when it doesn't start with it.
function V.afterWake(text, phrase)
  local wake = wordsOf(phrase or defaults.phrase)
  if #wake == 0 or not at(wordsOf(text), 1, wake) then return nil end
  return afterWords(trim(text), #wake)
end

-- Does this start a brain dump? The words after the phrase (or all of them, for a KEEP
-- phrase: "let's brainstorm names for the app"), or nil.
function V.dumpStart(text, phrase)
  local raw = trim(text)
  local w = wordsOf(raw)
  local i = lead(w, phrase)
  for _, p in ipairs(DUMP_STRIP) do
    if at(w, i, p) then return afterWords(raw, i + #p - 1) end
  end
  for _, p in ipairs(DUMP_KEEP) do
    if at(w, i, p) then return afterWords(raw, i - 1) end
  end
  return nil
end

-- Does this finish a brain dump? The words said before the finishing phrase ("" when it was
-- said on its own), or nil. At the end of a longer utterance it has to name Buddy ("...okay
-- Buddy, send it"), so "...and then I send it" never sends.
local ADDRESS = { okay = true, hey = true, alright = true, so = true }
local NOT_BUDDY = { my = true, a = true, the = true, your = true, his = true, her = true, our = true, their = true }
function V.dumpFinish(text, phrase)
  local raw = trim(text)
  local w = wordsOf(raw)
  local i, j = lead(w, phrase), #w
  if i > j then return nil end
  -- on its own: strip "thanks", "buddy" and so on from the end one at a time
  while j >= i do
    if FINISH[table.concat(w, " ", i, j)] then return "" end
    if not FILLER[w[j]] then break end
    j = j - 1
  end
  local function keep(n) -- the words before it, without "okay" in front of "Buddy"
    while n > 0 and ADDRESS[w[n]] do n = n - 1 end
    return n > 0 and beforeWords(raw, n) or ""
  end
  -- at the end: tried again after each "thanks" or "please" it ends with ("over to you" ends
  -- with one too, so it's tried before that's taken off)
  j = #w
  while j > 0 do
    for _, p in ipairs(FINISH) do
      local s = j - #p + 1
      if STRONG[table.concat(p, " ")] and at(w, s, p) then return keep(s - 1) end
      -- "...okay Buddy, send it"
      if at(w, s, p) and w[s - 1] == "buddy" and not NOT_BUDDY[w[s - 2] or ""] then return keep(s - 2) end
      -- "...send it, Buddy"
      if w[j] == "buddy" and at(w, j - #p, p) and not NOT_BUDDY[w[j - #p - 1] or ""] then
        return keep(j - #p - 1)
      end
    end
    if not FILLER[w[j]] or w[j] == "buddy" then break end
    j = j - 1
  end
  return nil
end

function V.turns(opts)
  opts = opts or {}
  local phrase, timeout = opts.phrase or defaults.phrase, opts.timeout or 6
  -- how long words cut at the helper's limit (a "split" end) wait for the rest
  local carryWait = tonumber(opts.carryWait) or 2
  local turn = { speaking = false, busy = false, live = false, liveOn = opts.live and true or false,
    saying = nil, spokeAt = -99, busyOffAt = nil, lastHeard = 0, lastUtt = 0 }
  local liveTimeout = tonumber(opts.liveTimeout) or 0
  -- a brain dump left alone this long is saved as a draft and the chat ends (0: never)
  local dumpTimeout = tonumber(opts.dumpTimeout) or 600
  local startAt, parts = {}, {} -- per utterance: when it began; what we know about it
  local phase = "idle"
  local wakeUtt, nextUtt, rest, deadline, carry -- carry: one-shot words cut at the helper's limit

  local function action(kind, value)
    if kind == "wake" then return { "wake", rest = value } end
    if kind == "words" or kind == "send" then return { kind, text = value } end
    return { kind }
  end

  local function reset()
    phase, wakeUtt, nextUtt, rest, deadline, carry = "idle", nil, nil, nil, nil, nil
  end

  -- A live chat starts here (the wake word with live on, or a brain dump with it off).
  local function goLive(self, ev, t, actions, forDump)
    reset()
    self.live, self.firstUtt, self.lastHeard = true, ev.utt, t
    self.dumpLive = forDump or nil -- live only for this dump: it closes once the dump is sent
    actions[#actions + 1] = action("liveStart")
    return self:liveEvent(ev, t, actions)
  end

  -- One-shot: an utterance cut at the helper's limit isn't over; its words wait for the next.
  local function holdSplit(self, ev, t, actions, nextStarted)
    carry = join(carry, rest)
    rest = nil
    if nextStarted then phase, nextUtt, deadline = "capture", ev.utt + 1, nil
    else phase, deadline = "waiting", t + carryWait end
    if carry ~= "" then actions[#actions + 1] = action("words", carry) end
    return actions
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
    if type(ev.utt) == "number" and ev.utt > self.lastUtt then self.lastUtt = ev.utt end
    -- an utterance that was open when a live chat ended, or when its dump was sent with
    -- Return, is over: what's still coming from it mustn't wake him again
    if self.taken and type(ev.utt) == "number" and ev.utt <= self.taken then
      if ev.ev == "end" then parts[ev.utt], startAt[ev.utt] = nil, nil end
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
          return goLive(self, ev, t, actions)
        elseif V.dumpStart(heard, phrase) then -- a brain dump opens one anyway
          return goLive(self, ev, t, actions, true)
        end
        phase, wakeUtt, rest = "wake", ev.utt, matched
      end
    elseif phase == "wake" and ev.utt == wakeUtt then
      if V.dumpStart(heard, phrase) then return goLive(self, ev, t, actions, true) end
      local matched = V.matchWake(heard, phrase)
      if matched ~= nil then
        rest = matched
        if ev.ev == "words" then actions[#actions + 1] = action("words", join(carry, rest)) end
      end
    elseif phase == "capture" and ev.utt == nextUtt then
      if not carry and V.dumpStart(heard, phrase) then return goLive(self, ev, t, actions, true) end
      if heard ~= "" then
        rest = V.matchWake(heard, phrase) or heard -- "okay Buddy" said again counts once
        if ev.ev == "words" then actions[#actions + 1] = action("words", join(carry, rest)) end
      end
    end
    if ev.ev == "end" then
      local nextStarted = startAt[ev.utt + 1] ~= nil
      startAt[ev.utt] = nil -- only utterances still being said are kept
      if (phase == "wake" and ev.utt == wakeUtt or phase == "capture" and ev.utt == nextUtt) and ev.split then
        return holdSplit(self, ev, t, actions, nextStarted)
      end
      if phase == "wake" and ev.utt == wakeUtt then
        if rest and rest ~= "" then
          actions[#actions + 1] = action("send", join(carry, rest))
          reset()
        elseif nextStarted then -- the question began while "okay Buddy" was still being written down
          phase, nextUtt, deadline = "capture", ev.utt + 1, nil
        else
          phase, deadline = "waiting", t + timeout
        end
      elseif phase == "capture" and ev.utt == nextUtt then
        local text = join(carry, rest)
        if text ~= "" then actions[#actions + 1] = action("send", text)
        else actions[#actions + 1] = action("nothing") end
        reset()
      end
    end
    return actions
  end

  -- The brain dump so far: what's been said, plus (open ~= false) the words of utterances
  -- still being written down.
  function turn:dumpText(open)
    local d = self.dump
    if not d then return "" end
    local list = { table.unpack(d.parts) }
    if d.maybe then list[#list + 1] = d.maybe.whole end
    if open ~= false then
      local keys = {}
      for k, u in pairs(parts) do if u.dumpWords then keys[#keys + 1] = k end end
      table.sort(keys)
      for _, k in ipairs(keys) do list[#list + 1] = parts[k].dumpWords end
    end
    return join(list)
  end

  -- Finish the dump: send what was said (last: the words before the finishing phrase), then
  -- end the live chat when why says so, or when it was live only for this dump.
  function turn:finishDump(last, actions, why)
    local d = self.dump
    d.maybe = nil
    if last and last ~= "" then d.parts[#d.parts + 1] = last end
    local text = self:dumpText(false)
    self.dump = nil
    if text ~= "" then actions[#actions + 1] = { "send", text = text, dump = true } end
    actions[#actions + 1] = { "dumpEnd", sent = text ~= "" }
    why = why or (self.dumpLive and "dump")
    if why then actions[#actions + 1] = { "liveEnd", why = why } end
    self.dumpLive = nil
    return actions
  end

  -- Return in the chat box sent the dump: it's over, and what's still being written down
  -- went with it.
  function turn:dumpTaken()
    if not self.dump then return {} end
    self.taken, self.dump = self.lastUtt, nil
    for k in pairs(parts) do parts[k], startAt[k] = nil, nil end
    local actions = { { "dumpEnd", sent = true } }
    if self.dumpLive then actions[2] = { "liveEnd", why = "dump" } end
    self.dumpLive = nil
    return actions
  end

  -- While live, every utterance is for Buddy (unless another app has the mic): words go to
  -- the panel as you talk, a pause sends them, talking over him cuts him off, and an ending
  -- phrase closes the chat. His own voice coming back in is dropped. In a brain dump a pause
  -- sends nothing: the words add up until a finishing phrase (or Return) sends them all.
  function turn:liveEvent(ev, t, actions)
    local utt = ev.utt
    local function forget() parts[utt], startAt[utt] = nil, nil end
    if self.busy then -- another app has the mic: none of this is for him
      if ev.ev == "end" then forget() elseif parts[utt] then parts[utt].dumpWords = nil end
      return actions
    end
    if self.busyOffAt and startAt[utt] and self.busyOffAt >= startAt[utt] - 0.5 then
      -- the mic was another app's while you spoke: not its words, and not its end either
      if ev.ev == "end" then
        forget()
        actions[#actions + 1] = self.dump and action("words", self:dumpText()) or action("drop")
      elseif parts[utt] then parts[utt].dumpWords = nil end
      return actions
    end
    local heard = trim(ev.text)
    local said = V.matchWake(heard, phrase) or heard
    local u = parts[utt] or {}
    parts[utt] = u
    if V.isNoise(said) then
      if ev.ev == "end" then
        forget()
        if utt == self.firstUtt then self.firstUtt = nil; actions[#actions + 1] = action("ready") end
      end
      return actions
    end
    -- An utterance judged echo stays echo: its "end" comes `gap` seconds (plus finalizing)
    -- after the sound stops, which can be well after he finished speaking.
    -- (And it's checked against what he was saying then: its end can come after his next
    -- message has started.)
    local talking = self.speaking or t - self.spokeAt < 1.5
    if (talking or u.echo) and not u.real
        and (V.isEcho(said, self.saying) or (u.echo and V.isEcho(said, u.echoOf))) then
      if not u.echo then u.echo, u.echoOf = true, self.saying end
      if ev.ev == "end" then forget() end
      return actions
    end
    u.real, self.lastHeard = true, t
    if self.speaking and not u.cut then
      u.cut = true
      actions[#actions + 1] = action("interrupt")
    end
    if not self.dump and V.dumpStart(heard, phrase) then
      self.dump = { parts = { self.carry } } -- (nil: an empty list) -- words cut at the limit just before it are part of it
      self.carry, u.trigger = nil, true
      self.dump.shown = self:dumpText()
      actions[#actions + 1] = { "dumpStart", text = self.dump.shown }
    end
    if self.dump then return self:dumpEvent(ev, u, heard, said, actions, t) end
    if ev.ev == "words" then
      actions[#actions + 1] = action("words", join(self.carry, said))
      return actions
    end
    forget()
    if utt == self.firstUtt then self.firstUtt = nil end
    if ev.split then -- cut at the helper's limit, not a pause: wait for the rest
      self.carry, self.carryUtt, self.carryAt = join(self.carry, said), utt, t
      actions[#actions + 1] = action("words", self.carry)
      return actions
    end
    local before = self.carry
    self.carry = nil
    if V.isEnd(said) then
      if before then actions[#actions + 1] = action("send", before) end
      actions[#actions + 1] = { "liveEnd", why = "voice" }
    else
      actions[#actions + 1] = action("send", join(before, said))
    end
    return actions
  end

  function turn:dumpEvent(ev, u, heard, said, actions, t)
    local d = self.dump
    local current = u.trigger and V.dumpStart(heard, phrase) or V.afterWake(heard, phrase) or heard
    -- more was said after a finishing phrase that ended at the helper's limit: it was part of it
    if d.maybe and ev.utt ~= d.maybe.utt then
      d.parts[#d.parts + 1] = d.maybe.whole
      d.maybe = nil
    end
    if ev.ev == "words" then
      u.dumpWords = current
      local shown = self:dumpText()
      if shown ~= d.shown then
        d.shown = shown
        actions[#actions + 1] = action("words", shown)
      end
      return actions
    end
    parts[ev.utt], startAt[ev.utt] = nil, nil
    if ev.utt == self.firstUtt then self.firstUtt = nil end
    local finish = V.dumpFinish(current, phrase)
    if finish and ev.split then
      -- "...okay Buddy, send it" right at the helper's limit: it finishes the dump if nothing
      -- more is said (turn:tick), and is part of it if you carry on
      d.maybe = { before = finish, whole = current, utt = ev.utt, at = t }
      return actions
    end
    if finish then return self:finishDump(finish, actions) end
    if not ev.split and V.isEnd(said) then return self:finishDump("", actions, "voice") end
    if current ~= "" then d.parts[#d.parts + 1] = current end
    local shown = self:dumpText()
    if shown ~= d.shown then
      d.shown = shown
      actions[#actions + 1] = action("words", shown)
    end
    return actions
  end

  -- The live chat is over. Hands back what was said and never sent (a brain dump, or words
  -- waiting for the rest), so it can be kept as a draft.
  function turn:endLive()
    local draft = self.dump and self:dumpText() or self.carry
    self.live, self.firstUtt, self.dump, self.dumpLive, self.carry = false, nil, nil, nil, nil
    self.taken = self.lastUtt -- what's still being said was for the chat that just ended
    startAt, parts = {}, {}
    return draft ~= "" and draft or nil
  end

  -- He's stopped listening for a moment: the utterances open now are dropped when they end.
  function turn:retire()
    if self.dump then return end -- a dump keeps what it has; the helper ends the utterance cleanly
    self.taken = math.max(self.taken or 0, self.lastUtt)
    reset()
  end

  -- Is an utterance after n still being said? (One that never ended counts for 45 s at most.)
  local function openAfter(n, t)
    for k, began in pairs(startAt) do
      if k > n and t - began < 45 then return true end
    end
    return false
  end

  function turn:tick(t)
    if self.live and self.carry and not self.dump and t - self.carryAt >= carryWait
        and not openAfter(self.carryUtt, t) then
      local text = self.carry
      self.carry = nil
      return { action("send", text) }
    end
    local d = self.dump
    if d and d.maybe and t - d.maybe.at >= carryWait and not openAfter(d.maybe.utt, t) then
      return self:finishDump(d.maybe.before, {})
    end
    local quietLimit = d and dumpTimeout or liveTimeout
    if self.live and quietLimit > 0 and not self.speaking and not self.busy
        and t - self.lastHeard >= quietLimit then
      self.lastHeard = t
      return { { "liveEnd", why = "quiet" } }
    end
    if phase == "waiting" and t >= deadline then
      local text = carry
      reset()
      if text and text ~= "" then return { action("send", text) } end
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
  if kind == "line" then -- his own lines: the bubble switch, then the slider's odds
    return (not s.muted and s.bubbles ~= false and (s.roll or 0) < (tonumber(s.outLoud) or 0) / 100) and true or false
  end
  return false
end

-- His own lines are spoken at all: the bubble switch is on and the slider is above never.
function V.bubblesOn(s)
  s = s or V.settings()
  return s.bubbles ~= false and (tonumber(s.outLoud) or 0) > 0
end

-- The console says why something he meant to say stayed silent: a chat answer, or a line
-- the slider picked. The first place to look when a spoken answer seems to be skipped.
function V.quiet(kind, text, why)
  local short = (tostring(text or ""):gsub("%s+", " ")):sub(1, 60)
  print("ClaudeBuddy voice: " .. kind .. " not spoken, " .. why .. ": " .. short)
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
  -- the bubble lines switch; settings saved before it existed had only the slider
  if result.bubbles == nil then result.bubbles = (tonumber(result.outLoud) or 0) > 0 end
  result.bubbles = result.bubbles == true
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
  -- the bubble switch and the slider agree: switching on at never means every line; the
  -- slider at never switches off, above it on
  if key == "bubbles" and value == true and (tonumber(saved.outLoud) or 0) == 0 then saved.outLoud = 100 end
  if key == "outLoud" then saved.bubbles = (tonumber(value) or 0) > 0 end
  hs.settings.set(V.settingsKey, saved)
  local settings = V.settings()
  if key == "live" and V.turn then
    V.turn.liveOn = value ~= false
    if value == false then V.endLive("off") end
  end
  if V.options and (key == "listen" or key == "answers" or key == "outLoud" or key == "bubbles" or key == "phrase") then
    local needed = settings.listen or settings.answers or V.bubblesOn(settings)
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
-- the helpers every voice.lua loaded in this Hammerspoon runs (the buddy's, a spec's sandbox,
-- the wizard's), PID -> that instance. V.start kills only a helper an earlier Hammerspoon left
-- behind, never one of these: a sandbox that reads the real settings must not take the
-- buddy's ears.
local owned = rawget(_G, "ClaudeBuddyVoiceHelpers")
if type(owned) ~= "table" then owned = {}; rawset(_G, "ClaudeBuddyVoiceHelpers", owned) end
local function now() return hs.timer.secondsSinceEpoch() end
local function needed(s)
  return s.listen or s.answers or V.bubblesOn(s)
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
  saved.listen, saved.answers, saved.outLoud, saved.bubbles = false, false, 0, false
  hs.settings.set(V.settingsKey, saved)
  trouble(message)
end
local function call(cb, name, ...)
  if cb and type(cb[name]) == "function" then cb[name](...) end
end
local function clearTimer(name)
  if V[name] then V[name]:stop(); V[name] = nil end
end
-- Voice can't start (or keeps stopping): nothing in line will ever be said, so every caller
-- hears back now instead of waiting for a helper that isn't coming.
local function abandon()
  V.active = false
  clearTimer("tickTimer")
  V.clearWaiting()
  V.renderSerial = (V.renderSerial or 0) + 1
  V.renderKind = nil
  V.flushQueue()
  if V.pending then os.remove(V.pending.file); call(V.pending.cb, "onSkip"); V.pending = nil end
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
      if V.options.onSend then V.options.onSend(action.text, action.dump and { dump = true } or nil) end
    elseif kind == "dumpStart" then
      V.interrupt() -- nothing more is said out loud until the dump is sent
      call(V.options, "onDumpStart", action.text)
    elseif kind == "dumpEnd" then call(V.options, "onDumpEnd", action.sent and true or false)
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
  item.deadline = now() + V.startLimit -- until the helper says it started (see V.checkStuck)
  command({ cmd = "speak", id = item.id, file = item.file })
end

local function event(ev)
  if type(ev) ~= "table" or type(ev.ev) ~= "string" then return end
  if ev.ev == "ready" then
    V.ready = true
    command({ cmd = "listen", on = listening() })
    deliverPending()
  elseif ev.ev == "note" then -- the helper put something right by itself: for the console
    print("ClaudeBuddy voice: helper: " .. tostring(ev.what) .. (ev.id and (" (speech " .. tostring(ev.id) .. ", try " .. tostring(ev.try) .. ")") or ""))
    return
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
    V.noStart, V.audioStuck, V.audioStuckSaid = 0, nil, nil -- the Mac's audio is answering
    if item then
      item.started = true
      item.deadline = now() + (tonumber(ev.secs) or 0) + V.stuckAfter
      call(item.cb, "onStart", ev.secs)
    end
  elseif ev.ev == "spoken" then
    local item = V.speeches and V.speeches[ev.id]
    if item then
      V.speeches[ev.id] = nil
      if V.currentId == ev.id then V.currentId = nil end
      os.remove(item.file)
      call(item.cb, "onEnd", ev.cut and true or false)
      if item.kind == "answer" and item.turnToken == V.turnToken then V.voiceTurn = false end
      local msg = item.msg
      if msg and msg == V.msg then
        if ev.cut then
          -- cut off (or replaced): the rest of this message is not spoken
          V.renderSerial = (V.renderSerial or 0) + 1
          V.renderKind = nil
          V.flushQueue()
        elseif item.last or (msg.broken and not msg.queue[1]) then
          V.finish(msg, msg.broken and not item.last) -- played out (or the rest couldn't be made)
          V.flushQueue()
        else
          -- between pieces: lines of his own keep waiting for the end of the message
          if msg.queue[1] and not V.pending then
            V.pending = table.remove(msg.queue, 1)
            deliverPending()
          end
          return
        end
      end
    end
    local held = V.held
    V.held = nil
    if held then held() end
    V.pump() -- the next message in line, now that this one is over
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
        abandon()
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
  V.noStart, V.audioStuck, V.audioStuckSaid = 0, nil, nil
  V.turn = V.turns({ phrase = V.settings().phrase, timeout = cfg.timeout or 6,
    live = V.settings().live ~= false, liveTimeout = cfg.liveTimeout, dumpTimeout = cfg.dumpTimeout,
    carryWait = (tonumber(cfg.gap) or 1) + 1 }) -- a split end waits a little longer than a pause
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
    owned[task:pid()] = nil
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
    -- the rest of a long answer, and what waited after it, is dropped, not played after the restart
    V.clearWaiting()
    V.renderSerial = (V.renderSerial or 0) + 1
    V.renderKind = nil
    V.flushQueue()
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
      abandon()
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
    abandon()
    trouble("Voice helper couldn't start.")
    return
  end
  V.task = task
  hs.settings.set(V.pidKey, task:pid())
  owned[task:pid()] = V
end

function V.start(opts)
  opts = opts or V.options or {}
  assert(opts.dir, "voice.start needs dir")
  if V.task == nil then V.pidKey = opts.pidKey or "claudeBuddy.voicePid" end
  local oldPid = tonumber(hs.settings.get(V.pidKey))
  local currentPid = V.task and V.task:pid()
  V.stop()
  local killedPid
  if oldPid and owned[oldPid] and owned[oldPid] ~= V then
    -- another voice.lua in this Hammerspoon runs that helper: not ours to stop or forget
  else
    killedPid = killSaved(oldPid)
    hs.settings.set(V.pidKey, nil)
  end
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
    V.checkStuck()
  end)
  if opts.bin then launch(generation); return V end
  if (hs.host.operatingSystemVersion().major or 0) < 26 then
    abandon()
    unsupported("Voice needs macOS 26 or later.")
    return V
  end
  local build
  build = hs.task.new(opts.dir .. "/ear/build.sh", function(code, out, err)
    if V.buildTask ~= build or generation ~= V.generation then return end
    V.buildTask = nil
    if code == 0 then launch(generation)
    else
      abandon()
      if code == 3 then unsupported("Voice needs Apple's Command Line Tools: xcode-select --install")
      else trouble(firstLine((err and err ~= "") and err or out)) end
    end
  end, { "--if-stale" })
  if not build or not build:start() then
    abandon()
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
  V.clearWaiting()
  for id, item in pairs(V.speeches or {}) do
    os.remove(item.file)
    call(item.cb, "onEnd", true)
    V.speeches[id] = nil
  end
  if V.pending then os.remove(V.pending.file); call(V.pending.cb, "onSkip") end
  V.flushQueue()
  V.pending, V.currentId, V.held = nil, nil, nil
  V.voiceTurn = false
  V.endLive("stopped") -- before the turn goes: a brain dump in it comes back as a draft
  V.turn = nil
  return V
end

-- The live chat is over: you said so, you walked away, or the helper had trouble. He says
-- goodbye out loud even when spoken answers are off (V.goodbye lets that one line through).
function V.endLive(why)
  if not V.live then return end
  V.live = false
  local dumping = V.isDumping()
  local draft = V.turn and V.turn:endLive() -- words said and never sent: kept as a draft
  if dumping then call(V.options, "onDumpEnd", false) end
  V.goodbye = true
  call(V.options, "onLiveEnd", why, draft)
  V.goodbye = nil
end

-- A brain dump is on: pauses don't send, and he says nothing out loud.
function V.isDumping() return V.turn ~= nil and V.turn.dump ~= nil end
-- The brain dump so far, words still being written down included.
function V.dumpText() return V.turn and V.turn:dumpText() or "" end
-- The chat box sent the dump (Return): it's over, and the words still coming went with it.
function V.dumpTaken()
  if V.turn and V.options then runActions(V.turn:dumpTaken()) end
end

-- Talking over him: cut the audio, and drop an answer that's still being made.
-- True for as long as a live voice chat is on (what Buddy's halo follows).
function V.isLive() return V.active == true and V.live == true end

function V.interrupt()
  V.stopSpeech()
  V.renderSerial = (V.renderSerial or 0) + 1
  V.renderKind, V.held = nil, nil
  V.flushQueue()
  if V.pending then os.remove(V.pending.file); call(V.pending.cb, "onSkip"); V.pending = nil end
end

function V.pause(reason)
  if reason ~= "dictate" then V.endLive("away"); V.interrupt() end -- screen off or locked: nobody to talk to
  V.pauses = V.pauses or {}
  V.pauses[reason] = true
  -- what was being said when he stopped listening (hold-space dictation takes the mic) isn't his
  if V.turn then V.turn:retire() end
  if V.ready then command({ cmd = "listen", on = false }) end
end

function V.resume(reason)
  if V.pauses then V.pauses[reason] = nil end
  if V.ready then command({ cmd = "listen", on = listening() }) end
end

function V.speaking() -- also between the pieces of a long message, and while lines wait
  return (V.turn and V.turn.speaking) or V.msg ~= nil or (V.waiting and V.waiting[1] ~= nil) or false
end

function V.hold(fn)
  V.held = fn
end

-- A stop (a click, "okay Buddy" over him, talking over him) is for all of it: what waits
-- in line isn't said either.
function V.stopSpeech()
  V.clearWaiting()
  if V.currentId then
    if V.task and V.task:isRunning() then command({ cmd = "stop" }) end
    return
  end
  if V.msg then -- between pieces: nothing is playing, so drop the rest here
    V.renderSerial = (V.renderSerial or 0) + 1
    V.renderKind = nil
    V.flushQueue()
  end
end

-- Everything he says out loud takes its turn in one line (V.waiting): a message is made and
-- played to its end before the next one starts, so a new line never cuts off the one he's
-- saying, and only one is ever being made. A stop (V.stopSpeech, V.interrupt, V.stop) empties
-- the line. Rules for the line:
--   - The same words already waiting, or being said, aren't said twice (the new one goes).
--   - opts.key: a newer message with the same key takes the waiting one's place (his own
--     chatter: only the latest waits).
--   - opts.first: goes ahead of what's waiting (an answer to what you just asked), never
--     ahead of what's playing.
--   - opts.maxWait (seconds, default V.maxWait): left out once its moment has passed.
--   - More than V.maxWaiting waiting: the oldest of his own lines goes, then the oldest.
--   - A line that isn't said out loud (the slider, quiet for an hour, unsafe text) still
--     waits its turn while he talks, so its bubble never covers the words he's saying.
-- Callbacks (cb): onTurn() when its turn comes and it's being made; onStart(secs) for each
-- piece that plays; then exactly one of onEnd(cut) or onSkip(dropped). onSkip(false): its
-- turn came but it isn't said; onSkip(true): it was dropped before its turn (show nothing).
V.maxWait, V.maxWaiting, V.stuckAfter, V.renderLimit = 180, 8, 10, 180
-- V.startLimit: seconds the helper gets to start playing a speech. Two in a row that never
-- start mean the Mac's audio service isn't answering (it happens: every app's sound hangs).
-- Then he says so once, shows his lines without a sound, and tries one again every
-- V.audioRetry seconds, so the line doesn't crawl at one bubble per V.startLimit.
V.startLimit, V.audioRetry = 20, 60

local function busyLine()
  return V.msg ~= nil or V.currentId ~= nil or V.pending ~= nil or (V.waiting ~= nil and V.waiting[1] ~= nil)
end

local function gates(kind, item)
  local s = V.settings()
  local muted = V.options and V.options.muted
  local busy = V.turn and V.turn.busy or false
  return V.decide(kind, { answers = s.answers, outLoud = s.outLoud, bubbles = s.bubbles,
    muted = type(muted) == "function" and muted() or false,
    busy = busy, voiceTurn = item.voiceTurn, roll = item.roll, live = item.live }), s, busy
end

local function enqueue(item, first)
  V.waiting = V.waiting or {}
  local waiting = V.waiting
  local words = normalized(item.spoken or item.text)
  if words ~= "" and V.msg and V.msg.words == words then return call(item.cb, "onSkip", true) end
  for i, other in ipairs(waiting) do
    if words ~= "" and other.words == words then return call(item.cb, "onSkip", true) end
    if item.key and other.key == item.key then
      waiting[i] = item -- the newer one takes its place in line
      item.first = other.first
      return call(other.cb, "onSkip", true)
    end
  end
  if first then
    local at = 1
    while waiting[at] and waiting[at].first do at = at + 1 end
    item.first = true
    table.insert(waiting, at, item)
  else
    waiting[#waiting + 1] = item
  end
  while #waiting > V.maxWaiting do
    local drop = 1
    for i, other in ipairs(waiting) do if other.kind == "line" then drop = i; break end end
    call(table.remove(waiting, drop).cb, "onSkip", true)
  end
end

function V.speak(text, kind, cb, opts)
  cb, opts = cb or {}, opts or {}
  local item = { text = text, kind = kind, cb = cb, at = now(), key = opts.key,
    maxWait = tonumber(opts.maxWait) or V.maxWait, roll = math.random(), voiceTurn = V.voiceTurn,
    live = (V.live or V.goodbye) and true or false, token = V.turnToken }
  local allowed, s, busy = gates(kind, item)
  if V.isDumping() then
    -- a brain dump is on: his own lines wait for nobody, the rest shows without a sound
    if kind == "line" then return call(cb, "onSkip", true) end
    allowed = false
    V.quiet(kind, text, "a brain dump is on")
  end
  if allowed and V.audioStuck and now() - V.audioStuck < V.audioRetry then
    allowed = false
    V.quiet(kind, text, "the Mac's sound isn't answering")
  end
  if not allowed then
    if V.isDumping() or V.audioStuck then -- said why above
    elseif kind == "answer" and (s.answers or V.live) then -- an answer they expected to hear
      V.quiet(kind, text, busy and "another app has the microphone" or "quiet for an hour is on")
    end
  elseif not V.active or not V.speech then
    -- before the first V.start (a hello at startup) nothing is wrong, so nothing is said
    if V.options then V.quiet(kind, text, "the voice helper isn't running") end
  else
    item.spoken = V.speech.speakable(text)
    if not item.spoken then
      V.quiet(kind, text, "nothing safe to say out loud (code, links, paths or private details)")
    end
  end
  -- not said out loud, with nothing playing or waiting: its bubble shows now
  if not item.spoken and not (V.active and busyLine()) then return call(cb, "onSkip", false) end
  item.words = normalized(item.spoken or text)
  item.waited = busyLine()
  enqueue(item, opts.first)
  V.pump()
end

local startMessage

-- Start the next message once nothing is being made, waiting to play or playing.
function V.pump()
  if V.pumping then V.pumpAgain = true; return end
  V.pumping = true
  repeat
    V.pumpAgain = false
    while V.waiting and V.waiting[1] and not V.msg and not V.currentId and not V.pending do
      local item = table.remove(V.waiting, 1)
      local ok, err = pcall(function()
        if not V.active then return call(item.cb, "onSkip", true) end
        if now() - item.at > item.maxWait then return call(item.cb, "onSkip", true) end -- too late now
        if item.spoken and item.waited then
          -- what may have changed while it waited: quiet for an hour, another app on the
          -- mic, the switches. His own lines just go; answers still show their bubble.
          if not gates(item.kind, item) then
            item.spoken = nil
            if item.kind == "line" then return call(item.cb, "onSkip", true) end
          end
        end
        if not item.spoken then return call(item.cb, "onSkip", false) end
        call(item.cb, "onTurn")
        startMessage(item)
      end)
      if not ok then
        print("ClaudeBuddy voice: " .. tostring(err))
        -- a message that broke while starting mustn't hold the line
        if V.msg and not V.currentId and not V.pending then
          V.renderSerial = (V.renderSerial or 0) + 1
          V.renderKind = nil
          V.flushQueue()
        end
      end
    end
  until not V.pumpAgain
  V.pumping = false
end

-- Drop everything waiting in line (each gets onSkip(true)).
function V.clearWaiting()
  local waiting = V.waiting or {}
  V.waiting = {}
  for _, item in ipairs(waiting) do call(item.cb, "onSkip", true) end
end

-- The helper always says when a speech ends, but if it ever doesn't, the line would stop
-- for good: a speech well past its length counts as over. Likewise a render that hangs with
-- nothing playing: after V.renderLimit seconds the message is dropped.
function V.checkStuck()
  local msg = V.msg
  if msg and msg.render and msg.renderAt and not V.currentId and not V.pending
      and now() - msg.renderAt > V.renderLimit then
    print("ClaudeBuddy voice: a speech render took over " .. V.renderLimit .. " s, dropping that message")
    V.renderSerial = (V.renderSerial or 0) + 1
    V.renderKind = nil
    V.flushQueue()
    return
  end
  local item = V.currentId and V.speeches and V.speeches[V.currentId]
  if not (item and item.deadline and now() > item.deadline) then return end
  if item.started then
    print("ClaudeBuddy voice: no end heard for speech " .. tostring(item.id) .. ", moving on")
  else
    print("ClaudeBuddy voice: speech " .. tostring(item.id) .. " never started, moving on")
    V.noStart = (V.noStart or 0) + 1
    if V.noStart >= 2 or V.audioStuck then
      V.audioStuck = now()
      V.clearWaiting() -- nothing in line would be heard either
    end
  end
  if V.task and V.task:isRunning() then command({ cmd = "stop" }) end
  event({ ev = "spoken", id = item.id, cut = not item.started })
  if V.audioStuck and not V.audioStuckSaid then
    V.audioStuckSaid = true
    trouble("This Mac's sound isn't answering, so I can't talk or listen right now. Restarting the Mac fixes it.")
  end
end

startMessage = function(item)
  local kind, cb, spoken, token = item.kind, item.cb, item.spoken, item.token
  local s = V.settings()
  local speech = V.speech
  -- A long message is spoken in pieces, in order, so the whole thing is said and the first
  -- words start without waiting for the last to be made.
  local pieces = speech.chunks and speech.chunks(spoken) or { spoken }
  if #pieces == 0 then pieces = { spoken } end
  V.renderKind = kind
  V.renderSerial = (V.renderSerial or 0) + 1
  local serial = V.renderSerial
  -- exactly one of onSkip / onEnd reaches the caller, however the message ends
  local msg = { queue = {}, serial = serial, cb = cb, words = item.words }
  V.msg = msg
  local function skipOnce()
    if not msg.ended then msg.ended = true; call(cb, "onSkip", false) end
  end
  local partCb = { onStart = cb.onStart, onSkip = skipOnce,
    onEnd = function(cut) if cut then V.finish(msg, true) end end }
  local function renderPiece(i)
    local last = i == #pieces
    local function stale()
      return serial ~= V.renderSerial or not V.active
    end
    -- this piece can't be made (both voices failed): what was made still plays, then it ends
    local function failed()
      if serial == V.renderSerial then V.renderKind = nil end
      if i == 1 then
        skipOnce()
        if msg == V.msg then V.flushQueue() end
      elseif msg == V.msg then
        msg.broken = true
        if not V.currentId and not V.pending and not msg.queue[1] then V.flushQueue() end
      end
    end
    local function rendered(path, why)
      msg.render = nil
      if last and serial == V.renderSerial then V.renderKind = nil end
      if stale() then
        if path then os.remove(path) end
        if i == 1 then skipOnce() end
        return
      end
      if path then
        V.nextId = (V.nextId or 0) + 1
        -- every piece is echo-checked against the whole message: an echo of one piece can
        -- end after the next has started
        local item = { id = V.nextId, file = path, kind = kind, cb = partCb,
          turnToken = token, text = spoken, msg = msg, last = last }
        -- never sent over one that's playing: the helper would cut it off
        if V.currentId or V.pending then
          msg.queue[#msg.queue + 1] = item
        else
          V.pending = item
          deliverPending()
        end
        if not last then renderPiece(i + 1) end
        return
      end
      local choice = s.voice or {}
      if choice.engine ~= "system" or choice.name then
        local backup = speech.render(pieces[i], { engine = "system" }, function(fallback, finalWhy)
          if stale() then
            if fallback then os.remove(fallback) end
            if i == 1 then skipOnce() end
            return
          end
          if fallback then return rendered(fallback) end
          if not V.voiceFailed then
            V.voiceFailed = true
            trouble("My voice isn't working: " .. tostring(finalWhy or why or "unknown error"))
          end
          failed()
        end)
        if backup then msg.render, msg.renderAt = backup, now() end
        return
      end
      if not V.voiceFailed then
        V.voiceFailed = true
        trouble("My voice isn't working: " .. tostring(why or "unknown error"))
      end
      failed()
    end
    -- kept so that dropping the message stops it (a cloned voice is ~5 GB for half a minute)
    local job = speech.render(pieces[i], s.voice, rendered)
    if job then msg.render, msg.renderAt = job, now() end
  end
  renderPiece(1)
end

-- The message is over (played out, cut, dropped or failed): tell the caller once.
function V.finish(msg, cut)
  if msg.ended then return end
  msg.ended = true
  call(msg.cb, "onEnd", cut and true or false)
end

-- Drop the pieces of a message that were made but never played, and end the message.
function V.flushQueue()
  local msg = V.msg
  V.msg = nil
  if not msg then return end
  -- and the piece still being made: renders that pile up can fill the Mac's memory
  if msg.render and V.speech and V.speech.cancel then V.speech.cancel(msg.render) end
  msg.render = nil
  for _, item in ipairs(msg.queue) do os.remove(item.file) end
  msg.queue = {}
  if V.pending and V.pending.msg == msg then os.remove(V.pending.file); V.pending = nil end
  V.finish(msg, true)
  V.pump()
end

return V
