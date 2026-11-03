-- "Check for updates…": GitHub's answer, the menu item's words, what a check you asked for
-- says or opens, and the item in Buddy's right-click menu. GitHub, the dialog, Buddy's
-- bubble and the settings are all stand-ins, so nothing here reaches the network or the
-- running Buddy.
return function(t, dir)
  local U = dofile(dir .. "/updater.lua") -- a fresh copy; start() never runs, so no timers
  local store = {}
  U.store = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
  U.version, U.repo = "1.14.0", "someone/buddy"
  local told, prompts, changes, asked = {}, 0, 0, {}
  U.tell = function(s) told[#told + 1] = s end
  U.prompt = function() prompts = prompts + 1 end
  U.onChange = function() changes = changes + 1 end
  local answer = { 200, '{"tag_name":"v1.15.0","body":"## New\\n- a thing","html_url":"https://example.com/r"}' }
  U.get = function(url, headers, done)
    asked[#asked + 1] = { url = url, headers = headers }
    if answer then done(answer[1], answer[2]) else U.pending = done end
  end

  -- GitHub's answer
  local rel = U.parse(200, '{"tag_name":"v1.15.0","body":"notes","html_url":"https://example.com/r"}')
  t.eq(rel and rel.version, "1.15.0", "parse: the tag without its v")
  t.eq(rel and rel.notes .. "|" .. rel.url, "notes|https://example.com/r", "parse: notes and page")
  local r2, why = U.parse(200, '{"tag_name":"1.16.0","body":null}')
  t.eq(r2 and r2.version .. "|" .. r2.notes .. "|" .. tostring(r2.url) or why, "1.16.0||nil", "parse: a bare tag, no notes")
  local function reason(status, body) return select(2, U.parse(status, body)) end
  t.ok(reason(-1):find("couldn't reach GitHub", 1, true), "offline: says it couldn't reach GitHub")
  t.ok(reason(404):find("no releases", 1, true), "404: no releases yet")
  t.ok(reason(403):find("slow down", 1, true), "403: GitHub's rate limit")
  t.ok(reason(500):find("(500)", 1, true), "another status: says which")
  t.ok(reason(200, "not json"):find("didn't make sense", 1, true), "bad JSON")
  t.ok(reason(200, '{"name":"x"}'):find("didn't make sense", 1, true), "no tag")

  -- the menu item's words, and the answer when nothing's newer
  t.eq(U.menuTitle(), "Check for updates…", "menu: nothing known yet")
  t.eq(U.upToDate("1.14.0"), "You're up to date! v1.14.0 is the latest.", "up to date")
  U.version = "1.15.0"
  t.eq(U.upToDate("1.14.0"), "You're on v1.15.0, ahead of the latest release (v1.14.0).", "a copy ahead of the releases")
  U.version = "1.14.0"

  -- a newer release: the Update / Later dialog, never a quiet install
  U.checkNow()
  t.eq(asked[1] and asked[1].url, "https://api.github.com/repos/someone/buddy/releases/latest", "asks the repo's latest release")
  t.eq(asked[1] and asked[1].headers["Cache-Control"], "no-cache", "never a cached answer")
  t.eq(prompts, 1, "newer: opens the Update / Later dialog")
  t.eq(U.available and U.available.version, "1.15.0", "newer: remembered for the card")
  t.eq(changes, 1, "newer: the card redraws")
  t.eq(#told, 0, "newer: the dialog is the answer")
  t.eq(store["claudeWidget.notifiedVersion"], "1.15.0", "seen: no notification for it later")
  t.eq(U.menuTitle(), "Update to v1.15.0…", "menu: names the update once it's known")

  -- the background check stays quiet about a version already seen
  U.check()
  t.eq(prompts .. "|" .. #told, "1|0", "background check: nothing new to say")

  -- GitHub unreachable while an update is known: still offers it
  answer = { -1, "" }
  U.checkNow()
  t.eq(prompts .. "|" .. #told, "2|0", "offline, update known: the dialog anyway")

  -- up to date (someone updated by hand): says so, and the card's line goes
  U.version = "1.15.0"
  answer = { 200, '{"tag_name":"v1.15.0"}' }
  U.checkNow()
  t.eq(told[#told], "You're up to date! v1.15.0 is the latest.", "up to date: says so")
  t.eq(U.available, nil, "up to date: the update line goes")
  t.eq(prompts, 2, "up to date: no dialog")

  -- offline with nothing known: says why
  answer = { 0, "" }
  U.checkNow()
  t.ok((told[#told] or ""):find("couldn't reach GitHub", 1, true), "offline: says why")

  -- a second click while GitHub is still answering asks only once
  answer = nil
  local before = #asked
  U.checkNow()
  U.checkNow()
  t.eq(#asked - before, 1, "two clicks, one request")
  t.eq(told[#told], "Still checking for updates…", "the second click hears it's still going")
  U.pending(200, '{"tag_name":"v1.15.0"}')
  t.eq(told[#told], "You're up to date! v1.15.0 is the latest.", "then the answer")
  answer = { 200, '{"tag_name":"v1.15.0"}' }
  U.checkNow()
  t.eq(#asked - before, 2, "after the answer, a click asks again")

  -- Buddy's right-click menu has the item, named by the updater, and it checks
  local S = dofile(dir .. "/tests/buddy_sandbox.lua")(dir, {})
  local ok, err = pcall(function()
    local checks = 0
    local fake = { checkNow = function() checks = checks + 1 end, menuTitle = function() return "Check for updates…" end }
    S.M.updater = function() return fake end
    local function find(items, title)
      for i, it in ipairs(items or {}) do if it.title == title then return it, i end end
    end
    local items = S.rightClick()
    local item, at = find(items, "Check for updates…")
    local _, news = find(items, "What's new")
    t.ok(item and at == news + 1, "right-click: Check for updates… right after What's new")
    if item then item.fn() end
    t.eq(checks, 1, "right-click: the item checks")
    fake.menuTitle = function() return "Update to v1.16.0…" end
    t.ok(find(S.rightClick(), "Update to v1.16.0…"), "right-click: the update's own words once known")
    S.M.updater = function() return nil end
    items = S.rightClick()
    t.ok(not find(items, "Check for updates…") and find(items, "What's new"), "no updater (no card): no item")
  end)
  S.done()
  t.ok(ok, "Buddy's menu: " .. tostring(err))
end
