-- notices.lua: lines other programs on this Mac hand Buddy to say.
return function(t, dir)
  local N = dofile(dir .. "/notices.lua")
  local moods = { health = true, food = true }
  local now = os.time({ year = 2026, month = 3, day = 10, hour = 15, min = 0 })
  local function line(tbl) return hs.json.encode(tbl) end

  -- parse: what a line means
  local n = N.parse(line({ text = " You're at 600 of 3,100 kcal. ", bubble = "2,500 kcal to go!", mood = "health",
    telegram = true, at = now - 30, from = "meals" }), now, moods)
  t.eq(n and n.text, "You're at 600 of 3,100 kcal.", "text, trimmed")
  t.eq(n and n.bubble, "2,500 kcal to go!", "bubble line")
  t.eq(n and n.mood, "health", "a known mood is kept")
  t.eq(n and n.telegram, true, "telegram defaults on")
  n = N.parse(line({ text = "Hi" }), now, moods)
  t.ok(n and n.bubble == nil and n.mood == nil and n.telegram == true, "only text is needed")
  t.eq(N.parse(line({ text = "Hi", telegram = false }), now, moods).telegram, false, "telegram = false is kept")
  t.eq(N.parse(line({ text = "Hi", mood = "party" }), now, moods).mood, nil, "an unknown mood is dropped")
  t.eq(N.parse(line({ text = "" }), now, moods), nil, "empty text: nothing")
  t.eq(N.parse(line({ text = "   " }), now, moods), nil, "blank text: nothing")
  t.eq(N.parse(line({ bubble = "no text" }), now, moods), nil, "no text: nothing")
  t.eq(N.parse("{not json", now, moods), nil, "junk: nothing")
  t.eq(N.parse("", now, moods), nil, "an empty line: nothing")
  t.eq(#N.parse(line({ text = string.rep("a", 1500) }), now, moods).text, 1000, "text is cut to 1000")
  t.eq(#N.parse(line({ text = "x", bubble = string.rep("b", 300) }), now, moods).bubble, 120, "bubble is cut to 120")
  t.eq(N.parse(line({ text = "old", at = now - 3601 }), now, moods), nil, "over an hour old: dropped")
  t.ok(N.parse(line({ text = "recent", at = now - 3599 }), now, moods), "under an hour old: kept")
  t.eq(N.parse(line({ text = "future", at = now + 301 }), now, moods), nil, "far in the future: dropped")
  t.eq(N.parse(line({ text = "odd", at = "soon" }), now, moods), nil, "an at that isn't a time: dropped")

  -- poll: takes the file, reads it on the next poll; caps a pickup at 5 and a day at 30
  local key = "claudeBuddy.test.notices." .. hs.host.uuid()
  local path = t.tmpdir() .. "/notices-new.jsonl"
  local store = N.new(path, { moods = moods, settingsKey = key })
  local function drop(count, extra)
    local f = io.open(path, "a")
    for i = 1, count do f:write(line({ text = "notice " .. i }), "\n") end
    if extra then f:write(extra, "\n") end
    f:close()
  end
  local function pickup() store:poll(now); return store:poll(now) end -- take, then read
  t.eq(#store:poll(now), 0, "no file: nothing")
  drop(2, "{junk")
  t.eq(#store:poll(now), 0, "the first poll only takes the file")
  t.eq(hs.fs.attributes(path), nil, "the file is taken")
  drop(1) -- a writer's line after the take goes to a fresh file
  local got = store:poll(now)
  t.eq(#got, 2, "the next poll reads the two good lines, the junk skipped")
  t.eq(got[1] and got[1].text, "notice 1", "in order")
  got = store:poll(now)
  t.eq(#got, 1, "and the line written in between comes on the poll after")
  t.eq(hs.fs.attributes(path), nil, "nothing waiting")
  t.eq(hs.fs.attributes(path .. ".reading"), nil, "and nothing left behind")
  drop(7)
  t.eq(#pickup(), 5, "at most 5 a pickup")
  t.eq(hs.fs.attributes(path .. ".reading"), nil, "the rest are dropped with the file")
  for _ = 1, 4 do drop(5); pickup() end -- 3 + 5 + 20 = 28 so far today
  drop(5)
  t.eq(#pickup(), 2, "30 a day")
  drop(1)
  t.eq(#pickup(), 0, "none after 30")
  drop(1)
  store:poll(now + 86400)
  t.eq(#store:poll(now + 86400), 1, "a new day starts over")

  -- wipe: Forget removes both files
  drop(1)
  local f = io.open(path .. ".reading", "w"); f:write("x"); f:close()
  store:wipe()
  t.ok(not hs.fs.attributes(path) and not hs.fs.attributes(path .. ".reading"), "wipe removes the files")
  hs.settings.clear(key)
end
