-- Test runner for the Lua modules, run inside Hammerspoon (there's no standalone Lua):
--   timeout 20 hs -c "return dofile('$R/tests/run.lua')('$R')"
-- Loads every tests/*_spec.lua. A spec returns function(t, dir); it may return a
-- function from that call for checks that finish later (async), which the runner
-- calls every 0.25 s until it returns true or 10 s pass. Async specs only work when
-- the runner is given a done callback: dofile(...)(R, function(summary) ... end).

local function mkdirs(path)
  local sofar = ""
  for part in path:gmatch("[^/]+") do
    sofar = sofar .. "/" .. part
    if not hs.fs.attributes(sofar) then hs.fs.mkdir(sofar) end
  end
end

local function newT(results, spec)
  local t = {}
  local function record(pass, name, why)
    results[#results + 1] = { pass = pass, name = spec .. ": " .. name, why = why }
  end
  function t.ok(cond, name) record(cond and true or false, name, "expected truthy") end
  function t.eq(actual, expected, name)
    record(actual == expected, name, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
  function t.tmpdir()
    local dir = (os.getenv("TMPDIR") or "/tmp/"):gsub("/$", "") .. "/buddy-tests-" .. hs.host.uuid()
    mkdirs(dir)
    return dir
  end
  function t.writeJson(path, tbl)
    mkdirs(path:match("^(.*)/[^/]*$"))
    local f = assert(io.open(path, "w"))
    f:write(hs.json.encode(tbl))
    f:close()
  end
  function t.readJson(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return hs.json.decode(s)
  end
  return t
end

local function summary(results)
  local passed, lines = 0, {}
  for _, r in ipairs(results) do
    if r.pass then passed = passed + 1 else lines[#lines + 1] = "FAIL " .. r.name .. " (" .. (r.why or "") .. ")" end
  end
  table.insert(lines, 1, string.format("%d passed, %d failed", passed, #results - passed))
  return table.concat(lines, "\n")
end

return function(dir, done)
  local results, pending = {}, {}
  -- every module must at least load: a syntax error breaks the live buddy on reload
  for name in hs.fs.dir(dir) do
    if name:match("%.lua$") then
      local _, err = loadfile(dir .. "/" .. name)
      results[#results + 1] = { pass = err == nil, name = "syntax: " .. name, why = err }
    end
  end
  local files = {}
  for name in hs.fs.dir(dir .. "/tests") do
    if name:match("_spec%.lua$") then files[#files + 1] = name end
  end
  table.sort(files)
  for _, name in ipairs(files) do
    local ok, ret = pcall(function()
      local spec = assert(loadfile(dir .. "/tests/" .. name))()
      return spec(newT(results, name), dir)
    end)
    if not ok then results[#results + 1] = { pass = false, name = name, why = tostring(ret) }
    elseif type(ret) == "function" then pending[#pending + 1] = { name = name, check = ret } end
  end
  if #pending == 0 or not done then
    for _, p in ipairs(pending) do results[#results + 1] = { pass = false, name = p.name, why = "async spec needs a done callback" } end
    local s = summary(results)
    if done then done(s) end
    return s
  end
  local started = hs.timer.secondsSinceEpoch()
  local timer
  timer = hs.timer.doEvery(0.25, function()
    for i = #pending, 1, -1 do
      local ok, finished = pcall(pending[i].check)
      if not ok then
        results[#results + 1] = { pass = false, name = pending[i].name, why = tostring(finished) }
        table.remove(pending, i)
      elseif finished then table.remove(pending, i) end
    end
    if #pending == 0 or hs.timer.secondsSinceEpoch() - started > 10 then
      timer:stop()
      for _, p in ipairs(pending) do results[#results + 1] = { pass = false, name = p.name, why = "timed out" } end
      done(summary(results))
    end
  end)
  return "running"
end
