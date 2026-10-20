-- Update checker (Hammerspoon module, started by the usage card)
--
-- Every 6 hours it asks GitHub for the latest release of this widget. When a newer one
-- is out it sends one macOS notification, puts an "Update available" line on the card
-- and has the buddy mention it. Clicking the card offers to update: a git clone moves
-- to the new release tag (fetch + fast-forward) and Hammerspoon reloads; any other
-- install opens the release page. Your config.lua is never touched.
-- Turn checks off with check_updates = false in config.lua (or in the setup wizard).
-- Publishing an update: tools/release <version> "what changed".

local U = {}

local REPO = "HomeFront-tech/claude-usage-widget" -- config.lua update_repo overrides (for forks)
local EVERY = 6 * 3600
local NOTIFIED_KEY, RAN_KEY = "claudeWidget.notifiedVersion", "claudeWidget.lastRunVersion"

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

function U.check()
  hs.http.asyncGet("https://api.github.com/repos/" .. U.repo .. "/releases/latest",
    { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "claude-usage-widget",
      ["Cache-Control"] = "no-cache" }, -- or macOS may replay a cached answer from before the release
    function(status, body)
      if status ~= 200 then return end
      local ok, rel = pcall(hs.json.decode, body or "")
      if not ok or type(rel) ~= "table" or type(rel.tag_name) ~= "string" then return end
      local v = rel.tag_name:gsub("^v", "")
      if not newer(v, U.version) then
        if U.available then U.available = nil; U.onChange() end
        return
      end
      U.available = { version = v, notes = rel.body or "", url = rel.html_url }
      U.onChange()
      if hs.settings.get(NOTIFIED_KEY) ~= v then
        hs.settings.set(NOTIFIED_KEY, v)
        notify("Claude widget v" .. v .. " is out", "Click the usage card to see what's new and update.", U.prompt)
        buddySay("Ooh, v" .. v .. " is out! Click the card.")
      end
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

  local last = hs.settings.get(RAN_KEY)
  if last and newer(U.version, last) then -- first start after an update
    U.helloTimer = hs.timer.doAfter(6, function() buddySay("I just got updated to v" .. U.version .. "!") end)
  end
  hs.settings.set(RAN_KEY, U.version)

  if cfg.check_updates ~= false then
    U.firstTimer = hs.timer.doAfter(20, U.check)
    U.timer = hs.timer.doEvery(EVERY, U.check)
  end
  return U
end

return U
