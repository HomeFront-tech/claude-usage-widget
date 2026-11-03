-- app.lua: when the regular Hammerspoon steps aside for Claude Buddy.app, and the one
-- launch right after "Make Buddy an app".
return function(t, dir)
  local A = dofile(dir .. "/app.lua")
  local tmp = t.tmpdir()
  local marker = tmp .. "/app.json"
  local fakeApp = tmp .. "/Claude Buddy.app"
  t.writeJson(fakeApp .. "/Contents/Info.plist", {}) -- only its being there counts

  -- The Dock menu's "Check for Updates..." (app/dockmenu.m): stand-ins for the watcher, the
  -- build, the library and the log, so nothing is built, loaded or listened for here.
  local function dock(code, text, lib)
    local D = { watched = {}, ran = {}, loaded = {}, logs = {}, checks = 0 }
    D.result = A.dockMenu({ dir = "/w", inApp = true, id = "test.buddy",
      check = function() D.checks = D.checks + 1 end,
      watch = function(name, fn) D.watched[#D.watched + 1] = name; D.fire = fn; return "watcher" end,
      run = function(script, args, done) D.ran[#D.ran + 1] = script .. " " .. table.concat(args, " "); done(code, text); return true end,
      loadlib = function(path, fn) D.loaded[#D.loaded + 1] = path .. ":" .. fn; return lib, "image not found" end,
      log = function(s) D.logs[#D.logs + 1] = s end })
    return D
  end
  t.eq(A.dockMenu({ dir = "/w", inApp = false, check = function() end }), nil, "dock: nothing outside the app")
  t.eq(A.dockNote("test.buddy"), "test.buddy.checkForUpdates", "dock: the app's own notification")
  local d = dock(0, "", function() return 1 end)
  t.eq(d.watched[1], "test.buddy.checkForUpdates", "dock: listens for its Dock item")
  t.eq(d.ran[1], "/w/app/dockmenu.sh --if-stale", "dock: builds the helper only when its source changed")
  t.eq(d.loaded[1], "/w/app/dockmenu.dylib:claude_buddy_dock_menu", "dock: loads it")
  t.eq(d.result.items, 1, "dock: one item taken over")
  t.eq(d.result.watcher, "watcher", "dock: the watcher is kept")
  t.eq(#d.logs, 0, "dock: nothing to report when it works")
  d.fire()
  t.eq(d.checks, 1, "dock: a click runs Buddy's check")
  d = dock(3, "no clang")
  t.eq(#d.loaded .. "|" .. #d.logs, "0|0", "dock: no Command Line Tools: quietly left as it was")
  d.fire()
  t.eq(d.checks, 1, "dock: still listening (a later build can take over)")
  d = dock(1, "dockmenu.m:3: error: oops\nmore")
  t.eq(d.logs[1], "the Dock menu helper didn't build: dockmenu.m:3: error: oops", "dock: a failed build says why")
  d = dock(0, "", nil)
  t.eq(d.logs[1], "the Dock menu helper didn't load: image not found", "dock: a failed load says why")
  d = dock(0, "", function() return 0 end)
  t.ok(d.logs[1] and d.logs[1]:find("no Check for Updates item", 1, true), "dock: no item found is reported")
  d = dock(0, "", function() error("boom") end)
  t.ok(d.logs[1] and d.logs[1]:find("boom", 1, true), "dock: an error in the helper is caught")

  if A.inApp() then -- run from Claude Buddy.app (BUDDY_HS_PORT=ClaudeBuddy tests/lua-tests)
    t.eq(A.hostName(), "Claude Buddy", "permissions go to the app")
    t.writeJson(marker, { path = fakeApp, dir = dir, bundle_id = A.BUNDLE_ID })
    t.ok(not A.stepAside(dir, marker), "the app itself never steps aside")
    return
  end
  t.eq(A.hostName(), "Hammerspoon", "permissions go to Hammerspoon here")
  t.eq(A.installed(marker), nil, "no note, no app")
  t.ok(not A.stepAside(dir, marker), "no app: Buddy starts here")

  t.writeJson(marker, { path = fakeApp, dir = dir .. "/", bundle_id = A.BUNDLE_ID })
  t.ok(A.installed(marker) ~= nil, "the note and its app")
  t.ok(A.stepAside(dir, marker), "the app runs this folder: step aside (a trailing slash is the same folder)")
  t.ok(not A.stepAside(dir .. "-other", marker), "an app for another clone doesn't stop this one")

  local opened = {}
  local function open(id) opened[#opened + 1] = id end
  t.ok(not A.handoff(marker, open), "no handoff flag: nothing opens")
  t.writeJson(marker, { path = fakeApp, dir = dir, bundle_id = A.BUNDLE_ID, handoff = true })
  t.ok(A.handoff(marker, open), "right after making the app: open it")
  t.eq(opened[1], A.BUNDLE_ID, "by its bundle ID")
  A.started(marker)
  t.eq(t.readJson(marker).handoff, nil, "the app clears the flag when it starts")
  t.eq(t.readJson(marker).path, fakeApp, "and keeps the rest of the note")
  t.ok(not A.handoff(marker, open) and #opened == 1, "so it opens once")

  -- the first start's settings copy: only Buddy's keys, and never over the app's own
  local prefs = { ["claudeBuddy.chat"] = { 1 }, ["claudeUsageWidget.topLeft"] = { x = 1 },
    ["claudeWidget.lastRunVersion"] = "1.13.0", MJShowDockIconKey = false, ["ps5.mode"] = "mac",
    ["claudeBuddy.voicePid"] = 123, ["claudeBuddy.test.taskSeen.X"] = 1, ["claudeBuddy.skinTest-Y"] = 1 }
  local got = {}
  local function set(k, v) got[k] = v end
  t.eq(A.migrate(prefs, { "MJConfigFile", "claudeBuddy.appLoginSet" }, set), 3, "three of Buddy's settings come over")
  t.ok(got["claudeBuddy.chat"] and got["claudeUsageWidget.topLeft"].x == 1 and got["claudeWidget.lastRunVersion"],
    "chat, the card's spot, the version")
  t.ok(got["ps5.mode"] == nil and got["claudeBuddy.voicePid"] == nil and got["claudeBuddy.test.taskSeen.X"] == nil,
    "not other modules', the helper's pid or specs' leftovers")
  got = {}
  t.eq(A.migrate(prefs, { "claudeBuddy.metAt" }, set), 0, "the app has its own already: nothing copied")
  t.eq(next(got), nil, "…and nothing overwritten")

  os.remove(fakeApp .. "/Contents/Info.plist")
  t.eq(A.installed(marker), nil, "app trashed: the note no longer counts")
  t.ok(not A.stepAside(dir, marker), "and Buddy starts here again")
end
