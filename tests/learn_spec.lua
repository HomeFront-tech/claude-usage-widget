-- learn.lua: what it has seen per app or site, when to ask the brain, and what it keeps.
return function(t, dir)
  local L = dofile(dir .. "/learn.lua")
  local moods = { watching = "videos and shows", reading = "documents and spreadsheets", coding = "writing code" }
  local path = t.tmpdir() .. "/learn/learn.json"
  local t0 = os.time({ year = 2026, month = 3, day = 10, hour = 9 })

  -- a fake brain that records the request and answers with a canned result
  local calls, canned = {}, { mood = "watching" }
  local brain = {
    classify = function(req, done)
      calls[#calls + 1] = req
      done(canned)
      return true
    end,
  }
  local on = { watching = function() return true end }
  local off = { watching = function() return false end }

  local l = L.new(path, moods)
  local function watch(key, secs, title, from)
    for i = 0, secs / 10 do l:observe(key, "YouTube", title or "cats", (from or t0) + i * 10) end
  end

  -- due: 120 s with no profile
  l:observe("yt", "YouTube", "cats", t0)
  t.ok(not l:due("yt", t0), "not due on the first look")
  for i = 1, 6 do l:observe("yt", "YouTube", "cats", t0 + i * 10) end
  t.ok(not l:due("yt", t0 + 60), "not due at 60 s")
  for i = 7, 12 do l:observe("yt", "YouTube", "cats", t0 + i * 10) end
  t.ok(l:due("yt", t0 + 120), "due at 120 s")
  t.ok(not l:due("nothing", t0), "an unseen key is not due")
  t.eq(l:moodFor("yt", t0), nil, "no mood before it has decided")

  -- titles: at most 8 distinct, each at most 80 characters
  local l2 = L.new(t.tmpdir() .. "/titles.json", moods)
  for i = 1, 12 do l2:observe("a", "A", "title " .. i, t0 + i) end
  l2:observe("a", "A", "title 12", t0 + 13)
  l2:observe("a", "A", ("x"):rep(200), t0 + 14)
  local req
  l2:decide("a", "A", { t = t0 }, { classify = function(r, done) req = r; done(nil); return true end }, on, function() end)
  t.eq(#req.titles, 8, "eight recent titles kept")
  t.eq(#req.titles[1], 80, "a long title is cut to 80")
  t.eq(req.titles[2], "title 12", "newest first")
  t.eq(req.moods, moods, "the mood list goes with the request")

  -- decide stores the mood
  local got
  t.ok(l:decide("yt", "YouTube", { t = t0 + 120, facts = "YouTube: 2nd time today", image = "QUJD" }, brain, on,
    function(r) got = r end), "decide starts")
  t.eq(calls[1].label, "YouTube", "label sent")
  t.eq(calls[1].facts, "YouTube: 2nd time today", "facts sent")
  t.eq(calls[1].image, "QUJD", "snapshot sent")
  t.eq(calls[1].titles[1], "cats", "titles sent")
  t.eq(l:moodFor("yt", t0 + 120), "watching", "mood stored")
  t.eq(got.mood, "watching", "done gets the result")
  t.ok(not l:due("yt", t0 + 120), "not due right after deciding")

  -- dayparts win over the app's mood
  canned = { mood = "coding", dayparts = { evening = "watching", morning = "reading" } }
  l:observe("w", "Work", "x", t0)
  l:decide("w", "Work", { t = t0 }, brain, on, function() end)
  local function at(h) return os.time({ year = 2026, month = 3, day = 11, hour = h }) end
  t.eq(l:moodFor("w", at(19)), "watching", "evening mood")
  t.eq(l:moodFor("w", at(8)), "reading", "morning mood")
  t.eq(l:moodFor("w", at(14)), "coding", "afternoon falls back to the app's mood")

  -- an invalid mood is dropped
  canned = { mood = "coding", dayparts = { night = "party", evening = "reading" } }
  l:observe("v", "V", "x", t0)
  l:decide("v", "V", { t = t0 }, brain, on, function() end)
  t.eq(l:moodFor("v", at(23)), "coding", "unknown daypart mood dropped")
  t.eq(l:moodFor("v", at(19)), "reading", "valid daypart mood kept")
  canned = { mood = "party" }
  l:observe("u", "U", "x", t0)
  local failed = "unset"
  l:decide("u", "U", { t = t0 }, brain, on, function(r) failed = r end)
  t.eq(l:moodFor("u", t0), nil, "unknown mood stores nothing")
  t.eq(failed, nil, "done gets nil")
  t.ok(not l:due("u", t0), "a failed look waits for another 120 s")

  -- a repeat look: 3600 s new and 24 h since
  l.apps.yt.fresh = 3600
  t.ok(not l:due("yt", t0 + 120 + 3600), "an hour new but under 24 h since")
  t.ok(l:due("yt", t0 + 120 + 86400), "an hour new and a day since")
  l.apps.yt.fresh = 3599
  t.ok(not l:due("yt", t0 + 120 + 86400), "under an hour new")

  -- watching off: nothing is sent
  local n = #calls
  t.ok(not l:decide("yt", "YouTube", { t = t0 }, brain, off, function() error("no callback") end), "not started")
  t.eq(#calls, n, "nothing sent while not watching")

  -- watching turned off before the answer: nothing stored, no question
  local watching, finish = true, nil
  local late = { watching = function() return watching end }
  local slow = { classify = function(r, done) finish = done; return true end }
  l:observe("z", "Z", "x", t0)
  local lateResult = "unset"
  l:decide("z", "Z", { t = t0 }, slow, late, function(r) lateResult = r end)
  watching = false
  finish({ mood = "watching", question = "Is this a show?" })
  t.eq(l:moodFor("z", t0), nil, "late answer not stored")
  t.eq(lateResult, nil, "late answer gives no question")

  -- the question comes back with the result
  watching = true
  l:observe("q", "Q", "x", t0)
  canned = { mood = "reading", question = "Is Q for work?" }
  l:decide("q", "Q", { t = t0 }, brain, on, function(r) got = r end)
  t.eq(got.question, "Is Q for work?", "question returned")

  -- Forget while the brain is thinking: the late answer is dropped
  local finish2
  l:observe("f", "F", "x", t0)
  l:decide("f", "F", { t = t0 }, { classify = function(r, done) finish2 = done; return true end }, on, function() end)
  l:wipe()
  finish2({ mood = "watching" })
  t.eq(l:moodFor("f", t0), nil, "an answer after wipe is dropped")

  -- questions: at most 3 a day
  local q = L.new(t.tmpdir() .. "/q.json", moods)
  t.ok(q:canAsk(t0), "can ask at first")
  q:asked(t0); q:asked(t0 + 60); q:asked(t0 + 120)
  t.ok(not q:canAsk(t0 + 180), "three asked: no more today")
  t.ok(q:canAsk(t0 + 86400), "fine again the next day")
  q:save()
  t.ok(not L.new(q.path, moods):canAsk(t0 + 180), "the count survives a reload")

  -- save, reload, corrupt file, wipe
  local l3 = L.new(t.tmpdir() .. "/keep.json", moods)
  l3:observe("yt", "YouTube", "cats", t0)
  canned = { mood = "watching", dayparts = { evening = "reading" } }
  l3:decide("yt", "YouTube", { t = t0 }, brain, on, function() end)
  t.ok(l3:save(), "saves")
  local l4 = L.new(l3.path, moods)
  t.eq(l4:moodFor("yt", at(14)), "watching", "mood reloads")
  t.eq(l4:moodFor("yt", at(19)), "reading", "daypart reloads")
  local fh = io.open(l3.path, "w"); fh:write("{nope"); fh:close()
  t.eq(L.new(l3.path, moods):moodFor("yt", at(14)), nil, "corrupt file loads empty")
  fh = io.open(l3.path, "w"); fh:write("[1,2]"); fh:close()
  t.eq(L.new(l3.path, moods):moodFor("yt", at(14)), nil, "wrong shape loads empty")
  l4:wipe()
  t.eq(l4:moodFor("yt", at(14)), nil, "wipe empties memory")
  t.ok(hs.fs.attributes(l4.path) == nil, "wipe deletes the file")

  -- saved moods that are no longer on the list are dropped
  l3 = L.new(t.tmpdir() .. "/stale.json", moods)
  l3:observe("yt", "YouTube", "cats", t0)
  l3:decide("yt", "YouTube", { t = t0 }, brain, on, function() end)
  l3:save()
  t.eq(L.new(l3.path, { coding = "x" }):moodFor("yt", at(14)), nil, "a mood that left the list is dropped")

  -- a long list is trimmed to the most recent apps on save
  local many = L.new(t.tmpdir() .. "/many.json", moods)
  for i = 1, 320 do many:observe("app" .. i, "App", nil, t0 + i * 100) end
  many:save()
  t.ok(many.apps.app320 and not many.apps.app1, "oldest apps dropped past 300")

  -- a learning look: the ponder pose is held until the answer lands, and a question is
  -- checked again then (full screen, calls, muted, 3 a day)
  local function look(opts)
    local lk = L.new(t.tmpdir() .. "/look.json", moods)
    lk:observe("yt", "YouTube", "cats", t0)
    local state = { ponder = nil, said = {}, finish = nil, full = false, hushed = false }
    local o = {
      t = t0, image = opts.image, privacy = opts.privacy or on, now = function() return t0 end,
      brain = { classify = function(_, done) state.finish = done; return opts.start ~= false end },
      ponder = function(p) state.ponder = p end,
      hushed = function() return state.hushed end,
      busy = function() return state.full end,
      say = function(q) state.said[#state.said + 1] = q end,
    }
    state.started = lk:look("yt", "YouTube", o)
    return lk, state
  end
  local lk, st = look({ image = "QUJD" })
  t.ok(st.started, "the look starts")
  t.eq(st.ponder, true, "ponder shows while a look with a snapshot is out")
  st.finish({ mood = "watching", question = "Is this a show?" })
  t.eq(st.ponder, false, "ponder clears when the answer lands")
  t.eq(st.said[1], "Is this a show?", "the question is said")
  t.eq(lk:moodFor("yt", t0), "watching", "the mood is stored")
  lk, st = look({})
  t.eq(st.ponder, nil, "no ponder without a snapshot")
  lk, st = look({ image = "QUJD" })
  st.full = true
  st.finish({ mood = "watching", question = "Is this a show?" })
  t.eq(#st.said, 0, "full screen at answer time: no question")
  t.eq(lk:moodFor("yt", t0), "watching", "the mood is still stored")
  t.ok(lk:canAsk(t0), "an unasked question is not counted")
  lk, st = look({ image = "QUJD" })
  st.hushed = true
  st.finish({ mood = "watching", question = "Is this a show?" })
  t.eq(#st.said, 0, "muted at answer time: no question")
  lk, st = look({ image = "QUJD" })
  st.finish({ mood = "bogus", question = "Hm?" })
  t.eq(st.ponder, false, "ponder clears when the answer is unusable")
  t.eq(#st.said, 0, "no question from an unusable answer")
  lk, st = look({ image = "QUJD", start = false })
  t.eq(st.started, false, "a look that can't start reports it")
  t.eq(st.ponder, false, "ponder clears when the look can't start")
  lk, st = look({ image = "QUJD", privacy = off })
  t.eq(st.ponder, false, "ponder clears when watching is off")
  lk, st = look({ image = "QUJD" })
  lk:asked(t0); lk:asked(t0); lk:asked(t0)
  st.finish({ mood = "watching", question = "Again?" })
  t.eq(#st.said, 0, "no fourth question in a day")
  lk, st = look({ image = "QUJD" })
  st.finish(nil)
  t.eq(st.ponder, false, "ponder clears when the brain gives nothing")

  -- time spent while you sit back and watch (observed every second, as buddy.lua now does while bored)
  local lw = L.new(t.tmpdir() .. "/watchtime.json", moods)
  for i = 0, 480 do lw:observe("yt", "YouTube", "cats", t0 + i) end -- 8 minutes, one look a second
  t.ok(lw.apps.yt.fresh >= 479, "eight minutes of hands-free watching are credited")
  t.ok(lw:due("yt", t0 + 480), "and it is due for its first look")
  local lg = L.new(t.tmpdir() .. "/gap.json", moods)
  lg:observe("yt", "YouTube", "cats", t0)
  lg:observe("yt", "YouTube", "cats", t0 + 480) -- nothing looked for 8 minutes: that was not time spent
  t.ok(lg.apps.yt.fresh == 0, "a long silence between looks is not counted")

  -- reaction order: picks, then a Claude state, then what it learned, then the built-in
  local builtin = function() return "coding" end
  t.eq(L.reaction({ learned = "watching", watching = true, builtin = builtin }), "watching", "a plain terminal takes the learned mood")
  t.eq(L.reaction({ claude = "claudeWork", learned = "watching", watching = true, builtin = builtin }), "claudeWork", "a Claude title wins over the learned mood")
  t.eq(L.reaction({ picked = "music", claude = "claudeWork", learned = "watching", watching = true, builtin = builtin }), "music", "your pick wins over everything")
  t.eq(L.reaction({ builtin = builtin }), "coding", "nothing learned: the built-in")
  t.eq(L.reaction({ learned = "watching", watching = false, builtin = builtin }), "coding", "with watching off the learned mood is not used")
  t.eq(L.reaction({ learned = "watching", builtin = builtin }), "coding", "no watching flag: not used either")
  t.eq(L.reaction({ picked = "music", learned = "watching", watching = false, builtin = builtin }), "music", "your pick still applies with watching off")
  t.eq(L.reaction({ claude = "claudeWait", watching = false, builtin = builtin }), "claudeWait", "a Claude state still applies with watching off")

  -- a look that can't start (the daily cap): no snapshot, no ponder, and that app is left alone for a while
  local function capped(over)
    local lk = L.new(t.tmpdir() .. "/cap.json", moods)
    for i = 0, 13 do lk:observe("yt", "YouTube", "cats", t0 + i * 10) end -- 130 s: due
    local st = { shots = 0, ponder = {}, asked = 0 }
    local o = { t = t0 + 130, privacy = on, now = function() return t0 + 130 end,
      brain = { canClassify = function() return over.can end, classify = function() st.asked = st.asked + 1; return over.start ~= false end },
      snapshot = function() st.shots = st.shots + 1; return "QUJD" end,
      ponder = function(p) st.ponder[#st.ponder + 1] = p end,
      hushed = function() return false end, busy = function() return false end, say = function() end }
    t.ok(lk:due("yt", t0 + 130), "due before the look")
    st.started = lk:look("yt", "YouTube", o)
    return lk, st
  end
  local ck, cs = capped({ can = false })
  t.eq(cs.started, false, "a capped look reports it did not start")
  t.eq(cs.shots, 0, "no snapshot is taken when the brain can't start")
  t.eq(#cs.ponder, 0, "no ponder pose either")
  t.eq(cs.asked, 0, "classify is not even called")
  t.ok(not ck:due("yt", t0 + 130 + 30), "not due again 30 s later")
  t.ok(not ck:due("yt", t0 + 130 + 1700), "still held 28 minutes later")
  t.ok(ck:due("yt", t0 + 130 + 1800), "due again after 30 minutes")
  ck, cs = capped({ can = true })
  t.eq(cs.shots, 1, "the snapshot is taken once the brain can start")
  t.eq(cs.ponder[1], true, "ponder shows with that snapshot")
  ck, cs = capped({ can = true, start = false })
  t.eq(cs.started, false, "a classify that refuses reports it")
  t.eq(cs.ponder[#cs.ponder], false, "ponder clears")
  t.ok(not ck:due("yt", t0 + 130 + 60), "and that app is held back too")
  ck:wipe()
  ck:observe("yt", "YouTube", "cats", t0)
  t.eq(ck.holdUntil.yt, nil, "Forget clears the holds")

  -- the mood list for the brain: one-line meanings for the keys given
  local list = L.moodList({ "watching", "coding", "nope" })
  t.ok(list.watching and list.coding, "meanings for known keys")
  t.eq(list.nope, nil, "no meaning, no entry")
end
