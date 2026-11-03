-- Update checker (Hammerspoon module, started by the usage card)
--
-- Every 6 hours it asks GitHub for the latest release of this widget. When a newer one
-- is out it sends one macOS notification, puts an "Update available" line on the card
-- and has the buddy mention it. Clicking the card offers to update: a git clone moves
-- to the new release tag (fetch + fast-forward) and Hammerspoon reloads; any other
-- install opens the release page. Your config.lua is never touched.
-- After an update, the first start shows the What's New window (whatsnew.lua).
-- "Check for updates…" (Buddy's right-click menu and the menu bar) asks GitHub right away
-- and always answers: up to date, the same Update / Later dialog, or why it couldn't check.
-- Turn the 6-hourly checks off with check_updates = false in config.lua (or in the setup
-- wizard); checking by hand still works.
-- Publishing an update: tools/release <version> "what changed".

local U = {}

local REPO = "HomeFront-tech/claude-usage-widget" -- config.lua update_repo overrides (for forks)
local EVERY = 6 * 3600
local NOTIFIED_KEY, RAN_KEY = "claudeWidget.notifiedVersion", "claudeWidget.lastRunVersion"

U.repo, U.version = REPO, "0.0.0" -- until start() reads config.lua and VERSION
U.onChange = function() end
U.store = { get = hs.settings.get, set = hs.settings.set } -- specs swap in a table
-- GitHub's answer comes back to done(status, body); specs swap in a fake.
function U.get(url, headers, done) hs.http.asyncGet(url, headers, done) end

local function parse(v)
  local t = {}
  for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
  return t
end

-- Is version a newer than version b?
local function newer(a, b)
  local x, y = parse(a), parse(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return false
end

local function buddySay(text)
  if ClaudeBuddy and ClaudeBuddy.say then ClaudeBuddy.say(text, true) end
end

local function notify(title, text, onClick)
  U.note = hs.notify.new(onClick, {
    title = title, informativeText = text, withdrawAfter = 0,
    hasActionButton = onClick ~= nil, actionButtonTitle = "Update",
  }):send()
end

-- Release notes as plain text for a dialog: no markdown marks, at most ~12 lines.
local function plainNotes(md)
  local lines = {}
  for line in (md or ""):gmatch("[^\r\n]+") do
    line = line:gsub("^#+%s*", ""):gsub("%*%*", ""):gsub("`", ""):gsub("^%s*[-*]%s+", "• ")
    if line:match("%S") and #lines < 12 then lines[#lines + 1] = line end
  end
  return table.concat(lines, "\n")
end

local function releasePage()
  return (U.available and U.available.url) or ("https://github.com/" .. U.repo .. "/releases/latest")
end

local function failed(msg)
  local choice = hs.dialog.blockAlert("Couldn't update automatically", (msg or ""):sub(1, 400)
    .. "\n\nTo update by hand: git -C \"" .. U.dir .. "\" pull", "Open release page", "OK")
  if choice == "Open release page" then hs.urlevent.openURL(releasePage()) end
end

local function git(args, done)
  U.task = hs.task.new("/usr/bin/git", function(code, out, err)
    done(code == 0, (err ~= "" and err) or out)
  end, hs.fnutils.concat({ "-C", U.dir }, args))
  U.task:start()
end

function U.update()
  local a = U.available
  if not a or not hs.fs.attributes(U.dir .. "/.git") then
    hs.urlevent.openURL(releasePage())
    return
  end
  git({ "fetch", "--quiet", "--tags", "origin" }, function(ok, msg)
    if not ok then return failed(msg) end
    git({ "merge", "--ff-only", "--quiet", "v" .. a.version }, function(ok2, msg2)
      if not ok2 then return failed(msg2) end
      notify("Claude widget updated", "Restarting with v" .. a.version .. "…")
      U.reloadTimer = hs.timer.doAfter(1, hs.reload)
    end)
  end)
end

-- Ask before updating, showing what's new.
function U.prompt()
  local a = U.available
  if not a then return end
  local notes = plainNotes(a.notes)
  local choice = hs.dialog.blockAlert("Update the Claude widget to v" .. a.version .. "?",
    (notes ~= "" and ("What's new:\n" .. notes .. "\n\n") or "") .. "You're on v" .. U.version .. ".",
    "Update", "Later")
  if choice == "Update" then U.update() end
end

-- GitHub's answer about the latest release: { version, notes, url }, or nil and a line
-- saying why there's no answer.
function U.parse(status, body)
  if status == 404 then return nil, "There are no releases on GitHub yet." end
  if status == 403 or status == 429 then return nil, "GitHub says to slow down. Try again in an hour." end
  if type(status) ~= "number" or status < 100 then return nil, "I couldn't reach GitHub. Are you online?" end
  if status ~= 200 then return nil, "GitHub didn't answer properly (" .. status .. "). Try again later." end
  local ok, rel = pcall(hs.json.decode, body or "")
  if not ok or type(rel) ~= "table" or type(rel.tag_name) ~= "string" then
    return nil, "GitHub's answer didn't make sense. Try again later."
  end
  return { version = (rel.tag_name:gsub("^v", "")), notes = type(rel.body) == "string" and rel.body or "",
    url = type(rel.html_url) == "string" and rel.html_url or nil }
end

-- Ask GitHub for the latest release; done(rel) or done(nil, why). Keeps U.available and
-- the card up to date either way.
local function fetch(done)
  U.get("https://api.github.com/repos/" .. U.repo .. "/releases/latest",
    { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "claude-usage-widget",
      ["Cache-Control"] = "no-cache" }, -- or macOS may replay a cached answer from before the release
    function(status, body)
      local rel, why = U.parse(status, body)
      if not rel then return done(nil, why) end
      if newer(rel.version, U.version) then
        U.available = rel
        U.onChange()
      elseif U.available then
        U.available = nil
        U.onChange()
      end
      done(rel)
    end)
end

function U.check()
  fetch(function(rel)
    local a = rel and U.available
    if not a or U.store.get(NOTIFIED_KEY) == a.version then return end
    U.store.set(NOTIFIED_KEY, a.version)
    notify("Claude widget v" .. a.version .. " is out",
      "Click the usage card, or Buddy's menu, to see what's new and update.", U.prompt)
    buddySay("Ooh, v" .. a.version .. " is out! Click the card.")
  end)
end

-- The menu item's words: what it will do.
function U.menuTitle()
  return U.available and ("Update to v" .. U.available.version .. "…") or "Check for updates…"
end

-- The answer when nothing newer is out (a copy ahead of the releases says so).
function U.upToDate(latest)
  if latest and newer(U.version, latest) then
    return "You're on v" .. U.version .. ", ahead of the latest release (v" .. latest .. ")."
  end
  return "You're up to date! v" .. U.version .. " is the latest."
end

-- An answer to a check you asked for: Buddy says it, or a notification when he's off the
-- desktop (or not running).
function U.tell(text)
  local B = ClaudeBuddy
  if type(B) == "table" and B.say and B.canvas and (not B.visible or B.visible()) then return B.say(text, "user") end
  U.note = hs.notify.new(nil, { title = "Claude Buddy", informativeText = text }):send()
end

-- "Check for updates…": ask GitHub now. A newer release gets the Update / Later dialog
-- (nothing installs without that yes); otherwise it says you're up to date, or why it
-- couldn't check.
function U.checkNow()
  if U.checking and os.time() - U.checking < 60 then return U.tell("Still checking for updates…") end
  U.checking = os.time() -- a minute at most, in case GitHub's answer never comes
  fetch(function(rel, why)
    U.checking = nil
    if U.available then
      U.store.set(NOTIFIED_KEY, U.available.version) -- you've seen it; no notification later
      return U.prompt()
    end
    U.tell(rel and U.upToDate(rel.version) or why)
  end)
end

-- opts: dir (the widget folder), onChange() to redraw the card
function U.start(opts)
  U.dir, U.onChange = opts.dir, opts.onChange or function() end
  local chunk = loadfile(U.dir .. "/config.lua")
  local ok, cfg = pcall(chunk or function() end)
  cfg = ok and type(cfg) == "table" and cfg or {}
  U.repo = cfg.update_repo or REPO

  local fh = io.open(U.dir .. "/VERSION")
  U.version = fh and (fh:read("l") or ""):match("[%d.]+") or "0.0.0"
  if fh then fh:close() end

  -- What's new (whatsnew.lua): after an update, a window shows what changed since the
  -- version you came from; a reload before it opens still gets it. No window, just a hello.
  -- If whatsnew.lua is missing or broken, the card still starts and Buddy just says hello.
  local ok, whatsNew = pcall(function()
    ClaudeWhatsNew = ClaudeWhatsNew or dofile(U.dir .. "/whatsnew.lua")
    return ClaudeWhatsNew.init(U.dir)
  end)
  if not ok then print("updater: What's New unavailable: " .. tostring(whatsNew)); whatsNew = nil end
  local last = hs.settings.get(RAN_KEY)
  local updated = last and newer(U.version, last)
  if updated and whatsNew then whatsNew.markFrom(last) end -- first start after an update
  if updated or (whatsNew and hs.settings.get("claudeWidget.whatsNewFrom")) then
    U.helloTimer = hs.timer.doAfter(6, function()
      local shown = whatsNew and select(2, pcall(whatsNew.showPending)) == true
      if not shown and updated then buddySay("I just got updated to v" .. U.version .. "!") end
    end)
  end
  hs.settings.set(RAN_KEY, U.version)

  if cfg.check_updates ~= false then
    U.firstTimer = hs.timer.doAfter(20, U.check)
    U.timer = hs.timer.doEvery(EVERY, U.check)
  end
  return U
end

return U
