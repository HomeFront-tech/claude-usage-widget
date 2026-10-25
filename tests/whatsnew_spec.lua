-- whatsnew.lua: which releases a window shows, what the page gets, what a feedback form
-- may send, the GitHub fallback, the daily cap and the offline queue. Everything runs on
-- an in-memory store and fake senders: no window opens and nothing leaves the Mac.
return function(t, dir)
  local W = dofile(dir .. "/whatsnew.lua")
  local logged = {}
  W.log = function(msg) logged[#logged + 1] = msg end
  local function memory()
    local m = {}
    return { get = function(k) return m[k] end, set = function(k, v) m[k] = v end, raw = m }
  end
  local function versions(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = r.version end
    return table.concat(out, ",")
  end
  local function rel(v, extra)
    local r = { version = v, title = "T " .. v, summary = "S", slides = {}, notes = {} }
    for k, x in pairs(extra or {}) do r[k] = x end
    return r
  end
  local function decode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
  end

  -- versions
  t.ok(W.newer("1.10.0", "1.9.9"), "1.10.0 is newer than 1.9.9")
  t.ok(not W.newer("1.6.0", "1.6.0"), "the same version isn't newer")

  -- picking releases
  local all = { rel("1.5.0"), rel("1.7.0"), rel("1.8.0"), rel("1.9.0"), rel("next") }
  t.eq(versions(W.pick(all, "1.5.0", "1.8.0")), "1.8.0,1.7.0", "skipped a release: both, newest first")
  t.eq(versions(W.pick(all, "1.8.0", "1.8.0")), "", "nothing newer than where you were")
  t.eq(#W.pick(nil, "1.5.0", "1.8.0"), 0, "no releases file")
  t.eq(versions(W.forMenu({ rel("next") }, "1.6.0")), "next", "menu in a dev checkout: the draft")
  t.eq(versions(W.forMenu({ rel("1.7.0"), rel("next") }, "1.7.0")), "1.7.0", "menu: this version's entry")
  t.eq(versions(W.forMenu({ rel("1.6.0"), rel("1.7.0") }, "1.6.5")), "1.6.0", "menu: the newest at or below this version")
  t.eq(versions(W.forMenu({ rel("1.7.0"), rel("next") }, "1.7.0", "next")), "next", "menu: a version by name")
  t.eq(#W.forMenu({ rel("1.7.0") }, "1.7.0", "2.0.0"), 0, "menu: a version that isn't there")

  -- loading the file
  local tmp = t.tmpdir()
  hs.fs.mkdir(tmp .. "/whatsnew")
  local f = assert(io.open(tmp .. "/whatsnew/releases.json", "w"))
  f:write("{ not json")
  f:close()
  local list, err = W.load(tmp)
  t.eq(#list, 0, "bad JSON: no releases")
  t.ok(err ~= nil, "bad JSON: says why")
  local _, missing = W.load(tmp .. "/nowhere")
  t.ok(missing ~= nil, "missing file: says why")
  t.writeJson(tmp .. "/whatsnew/releases.json", { releases = {
    rel("1.7.0", { slides = {
      { title = "Good", text = "Fine.", scene = { kind = "buddy" } },
      { title = "Long", text = string.rep("x", 221), scene = { kind = "buddy" } },
      { title = "Also good", text = "Fine too.", scene = { kind = "phone", messages = {} } },
    } }),
    rel("1.8.0", { title = string.rep("t", 41) }),
    rel("1.9", {}),
  } })
  list = W.load(tmp)
  t.eq(versions(list), "1.7.0", "entries with a long title or a bad version are skipped")
  t.eq(#list[1].slides, 2, "a slide over the limit is skipped, the rest kept")
  t.eq(list[1].slides[2].title, "Also good", "slides keep their order")
  t.ok(#logged >= 3, "each skip leaves a note")
  local real, realErr = W.load(dir)
  t.ok(realErr == nil and #real >= 1, "the shipped releases file loads")

  -- what the page gets
  local skinsDir = dir .. "/skins/"
  local function skinFile(id)
    if id == "gone" then return nil end
    return hs.fs.attributes(skinsDir .. id .. ".json") and (skinsDir .. id .. ".json") or nil
  end
  local page = W.pageData({ rel("1.7.0", {
    hero = { skin = "gone", wave = true, lines = { "Hi" } },
    slides = {
      { title = "Grid", text = "x", scene = { kind = "skins", skins = { "witch", "gone", "ghost" } },
        action = { label = "Wear it", skin = "witch" } },
      { title = "Gone", text = "x", scene = { kind = "buddy", skin = "gone" }, action = { label = "No", skin = "gone" } },
    },
  }) }, { dir = dir, version = "1.7.0", from = "1.6.0", repoURL = "https://github.com/x/y", mode = "email",
    canWear = true, skinFile = skinFile })
  local r1 = page.releases[1]
  t.eq(r1.hero.skin, "classic", "a missing hero skin becomes Classic")
  t.eq(table.concat(r1.slides[1].scene.skins, ","), "witch,ghost", "a missing skin leaves the grid")
  t.eq(r1.slides[2].scene.skin, "classic", "a missing scene skin becomes Classic")
  t.ok(page.skins.witch and page.skins.witch.id == "witch", "the page gets the skin's JSON")
  t.ok(page.skins.classic ~= nil, "and Classic, which it fell back to")
  t.ok(page.wearable.witch, "an installed skin can be worn")
  t.ok(not page.wearable.gone, "a missing one can't")
  t.eq(page.mode, "email", "mode passes through")
  local noWear = W.pageData({ rel("1.7.0", { slides = { { title = "G", text = "x",
    scene = { kind = "skins", skins = { "witch" } }, action = { label = "Wear", skin = "witch" } } } }) },
    { dir = dir, version = "1.7.0", mode = "email", canWear = false, skinFile = skinFile })
  t.ok(next(noWear.wearable) == nil, "without Buddy running nothing can be worn")
  t.ok(all[2].slides ~= nil and W.pageData(all, { dir = dir, skinFile = skinFile }) ~= nil, "pageData copes with bare entries")
  t.ok(W.initJSON({ t = "</script>" }):find("<\\/script>", 1, true) ~= nil, "init JSON can't close the script tag")

  -- what a form may send
  local form = W.form({ rating = 6, idea = "  more hats  ", reply_to = "nope" })
  t.eq(form.rating, nil, "a rating outside 1-5 is dropped")
  t.eq(form.idea, "more hats", "the idea is trimmed")
  t.eq(form.reply_to, nil, "a reply address that isn't an email is dropped")
  t.eq(W.form({ rating = 4.0 }).rating, 4, "a whole-number rating from JSON")
  t.eq(W.form({ rating = 2.5, idea = "x" }).rating, nil, "a fractional rating is dropped")
  t.eq(W.form({ idea = "x", reply_to = "sam@example.com" }).reply_to, "sam@example.com", "a reply address")
  local none, why = W.form({ idea = "   " })
  t.eq(none, nil, "a blank form sends nothing")
  t.eq(why, "empty", "and says why")
  t.eq(utf8.len(W.form({ idea = string.rep("é", 2100) }).idea), 2000, "an idea is cut at 2000 characters")
  local p = W.payload(W.form({ rating = 5 }), "1.7.0", "15.1")
  t.eq(p.rating, 5, "payload: rating")
  t.eq(p.idea, nil, "payload: no idea, no field")
  t.eq(p.version .. " " .. p.macos, "1.7.0 15.1", "payload: versions")

  -- the GitHub fallback holds what was typed and the versions, nothing else
  local typed = W.form({ rating = 3, idea = 'Say "hi" </script> 🎃\nsecond line', reply_to = "sam@example.com" })
  local url = W.issueURL("https://github.com/x/y", typed, "1.7.0", "15.1")
  t.ok(url:find("^https://github.com/x/y/issues/new%?title=") ~= nil, "a new-issue link")
  local plain = decode(url)
  t.ok(plain:find('Say "hi" </script> 🎃\nsecond line', 1, true) ~= nil, "the idea survives the link")
  t.ok(plain:find("title=Idea: Say \"hi\" </script> 🎃&", 1, true) ~= nil, "titled with the idea's first line")
  t.ok(plain:find("Rating: 3/5", 1, true) ~= nil, "the rating")
  t.ok(plain:find("Reply to: sam@example.com", 1, true) ~= nil, "the reply address they typed")
  t.ok(plain:find("Buddy v1.7.0 · macOS 15.1", 1, true) ~= nil, "the versions")
  t.ok(not plain:find(os.getenv("HOME"), 1, true), "no home folder")
  t.ok(not plain:lower():find("config", 1, true), "no config")

  -- five sends a day
  local store = memory()
  for i = 1, 5 do
    t.ok(W.allow(store, "2026-10-25"), "send " .. i .. " allowed")
    W.count(store, "2026-10-25")
  end
  t.ok(not W.allow(store, "2026-10-25"), "the sixth isn't")
  t.ok(W.allow(store, "2026-10-26"), "a new day starts over")

  -- the offline queue
  local q = memory()
  local now = 1000000
  for i = 1, 6 do W.enqueue(q, { idea = "n" .. i }, now + i) end
  t.eq(#W.queued(q), 5, "the queue keeps 5")
  t.eq(W.queued(q)[1].p.idea, "n2", "the oldest is dropped")
  local posted = 0
  W.flush(q, function(_, done) posted = posted + 1; done(503) end, now + 10)
  t.eq(posted, 1, "a server error stops the flush")
  t.eq(#W.queued(q), 5, "and keeps everything")
  W.flush(q, function(_, done) done(429) end, now + 10)
  t.eq(#W.queued(q), 5, "too many requests is tried again later")
  local calls = 0
  W.flush(q, function(_, done) calls = calls + 1; done(calls == 1 and 400 or 503) end, now + 10)
  t.eq(#W.queued(q), 4, "a 400 is dropped, not retried forever")
  t.eq(calls, 2, "and the flush goes on to the next one")
  W.flush(q, function(_, done) done(200) end, now + 10)
  t.eq(#W.queued(q), 0, "sent ones leave the queue")
  W.enqueue(q, { idea = "old" }, now)
  posted = 0
  W.flush(q, function(_, done) posted = posted + 1; done(200) end, now + 4 * 86400)
  t.eq(posted, 0, "a 4-day-old item isn't sent")
  t.eq(#W.queued(q), 0, "it's dropped")

  -- the page's messages, with fake senders
  local function session(mode, status)
    W.store, W.version, W.repoURL = memory(), "1.7.0", "https://github.com/x/y"
    W.feedbackURL = mode == "email" and "https://feedback.example/feedback" or nil
    W.macos = function() return "15.1" end
    W.today = function() return "2026-10-25" end
    W.reset()
    local d = { posts = {}, opened = {}, replies = {}, worn = {}, copied = {}, shared = 0, closed = 0 }
    d.post = function(payload, done) d.posts[#d.posts + 1] = payload; done(status or 200) end
    d.openURL = function(u) d.opened[#d.opened + 1] = u end
    d.reply = function(r) d.replies[#d.replies + 1] = r end
    d.wear = function(id) d.worn[#d.worn + 1] = id end
    d.copy = function(text) d.copied[#d.copied + 1] = text end
    d.copiedNote = function() end
    d.share = function() d.shared = d.shared + 1 end
    d.close = function() d.closed = d.closed + 1 end
    d.retry = function() end
    return d
  end
  local d = session("email")
  W.handle({ type = "send", rating = 5, idea = "More hats" }, d)
  t.eq(#d.posts, 1, "email: Send posts")
  t.eq(d.posts[1].idea .. " " .. d.posts[1].rating .. " " .. d.posts[1].version, "More hats 5 1.7.0", "with the form and version")
  t.eq(d.replies[1].text, "Sent. Thanks!", "and says so")
  W.handle({ type = "close" }, d)
  t.eq(#d.posts, 1, "a rating already sent isn't sent again on close")
  t.eq(d.closed, 1, "close closes")

  d = session("email")
  W.handle({ type = "rate", rating = 4 }, d)
  W.handle({ type = "close" }, d)
  t.eq(#d.posts, 1, "a face picked, then closed: the rating goes")
  t.eq(d.posts[1].rating, 4, "just the rating")
  t.eq(d.posts[1].idea, nil, "no idea")
  W.handle({ type = "close" }, d)
  t.eq(#d.posts, 1, "closing twice doesn't send twice")

  d = session("email", 503)
  W.handle({ type = "send", idea = "Offline idea" }, d)
  t.eq(#W.queued(W.store), 1, "offline: queued")
  t.eq(d.replies[1].text, "Saved. I'll send it when you're back online.", "and says so")

  d = session("email")
  for _ = 1, 5 do W.count(W.store, "2026-10-25") end
  W.handle({ type = "send", idea = "Sixth" }, d)
  t.eq(#d.posts, 0, "over the daily cap: nothing posted")
  t.eq(d.replies[1].text, "That's plenty for today. Thanks!", "and says so")
  W.handle({ type = "rate", rating = 2 }, d)
  W.handle({ type = "close" }, d)
  t.eq(#d.posts, 0, "a close-time rating over the cap is dropped quietly")

  d = session("github")
  W.handle({ type = "send", rating = 3, idea = "Bigger bubble", reply_to = "sam@example.com" }, d)
  t.eq(#d.posts, 0, "github mode posts nothing")
  t.ok(d.opened[1] and d.opened[1]:find("/issues/new?", 1, true) ~= nil, "it opens a new issue")
  t.ok(not d.opened[1]:find("example.com", 1, true), "a reply address never goes in a public issue")
  t.eq(d.replies[1].text, "Opened on GitHub. Click Submit there to post it.", "and says what to do")
  W.handle({ type = "send", idea = "  " }, d)
  t.eq(#d.opened, 1, "a blank idea opens nothing")
  d = session("github")
  W.handle({ type = "rate", rating = 5 }, d)
  W.handle({ type = "close" }, d)
  t.eq(#d.posts + #d.opened, 0, "github mode: a lone rating isn't sent anywhere")

  d = session("email")
  W.handle({ type = "open", url = "https://evil.example/releases/tag/v1" }, d)
  W.handle({ type = "open", url = "https://github.com/x/y/releases/tag/v1.7.0" }, d)
  t.eq(#d.opened, 1, "only this repo's release pages open")
  W.handle({ type = "wear", skin = "witch" }, d)
  t.eq(d.worn[1], "witch", "wear passes the skin on")
  W.handle({ type = "copy" }, d)
  t.eq(d.copied[1], "https://github.com/x/y", "copy puts the repo link on the clipboard")
  W.handle({ type = "share" }, d)
  t.eq(d.shared, 1, "share opens the share menu")

  -- a reply that arrives after its window closed and another opened is dropped
  d = session("email")
  local held
  d.post = function(payload, done) d.posts[#d.posts + 1] = payload; held = done end
  W.handle({ type = "send", idea = "Slow one" }, d)
  W.gen = W.gen + 1 -- a new window
  held(200)
  t.eq(#d.replies, 0, "a stale reply doesn't reach the new window")

  -- a rating the server turned down can go again
  d = session("email", 400)
  W.handle({ type = "send", rating = 5, idea = "Rejected" }, d)
  t.eq(d.replies[1].text, "That didn't go through. Sorry!", "a refused send says so")
  W.handle({ type = "rate", rating = 5 }, d)
  W.handle({ type = "close" }, d)
  t.eq(#d.posts, 2, "and the rating goes again on close")
  t.eq(d.posts[2].rating, 5, "the same rating")

  -- opening from the menu uses up a pending update window, so it can't pop up again
  local said, shown = {}, nil
  local realShow, realSay = W.show, W.say
  W.show = function(list) shown = list end
  W.say = function(text) said[#said + 1] = text end
  local rdir = t.tmpdir()
  t.writeJson(rdir .. "/whatsnew/releases.json", { releases = { rel("1.7.0") } })
  W.dir, W.version, W.store = rdir, "1.7.0", memory()
  W.store.set("claudeWidget.whatsNewFrom", "1.6.0")
  t.ok(W.open(), "the menu opens it")
  t.eq(shown and shown[1].version, "1.7.0", "on the update's release")
  t.ok(not W.showPending(), "the timer then has nothing left to show")
  W.store.set("claudeWidget.whatsNewFrom", "1.6.0")
  shown = nil
  t.ok(W.showPending(), "pending: the window opens")
  t.eq(shown and shown[1].version, "1.7.0", "on what's new since 1.6.0")
  t.eq(said[#said], "I got updated! Come see what's new.", "and Buddy says so")
  W.show, W.say = realShow, realSay

  W.store = memory()
  t.ok(not W.showPending(), "nothing pending: no window")
end
