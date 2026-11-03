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
  local opts = { feeds = { "https://one.example/rss", "https://two.example/rss", "https://three.example/rss" },
    every_hours = 2, share = 0.25, get = get, now = function() return clock end }
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
  local N = T.new(tmp .. "/none.json", { feeds = { "https://two.example/rss" }, get = get, now = function() return clock end })
  local called = false
  N.refresh(function() called = true; return true end, function(ok) result = ok end)
  t.ok(not called and result == false, "refresh: no headlines, no brain call")
  t.eq(T.new(tmp .. "/d.json", {}).share, 0.5, "store: half the canned lines by default")
  t.eq(T.new(tmp .. "/e.json", { share = 7 }).share, 1, "store: share is at most 1")

  S.wipe()
  t.eq(S.text(clock), nil, "wipe: topics gone")
  t.eq(S.line("idle", clock), nil, "wipe: lines gone")
  t.ok(not hs.fs.attributes(tmp .. "/topics.json"), "wipe: file gone")
end
