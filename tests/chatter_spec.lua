-- chatter.lua: what Buddy has said lately, how often he may make small talk, and whether
-- you are going back and forth between the same two windows (one job, not many arrivals).
return function(t, dir)
  local Chatter = dofile(dir .. "/chatter.lua")
  local function new(over)
    local o = { level = "chatty", ambient = 50, jitter = false }
    for k, v in pairs(over or {}) do o[k] = v end
    return Chatter.new(o)
  end
  local T0 = os.time({ year = 2026, month = 3, day = 10, hour = 9 })

  -- lines: nothing twice inside 40 minutes, and silence beats a repeat
  local d = new()
  local pool = { "one", "two", "three" }
  local got = {}
  for i = 1, 3 do got[i] = d:choose(pool, T0 + i) end
  table.sort(got)
  t.eq(table.concat(got, " "), "one three two", "three picks from three lines are three different lines")
  t.eq(d:choose(pool, T0 + 10), nil, "with every line said lately it says nothing")
  t.eq(d:fresh("one", T0 + 10), false, "a line said a moment ago is not fresh")
  t.eq(d:fresh("one", T0 + 2500), true, "40 minutes later it is")
  t.ok(d:choose(pool, T0 + 2500) ~= nil, "and it can be picked again")
  d = new()
  d:mark("b", T0)
  t.eq(d:choose({ "a", "b" }, T0 + 1), "a", "a line said by some other route is skipped too")
  d = new()
  t.eq(d:choose({ "Hi %t!", "Yo %t!" }, T0, function(line) return line:gsub("%%t", "") end) ~= nil, true, "a key function names the line")
  t.eq(d:choose({}, T0), nil, "an empty list gives nothing")
  t.eq(d:choose(nil, T0), nil, "and so does no list")

  -- small talk: a gap between lines and a cap per ten minutes
  d = new()
  t.eq(d:can(T0), true, "the first bit of small talk is fine")
  d:spent(T0)
  t.eq(d:can(T0 + 2), false, "a remark 2 s after the last line is too soon")
  t.eq(d:can(T0 + 5), true, "5 s after is fine for arriving somewhere")
  t.eq(d:can(T0 + 5, "ambient"), false, "but a line of his own waits longer")
  t.eq(d:can(T0 + 13, "ambient"), true, "12 s on chatty")
  for i = 1, 5 do d:spent(T0 + 13 * i) end
  t.eq(d:can(T0 + 200), false, "six in ten minutes is the chatty limit")
  t.eq(d:can(T0 + 601), true, "the oldest one ages out")
  d = new({ level = "normal" })
  d:spent(T0)
  t.eq(d:can(T0 + 20, "ambient"), false, "normal waits longer between lines")
  t.eq(d:can(T0 + 31, "ambient"), true, "30 s on normal")
  t.eq(d:can(T0 + 8), false, "and 10 s before a remark on arriving")
  t.eq(d:can(T0 + 11), true, "then it's fine")
  d:spent(T0 + 31); d:spent(T0 + 70)
  t.eq(d:can(T0 + 200), false, "and allows three in ten minutes")
  d = new({ level = "quiet" })
  d:spent(T0)
  t.eq(d:can(T0 + 500), false, "quiet allows one in ten minutes")

  -- lines he makes by himself are the first to go: they leave room for real arrivals
  d = new()
  for i = 0, 3 do d:spent(T0 + 20 * i) end
  t.eq(d:can(T0 + 100, "ambient"), false, "four lines in ten minutes: no more filler on chatty")
  t.eq(d:can(T0 + 100), true, "but an arrival still gets its line")
  d = new({ level = "normal" })
  d:spent(T0); d:spent(T0 + 40)
  t.eq(d:can(T0 + 100, "ambient"), false, "two on normal")
  t.eq(d:can(T0 + 100), true, "with one left for an arrival")

  -- by himself: the longer you stay put, the longer he waits
  d = new()
  t.eq(d:ambientGap(), 50, "the first wait is the base")
  d:ambientSaid()
  t.eq(d:ambientGap(), 100, "then double")
  d:ambientSaid(); d:ambientSaid()
  t.eq(d:ambientGap(), 400, "up to eight times the base")
  d:ambientSaid()
  t.eq(d:ambientGap(), 400, "and no further")
  local j = Chatter.new({ level = "chatty", ambient = 100 })
  local lo, hi = math.huge, 0
  for _ = 1, 40 do
    j:ambientSaid()
    j.ambientN = 0
    lo, hi = math.min(lo, j:ambientGap()), math.max(hi, j:ambientGap())
  end
  t.ok(lo >= 85 and hi <= 125 and hi > lo, "the wait wobbles, so he isn't a metronome")

  -- stay(d, key, label, from, secs): be in a window, polled every second
  local function stay(dd, key, label, from, secs, group, glabel)
    local kinds = {}
    for s = 0, secs do
      dd:visit(key, label, from + s, group, glabel)
      local k = dd:settled(from + s)
      if k then kinds[#kinds + 1] = k end
    end
    return kinds[1], #kinds, from + secs + 1
  end

  -- arriving, passing through, coming back
  d = new()
  t.eq(d:visit("mail", "Mail", T0), "moved", "a new window is a move")
  t.eq(d:settled(T0), nil, "nothing is said the moment you land")
  t.eq(d:visit("mail", "Mail", T0 + 1), "same", "the next look is the same window")
  t.eq(d:settled(T0 + 2), nil, "still settling")
  t.eq(d:settled(T0 + 3), "arrival", "three seconds in, it's an arrival")
  t.eq(d:settled(T0 + 4), nil, "said once per visit")
  d = new()
  local kind, n, at = stay(d, "mail", "Mail", T0, 20)
  t.eq(kind, "arrival", "first window: an arrival"); t.eq(n, 1, "one per visit")
  kind, n, at = stay(d, "x", "X", at, 1)
  t.eq(kind, nil, "a window you pass through in a second gets no arrival")
  kind, n, at = stay(d, "mail", "Mail", at, 20)
  t.eq(kind, "return", "back in Mail a moment later is a return, not an arrival")
  kind, n, at = stay(d, "notes", "Notes", at, 20)
  t.eq(kind, "arrival", "somewhere new is an arrival")
  kind = stay(d, "mail", "Mail", at + 400, 20)
  t.eq(kind, "arrival", "back after more than three minutes away counts as arriving again")

  -- the ambient wait starts over on a real arrival, not on a return
  d = new()
  _, _, at = stay(d, "a", "A", T0, 10)
  d:ambientSaid(); d:ambientSaid()
  _, _, at = stay(d, "b", "B", at, 10)
  t.eq(d:ambientGap(), 50, "a new window starts the wait over")
  d:ambientSaid(); d:ambientSaid()
  _, _, at = stay(d, "a", "A", at, 10)
  t.eq(d:ambientGap(), 200, "flipping back does not")

  -- back and forth between two windows is one job
  d = new()
  at = T0
  _, _, at = stay(d, "code", "Editor", at, 30)
  _, _, at = stay(d, "web", "Preview site", at, 20)
  t.eq(d:workflow(at), nil, "one switch is not a pattern")
  _, _, at = stay(d, "code", "Editor", at, 30)
  t.eq(d:workflow(at), nil, "there and back is not one yet")
  kind, _, at = stay(d, "web", "Preview site", at, 20)
  local wf = d:workflow(at)
  t.ok(wf ~= nil, "A, B, A, B is a workflow")
  t.eq(kind, "return", "and landing in it is a return")
  t.eq(wf and (wf.a.label .. " + " .. wf.b.label), "Editor + Preview site", "it knows both windows, in the order you started")
  t.eq(wf and wf.flips, 3, "three flips so far")
  t.eq(wf and wf.since, T0, "since you first sat down in the first one")
  t.eq(d:workflowDue(at), true, "he may say so once")
  d:workflowSaid(at)
  t.eq(d:workflowDue(at + 60), false, "then not again for a while")
  t.eq(d:workflow(at).nextAt, at + 480, "eight minutes")
  d:workflowSaid(at + 200)
  t.eq(d:workflow(at + 200).nextAt, at + 200 + 900, "and the wait after that is longer")
  _, _, at = stay(d, "code", "Editor", at, 30)
  t.eq(d:workflow(at).flips, 4, "each flip is counted")
  t.eq(d:inWorkflow(at - 1), true, "the window in front is part of it")
  kind, _, at = stay(d, "chat", "Messages", at, 15)
  t.eq(kind, "arrival", "a third window is still an arrival")
  t.ok(d:workflow(at) ~= nil, "and a short trip elsewhere does not end the job")
  t.eq(d:inWorkflow(at - 1), false, "though that window is not part of it")
  kind, _, at = stay(d, "web", "Preview site", at, 20)
  t.eq(kind, "return", "back into it is a return")
  t.eq(d:workflow(at).flips, 5, "and counts as a flip")
  t.eq(d:workflow(at + 310), nil, "five minutes without a flip and the job is over")

  -- a window you pass through doesn't break the pattern
  d = new()
  at = T0
  _, _, at = stay(d, "a", "A", at, 10)
  _, _, at = stay(d, "b", "B", at, 10)
  _, _, at = stay(d, "zz", "Switcher", at, 1)
  _, _, at = stay(d, "a", "A", at, 10)
  _, _, at = stay(d, "b", "B", at, 10)
  t.ok(d:workflow(at) ~= nil, "a one-second stop in between is ignored")

  -- slow switching isn't a workflow; private windows never are
  d = new()
  at = T0
  for _ = 1, 3 do
    _, _, at = stay(d, "a", "A", at, 10); at = at + 400
    _, _, at = stay(d, "b", "B", at, 10); at = at + 400
  end
  t.eq(d:workflow(at), nil, "the same two windows minutes apart are not one job")
  d = new()
  at = T0
  for _ = 1, 3 do
    _, _, at = stay(d, Chatter.PRIVATE, nil, at, 10)
    _, _, at = stay(d, "b", "B", at, 10)
  end
  t.eq(d:workflow(at), nil, "a private window is never part of a workflow")

  -- three windows in rotation is not a pair
  d = new()
  at = T0
  for _ = 1, 2 do
    _, _, at = stay(d, "a", "A", at, 10)
    _, _, at = stay(d, "b", "B", at, 10)
    _, _, at = stay(d, "c", "C", at, 10)
  end
  t.eq(d:workflow(at), nil, "A, B, C in turn is not a two-window job")

  -- it remembers pairs: by group (every Claude Code session is "Claude Code"), across restarts
  local path = t.tmpdir() .. "/learn/workflows-" .. hs.host.uuid() .. ".json"
  d = new({ path = path })
  at = T0
  for _ = 1, 2 do
    _, _, at = stay(d, "win:1", "Fix the login page", at, 10, "claude-code", "Claude Code")
    _, _, at = stay(d, "localhost", "Localhost", at, 10)
  end
  wf = d:workflow(at)
  t.ok(wf ~= nil, "a session and a site make a workflow")
  local times, days = d:known(wf)
  t.eq(times, 1, "first time for this pair"); t.eq(days, 1, "on one day")
  d:save(at)
  local saved = t.readJson(path)
  local id = next(saved.pairs)
  t.ok(id:find("claude-code", 1, true) and id:find("localhost", 1, true), "saved under the groups, not the session's name")
  t.ok(not hs.json.encode(saved):find("login page", 1, true), "the session's name is not kept")
  local d2 = new({ path = path })
  at = T0 + 86400
  _, _, at = stay(d2, "win:9", "Another session", at, 10, "claude-code", "Claude Code")
  _, _, at = stay(d2, "localhost", "Localhost", at, 10)
  t.eq(d2:workflow(at), nil, "a pair seen once still needs the full pattern")
  _, _, at = stay(d2, "win:9", "Another session", at, 10, "claude-code", "Claude Code")
  _, _, at = stay(d2, "localhost", "Localhost", at, 10)
  times, days = d2:known(d2:workflow(at))
  t.eq(times, 2, "the second time is counted after a restart"); t.eq(days, 2, "on a second day")
  d2:save(at)
  local d3 = new({ path = path })
  at = T0 + 2 * 86400
  _, _, at = stay(d3, "win:4", "Third session", at, 10, "claude-code", "Claude Code")
  _, _, at = stay(d3, "localhost", "Localhost", at, 10)
  _, _, at = stay(d3, "win:4", "Third session", at, 10, "claude-code", "Claude Code")
  t.ok(d3:workflow(at) ~= nil, "a pair it knows is recognised one flip sooner")
  d3:wipe()
  t.eq(hs.fs.attributes(path), nil, "Forget deletes the file")
  t.eq(d3:workflow(at), nil, "and the workflow in progress")
  t.eq(d3:fresh("anything", at), true, "and what it said")
  local broken = t.tmpdir() .. "/workflows-broken.json"
  local f = assert(io.open(broken, "w")); f:write("{not json"); f:close()
  t.ok(new({ path = broken }):can(T0), "a damaged file is ignored")
  os.remove(broken)

  -- two Claude Code sessions: the same group twice is still a pair
  d = new()
  at = T0
  for _ = 1, 2 do
    _, _, at = stay(d, "win:1", "One", at, 10, "claude-code", "Claude Code")
    _, _, at = stay(d, "win:2", "Two", at, 10, "claude-code", "Claude Code")
  end
  wf = d:workflow(at)
  t.ok(wf and wf.a.group == wf.b.group, "two sessions make a workflow of one group")

  -- with watching off he still knows an arrival from a return, but learns no workflows
  d = new()
  d.watching = false
  at = T0
  for _ = 1, 3 do
    _, _, at = stay(d, "a", "A", at, 10)
    kind, _, at = stay(d, "b", "B", at, 10)
  end
  t.eq(d:workflow(at), nil, "no workflow while watching is off")
  t.eq(next(d.pairs), nil, "and no pair is remembered")
  t.eq(kind, "return", "a window you were just in is still a return")
  d = new()
  at = T0
  for _ = 1, 2 do
    _, _, at = stay(d, "a", "A", at, 10)
    _, _, at = stay(d, "b", "B", at, 10)
  end
  d.watching = false
  t.eq(d:workflow(at), nil, "turning watching off ends the workflow in progress")

  -- stepping away: when you're back the stay starts over, and so does the ambient wait
  d = new()
  stay(d, "a", "A", T0, 100)
  d:ambientSaid(); d:ambientSaid()
  d:rest()
  d:visit("a", "A", T0 + 2000)
  t.eq(d:stayed(T0 + 2010), 10, "after a break the stay starts over")
  t.eq(d:ambientGap(), 50, "and so does the wait")
  t.eq(d:settled(T0 + 2010), nil, "but the same window is not a new arrival")
  d = new()
  stay(d, "a", "A", T0, 100)
  d:visit("a", "A", T0 + 5000)
  t.eq(d:stayed(T0 + 5010), 10, "a long gap between looks (the Mac slept) starts the stay over too")

  -- how long you've been in this window
  d = new()
  stay(d, "a", "A", T0, 100)
  t.eq(d:stayed(T0 + 100), 100, "seconds in the window in front")
end
