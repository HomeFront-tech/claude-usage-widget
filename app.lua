-- Claude Buddy.app: the card and Buddy in their own copy of the Hammerspoon engine, with
-- their own name, icon, Dock icon and permissions (tools/build-app makes it; app/init.lua
-- is its config). The regular Hammerspoon keeps whatever else you run in it.
--
-- tools/build-app leaves a note at MARKER: where the app is and which folder it runs.
-- While that app exists, the copy in the regular Hammerspoon steps aside, so the two
-- never run at once. Trash the app and the regular Hammerspoon has Buddy back on its
-- next reload.

local A = {}

A.BUNDLE_ID = "com.github.claude-usage-widget.claude-buddy"
A.NAME = "Claude Buddy"
A.ENGINE = "org.hammerspoon.Hammerspoon"
A.MARKER = (os.getenv("HOME") or "") .. "/Library/Application Support/claude-usage-widget/app.json"

-- The app's own bundle ID, or the regular Hammerspoon's.
function A.selfId() return (hs.processInfo and hs.processInfo.bundleID) or A.ENGINE end

-- Running inside Claude Buddy.app (or a test build of it, whose ID only adds a suffix).
function A.inApp() return A.selfId():sub(1, #A.BUNDLE_ID) == A.BUNDLE_ID end

-- What to call the program macOS asks permissions for.
function A.hostName() return A.inApp() and A.NAME or "Hammerspoon" end

local function readJson(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  local ok, t = pcall(hs.json.decode, s)
  return ok and type(t) == "table" and t or nil
end

local function writeJson(path, t)
  local f = io.open(path .. ".tmp", "w")
  if not f then return false end
  f:write(hs.json.encode(t, true))
  f:close()
  return os.rename(path .. ".tmp", path)
end

-- The same folder, however it's spelt: a trailing slash or a symlinked parent (the app's
-- note has the real path; Hammerspoon may load the folder through a link).
local function real(p) return ((hs.fs.pathToAbsolute(p) or p):gsub("/+$", "")) end
local function same(a, b) return type(a) == "string" and type(b) == "string" and real(a) == real(b) end

-- The note tools/build-app left, while its app is still there (nil once it's trashed).
function A.installed(marker)
  local m = readJson(marker or A.MARKER)
  if not (m and type(m.path) == "string" and hs.fs.attributes(m.path .. "/Contents/Info.plist")) then return nil end
  return m
end

-- In the regular Hammerspoon, with the app made for this folder: don't start here.
function A.stepAside(dir, marker)
  if A.inApp() then return false end
  local m = A.installed(marker)
  return m ~= nil and same(m.dir, dir)
end

-- Right after "Make Buddy an app": the regular Hammerspoon has just stepped aside, so it
-- opens the app once. The app clears the flag when it starts (A.started).
function A.handoff(marker, open)
  local m = A.installed(marker)
  if not (m and m.handoff) then return false end
  ;(open or function(id) hs.task.new("/usr/bin/open", nil, { "-b", id }):start() end)(m.bundle_id or A.BUNDLE_ID)
  return true
end

-- Buddy's settings in the regular Hammerspoon's preferences (its hs.settings), which the
-- app copies into its own the first time it starts after `tools/build-app --migrate`.
-- Copying happens there, once the copy in Hammerspoon has stepped aside, so nothing
-- changes in between. A helper's process ID means nothing in another program, and the
-- specs' leftovers stay behind.
local PREFIXES = { "claudeBuddy.", "claudeUsageWidget.", "claudeWidget." }
local SKIP = { ["claudeBuddy.voicePid"] = true, ["claudeBuddy.appLoginSet"] = true }
local SKIP_PARTS = { ".test.", "skinTest-", ".spec-" }

function A.isBuddyKey(k)
  if type(k) ~= "string" or SKIP[k] then return false end
  for _, part in ipairs(SKIP_PARTS) do
    if k:find(part, 1, true) then return false end
  end
  for _, p in ipairs(PREFIXES) do
    if k:sub(1, #p) == p then return true end
  end
  return false
end

-- prefs: Hammerspoon's preferences as a table; mine: this app's keys; set(k, v) stores one
-- here. Copies nothing when the app has Buddy settings of its own. Returns how many.
function A.migrate(prefs, mine, set)
  for _, k in ipairs(mine or {}) do
    if A.isBuddyKey(k) then return 0 end
  end
  local n = 0
  for k, v in pairs(prefs or {}) do
    if A.isBuddyKey(k) then set(k, v); n = n + 1 end
  end
  return n
end

local function enginePrefs()
  local xml = hs.execute("/usr/bin/defaults export " .. A.ENGINE .. " - 2>/dev/null")
  local ok, t = pcall(hs.plist.readString, xml or "")
  return ok and type(t) == "table" and t or nil
end

-- At the app's start, before the card and Buddy: the one handoff is done, and the first
-- time, Buddy's settings come over from Hammerspoon.
function A.started(marker)
  marker = marker or A.MARKER
  local m = readJson(marker)
  if not (m and (m.handoff or m.migrate)) then return end
  if m.migrate then
    local n = A.migrate(enginePrefs(), hs.settings.getKeys(), hs.settings.set)
    print("ClaudeBuddy app: copied " .. n .. " settings from Hammerspoon")
  end
  m.handoff, m.migrate = nil, nil
  writeJson(marker, m)
end

-- "Make Buddy an app…": builds Claude Buddy.app from this Hammerspoon, then reloads this
-- Hammerspoon, which steps aside and opens the app; the app brings Buddy's settings over.
-- done(ok, message) gets the build's last line when it fails.
function A.make(dir, done, opts)
  opts = opts or {}
  local task = hs.task.new("/usr/bin/python3", function(code, out, err)
    local last = ((err or "") ~= "" and err or out or ""):match("([^\n]+)\n*$") or ""
    if code ~= 0 then return done(false, last ~= "" and last or "The build failed.") end
    done(true)
    if opts.reload ~= false then A.reloadTimer = hs.timer.doAfter(1, hs.reload) end
  end, { "-I", dir .. "/tools/build-app", "--migrate", "--handoff" })
  if not task:start() then return done(false, "Couldn't run tools/build-app.") end
  A.task = task
  return true
end

-- The menu item's version: asks first, then makes the app. say(line, "user") is Buddy's.
function A.offer(dir, say)
  say = say or function() end
  local answer = hs.dialog.blockAlert("Make Buddy an app?",
    "Buddy moves into his own app, Claude Buddy, in your Applications folder, with his own Dock "
    .. "icon and menu bar item. His settings and memory come with him, and Hammerspoon restarts "
    .. "once. macOS asks again for Screen Recording and the microphone, this time for Claude Buddy.",
    "Make the app", "Not now")
  if answer ~= "Make the app" then return false end
  say("Packing my bags…", "user")
  return A.make(dir, function(ok, why)
    if ok then return end
    say("I couldn't make the app: " .. tostring(why), "user")
    print("ClaudeBuddy app: " .. tostring(why))
  end)
end

return A
