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
end
