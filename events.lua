-- Things that happen on the Mac, for the buddy to comment on (Hammerspoon module)
--
-- Built in: waking up, unlocking, screens coming and going, USB gadgets, headphones,
-- the internet dropping and coming back, drives, screenshots, downloads and app
-- crashes. Your own come from config.lua `events`: a log file to watch for a line
-- (Lua pattern), or a folder to watch for new files. See config.example.lua.
--
-- Each event calls react{ id, mood, lines, caps, file, text } and the buddy picks a
-- line and shows the mood for a few seconds. Events repeat at most once a minute.

local E = {}

local HOME = os.getenv("HOME")
local TEMP = { "%.crdownload$", "%.download$", "%.part$", "%.tmp$", "%.partial$", "^%.", "^~%$" }
local last = {} -- event id -> when it last fired

local function expand(p) return (p:gsub("^~", HOME)) end

local function screenshotDir()
  local out = hs.execute("defaults read com.apple.screencapture location 2>/dev/null") or ""
  out = out:gsub("%s+$", "")
  return out ~= "" and expand(out) or HOME .. "/Desktop"
end

-- Built-in reactions. Lines: %1 is the first detail (device or app name), %f a file name.
local BUILTIN = {
  wake       = { mood = "startle", lines = { "I'm up! I'm up!", "Good nap. What'd I miss?", "Back in business!", "Who turned the lights off?" } },
  unlock     = { mood = "joy", lines = { "Welcome back {name}!", "There you are {name}!", "Missed you {name}!" } },
  screenAdd  = { mood = "curious", lines = { "Ooh, another screen!", "More room for me!", "A new screen? Fancy." } },
  screenGone = { mood = "curious", lines = { "Hey, where'd that screen go?", "One screen down. Game time?", "Less screen, more focus." } },
  usb        = { mood = "curious", lines = { "Ooh, a %1!", "What's this %1 for?", "%1 plugged in. Hi!" } },
  headphones = { mood = "music", lines = { "Headphones on. Focus mode!", "Ooh, private listening.", "%1 connected. Jam time?" } },
  speakers   = { mood = "music", lines = { "Sound's on %1 now.", "Switching to %1!" } },
  offline    = { mood = "worried", lines = { "Uh oh, the internet's gone!", "Hello? Internet?", "We're offline!" } },
  online     = { mood = "joy", lines = { "We're back online!", "Internet's back. Phew!", "Reconnected!" } },
  drive      = { mood = "curious", lines = { "A new drive! What's on it?", "%1 mounted.", "Ooh, storage!" } },
  screenshot = { mood = "joy", lines = { "Say cheese!", "Snap! Am I in it?", "Ooh, a screenshot.", "Got my good side?" } },
  download   = { mood = "joy", lines = { "Download's done: %f", "Got %f!", "%f landed." } },
  crash      = { mood = "worried", lines = { "Uh oh, %1 crashed!", "%1 fell over…", "RIP %1. Again?" } },
}

local function fire(id, spec, extra, cooldown)
  local t = hs.timer.secondsSinceEpoch()
  if last[id] and t - last[id] < (cooldown or 60) then return end
  last[id] = t
  local ev = { id = id, mood = spec.mood, lines = spec.lines, ai = spec.ai }
  for k, v in pairs(extra or {}) do ev[k] = v end
  E.react(ev)
end

local function short(name)
  name = name:gsub("%.[%w]+$", "")
  return #name > 22 and name:sub(1, 20) .. "…" or name
end

local function isTemp(name)
  for _, p in ipairs(TEMP) do
    if name:find(p) then return true end
  end
  return false
end

-- New files in a folder (not its subfolders): onFile(path, name).
local function watchFolder(dir, onFile)
  dir = expand(dir):gsub("/+$", "")
  if not hs.fs.attributes(dir) then return nil end
  local seen = {}
  return hs.pathwatcher.new(dir, function(paths, flags)
    for i, p in ipairs(paths) do
      local f = flags[i] or {}
      local parent, name = p:match("^(.*)/([^/]+)$")
      if parent == dir and f.itemIsFile and (f.itemCreated or f.itemRenamed) and not seen[p]
          and not isTemp(name) and hs.fs.attributes(p) then
        seen[p] = true
        onFile(p, name)
      end
    end
  end):start()
end

