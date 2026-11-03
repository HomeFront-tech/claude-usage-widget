-- topics.lua: reading headline feeds, checking the brain's lines, and the store that keeps
-- topics and fresh lines between refreshes. No network: the fetcher and the brain are fakes.
return function(t, dir)
  local T = dofile(dir .. "/topics.lua")

  -- feeds: RSS items (Google News style, with a source to strip) and Atom entries
  local rss = [==[<?xml version="1.0"?><rss><channel><title>Top stories</title>
    <item><title>Big &amp; Loud: band&#39;s comeback tour sells out - Music Daily</title><source url="x">Music Daily</source></item>
    <item><title><![CDATA[Robot vacuum learns to   climb stairs]]></title><link>https://a.example</link></item>
    <item><title>Big &amp; Loud: band&#39;s comeback tour sells out - Music Daily</title><source url="x">Music Daily</source></item>
    <item><title>Rival - Team - Final score - Sports Now</title><source url="y">Sports Now</source></item>
    <item><title></title></item>
  </channel></rss>]==]
  local got = T.parse(rss, 10)
  t.eq(#got, 3, "parse: empty titles and repeats are dropped")
  t.eq(got[1], "Big & Loud: band's comeback tour sells out", "parse: entities decoded, the source after the dash goes")
  t.eq(got[2], "Robot vacuum learns to climb stairs", "parse: CDATA unwrapped, spaces tidied")
  t.eq(got[3], "Rival - Team - Final score", "parse: only the last dash part is the source")
  t.eq(#T.parse(rss, 1), 1, "parse: stops at the limit")
  local atom = [[<feed><title>Feed</title><entry><title type="html">Comet &#x2014; seen tonight</title></entry></feed>]]
  t.eq(T.parse(atom, 5)[1], "Comet — seen tonight", "parse: Atom entries, hex entities")
  t.eq(#T.parse("not a feed", 5), 0, "parse: junk gives nothing")
  local latin = "<rss><item><title>Caf\233 opens downtown</title></item>"
    .. "<item><title>Odd &#55357; entity</title></item><item><title>Fine headline</title></item></rss>"
  local kept = T.parse(latin, 5)
  t.ok(#kept == 1 and kept[1] == "Fine headline", "parse: titles that aren't valid UTF-8 (Latin-1, surrogates) are skipped")

  -- lines: plain, short, nothing private-looking
  t.eq(T.clean("  Snow again?   Shocking.  "), "Snow again? Shocking.", "clean: spaces tidied")
  t.eq(T.clean('He said "hi"'), nil, "clean: no quotation marks")
  t.eq(T.clean("Ship it \u{1F680}"), nil, "clean: no emoji")
  t.eq(T.clean("Big day #winning"), nil, "clean: no hashtags")
  t.eq(T.clean("Call 555-555-0199 now"), nil, "clean: no phone numbers")
  t.eq(T.clean("That costs $40"), nil, "clean: no dollar amounts")
  t.eq(T.clean("100% done"), nil, "clean: no percent signs (they're placeholders)")
  t.eq(T.clean("See www.example.com"), nil, "clean: no links")
  t.eq(T.clean("*yawn* bedtime"), nil, "clean: no stage directions")
  t.eq(T.clean(string.rep("word ", 30)), nil, "clean: not too long")
  t.eq(T.clean(42), nil, "clean: strings only")
  t.eq(T.clean("Buddy: Stretch time."), "Stretch time.", "clean: a speaker label goes")
  t.eq(T.clean("Back in 2026, ha."), "Back in 2026, ha.", "clean: a year is fine")

  -- the store: refresh, keep, reload, go stale, forget
  local tmp = t.tmpdir()
  local clock = 1000000
  local feeds = {
    ["https://one.example/rss"] = { 200, rss },
    ["https://two.example/rss"] = { 500, "" },
    ["https://three.example/rss"] = { 200, atom },
  }
  local fetched = {}
  local function get(url, done)
    fetched[#fetched + 1] = url
    local r = feeds[url]
    done(r[1], r[2])
  end
  -- fake timers (later) and console (log)
  local timers, logged = {}, {}
  local function later(seconds, fn)
    local timer = { seconds = seconds, fn = fn, stopped = false }
    function timer:stop() self.stopped = true end
    timers[#timers + 1] = timer
    return timer
  end
  local function log(text) logged[#logged + 1] = text end
  local opts = { feeds = { "https://one.example/rss", "https://two.example/rss", "https://three.example/rss" },
    every_hours = 2, share = 0.25, get = get, now = function() return clock end, later = later, log = log }
  local function store(name, now, more)
    local o = { feeds = opts.feeds, get = get, now = now, later = later, log = log }
    for k, v in pairs(more or {}) do o[k] = v end
    return T.new(tmp .. "/" .. name, o)
  end
  local S = T.new(tmp .. "/topics.json", opts)
  t.eq(S.share, 0.25, "store: share comes from the options")
  t.ok(S.due(clock), "store: due when it has nothing")
  t.eq(S.text(clock), nil, "store: no topics yet")
  t.eq(S.line("idle", clock), nil, "store: no lines yet")

  local asked, finished
  S.refresh(function(headlines, moods, done)
    asked = { headlines = headlines, moods = moods }
    done({ topics = { "A comeback tour", 'Bad "quoted" one', "Stair-climbing robot vacuums" },
      lines = { idle = { "Comeback tour? You never left the terminal.", "Visit 555-555-0199" },
        coding = { "Even robot vacuums climb higher than this stack." },
        nonsense = { "Not a mood" }, sleepy = "not a list" } })
    return true
  end, function(ok) finished = ok end)
  t.eq(#fetched, 3, "refresh: every feed fetched")
  t.ok(asked and asked.headlines[1] == "Big & Loud: band's comeback tour sells out", "refresh: headlines handed to the brain")
  t.ok(asked and asked.headlines[2] == "Comet — seen tonight", "refresh: feeds take turns in the list")
  t.ok(asked and asked.moods.idle and asked.moods.coding, "refresh: the moods go along with what they mean")
  t.eq(finished, true, "refresh: reports success")
  t.ok(#timers == 1 and timers[1].seconds == 300 and timers[1].stopped, "refresh: a 5-minute watchdog, stopped once answered")
  t.eq(#logged, 0, "refresh: a refresh that worked logs nothing")
  t.eq(S.text(clock), "A comeback tour; Stair-climbing robot vacuums", "store: clean topics kept")
  t.eq(S.line("idle", clock), "Comeback tour? You never left the terminal.", "store: clean lines kept")
  t.eq(S.line("coding", clock), "Even robot vacuums climb higher than this stack.", "store: lines per mood")
  t.eq(S.line("nonsense", clock), nil, "store: unknown moods dropped")
  t.eq(S.line("sleepy", clock), nil, "store: a mood that isn't a list is dropped")
  t.ok(not S.due(clock + 3600), "store: not due before every_hours")
  t.ok(S.due(clock + 2 * 3600), "store: due after every_hours")

  local again = T.new(tmp .. "/topics.json", opts)
  t.eq(again.text(clock), "A comeback tour; Stair-climbing robot vacuums", "store: topics survive a reload")
  t.eq(again.line("coding", clock), "Even robot vacuums climb higher than this stack.", "store: lines survive a reload")
  t.eq(again.text(clock + 3 * 86400), nil, "store: topics go stale after two days")
  t.eq(again.line("coding", clock + 3 * 86400), nil, "store: so do the lines")

  -- a brain that can't start, or no headlines at all: try again later, not every tick
  local F = T.new(tmp .. "/other.json", opts)
  local result
  F.refresh(function() return false end, function(ok) result = ok end)
  t.eq(result, false, "refresh: a brain that can't start fails")
  t.ok(not F.due(clock + 60), "refresh: and waits before trying again")
  t.ok(F.due(clock + 3600), "refresh: but tries again within the hour")
  t.eq(#logged, 1, "refresh: a failure logs one line")
  t.ok(logged[1] and logged[1]:find("brain couldn't start", 1, true), "refresh: saying why")
  local N = store("none.json", function() return clock end, { feeds = { "https://two.example/rss" } })
  local called = false
  N.refresh(function() called = true; return true end, function(ok) result = ok end)
  t.ok(not called and result == false, "refresh: no headlines, no brain call")
  t.ok(#logged == 2 and logged[2]:find("no feed answered", 1, true), "refresh: feeds that fail are logged once")

  -- back off: each failure in a row doubles the wait (30 min, 1 h, 2 h, 4 h, then 6 h at
  -- most); a refresh that works starts over at 30 min
  local bt, brainUp = clock, false
  local B = store("backoff.json", function() return bt end)
  local function ask(_, _, done)
    if not brainUp then return false end
    done({ topics = { "Something light" } })
    return true
  end
  local logs = #logged
  for i, w in ipairs({ 1800, 3600, 7200, 14400, 21600, 21600 }) do
    B.refresh(ask)
    t.ok(not B.due(bt + w - 1) and B.due(bt + w), "backoff: failure " .. i .. " waits " .. w .. " s")
    if i == 2 then
      t.ok(not store("backoff.json", function() return bt end).due(bt + 1800), "backoff: the wait survives a reload")
    end
    bt = bt + w
  end
  t.eq(#logged, logs + 6, "backoff: one log line per failure")
  brainUp = true
  B.refresh(ask)
  t.eq(B.text(bt), "Something light", "backoff: a refresh that works")
  brainUp, bt = false, bt + 4 * 3600
  B.refresh(ask)
  t.ok(not B.due(bt + 1799) and B.due(bt + 1800), "backoff: ... starts the wait over at 30 min")

  -- watchdog: a brain that never answers doesn't keep it busy for good
  local wt, wCalls, wResult, lateDone = clock, 0, nil, nil
  local W = store("watch.json", function() return wt end)
  local nTimers = #timers
  W.refresh(function(_, _, done) lateDone = done; return true end, function(ok) wCalls, wResult = wCalls + 1, ok end)
  local dog = timers[#timers]
  t.ok(#timers == nTimers + 1 and dog.seconds == 300 and not dog.stopped, "watchdog: armed for 5 min while the brain thinks")
  t.ok(not W.due(wt + 86400), "watchdog: busy while it waits for the brain")
  logs = #logged
  dog.fn()
  t.ok(wCalls == 1 and wResult == false, "watchdog: no answer in 5 min counts as a failure")
  t.eq(#logged, logs + 1, "watchdog: and is logged once")
  t.ok(not W.due(wt + 1799) and W.due(wt + 1800), "watchdog: not busy any more, tries again after the wait")
  lateDone({ topics = { "Too late" }, lines = { idle = { "A line that came too late." } } })
  t.eq(W.text(wt), nil, "watchdog: an answer after it is ignored")
  t.ok(wCalls == 1 and #logged == logs + 1, "watchdog: ... without another finish or log line")
  t.eq(T.new(tmp .. "/d.json", {}).share, 0.5, "store: half the canned lines by default")
  t.eq(T.new(tmp .. "/e.json", { share = 7 }).share, 1, "store: share is at most 1")

  S.wipe()
  t.eq(S.text(clock), nil, "wipe: topics gone")
  t.eq(S.line("idle", clock), nil, "wipe: lines gone")
  t.ok(not hs.fs.attributes(tmp .. "/topics.json"), "wipe: file gone")

  -- Forget while a refresh is running: the brain's answer was written from the forgotten
  -- notes, so it's dropped
  local G = store("forget.json", function() return clock end)
  local pending
  G.refresh(function(_, _, done) pending = done; return true end)
  local gDog = timers[#timers]
  t.ok(hs.fs.attributes(tmp .. "/forget.json") ~= nil, "wipe race: the refresh wrote its try time")
  G.wipe()
  t.ok(gDog.stopped, "wipe race: the running refresh's watchdog stops")
  pending({ topics = { "A comeback tour" }, lines = { idle = { "Comeback tour? You never left the terminal." } } })
  t.eq(G.text(clock), nil, "wipe race: an answer that comes after Forget brings no topics back")
  t.eq(G.line("idle", clock), nil, "wipe race: nor lines")
  t.ok(not hs.fs.attributes(tmp .. "/forget.json"), "wipe race: and the file isn't written again")
  t.ok(G.due(clock), "wipe race: not busy any more")
  local held, hAsked = {}, false
  local H = store("held.json", function() return clock end,
    { get = function(url, done) held[#held + 1] = function() done(feeds[url][1], feeds[url][2]) end end })
  H.refresh(function() hAsked = true; return true end)
  H.wipe()
  for _, answer in ipairs(held) do answer() end
  t.ok(#held == 3 and not hAsked, "wipe race: feeds that answer after Forget don't reach the brain")
  t.ok(not hs.fs.attributes(tmp .. "/held.json"), "wipe race: nor write the file")
end
