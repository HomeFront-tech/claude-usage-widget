-- facts.lua: running counts of opens and minutes per app or site, and the lines made from them.
return function(t, dir)
  local F = dofile(dir .. "/facts.lua")
  local rules = { { "youtube", "watching" } }

  -- keys
  local k, l = F.keyFor("com.google.Chrome", "Chrome", "cats - YouTube", true, rules)
  t.eq(k, "youtube", "browser rule key")
  t.eq(l, "YouTube", "browser rule label")
  k, l = F.keyFor("com.google.Chrome", "Chrome", "Q3 numbers - Google Sheets", true, {})
  t.eq(k, "google sheets", "site name from the title")
  t.eq(l, "Google Sheets", "site label keeps its case")
  k, l = F.keyFor("com.google.Chrome", "Chrome", "Untitled", true, {})
  t.eq(k, "com.google.Chrome", "no site name falls back to the bundle id")
  t.eq(l, "Chrome", "label falls back to the app name")
  k, l = F.keyFor("com.apple.mail", "Mail", "Inbox - Mail", false, rules)
  t.eq(k, "com.apple.mail", "apps key by bundle id")
  t.eq(l, "Mail", "apps label by name")
  k = F.keyFor("com.google.Chrome", "Chrome", "x - " .. ("a"):rep(80), true, {})
  t.ok(#k <= 40, "site key is capped at 40 characters")

  -- opens, minutes, the 60 s rule
  local path = t.tmpdir() .. "/learn/facts.json"
  local f = F.new(path)
  local t0 = os.time({ year = 2026, month = 3, day = 10, hour = 9 })
  local now = t0
  local function stay(key, label, secs)
    local opened = false
    for _ = 1, secs / 10 do
      if f:observe(key, label, now) then opened = true end
      now = now + 10
    end
    return opened
  end
  t.ok(stay("youtube", "YouTube", 300), "first stay counts an open")
  stay("mail", "Mail", 120)
  t.ok(stay("youtube", "YouTube", 300), "second stay after 2 min away counts")
  stay("mail", "Mail", 30)
  t.ok(not f:observe("youtube", "YouTube", now), "coming back after 30 s is not an open")
  local g = f:get("youtube", now)
  t.eq(g.opens, 2, "two opens")
  t.ok(g.seconds >= 590 and g.seconds <= 640, "about ten minutes so far")
  t.eq(g.streak, 1, "one day so far")
  t.eq(g.daypart, nil, "no habit under 30 minutes")
  t.eq(f:describe("youtube", "YouTube", now), "YouTube: 2nd time today, 10 min so far", "describe")
  t.eq(f:line("youtube", "YouTube", now), "YouTube again!", "second open line")

  -- third open
  stay("mail", "Mail", 120)
  stay("youtube", "YouTube", 20)
  t.eq(f:get("youtube", now).opens, 3, "third open")
  t.eq(f:line("youtube", "YouTube", now), "YouTube for the third time today!", "third open line")

  -- save, reload, garbage
  f:save()
  t.ok(hs.fs.attributes(path) ~= nil, "save creates the folder and file")
  local f2 = F.new(path)
  t.eq(f2:get("youtube", now).opens, 3, "reloads what was saved")
  local bad = t.tmpdir() .. "/facts.json"
  local fh = io.open(bad, "w"); fh:write("{nope not json"); fh:close()
  local f3 = F.new(bad)
  t.eq(f3:get("youtube", now).opens, 0, "garbage file starts empty")
  fh = io.open(bad, "w"); fh:write("[1,2,3]"); fh:close()
  t.eq(F.new(bad):get("x", now).opens, 0, "wrong shape starts empty")

  -- next day, streaks, two hours
  local f4 = F.new(t.tmpdir() .. "/f4.json")
  local d1 = os.time({ year = 2026, month = 3, day = 10, hour = 20 })
  for i = 0, 2 do
    local base = d1 + i * 86400
    f4:observe("yt", "YouTube", base)
    f4:observe("yt", "YouTube", base + 10)
  end
  local next1 = os.time({ year = 2026, month = 3, day = 13, hour = 0, min = 1 })
  f4:observe("mail", "Mail", next1)
  f4:observe("yt", "YouTube", next1 + 120)
  t.eq(f4:get("yt", next1 + 120).opens, 1, "a new day starts at one open")
  t.eq(f4:get("yt", next1 + 120).streak, 4, "four days running")
  t.ok(f4:describe("yt", "YouTube", next1 + 120):find("4 days running", 1, true), "describe mentions the streak")
  t.eq(f4:get("yt", next1 - 30).opens, 1, "the day before keeps its own count")

  -- usual part of day, once there are 30 minutes
  local f5 = F.new(t.tmpdir() .. "/f5.json")
  local ev = os.time({ year = 2026, month = 3, day = 10, hour = 20 })
  for i = 0, 200 do f5:observe("yt", "YouTube", ev + i * 10) end -- about 33 minutes
  t.eq(f5:get("yt", ev + 2000).daypart, "evening", "usual part of day")
  t.ok(f5:describe("yt", "YouTube", ev + 2000):find("usually in the evening", 1, true), "describe mentions it")
  local nightTime = os.time({ year = 2026, month = 3, day = 11, hour = 2 })
  local f6 = F.new(t.tmpdir() .. "/f6.json")
  for i = 0, 200 do f6:observe("yt", "YouTube", nightTime + i * 10) end
  t.eq(f6:get("yt", nightTime + 2000).daypart, "night", "2 a.m. is night")

  -- two hours and many rounds
  local f7 = F.new(t.tmpdir() .. "/f7.json")
  local s = os.time({ year = 2026, month = 3, day = 10, hour = 9 })
  for i = 0, 7300, 10 do f7:observe("yt", "YouTube", s + i) end
  t.eq(f7:line("yt", "YouTube", s + 7300), "Two hours of YouTube today!", "two hours line")
  local f8 = F.new(t.tmpdir() .. "/f8.json")
  local c = s
  for _ = 1, 12 do
    f8:observe("yt", "YouTube", c); f8:observe("mail", "Mail", c + 100); c = c + 200
  end
  f8:observe("yt", "YouTube", c)
  t.eq(f8:line("yt", "YouTube", c), "YouTube, round 13 today.", "round line")
  t.eq(F.new(t.tmpdir() .. "/f9.json"):line("yt", "YouTube", c), nil, "no line without opens")

  -- 14 days kept
  local f10 = F.new(t.tmpdir() .. "/f10.json")
  f10:observe("yt", "YouTube", s - 20 * 86400)
  f10:observe("yt", "YouTube", s)
  f10:save()
  local raw = t.readJson(f10.path)
  local n = 0
  for _ in pairs(raw.days) do n = n + 1 end
  t.eq(n, 1, "days older than 14 are dropped on save")

  -- wipe
  f:wipe()
  t.eq(f:get("youtube", now).opens, 0, "wipe empties memory")
  t.ok(hs.fs.attributes(path) == nil, "wipe deletes the file")

  -- malformed records inside a valid file are dropped, the rest kept
  local mal = t.tmpdir() .. "/mal.json"
  t.writeJson(mal, { days = {
    ["2026-03-10"] = { yt = { label = "YouTube", opens = 2, seconds = 600, parts = { evening = 600 } },
                       bad1 = "oops", bad2 = { opens = "x", seconds = 5 }, bad3 = { opens = 1 }, bad4 = 7,
                       bad5 = { opens = 1, seconds = 5, parts = "no" } },
    ["2026-03-09"] = "not a table", ["junk"] = { yt = { opens = 1, seconds = 1 } }, ["2026-03-08"] = 5 },
    seen = { yt = 5, bad = "x" } })
  local fm = F.new(mal)
  local noon = os.time({ year = 2026, month = 3, day = 10, hour = 12 })
  local gm = fm:get("yt", noon)
  t.eq(gm.opens, 2, "valid record survives")
  t.eq(fm:get("bad1", noon).opens, 0, "string record dropped")
  t.eq(fm:get("bad2", noon).opens, 0, "non-numeric field dropped")
  t.eq(fm:get("bad3", noon).opens, 0, "missing field dropped")
  t.eq(fm:get("bad5", noon).opens, 1, "a bad parts field only loses its parts")
  t.eq(fm:describe("bad1", "Bad", noon), "Bad: not opened today", "describe on a dropped record")
  fm:observe("bad1", "Bad", noon)
  t.eq(fm:get("bad1", noon).opens, 1, "a dropped key can be observed again")

  -- bad "seen" timestamps are dropped on load, and saving still works
  local sp = t.tmpdir() .. "/seen.json"
  local sf = io.open(sp, "w")
  sf:write('{"days":{},"seen":{"youtube":1e20,"mail":-5,"x":"abc","nan":null,"zero":0,"ok":' .. noon .. '}}')
  sf:close()
  local fs2 = F.new(sp)
  t.eq(fs2.seen.youtube, nil, "huge timestamp dropped")
  t.eq(fs2.seen.mail, nil, "negative timestamp dropped")
  t.eq(fs2.seen.x, nil, "text timestamp dropped")
  t.eq(fs2.seen.zero, nil, "zero timestamp dropped")
  t.eq(fs2.seen.ok, noon, "good timestamp kept")
  fs2.lastT = noon
  t.ok(fs2:save(), "save succeeds after loading bad timestamps")
  local sraw = t.readJson(sp)
  t.eq(sraw.seen.ok, noon, "good timestamp saved")
  t.eq(sraw.seen.youtube, nil, "bad timestamp gone from the file")

  -- exactly 14 days: today plus the 13 before it
  local fb = F.new(t.tmpdir() .. "/fb.json")
  local today = os.time({ year = 2026, month = 3, day = 20, hour = 12 })
  local days = {}
  for n = 0, 20 do
    local d = os.date("%Y-%m-%d", os.time({ year = 2026, month = 3, day = 20 - n, hour = 12 }))
    days[d] = { yt = { label = "YouTube", opens = 1, seconds = 200, parts = { morning = 200 } } }
  end
  local bf = t.tmpdir() .. "/boundary.json"
  t.writeJson(bf, { days = days })
  fb = F.new(bf)
  t.eq(fb:get("yt", today).streak, 14, "streak counts at most 14 days")
  t.eq(fb:get("yt", today).daypart, "morning", "14 days of 200 s is enough for a habit")
  -- the oldest day (13 back) counts; the one before it (14 back) does not: 14*200 = 2800 vs 13*200 = 2600
  local fh = F.new(t.tmpdir() .. "/fh.json")
  fh.days = {}
  for n = 0, 13 do
    fh.days[os.date("%Y-%m-%d", os.time({ year = 2026, month = 3, day = 20 - n, hour = 12 }))] =
      { yt = { opens = 1, seconds = 130, parts = { night = 130 } } } -- 14 * 130 = 1820 >= 1800
  end
  t.eq(fh:get("yt", today).daypart, "night", "all 14 days count toward the habit")
  fh.days[os.date("%Y-%m-%d", os.time({ year = 2026, month = 3, day = 6, hour = 12 }))] = nil -- 14 back, absent already
  fh.days[os.date("%Y-%m-%d", os.time({ year = 2026, month = 3, day = 7, hour = 12 }))] = nil -- 13 back removed
  t.eq(fh:get("yt", today).daypart, nil, "13 days of 130 s is under 30 minutes")
  local fo = F.new(t.tmpdir() .. "/fo.json")
  fo.days[os.date("%Y-%m-%d", os.time({ year = 2026, month = 3, day = 6, hour = 12 }))] =
    { yt = { opens = 1, seconds = 3600, parts = { night = 3600 } } } -- 14 days back: outside
  t.eq(fo:get("yt", today).daypart, nil, "a record 14 days back is outside the window")
  fo.days[os.date("%Y-%m-%d", os.time({ year = 2026, month = 3, day = 7, hour = 12 }))] =
    { yt = { opens = 1, seconds = 3600, parts = { night = 3600 } } } -- 13 days back: inside
  t.eq(fo:get("yt", today).daypart, "night", "a record 13 days back is inside")
  fo.lastT = today
  fo:save()
  local kept = t.readJson(fo.path).days
  t.ok(kept["2026-03-07"] ~= nil, "save keeps the record 13 days back")
  t.ok(kept["2026-03-06"] == nil, "save drops the record 14 days back")

  -- the per-poll step, with fake collaborators
  local function fakes(over)
    local said, quips = {}, {}
    local o = {
      t = 0, bid = "com.google.Chrome", app = "Chrome", title = "cats - YouTube", isBrowser = true,
      rules = rules, mood = "watching", lines = true, quiet = false, said = {},
      privacy = { private = function() return false end, busy = function() return false end, watching = function() return true end },
      say = function(text, force) said[#said + 1] = text end,
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return o, said, quips
  end
  local function brainFake(quips, reply, started)
    return { busy = function() return false end,
             quip = function(ctx, done) quips[#quips + 1] = ctx; if started ~= false then done(reply) end; return started ~= false end }
  end
  -- polls come every second or so: stay on a title until `until_`, ticking every 10 s
  local function stayOn(st, o, title, until_)
    o.title = title
    while o.t < until_ do o.t = o.t + 10; F.tick(st, o) end
  end
  local ts = F.new(t.tmpdir() .. "/tick.json")
  local base = os.time({ year = 2026, month = 3, day = 10, hour = 9 })
  local o, said, quips = fakes({ t = base })
  stayOn(ts, o, "cats - YouTube", base + 20)
  t.eq(F.tick(ts, o), "youtube", "tick returns the key it counted")
  t.eq(#said, 0, "first open says nothing")
  stayOn(ts, o, "Inbox - Mail", base + 100)
  stayOn(ts, o, "cats - YouTube", base + 200)
  t.eq(ts:get("youtube", base + 200).opens, 2, "tick counted a second open")
  t.eq(said[1], "YouTube again!", "plain line without a brain")
  stayOn(ts, o, "Inbox - Mail", base + 300)
  stayOn(ts, o, "cats - YouTube", base + 400)
  t.eq(ts:get("youtube", base + 400).opens, 3, "third open counted")
  t.ok(not said[2] or not said[2]:find("YouTube", 1, true), "not said again for that key within 15 minutes")

  -- brain quip only when watching and a Brain; otherwise the plain line
  local function secondOpen(over)
    local st = F.new(t.tmpdir() .. "/t2.json")
    local o2, said2, quips2 = fakes(over)
    if o2.brain == true then o2.brain = brainFake(quips2, "Candid line.") end
    o2.t = base
    stayOn(st, o2, "cats - YouTube", base + 20)
    stayOn(st, o2, "Inbox - Mail", base + 100)
    stayOn(st, o2, "cats - YouTube", base + 200)
    return said2, quips2
  end
  local sd, qs = secondOpen({ brain = true })
  t.eq(#qs, 1, "brain asked for a fact quip")
  t.eq(qs[1].kind, "fact", "kind fact")
  t.ok(qs[1].facts:find("YouTube: 2nd time today", 1, true), "facts handed over")
  t.eq(sd[1], "Candid line.", "the brain's line is said")
  local unwatched = { private = function() return false end, busy = function() return false end, watching = function() return false end }
  sd, qs = secondOpen({ brain = true, privacy = unwatched })
  t.eq(#qs, 0, "no quip while not watching, so no facts reach a prompt")
  t.eq(sd[1], "YouTube again!", "plain line instead")
  -- a brain that declines (busy / no unprompted) falls back to the plain line
  local st3 = F.new(t.tmpdir() .. "/t3.json")
  local o3, said3, q3 = fakes({})
  o3.brain = brainFake(q3, nil, false)
  o3.t = base
  stayOn(st3, o3, "cats - YouTube", base + 20)
  stayOn(st3, o3, "Inbox - Mail", base + 100)
  stayOn(st3, o3, "cats - YouTube", base + 200)
  t.eq(said3[1], "YouTube again!", "declined quip falls back to the plain line")

  -- gates: the config. Only a config the wizard saved (wizard = 2) talks.
  local FW = dofile(dir .. "/setup.lua")
  t.eq(F.talks({ chatter = "chatty", ai = {} }), false, "legacy config does not talk")
  t.eq(F.talks({ watch = true }), false, "a watch key alone does not make a config wizard-made")
  t.eq(F.talks(FW.setOption(t.tmpdir(), { chatter = "chatty" }, "watch", true)), false, "legacy config plus the menu's watching switch stays quiet")
  t.eq(F.talks({ wizard = 1 }), false, "an older marker does not talk")
  t.eq(F.talks({ wizard = true }), false, "only a number counts")
  t.eq(F.talks({ wizard = 2, watch = false }), true, "wizard-saved config talks, even with watching off (plain lines)")
  local wdir = t.tmpdir()
  FW.save(wdir, { chatter = "chatty" }, { brain = false, apps = {} })
  t.eq(F.talks(dofile(wdir .. "/config.lua")), true, "a config the wizard saved talks")
  t.eq(F.talks(nil), false, "no config does not talk")
  -- gates: legacy configs (lines = false), quiet, busy, private windows
  sd = secondOpen({ lines = false, brain = true })
  t.eq(#sd, 0, "legacy config: counted but silent")
  sd, qs = secondOpen({ quiet = true, brain = true })
  t.eq(#sd + #qs, 0, "muted or only-when-clicked: silent")
  sd = secondOpen({ privacy = { private = function() return false end, busy = function() return true end, watching = function() return true end } })
  t.eq(#sd, 0, "busy (call, game): silent")
  local priv = F.new(t.tmpdir() .. "/t4.json")
  local o5 = fakes({ privacy = { private = function() return true end, busy = function() return false end, watching = function() return true end } })
  t.eq(F.tick(priv, o5), nil, "private window is not counted")
  t.eq(priv:get("youtube", 0).opens, 0, "nothing recorded for a private window")
  local o6 = fakes({ bid = "" })
  t.eq(F.tick(priv, o6), nil, "no bundle id is skipped")

  -- hands-free watching: a long silence with the same tab is the same visit
  local hb = os.time({ year = 2026, month = 3, day = 10, hour = 14 })
  local fg = F.new(t.tmpdir() .. "/gap.json")
  for i = 0, 6 do fg:observe("youtube", "YouTube", hb + i * 10) end
  t.eq(fg:get("youtube", hb + 60).opens, 1, "first visit counts one open")
  t.ok(not fg:observe("youtube", "YouTube", hb + 60 + 480), "the same key after an 8 minute gap is not a new open")
  t.eq(fg:get("youtube", hb + 540).opens, 1, "opens unchanged across the gap")
  fg:observe("mail", "Mail", hb + 600)
  t.ok(fg:observe("youtube", "YouTube", hb + 700), "a different key in between and 60 s away: a new open")
  t.eq(fg:get("youtube", hb + 700).opens, 2, "two opens")
  -- watched without touching the mouse: observed every few seconds, minutes are credited
  local fv = F.new(t.tmpdir() .. "/video.json")
  local opened = 0
  for i = 0, 96 do if fv:observe("youtube", "YouTube", hb + i * 5) then opened = opened + 1 end end
  t.eq(opened, 1, "an 8 minute video is one open")
  t.ok(fv:get("youtube", hb + 480).seconds >= 470, "its minutes are credited")
  t.ok(fv:line("youtube", "YouTube", hb + 480) == nil, "and nothing to say about it")
  -- midnight still starts today's first open for the same key
  local fm2 = F.new(t.tmpdir() .. "/midnight.json")
  fm2:observe("yt", "YouTube", os.time({ year = 2026, month = 3, day = 10, hour = 23, min = 59 }))
  t.ok(fm2:observe("yt", "YouTube", os.time({ year = 2026, month = 3, day = 11, hour = 0, min = 20 })), "a gap over midnight is today's first open")
  -- what it does for each state of you
  t.eq(F.stage("active"), "talk", "active: count and talk")
  t.eq(F.stage("bored"), "count", "bored: keep counting, say nothing")
  t.eq(F.stage("asleep"), nil, "asleep: nothing counts")
  t.eq(F.stage(nil), nil, "no state: nothing counts")

  -- a brain line is checked again when it lands
  local function late(gate, reply)
    local st = F.new(t.tmpdir() .. "/late.json")
    local o7, said7 = fakes({ gate = gate })
    local pending
    o7.brain = { busy = function() return false end, quip = function(_, done) pending = done; return true end }
    o7.t = base
    stayOn(st, o7, "cats - YouTube", base + 20)
    stayOn(st, o7, "Inbox - Mail", base + 100)
    stayOn(st, o7, "cats - YouTube", base + 200)
    t.ok(pending ~= nil, "a quip was asked for")
    pending(reply)
    return said7
  end
  local okGate = { muted = false, quietFor = 60, watching = true, busy = false }
  local function with(over) local g = {}; for k, v in pairs(okGate) do g[k] = v end; for k, v in pairs(over) do g[k] = v end; return function() return g end end
  t.eq(late(with({}), "Candid.")[1], "Candid.", "delivered when the gates are still open")
  t.eq(#late(with({ muted = true }), "Candid."), 0, "dropped when muted by the time it lands")
  t.eq(#late(with({ quietFor = -1 }), "Candid."), 0, "dropped on only-when-clicked")
  t.eq(#late(with({ busy = true }), "Candid."), 0, "dropped when a call or full screen started")
  t.eq(#late(with({ watching = false }), "Candid."), 0, "a brain line is dropped when watching went off")
  t.eq(late(with({ watching = false }), nil)[1], "YouTube again!", "the plain fallback needs no watching")
  t.eq(#late(with({ busy = true }), nil), 0, "the plain fallback is gated too")
  t.eq(late(function() return {} end, "Hm.")[1], nil, "an empty gate table lacks watching: a brain line is dropped")
  t.eq(F.mayDeliver({ watching = true }, true), true, "mayDeliver with everything open")

  -- the window in front, as a summary for a screen quip
  local fa = F.new(t.tmpdir() .. "/about.json")
  for i = 0, 6 do fa:observe("youtube", "YouTube", hb + i * 10) end
  local win = { app = "Chrome", title = "cats - YouTube", bid = "com.google.Chrome" }
  t.eq(fa:aboutWindow(win, true, rules, hb + 70), "YouTube: 1st time today, 1 min so far", "a counted window is described")
  t.eq(fa:aboutWindow({ app = "Chrome", title = "Never seen - Nowhere", bid = "com.google.Chrome" }, true, rules, hb + 70), nil, "an unseen window has nothing to say")
  t.eq(fa:aboutWindow({ app = "X", title = "y", bid = "" }, false, rules, hb), nil, "no bundle id: nothing")
  t.eq(fa:aboutWindow(nil, false, rules, hb), nil, "no window: nothing")
end
