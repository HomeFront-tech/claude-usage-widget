-- The IDE (Beta): which config turns it on, and which pages stay in its window.
return function(t, dir)
  local I = dofile(dir .. "/ide.lua")

  t.ok(I.isLocal("http://127.0.0.1:8750/"), "127.0.0.1 is this Mac")
  t.ok(I.isLocal("http://localhost:3000"), "localhost is this Mac")
  t.ok(I.isLocal("http://[::1]:8750/x"), "[::1] is this Mac")
  t.ok(not I.isLocal("https://example.com/"), "a website isn't")
  t.ok(not I.isLocal("http://127.0.0.1.evil.com/"), "a look-alike host isn't")
  t.ok(not I.isLocal("http://localhost@evil.com/"), "user@host tricks aren't")
  t.ok(not I.isLocal("file:///etc/passwd"), "files aren't")
  t.ok(not I.isLocal(nil), "nothing isn't")

  t.ok(I.sameOrigin("http://127.0.0.1:8750/api/x?y", "http://127.0.0.1:8750/"), "same page, other path")
  t.ok(not I.sameOrigin("http://127.0.0.1:9999/", "http://127.0.0.1:8750/"), "other port")
  t.ok(not I.sameOrigin("https://127.0.0.1:8750/", "http://127.0.0.1:8750/"), "other scheme")
  t.ok(not I.sameOrigin("http://localhost:8750/", "http://127.0.0.1:8750/"), "other host name")

  t.eq(I.settings(nil), nil, "off unless set")
  t.eq(I.settings(false), nil, "false is off")
  local s, why = I.settings({ url = "https://example.com" })
  t.ok(s == nil and why:find("this Mac", 1, true), "a website is refused")
  s, why = I.settings({ url = "http://127.0.0.1:8750/", start = "python3 hub.py" })
  t.ok(s == nil and why:find("ide.dir", 1, true), "start needs a folder")
  s = I.settings({ url = "http://127.0.0.1:8750/" })
  t.eq(s and s.title, "IDE (Beta)", "default window title")
  t.eq(s and s.start, nil, "no start, opens only")
  s = I.settings({ url = "http://127.0.0.1:8750/", dir = "~/dev/hub", start = "python3 hub.py", title = "Hub" })
  t.eq(s and s.dir, os.getenv("HOME") .. "/dev/hub", "~ in dir")
  t.eq(s and s.title, "Hub", "own title")
  t.eq(I.setup(nil), nil, "setup is nil when off")

  -- Keep callbacks under our control: no server, timer or browser is started.
  local replies, timers, launches, opened, spokenForce = {}, {}, 0, 0, nil
  local fake = {
    fs = { mkdir = function() end },
    alert = { show = function() end },
    http = { asyncGet = function(_, _, cb) replies[#replies + 1] = cb end },
    urlevent = { openURL = function() opened = opened + 1 end },
    task = { new = function()
      return { environment = function() return {} end, setEnvironment = function() end,
        start = function() launches = launches + 1; return true end }
    end },
    timer = { doEvery = function(_, cb)
      local timer = { tick = cb, stop = function(self) self.stopped = true end }
      timers[#timers + 1] = timer
      return timer
    end },
  }
  local env = setmetatable({ hs = fake, ClaudeBuddy = {
    canvas = true, say = function(_, force) spokenForce = force end,
  } }, { __index = _G })
  local testI = assert(loadfile(dir .. "/ide.lua", "t", env))()
  testI.setup({ url = "http://127.0.0.1:8750/", dir = "/tmp", start = "unused" })
  testI.browser(); testI.browser()
  t.eq(#replies, 1, "repeated opens share the initial probe")
  replies[1](503)
  t.eq(spokenForce, "user", "an explicit IDE request can report progress in silent mode")
  t.eq(launches, 1, "repeated opens start only one server")
  timers[1].tick()
  replies[2](200)
  t.eq(opened, 2, "both queued callers are completed")
  t.ok(timers[1].stopped, "the completed attempt stops its own timer")
  t.eq(testI.startup, nil, "completion clears the shared operation")

  testI.browser(); replies[3](503)
  timers[2].tick()
  local stale = replies[4]
  for _ = 2, 40 do timers[2].tick() end
  t.eq(testI.startup, nil, "a stuck readiness probe eventually times out")
  testI.browser(); replies[5](503)
  stale(200)
  t.ok(testI.startup ~= nil, "an old reply cannot finish a newer attempt")
  t.ok(not timers[3].stopped, "an old reply cannot stop the newer timer")
  timers[3].tick(); replies[6](200)
  t.eq(opened, 3, "only the new successful attempt opens the browser")

end
