-- Buddy's small talk on a pretend desktop (the sandbox's S.front and S.windows): what a log
-- of 5,000 real lines showed he got wrong. A line every 50 s while you sat still, a fresh
-- arrival at every flip between two windows, three lines for one switch, and system pop-ups
-- greeted as apps.
return function(t, dir)
  local sandbox = dofile(dir .. "/tests/buddy_sandbox.lua")
  local function app(bid, name, pid)
    return { pid = function() return pid end, bundleID = function() return bid end, name = function() return name end,
      focusedWindow = function() return nil end }
  end
  local function row(pid, id, title, owner)
    return { kCGWindowLayer = 0, kCGWindowBounds = { X = 0, Y = 0, Width = 800, Height = 600 }, kCGWindowOwnerPID = pid,
      kCGWindowName = title, kCGWindowNumber = id, kCGWindowOwnerName = owner }
  end
  local MAIL = { app("com.apple.mail", "Mail", 11), row(11, 101, "Inbox", "Mail") }
  local PREVIEW = { app("com.apple.Preview", "Preview", 12), row(12, 102, "plan.pdf", "Preview") }
  local ZETA = { app("com.example.zeta", "Zeta", 13), row(13, 103, "Zeta", "Zeta") }
  local POPUP = { app("com.apple.UserNotificationCenter", "UserNotificationCenter", 14),
    row(14, 104, "", "UserNotificationCenter") }
  local function start(cfg)
    local c = { chatter = "chatty", wizard = 2, watch = true, halloween = false }
    for k, v in pairs(cfg or {}) do c[k] = v end
    local S = sandbox(dir, c)
    S.step(1, 30); S.poll() -- past the hello
    for i = #S.said, 1, -1 do S.said[i] = nil end
    return S
  end
  -- be in a window for secs seconds, looked at once a second
  local function be(S, where, secs)
    S.front, S.windows = where[1], { where[2] }
    for _ = 1, secs do S.step(1, 1); S.poll() end
  end
  local function dupes(list)
    local seen, n = {}, 0
    for _, line in ipairs(list) do
      if seen[line] then n = n + 1 end
      seen[line] = true
    end
    return n
  end
  local function has(list, a, b)
    for _, line in ipairs(list) do
      if line:find(a, 1, true) and (not b or line:find(b, 1, true)) then return true end
    end
    return false
  end
  local function all(S) return " [" .. table.concat(S.said, " | ") .. "]" end

  -- sitting in one window
  local S = start()
  be(S, MAIL, 600)
  t.ok(#S.said >= 2 and #S.said <= 5, "ten minutes in one window: a few lines, not a dozen" .. all(S))
  t.eq(dupes(S.said), 0, "and none of them twice")
  t.eq(#S.errors, 0, "no errors: " .. tostring(S.errors[1]))
  S.done()

  -- passing through a window
  S = start()
  be(S, MAIL, 20); be(S, ZETA, 1); be(S, MAIL, 20)
  t.ok(not has(S.said, "Zeta"), "a window you pass through gets no remark" .. all(S))
  t.eq(#S.said, 1, "and coming back to Mail isn't a second arrival")
  S.done()

  -- flipping between two windows
  S = start()
  for _ = 1, 8 do be(S, MAIL, 20); be(S, PREVIEW, 20) end
  t.ok(#S.said <= 6, "five minutes of flipping: a handful of lines, not one per flip" .. all(S))
  t.ok(has(S.said, "Mail", "Preview"), "he notices the two windows are one job")
  t.eq(dupes(S.said), 0, "and says nothing twice")
  t.eq(#S.errors, 0, "no errors: " .. tostring(S.errors[1]))
  S.done()

  -- somewhere new right after a back-and-forth is still an arrival
  S = start()
  for _ = 1, 2 do be(S, MAIL, 20); be(S, PREVIEW, 20) end
  be(S, ZETA, 10)
  t.ok(has(S.said, "Zeta"), "a third window gets its own remark" .. all(S))
  S.done()

  -- he has used up his own lines for now, and you open something new: it still gets a remark
  S = start()
  be(S, MAIL, 60); be(S, PREVIEW, 115)
  t.eq(#S.said, 4, "two arrivals and two lines of his own" .. all(S))
  be(S, ZETA, 10)
  t.ok(has(S.said, "Zeta"), "a new window gets its remark even when he's out of filler" .. all(S))
  S.done()

  -- with a brain: a window he doesn't know gets his look at the screen, not a stock line too,
  -- and the two-window job is handed to the brain with both windows named
  local asked = {}
  local brain = setmetatable({ busy = function() return false end, private = function() return false end,
    quip = function(ctx, done) asked[#asked + 1] = ctx; done("Brain line " .. #asked .. "."); return true end },
    { __index = function(B, k)
      if k == "configure" then return function() return B end end
      return function() return nil end
    end })
  local function startBrainy()
    local B = sandbox(dir, { chatter = "chatty", wizard = 2, watch = true, halloween = false, ai = { engine = "ollama" } },
      { stubs = { ["brain.lua"] = brain } })
    B.step(1, 30); B.poll()
    for i = #B.said, 1, -1 do B.said[i] = nil end
    for i = #asked, 1, -1 do asked[i] = nil end
    return B
  end
  S = startBrainy()
  be(S, ZETA, 12)
  t.eq(#S.said, 1, "one remark for a window he doesn't know" .. all(S))
  t.eq(S.said[1], "Brain line 1.", "and it's his look at the screen")
  t.eq(asked[1] and asked[1].kind, "screen", "asked for as a look")
  S.done()
  S = startBrainy()
  for _ = 1, 2 do be(S, MAIL, 20); be(S, PREVIEW, 20) end
  local wfAsk
  for _, ctx in ipairs(asked) do if ctx.kind == "workflow" then wfAsk = ctx end end
  t.ok(wfAsk ~= nil, "the brain is asked about the two-window job" .. all(S))
  t.eq(wfAsk and wfAsk.a, "Mail (window: Inbox)", "with the first window and its title")
  t.eq(wfAsk and wfAsk.b, "Preview (window: plan.pdf)", "and the second")
  t.ok(wfAsk and wfAsk.unprompted == true and wfAsk.flips == 3, "as a line he starts himself, with the flips so far")
  S.done()

  -- Buddy's own panel in front (the chat, a menu): no remark about the window behind it
  S = start()
  local OWN = { app("org.hammerspoon.Hammerspoon", "Hammerspoon", 15), row(15, 105, "", "Hammerspoon") }
  be(S, MAIL, 1); be(S, OWN, 10)
  t.eq(#S.said, 0, "nothing is said while his own panel is in front" .. all(S))
  be(S, MAIL, 5)
  t.eq(#S.said, 1, "the remark comes once you're back in the window" .. all(S))
  S.done()

  -- starting up: hello, and nothing before it
  S = sandbox(dir, { chatter = "chatty", wizard = 2, watch = true, halloween = false })
  t.eq(#S.said, 1, "at start he says hello and nothing else [" .. table.concat(S.said, " | ") .. "]")
  S.done()

  -- a system pop-up
  S = start()
  be(S, MAIL, 20); be(S, POPUP, 10); be(S, MAIL, 20)
  t.ok(not has(S.said, "UserNotificationCenter"), "a system pop-up isn't an app to remark on" .. all(S))
  t.eq(#S.said, 1, "and Mail after it isn't a new arrival")
  S.done()

  -- one switch, one line: the count is the remark when there's one to make
  S = start()
  be(S, MAIL, 30); be(S, PREVIEW, 200)
  local n = #S.said
  be(S, MAIL, 10)
  t.eq(S.said[n + 1], "Mail again!", "back after a few minutes: the count is the arrival remark" .. all(S))
  t.eq(#S.said, n + 1, "and it's the only line for that switch")
  S.done()
  S = start()
  for _ = 1, 4 do be(S, MAIL, 70); be(S, PREVIEW, 70) end
  t.ok(not has(S.said, "again!") and not has(S.said, "time today"), "flipping doesn't run up 'again!' lines" .. all(S))
  S.done()

  -- with watching paused he doesn't study the pattern
  S = start()
  S.M.pauseWatching(3600)
  for i = #S.said, 1, -1 do S.said[i] = nil end
  for _ = 1, 4 do be(S, MAIL, 20); be(S, PREVIEW, 20) end
  t.ok(not has(S.said, "Mail", "Preview"), "no workflow line while watching is paused" .. all(S))
  S.M.resumeWatching()
  S.done()

  -- a reaction written for an app is known; a whole browser or a terminal is not
  S = start()
  t.eq(S.M.knownMood("com.anthropic.claudefordesktop", "Claude", "", false), "love", "the Claude app has its own reaction")
  t.eq(S.M.knownMood("com.google.Chrome", "Google Chrome", "cats - youtube", true), "watching", "so does a site with a title rule")
  t.eq(S.M.knownMood("com.google.Chrome", "Google Chrome", "some page", true), nil, "a browser as a whole does not")
  t.eq(S.M.knownMood("com.apple.Terminal", "Terminal", "zsh", false), nil, "nor a plain terminal")
  t.eq(S.M.knownMood("com.example.zeta", "Zeta", "", false), nil, "nor an app nobody wrote one for")

  -- a session's name is matched by whole words (or their starts), not by letters inside one
  local function pool(topic) return table.concat(S.M.sessionPool(topic, "wait"), "|") end
  t.ok(pool("Plan the launch"):find("Planning mode", 1, true), "a session about a plan gets the planning lines")
  t.ok(pool("Planning Q3"):find("Planning mode", 1, true), "the start of a word counts")
  t.ok(not pool("Explanation of prefixes"):find("Planning mode", 1, true), "'explanation' is not a plan")
  t.ok(not pool("Explanation of prefixes"):find("Bug hunt", 1, true), "and 'prefixes' is not a fix")
  t.ok(not pool("Mouse buttons for voice"):find("calling", 1, true), "voice isn't a phone call")
  t.ok(pool("Phone call script"):find("calling", 1, true), "a phone call is")
  S.done()
end
