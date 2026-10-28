-- Checks the AIs on the usage card other than Claude (Hammerspoon module). Each runs
-- bin/ai-usage on its own timer, the way usage_widget.lua runs bin/claude-usage: one check
-- at a time per AI, a pause when the service asks for one (retry_after), and the last good
-- numbers saved in hs.settings so a reload shows them straight away. A slow or broken AI
-- only ever holds up its own row.

local Poll = {}
local SAVED = "claudeUsageWidget.provider." -- .. id: the last good result

-- Codex finds its own tools on this PATH; Hammerspoon's own is shorter.
local function env()
  local home = os.getenv("HOME") or ""
  return { HOME = home, USER = os.getenv("USER"), LOGNAME = os.getenv("LOGNAME"), TMPDIR = os.getenv("TMPDIR"),
    PATH = home .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" }
end

-- One check: python -I script args…, with input on stdin when given (a key being checked
-- before Save). done(res) runs once, with the fetcher's JSON or a short error.
Poll.tasks = {} -- running checks and their timers, kept referenced until they finish
function Poll.run(python, script, args, input, done, timeout)
  local finished, task, guard = false, nil, nil
  local function finish(res)
    if finished then return end
    finished = true
    if guard then guard:stop() end
    if task then Poll.tasks[task] = nil end
    done(res)
  end
  local argv = { "-I", script }
  for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
  local made, created = pcall(hs.task.new, python, function(_, out)
    local ok, res = pcall(hs.json.decode, out or "")
    finish(ok and type(res) == "table" and res or { ok = false, error = "Usage check failed" })
  end, argv)
  if not (made and created) then return finish({ ok = false, error = "Usage check failed" }) end
  task = created
  task:setEnvironment(env())
  if input then task:setInput(input) end
  Poll.tasks[task] = true
  if not task:start() then return finish({ ok = false, error = "Usage check failed" }) end
  guard = hs.timer.doAfter(timeout or 30, function()
    if task:isRunning() then task:terminate() end
    finish({ ok = false, error = "Didn't answer" })
  end)
  Poll.tasks[task] = guard
  return task
end

local Poller = {}
Poller.__index = Poller

-- opts: python, script, ids, argsFor(id), refreshFor(id) in seconds, onResult(id), and
-- optionally store ({ get, set }, default hs.settings) and timeout (seconds, default 30).
function Poll.new(opts)
  return setmetatable({ opts = opts, store = opts.store or hs.settings,
    results = {}, errors = {}, running = {}, waitUntil = {}, timers = {} }, Poller)
end

function Poller:refresh(id)
  if self.running[id] or os.time() < (self.waitUntil[id] or 0) then return end
  local o = self.opts
  self.running[id] = Poll.run(o.python, o.script, o.argsFor(id), nil, function(res)
    self.running[id] = nil
    if res.ok then
      self.results[id], self.errors[id] = res, nil
      self.store.set(SAVED .. id, res)
    else
      self.errors[id] = type(res.error) == "string" and res.error or "Usage check failed"
      if res.retry_after then
        self.waitUntil[id] = os.time() + math.max(60, math.min(tonumber(res.retry_after) or 600, 3600))
      end
    end
    if o.onResult then o.onResult(id) end
  end, o.timeout)
end

function Poller:refreshAll()
  for _, id in ipairs(self.opts.ids) do self:refresh(id) end
end

-- Shows the saved numbers, checks each AI whose numbers are over a minute old, and starts
-- one timer per AI at its own refresh.
function Poller:start()
  for _, id in ipairs(self.opts.ids) do
    local saved = self.store.get(SAVED .. id)
    if type(saved) == "table" and saved.ok then self.results[id] = saved end
    local fresh = type(saved) == "table" and type(saved.fetched_at) == "number" and os.time() - saved.fetched_at < 60
    if not fresh then self:refresh(id) end
    self.timers[id] = hs.timer.doEvery(self.opts.refreshFor(id), function() self:refresh(id) end)
  end
  return self
end

function Poller:stop()
  for _, timer in pairs(self.timers) do timer:stop() end
  self.timers = {}
end

return Poll
