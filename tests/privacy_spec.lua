-- Privacy: the watching switch, pause, private windows, busy moments and Forget.
return function(t, dir)
  -- The live buddy keeps a pause and the day it first met you in settings; the specs set both
  -- aside first (a saved pause would fail the "watching" checks) and put them back after.
  local KEY, MET = "claudeBuddy.watchPausedUntil", "claudeBuddy.metAt"
  local savedPause, savedMet = hs.settings.get(KEY), hs.settings.get(MET)
  hs.settings.set(KEY, nil)
  local ok, err = pcall(function()
  local P = dofile(dir .. "/privacy.lua")

  -- busy moments: calls, meetings, full screen, games
  P.configure({})
  t.ok(P.busy("us.zoom.xos", "", false, "idle"), "Zoom is busy")
  t.ok(P.busy("x", "", true, "idle"), "full screen is busy")
  t.ok(P.busy("x", "", false, "gaming"), "gaming is busy")
  t.ok(P.busy("x", "", false, "call"), "a call is busy")
  t.ok(P.busy("com.google.Chrome", "Standup - Google Meet", false, "idle"), "a Meet tab is busy")
  t.ok(not P.busy("x", "Docs", false, "idle"), "plain work is not busy")

  -- the switch
  t.ok(P.configure({}).watching(), "no watch key: watching")
  t.ok(not P.configure({ watch = false }).watching(), "watch = false: not watching")
  t.ok(P.configure({ watch = true }).watching(), "watch = true: watching")

  -- pause (the setting is saved and restored by the wrapper above)
  P.configure({})
  P.pause(3600, 1000)
  t.ok(not P.watching(2000), "paused at 2000")
  t.eq(P.pausedUntil(2000), 4600, "pausedUntil")
  t.ok(P.watching(4601), "watching again at 4601")
  t.eq(P.pausedUntil(4601), nil, "no pause left once it ends")
  P.pause(3600, 1000)
  P.resume()
  t.ok(P.watching(2000), "resume ends the pause")
  t.eq(hs.settings.get(KEY), nil, "resume clears the setting")
  P.pause(3600, 1000)
  t.eq(P.configure({}).pausedUntil(2000), 4600, "a pause survives a reload")
  P.configure({ watch = false })
  P.pause(60, 1000)
  t.ok(not P.watching(5000), "watch = false stays off after a pause ends")

  -- until morning: next local 06:00
  local function at(h) return os.time({ year = 2026, month = 3, day = 10, hour = h, min = 0, sec = 0 }) end
  local late = P.pauseUntilMorning(at(23))
  t.eq(os.date("%Y-%m-%d %H:%M", late), "2026-03-11 06:00", "23:00 -> tomorrow 06:00")
  local early = P.pauseUntilMorning(at(3))
  t.eq(os.date("%Y-%m-%d %H:%M", early), "2026-03-10 06:00", "03:00 -> today 06:00")
  t.eq(P.pausedUntil(at(3)), early, "pauseUntilMorning pauses")
  hs.settings.set(KEY, nil)

  -- private windows
  P.configure({ never_look = { "x.y" } })
  t.ok(P.private("com.bitwarden.desktop", "Bitwarden", ""), "password manager app")
  t.ok(P.private("com.apple.Passwords", "Passwords", ""), "Passwords app")
  t.ok(P.private(nil, "Chrome", "Chase Bank - Sign in"), "bank title")
  t.ok(P.private("x.y", "X", ""), "never_look bundle id")
  t.ok(not P.private("com.apple.Safari", "Safari", "Recipes"), "ordinary window")
  P.configure({ ai = { private = { "Tax Return" } } })
  t.ok(P.private("a.b", "Preview", "2025 tax return.pdf"), "configured private word, any case")

  -- Forget
  local s2 = hs.settings.get("claudeBuddy.appSeconds")
  local s3 = hs.settings.get("claudeBuddy.askedToTeach")
  hs.settings.set("claudeBuddy.appSeconds", { a = 1 })
  hs.settings.set("claudeBuddy.askedToTeach", { a = true })
  local calls = { brain = 0, chat = 0, store = 0 }
  P.forget({
    brain = { forget = function() calls.brain = calls.brain + 1 end },
    chat = { forget = function() calls.chat = calls.chat + 1 end },
    stores = { { wipe = function() calls.store = calls.store + 1 end }, { wipe = function() calls.store = calls.store + 1 end } },
  })
  t.eq(calls.brain, 1, "forget: brain once")
  t.eq(calls.chat, 1, "forget: chat once")
  t.eq(calls.store, 2, "forget: each store once")
  t.eq(hs.settings.get("claudeBuddy.appSeconds"), nil, "forget clears app habits")
  t.eq(hs.settings.get("claudeBuddy.askedToTeach"), nil, "forget clears the teaching flags")
  -- Forget starts the friendship over: the day they met is now, so the persona is "new" again
  hs.settings.set(MET, os.time() - 90 * 86400)
  P.forget({})
  t.ok(math.abs(tonumber(hs.settings.get(MET)) - os.time()) <= 2, "forget resets the day you met to now")
  hs.settings.set("claudeBuddy.appSeconds", s2)
  hs.settings.set("claudeBuddy.askedToTeach", s3)

  -- the "I peek at your screen" notice: only when it will actually look
  t.eq(P.willLook({ brain = true, watching = true, auto = true }), true, "brain, watching, Auto: looks")
  t.eq(P.willLook({ brain = true, watching = true, health = true }), true, "brain, watching, health spotting: looks")
  t.eq(P.willLook({ brain = false, watching = true, health = true, auto = true }), false, "no brain: never looks")
  t.eq(P.willLook({ brain = true, watching = false, health = true, auto = true }), false, "watching off: never looks")
  t.eq(P.willLook({ brain = true, watching = true }), false, "nothing that looks is on")
  t.eq(P.willLook({ brain = true, watching = true, auto = false, health = false }), false, "both off")

  -- the brain asks Privacy
  local B = dofile(dir .. "/brain.lua")
  t.ok(B.private("Chrome", "My Bank", nil), "brain alone: built-in private words")
  t.ok(not B.private("Chrome", "Recipes", nil), "brain alone: ordinary window")
  t.ok(B.snapshot(nil) == nil, "no window, no snapshot")
  local ctx = { kind = "session", app = "Chrome", title = "Bank", winId = 7, topic = "fix login", facts = { "x" }, mins = 3 }
  local on = B.scrub(ctx)
  t.eq(on.title, "Bank", "watching: title kept")
  t.eq(on.topic, "fix login", "watching: topic kept")
  P.configure({ watch = false })
  B.setPrivacy(P)
  local off = B.scrub(ctx)
  t.eq(off.app, nil, "not watching: no app")
  t.eq(off.title, nil, "not watching: no title")
  t.eq(off.winId, nil, "not watching: no window")
  t.eq(off.topic, nil, "not watching: no session name")
  t.eq(off.facts, nil, "not watching: no facts")
  t.eq(off.kind, "session", "not watching: other fields kept")
  t.eq(ctx.title, "Bank", "scrub copies, never edits")
  t.ok(B.snapshot(5) == nil, "not watching: no snapshot")
  P.configure({ ai = { private = { "tax" } } })
  B.setPrivacy(P)
  t.ok(B.private("Preview", "tax 2025", nil), "brain follows Privacy's words")
  t.ok(B.private("Chrome", "Recipes", "com.1password.1password"), "brain follows Privacy's apps")
  end)
  hs.settings.set(KEY, savedPause)
  hs.settings.set(MET, savedMet)
  if not ok then error(err, 0) end
end
