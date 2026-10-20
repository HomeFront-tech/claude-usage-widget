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

function A.configure(ai, dir)
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
  if type(model) ~= "string" or model:find(":", 1, true) then model = "haiku" end
  local config = {
    model = model, search = expandedList(AI.search),
    private_paths = expandedList(AI.private_paths), sources = sources,
    web_search = AI.web_search ~= false,
  }
  local file = assert(io.open(AGENT .. "/config.json", "w"))
  file:write(hs.json.encode(config))
  file:close()
  return A
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

function A.run(req, done)
  local task
  local ok, created = pcall(hs.task.new, "/usr/bin/python3", function(_, out)
    running[task] = nil
    local info = lastJson(out)
    if not info then return done(nil, "Claude didn't answer.", {}) end
    if info.ok and type(info.text) == "string" and info.text ~= "" then
      return done(info.text, nil, info)
    end
    done(nil, type(info.error) == "string" and info.error ~= "" and info.error or "Claude didn't answer.", info)
  end, { DIR .. "/bin/buddy-agent" })
  if not ok or not created then return done(nil, "Claude didn't answer.", {}) end
  task = created
  local startedOk, started = pcall(function()
    task:setEnvironment({ HOME = HOME, PATH = PATH, BUDDY_AGENT_DIR = AGENT })
    task:setInput(hs.json.encode(req))
    running[task] = true
    return task:start()
  end)
  if not startedOk or not started then
    running[task] = nil
    return done(nil, "Claude didn't answer.", {})
  end
end

function A.unprompted(now)
  local day = os.date("%Y-%m-%d", now)
  local state = hs.settings.get("claudeBuddy.agentDay") or {}
  if type(state) ~= "table" or state.day ~= day or type(state.n) ~= "number" then
    state = { day = day, n = 0 }
  end
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
