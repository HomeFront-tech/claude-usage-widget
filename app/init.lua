-- Claude Buddy.app's config. tools/build-app points the app here (its MJConfigFile), so
-- this copy of the Hammerspoon engine runs only the card and Buddy, from the folder above
-- this one. The regular Hammerspoon keeps ~/.hammerspoon/init.lua and whatever else you
-- run there; the card and Buddy step aside in it while this app exists (app.lua).

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/app/[^/]*$") or (os.getenv("HOME") .. "/.hammerspoon/claude-usage-widget")

-- The hs command line reaches this app as `hs -m ClaudeBuddy -c '…'`. The port name
-- "Hammerspoon" stays with the regular Hammerspoon, so both can answer at once.
local ipc = require("hs.libipc")
local localPort = ipc.localPort
ipc.localPort = function(name, fn) return localPort(name == "Hammerspoon" and "ClaudeBuddy" or name, fn) end
require("hs.ipc")
ipc.localPort = localPort

local CFG = (function()
  local chunk = loadfile(DIR .. "/config.lua")
  local ok, cfg = pcall(chunk or function() end)
  return ok and type(cfg) == "table" and cfg or {}
end)()

hs.menuIcon(false)               -- no hammer: the card's own menu bar item stands in
hs.dockIcon(CFG.dock_icon ~= false)
hs.openConsoleOnDockClick(false) -- a Dock click brings Buddy, not the engine's console
hs.dockIconClickCallback = function()
  if ClaudeBuddy and ClaudeBuddy.present then ClaudeBuddy.present() end
end

local App = dofile(DIR .. "/app.lua")
App.started()
-- Start at login the first time; the setup wizard's switch decides after that.
if not hs.settings.get("claudeBuddy.appLoginSet") then
  hs.settings.set("claudeBuddy.appLoginSet", true)
  hs.autoLaunch(true)
end

-- Keep both global (no `local`): Hammerspoon cleans up local objects.
ClaudeUsage = dofile(DIR .. "/usage_widget.lua").start()
ClaudeBuddy = dofile(DIR .. "/buddy.lua").start()

-- The Dock icon's "Check for Updates..." runs Buddy's update check, not the engine's (app.lua).
ClaudeBuddyDock = App.dockMenu({ dir = DIR, check = function()
  if ClaudeUsage and ClaudeUsage.updater then ClaudeUsage.updater.checkNow() end
end })
