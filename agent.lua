-- Claude Code runner and local state for Buddy's optional Haiku brain.
local A = {}
local HOME = os.getenv("HOME") or ""
local PATH = HOME .. "/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
local AGENT, DIR, AI
local running = {}

local function expand(path)
  if type(path) ~= "string" then return path end
  if path == "~" then return HOME end
  if path:sub(1, 2) == "~/" then return HOME .. path:sub(2) end
  return path
end

local function expandedList(items)
  local out = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do out[#out + 1] = expand(item) end
  return out
end

local function mkdirs(path)
  local sofar = ""
  for part in path:gmatch("[^/]+") do
    sofar = sofar .. "/" .. part
    if not hs.fs.attributes(sofar) then hs.fs.mkdir(sofar) end
  end
end

-- extra (buddy.lua): tasks = false when config.lua turns tasks off, projects = its folders.
function A.configure(ai, dir, health, extra)
  extra = type(extra) == "table" and extra or {}
  AI, DIR = ai or {}, dir
  AGENT = expand(AI.agent_dir or "~/Library/Application Support/claude-usage-widget/agent")
  mkdirs(AGENT)
  local sources = {}
  for name, source in pairs(type(AI.sources) == "table" and AI.sources or {}) do
    if type(source) == "table" then
      sources[name] = { cmd = expandedList(source.cmd), about = source.about, arg = source.arg }
    end
  end
  local model = AI.model
  if type(model) ~= "string" or not (model == "auto" or model == "haiku" or
    model == "sonnet" or model == "opus" or model == "fable" or
    model:sub(1, 7) == "claude-") then model = "haiku" end
  local config = {
    model = model, search = expandedList(AI.search),
    private_paths = expandedList(AI.private_paths), sources = sources,
    web_search = AI.web_search ~= false,
    health = health == true, -- chat gets the health tools only when config.lua turns health on
    tasks = extra.tasks ~= false, -- chat gets the task tools (tasks.lua) unless config.lua says tasks = false
    projects = expandedList(extra.projects),
    watch_min = AI.watch_min or 15,
  }
  local file = assert(io.open(AGENT .. "/config.json", "w"))
  file:write(hs.json.encode(config))
  file:close()
  return A
end

function A.setModel(model)
  local path = AGENT .. "/config.json"
  local file = assert(io.open(path, "r"))
  local config = hs.json.decode(file:read("*a"))
  file:close()
  config.model = model
  file = assert(io.open(path, "w"))
  file:write(hs.json.encode(config))
  file:close()
end

function A.dir() return AGENT end

local function lastJson(out)
  local line
  for candidate in (out or ""):gmatch("[^\r\n]+") do
    if candidate:sub(1, 1) == "{" then line = candidate end
  end
  if not line then return nil end
  local ok, value = pcall(hs.json.decode, line)
  return ok and type(value) == "table" and value or nil
end

function A.run(req, done, onPartial)
  local task, grace
  local pending, final = "", nil
  local streamed, ended, finished = onPartial ~= nil, false, false
  local function readLines(chunk)
    pending = pending .. (chunk or "")
    while true do
      local line, rest = pending:match("^([^\n]*)\n(.*)$")
      if not line then break end
      pending = rest
      local ok, value = pcall(hs.json.decode, line)
      if ok and type(value) == "table" then
        if type(value.partial) == "string" and onPartial then
          local delivered = pcall(onPartial, value.partial)
          if not delivered then onPartial = nil end -- preview failure must not lose the finished answer
        end
        if value.ok ~= nil then final = value end
      end
    end
  end
  local function result()
    local info = final or lastJson(pending)
    return info and info.ok ~= nil and info or nil
  end
  local function finish()
    if finished then return end
    finished = true
    if grace then grace:stop() grace = nil end
    if task then running[task] = nil end
    local info = result()
    if not info then return done(nil, "Claude didn't answer.", {}) end
    if info.ok and type(info.text) == "string" and info.text ~= "" then
      return done(info.text, nil, info)
    end
    done(nil, type(info.error) == "string" and info.error ~= "" and info.error or "Claude didn't answer.", info)
  end
  local function complete(_, out)
    if finished or ended then return end
    ended = true
    if streamed then readLines(out or "") else pending = out or "" end
    if not streamed or result() then return finish() end
    -- Hammerspoon can report termination before delivering the last stdout chunk.
    grace = hs.timer.doAfter(0.25, finish)
  end
  local function stream(_, out)
    if finished then return true end
    readLines(out or "")
    if ended and result() then finish() end
    return true
  end
  local ok, created
  if onPartial then
    ok, created = pcall(hs.task.new, "/usr/bin/python3", complete, stream, { DIR .. "/bin/buddy-agent" })
  else
    ok, created = pcall(hs.task.new, "/usr/bin/python3", complete, { DIR .. "/bin/buddy-agent" })
  end
  if not ok or not created then return done(nil, "Claude didn't answer.", {}) end
  task = created
  local startedOk, started = pcall(function()
    -- Claude finds your login in the keychain by USER
    task:setEnvironment({ HOME = HOME, PATH = PATH, BUDDY_AGENT_DIR = AGENT,
      USER = os.getenv("USER"), LOGNAME = os.getenv("LOGNAME"), TMPDIR = os.getenv("TMPDIR") })
    task:setInput(hs.json.encode(req) .. "\n")
    running[task] = true
    return task:start()
  end)
  if not startedOk or not started then
    return finish()
  end
end

local function today(now)
  local day = os.date("%Y-%m-%d", now)
  local state = hs.settings.get("claudeBuddy.agentDay") or {}
  if type(state) ~= "table" or state.day ~= day or type(state.n) ~= "number" then
    state = { day = day, n = 0 }
  end
  return state, day
end

-- Is today's cap on unprompted calls used up? Only looks; it doesn't count a call.
function A.capReached(now)
  return (today(now)).n >= (AI.daily_unprompted or 300)
end

function A.unprompted(now)
  local state = today(now)
  if state.n >= (AI.daily_unprompted or 300) then return false end
  state.n = state.n + 1
  hs.settings.set("claudeBuddy.agentDay", state)
  return true
end

function A.takeNotes()
  local path = AGENT .. "/notes-new.jsonl"
  local file = io.open(path, "r")
  if not file then return {} end
  local notes = {}
  for line in file:lines() do
    if line:sub(1, 1) == "{" then
      local ok, value = pcall(hs.json.decode, line)
      if ok and type(value) == "table" and type(value.note) == "string" and value.note ~= "" then
        notes[#notes + 1] = value.note
      end
    end
  end
  file:close()
  file = io.open(path, "w")
  if file then file:close() end
  return notes
end

function A.putNotes(notes)
  if #notes == 0 then return end
  local file = assert(io.open(AGENT .. "/notes-new.jsonl", "a"))
  for _, note in ipairs(notes) do file:write(hs.json.encode({ note = note }) .. "\n") end
  file:close()
end

return A
