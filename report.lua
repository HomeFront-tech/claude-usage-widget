-- Bug reports (Hammerspoon module, opened from the buddy's menu)
--
-- "Report a bug…" opens a new GitHub issue for this widget in the browser, with
-- headings to fill in and the details a fix usually needs: the widget version and how
-- it was installed, macOS, Hammerspoon, permissions, which features are on, and the
-- widget's recent errors from the Hammerspoon console. The home folder shows as ~, and
-- nothing from config.lua goes in except on/off switches and the brain's model name.
-- The widget sends nothing itself: you read and edit the report on GitHub, and it's
-- filed only when you click Submit there (GitHub needs a free account).
-- Try it: hs -c 'ClaudeBuddy.reportBug()'

local R = {}

local REPO = "HomeFront-tech/claude-usage-widget" -- as in updater.lua; config.lua update_repo overrides
local MAX_ERRORS = 10 -- console lines kept, newest last
local MAX_URL = 7000  -- GitHub turns away much longer new-issue links

local HOME = os.getenv("HOME")

local function enc(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function tidy(s) return (s:gsub((HOME:gsub("%p", "%%%0")), "~")) end

local function onOff(b) return b and "on" or "off" end

local function version(dir)
  local fh = io.open(dir .. "/VERSION")
  local v = fh and (fh:read("l") or ""):match("[%d.]+") or "?"
  if fh then fh:close() end
  return v
end

-- "git v1.3.0-2-gabc1234-dirty" for a clone: commits past the tag, and local changes.
local function install(dir)
  if not hs.fs.attributes(dir .. "/.git") then return "download" end
  local out, ok = hs.execute("/usr/bin/git -C '" .. dir:gsub("'", "'\\''") .. "' describe --tags --always --dirty 2>/dev/null")
  return ok and "git " .. out:gsub("%s+$", "") or "git"
end

local function features(dir, cfg)
  local ai = type(cfg.ai) == "table" and cfg.ai or nil
  return table.concat({
    "setup done: " .. (hs.fs.attributes(dir .. "/config.lua") and "yes" or "no"),
    "brain: " .. (ai and (ai.model or "on") or "off"),
    "dictation: " .. onOff(ai and ai.dictation ~= false),
    "chatter: " .. (cfg.chatter or "chatty"),
    "on top: " .. onOff(cfg.buddy_on_top),
    "Mac events: " .. onOff(cfg.system_events ~= false),
    "own events: " .. #(cfg.events or {}),
    "update checks: " .. onOff(cfg.check_updates ~= false),
    "history import: " .. onOff(cfg.import_history == true),
  }, " · ")
end

-- Console lines that point into this widget's files: its errors and their tracebacks.
local function recentErrors(dir)
  local here = ((dir:match("([^/]+)/?$") or "") .. "/"):gsub("%p", "%%%0") .. "[%w_]+%.lua:%d+"
  local found = {}
  for line in hs.console.getConsole():gmatch("[^\r\n]+") do
    if line:find(here) then found[#found + 1] = tidy(line):sub(1, 200) end
  end
  return { table.unpack(found, math.max(1, #found - MAX_ERRORS + 1)) }
end

local function body(dir, cfg, errors)
  local mac = hs.host.operatingSystemVersion()
  local update = ClaudeUsage and ClaudeUsage.updater and ClaudeUsage.updater.available
  local screen = hs.screenRecordingState and onOff(hs.screenRecordingState()) or "?"
  local lines = {
    "### What happened?", "", "",
    "### What did you expect?", "", "",
    "### How can we make it happen again?", "1. ", "",
    "### Details",
    string.format("- Widget: v%s (%s)%s", version(dir), install(dir),
      update and (" · v" .. update.version .. " is out") or ""),
    string.format("- macOS %d.%d.%d (%s) · Hammerspoon %s", mac.major, mac.minor, mac.patch,
      (hs.execute("/usr/bin/uname -m"):gsub("%s+$", "")), hs.processInfo.version),
    "- Screen Recording: " .. screen .. " · Accessibility: " .. onOff(hs.accessibilityState()),
    "- " .. features(dir, cfg),
    "",
  }
  if #errors > 0 then
    lines[#lines + 1] = "<details><summary>Recent widget errors from the Hammerspoon console</summary>"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```"
    for _, e in ipairs(errors) do lines[#lines + 1] = e end
    lines[#lines + 1] = "```"
    lines[#lines + 1] = "</details>"
  else
    lines[#lines + 1] = "No widget errors in the Hammerspoon console."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "_Filled in by the buddy's Report a bug. Check it before you submit and remove anything you'd rather not share._"
  return table.concat(lines, "\n")
end

-- The new-issue link, dropping the oldest console lines until GitHub will take it.
function R.url(dir, cfg)
  local repo = cfg.update_repo or REPO
  local errors = recentErrors(dir)
  while true do
    local url = "https://github.com/" .. repo .. "/issues/new?labels=bug&body=" .. enc(body(dir, cfg, errors))
    if #url <= MAX_URL or #errors == 0 then return url end
    table.remove(errors, 1)
  end
end

-- dir: the widget folder; cfg: config.lua's table.
function R.open(dir, cfg)
  hs.urlevent.openURL(R.url(dir, cfg or {}))
end

return R
