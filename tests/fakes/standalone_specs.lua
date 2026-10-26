-- Run the callback-only regression specs when Hammerspoon IPC is unavailable:
-- lua tests/fakes/standalone_specs.lua [tests/agent_stream_spec.lua ...]
-- This checks callback state, not Hammerspoon itself. Timers never run automatically,
-- JSON uses round-trip fixtures, settings stay in memory, and no files are written.
local realOpen = io.open
local values, files, directories, settings = {}, {}, {}, {}
local serial = 0
local function nextId()
  serial = serial + 1
  return serial
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end
local function timer(delay, callback)
  return { delay = delay, callback = callback, start = function(self) return self end,
    stop = function(self) self.stopped = true; return self end }
end
local function mkdir(path)
  directories[path] = true
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not directories[parent] then mkdir(parent) end
  return true
end
local screen = { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
hs = {
  json = {
    encode = function(value)
      local text = string.format('{"fixture":%020d}', nextId())
      values[text] = copy(value)
      return text
    end,
    decode = function(text)
      if values[text] == nil then error("incomplete JSON fixture") end
      return copy(values[text])
    end,
  },
  task = { new = function() error("unexpected process in standalone spec") end },
  http = { doAsyncRequest = function() error("unexpected network call in standalone spec") end },
  host = { uuid = function() return "fake-" .. nextId() end },
  timer = { doAfter = timer, doEvery = timer, secondsSinceEpoch = function() return os.time() end },
  settings = {
    get = function(key) return copy(settings[key]) end,
    set = function(key, value) settings[key] = copy(value) end,
    clear = function(key) settings[key] = nil end,
  },
  fs = {
    mkdir = mkdir,
    attributes = function(path, key)
      local mode = directories[path] and "directory" or files[path] and "file" or nil
      if not mode then return nil end
      local attrs = { mode = mode, size = files[path] and #files[path] or 0 }
      if key then return attrs[key] end
      return attrs
    end,
    dir = function(path)
      local names = {}
      for full in pairs(directories) do
        if full:sub(1, #path + 1) == path .. "/" then
          local tail = full:sub(#path + 2)
          if not tail:find("/", 1, true) then names[#names + 1] = tail end
        end
      end
      for full in pairs(files) do
        if full:sub(1, #path + 1) == path .. "/" then
          local tail = full:sub(#path + 2)
          if not tail:find("/", 1, true) then names[#names + 1] = tail end
        end
      end
      table.sort(names)
      local index = 0
      return function() index = index + 1; return names[index] end
    end,
  },
  caffeinate = { watcher = { new = function(callback) return timer(0, callback) end } },
  application = { watcher = {} },
  screen = { watcher = {}, primaryScreen = function() return screen end,
    allScreens = function() return { screen } end },
  canvas = { windowLevels = { floating = 1, desktopIcon = 0 } },
  eventtap = {},
  styledtext = { defaultFonts = { system = { name = "System" }, boldSystem = { name = "System Bold" } },
    new = function(text) return text end },
  drawing = { getTextDrawingSize = function(text) return { w = #text * 8, h = 20 } end },
  mouse = { absolutePosition = function() return { x = 0, y = 0 } end },
  window = { list = function() return {} end },
}
io.open = function(path, mode)
  -- Absolute paths are fixtures only, including the hidden Buddy's scratch stores.
  if path:sub(1, 1) == "/" then
    if mode == "w" or mode == "wb" then files[path] = "" end
    if mode == "a" or mode == "ab" then files[path] = files[path] or "" end
    if files[path] == nil then return nil end
    local offset = 0
    return {
      write = function(_, text) files[path] = files[path] .. text end,
      read = function() local text = files[path]:sub(offset + 1); offset = #files[path]; return text end,
      seek = function(_, _, at) offset = at; return offset end,
      close = function() end,
    }
  end
  if mode and mode ~= "r" and mode ~= "rb" then error("unexpected file write in standalone spec") end
  return realOpen(path, mode)
end
os.remove = function(path)
  if files[path] == nil and not directories[path] then return nil end
  files[path], directories[path] = nil, nil
  return true
end

local passed, failed = 0, 0
local specs = { table.unpack(arg) }
if #specs == 0 then
  specs = { "tests/agent_stream_spec.lua", "tests/telegram_recovery_spec.lua", "tests/task_review_spec.lua",
    "tests/tasks_phone_spec.lua", "tests/task_topics_spec.lua" }
end
for _, path in ipairs(specs) do
  local t = { tmpdir = function() local path = "/fake/dir-" .. nextId(); mkdir(path); return path end }
  function t.writeJson(path, value)
    mkdir(path:match("^(.*)/[^/]+$"))
    files[path] = hs.json.encode(value)
  end
  function t.readJson(path) return files[path] and hs.json.decode(files[path]) end
  function t.ok(condition, name)
    if condition then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. path .. ": " .. name) end
  end
  function t.eq(actual, expected, name)
    t.ok(actual == expected, name .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
  local ok, err = pcall(function() dofile(path)(t, ".") end)
  if not ok then failed = failed + 1; print("FAIL " .. path .. ": " .. tostring(err)) end
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
