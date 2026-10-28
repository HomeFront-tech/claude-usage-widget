-- usage_poll.lua: running the fetchers, with a stand-in bin/ai-usage (tests/fakes/ai-usage).
return function(t, dir)
  local Poll = dofile(dir .. "/usage_poll.lua")
  local py, fake = "/usr/bin/python3", dir .. "/tests/fakes/ai-usage"
  local got = {}
  Poll.run(py, fake, { "openrouter", "--key-stdin" }, "sk-or-v1-testkey123\n", function(res) got.stdin = res end)
  Poll.run(py, fake, { "junk" }, nil, function(res) got.junk = res end)
  Poll.run(py, fake, { "slow" }, nil, function(res) got.slow = res end, 1)

  local function args(id) return { id } end
  local function every() return 300 end
  local mem, told = {}, {}
  local p = Poll.new({ python = py, script = fake, ids = { "codex", "busy" }, argsFor = args, refreshFor = every,
    store = { get = function(k) return mem[k] end, set = function(k, v) mem[k] = v end },
    onResult = function(id) told[#told + 1] = id end })
  p:start()

  local seeded = { ["claudeUsageWidget.provider.codex"] = { ok = true, provider = "codex", fetched_at = os.time(),
    limits = { { label = "Week", pct = 7 } } } }
  local p2 = Poll.new({ python = py, script = fake, ids = { "codex" }, argsFor = args, refreshFor = every,
    store = { get = function(k) return seeded[k] end, set = function(k, v) seeded[k] = v end } })
  p2:start()
  t.eq(p2.running.codex, nil, "a fresh saved result isn't fetched again")
  t.eq(p2.results.codex and p2.results.codex.limits[1].pct, 7, "the saved result shows straight away")

  local started = hs.timer.secondsSinceEpoch()
  return function()
    local ready = got.stdin and got.junk and got.slow and p.results.codex and p.errors.busy
    if not ready and hs.timer.secondsSinceEpoch() - started < 8 then return false end
    t.eq(got.stdin and got.stdin.facts[1], "stdin:yes", "the key goes in on stdin")
    t.eq(got.junk and got.junk.error, "Usage check failed", "output that isn't JSON")
    t.eq(got.slow and got.slow.error, "Didn't answer", "a fetcher that hangs is stopped")
    t.eq(p.results.codex and p.results.codex.limits[1].pct, 41, "a good result is kept")
    t.ok(mem["claudeUsageWidget.provider.codex"], "and saved for the next reload")
    t.eq(p.errors.busy, "Busy", "an error is kept apart from the numbers")
    t.eq(p.results.busy, nil, "an error leaves no numbers")
    t.ok((p.waitUntil.busy or 0) > os.time(), "retry_after holds the next check")
    p:refresh("busy")
    t.eq(p.running.busy, nil, "no check before then")
    t.ok(#told >= 2, "onResult hears about each check")
    p:stop()
    p2:stop()
    return true
  end
end