-- Log files are checked every few seconds; only text added since the last look counts,
-- so a pattern may span lines (handy for JSON logs).
local function tailer(rules)
  local logs = {}
  for _, r in ipairs(rules) do
    local path = expand(r.log)
    local a = hs.fs.attributes(path)
    logs[#logs + 1] = { rule = r, path = path, offset = a and a.size or 0 }
  end
  return hs.timer.doEvery(3, function()
    for _, l in ipairs(logs) do
      local a = hs.fs.attributes(l.path)
      local size = a and a.size or 0
      if size < l.offset then l.offset = 0 end -- rotated or truncated
      if size > l.offset then
        local fh = io.open(l.path, "r")
        if fh then
          fh:seek("set", math.max(l.offset, size - 65536))
          local chunk = fh:read(size - l.offset) or ""
          fh:close()
          l.offset = size
          local caps = { chunk:match(l.rule.match) }
          if #caps > 0 then
            fire("log:" .. l.rule.log .. l.rule.match, l.rule, { caps = caps, text = chunk }, l.rule.cooldown)
          end
        end
      end
    end
  end)
end

-- cfg: config.lua table. react(ev): the buddy's reaction function.
function E.start(cfg, react)
  E.react = react
  local on = cfg.system_events ~= false
  E.watchers = {}
  local function keep(w) if w then E.watchers[#E.watchers + 1] = w end end

  if on then
    keep(hs.caffeinate.watcher.new(function(ev)
      local W = hs.caffeinate.watcher
      if ev == W.systemDidWake then fire("wake", BUILTIN.wake)
      elseif ev == W.screensDidUnlock then fire("unlock", BUILTIN.unlock, nil, 600) end
    end):start())

    local screens = #hs.screen.allScreens()
    keep(hs.screen.watcher.new(function()
      local n = #hs.screen.allScreens()
      if n > screens then fire("screen", BUILTIN.screenAdd, nil, 20)
      elseif n < screens then fire("screen", BUILTIN.screenGone, nil, 20) end
      screens = n
    end):start())

    keep(hs.usb.watcher.new(function(d)
      local name = d.productName or ""
      if d.eventType == "added" and name ~= "" and not name:lower():find("hub", 1, true) then
        fire("usb:" .. name, BUILTIN.usb, { caps = { name } }, 120)
      end
    end):start())

    local out = hs.audiodevice.defaultOutputDevice()
    local outName = out and out:name() or ""
    hs.audiodevice.watcher.setCallback(function(ev)
      if ev ~= "dOut" then return end
      local d = hs.audiodevice.defaultOutputDevice()
      local name = d and d:name() or ""
      if name == outName or name == "" then return end
      outName = name
      local l = name:lower()
      local phones = l:find("airpods") or l:find("headphone") or l:find("buds") or l:find("beats") or l:find("headset")
      fire("audio", phones and BUILTIN.headphones or BUILTIN.speakers, { caps = { name } }, 30)
    end)
    hs.audiodevice.watcher.start()
    E.audio = true

    local online
    E.net = hs.network.reachability.internet():setCallback(function(_, flags)
      local up = (flags & hs.network.reachability.flags.reachable) > 0
      if online ~= nil and up ~= online then
        if up then fire("net", BUILTIN.online, nil, 20) else fire("net", BUILTIN.offline, nil, 20) end
      end
      online = up
    end):start()
    online = (E.net:status() & hs.network.reachability.flags.reachable) > 0

    keep(hs.fs.volume.new(function(ev, info)
      if ev == hs.fs.volume.didMount and info and info.path then
        fire("drive", BUILTIN.drive, { caps = { info.path:match("([^/]+)$") or "Drive" } }, 60)
      end
    end):start())

    keep(watchFolder(screenshotDir(), function(_, name)
      local l = name:lower()
      if l:find("^screenshot") or l:find("^screen shot") or l:find("^cleanshot") then
        fire("screenshot", BUILTIN.screenshot, { file = short(name) }, 10)
      end
    end))
    keep(watchFolder(HOME .. "/Downloads", function(_, name)
      fire("download", BUILTIN.download, { file = short(name) }, 20)
    end))
    keep(watchFolder(HOME .. "/Library/Logs/DiagnosticReports", function(_, name)
      local app = name:match("^(.-)[-_]%d%d%d%d%-%d%d%-%d%d")
      local skip = { JetsamEvent = true, stacks = true, LowBatteryLog = true, Kernel = true }
      if app and name:find("%.ips$") and not skip[app] and not app:find("^ExcUserFault") and not name:find("cpu_resource") and not name:find("diskwrites") then
        fire("crash:" .. app, BUILTIN.crash, { caps = { app } }, 300)
      end
    end))
  end

  local logs = {}
  for _, r in ipairs(cfg.events or {}) do
    if r.log and r.match then
      logs[#logs + 1] = r
    elseif r.folder then
      keep(watchFolder(r.folder, function(_, name)
        local caps = { name:match(r.match or ".") }
        if #caps > 0 then fire("folder:" .. r.folder, r, { caps = caps, file = short(name) }, r.cooldown or 10) end
      end))
    end
  end
  if #logs > 0 then E.tail = tailer(logs) end
  return E
end

-- Fire a built-in reaction by hand, e.g. ClaudeBuddy.event("crash", "Safari").
function E.test(id, detail)
  local spec = BUILTIN[id]
  if spec then last[id] = nil; fire(id, spec, { caps = { detail or "Gadget" }, file = detail or "file.pdf" }, 0) end
end

return E
