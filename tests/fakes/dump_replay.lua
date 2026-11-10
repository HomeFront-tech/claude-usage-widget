-- The turn rules (voice.lua's V.turns, live chat on) replayed over a helper's events, outside
-- Hammerspoon: lua tests/fakes/dump_replay.lua <voice.lua> <events.jsonl>
-- Prints one tab-separated line per action except "words": kind, "dump" or "", text.
-- Each event is a second after the last, and the tick runs between them.
hs = { timer = { secondsSinceEpoch = os.time } }
local V = dofile(arg[1])
local turn = V.turns({ phrase = "okay Buddy", timeout = 6, live = true })
local function unescape(s)
  return (s:gsub('\\u(%x%x%x%x)', function(h) return utf8.char(tonumber(h, 16)) end)
    :gsub('\\(["\\/])', "%1"))
end
local function out(actions)
  for _, a in ipairs(actions) do
    if a[1] ~= "words" then print(table.concat({ a[1], a.dump and "dump" or "", a.text or "" }, "\t")) end
  end
end
local t = 0
for line in io.lines(arg[2]) do
  local ev = line:match('"ev":"(%a+)"')
  if ev == "start" or ev == "words" or ev == "end" then
    t = t + 1
    out(turn:tick(t))
    out(turn:event({ ev = ev, utt = tonumber(line:match('"utt":(%d+)')),
      text = unescape(line:match('"text":"(.-)"[,}]') or ""), split = line:find('"split":true', 1, true) ~= nil }, t))
  end
end
out(turn:tick(t + 60))
