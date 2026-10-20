return function(t, dir)
  local jobLine = dofile(dir .. "/job_line.lua")
  local long = string.rep("x", 200)
  local failure = jobLine("Daily\nstatus", false, "private error")
  local longSuccess, longFailure = jobLine(long, true), jobLine(long, false)

  t.eq(jobLine("Daily status", true), "Your Daily status is up.", "success wording")
  t.eq(failure, "Daily status didn't come through.", "failure wording")
  t.ok(not failure:find("\n", 1, true), "failure is one line")
  t.ok(not jobLine("Daily\nstatus", true):find("\n", 1, true), "success is one line")
  t.ok(utf8.len(longSuccess) and utf8.len(longSuccess) <= 140, "success length capped")
  t.ok(utf8.len(longFailure) and utf8.len(longFailure) <= 140, "failure length capped")
  t.ok(longFailure:sub(-#" didn't come through.") == " didn't come through.",
    "failure wording survives clipping")
  t.ok(not failure:find("private error", 1, true), "failure excludes error text")
  t.eq(jobLine("Daily status", "start"), "On it: Daily status…", "start wording")
  for _, name in ipairs({ "Order 123", "name@example", "cost $50" }) do
    t.eq(jobLine(name, "start"), "On it: your job…", "unsafe start name")
    t.eq(jobLine(name, true), "Your job is up.", "unsafe success name")
    t.eq(jobLine(name, false), "Your job didn't come through.", "unsafe failure name")
  end
  local longStart = jobLine(long, "start")
  t.ok(utf8.len(longStart) and utf8.len(longStart) <= 140, "start length capped")
  t.ok(not jobLine("Daily\nstatus", "start"):find("\n", 1, true), "start is one line")
end
