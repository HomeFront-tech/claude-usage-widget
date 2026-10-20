-- Approve / Deny panel for Opus runs Grok asks for (Hammerspoon module)
--
-- bin/buddy-opus-approve writes approvals/<id>.req.json (tool, detail, deadline) and calls
-- ClaudeBuddy.grokApprove(id). This shows the request next to the buddy, one at a time,
-- and writes approvals/<id>.res.json with the owner's answer. No answer by the deadline
-- writes "deny". The first answer written stands. The page is approve.html.

local A = {}

local function readJson(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  local ok, v = pcall(hs.json.decode, s)
  return ok and v or nil
end

local function exists(path) return hs.fs.attributes(path) ~= nil end

-- stateDir: grok state folder. hooks (optional): anchor() -> buddy frame, onShow(req),
-- onDone(req, behavior).
function A.configure(stateDir, hooks)
  A.dir = stateDir .. "/approvals"
  A.hooks = hooks or {}
  A.queue = {}
  return A
end

-- Requests still waiting for an answer whose deadline hasn't passed, oldest first.
function A.pending()
  local list = {}
  if not exists(A.dir) then return list end
  for name in hs.fs.dir(A.dir) do
    local id = name:match("^(.+)%.req%.json$")
    if id and not exists(A.dir .. "/" .. id .. ".res.json") then
      local req = readJson(A.dir .. "/" .. name)
      if req and (req.deadline or 0) > os.time() then list[#list + 1] = req end
    end
  end
  table.sort(list, function(a, b) return (a.deadline or 0) < (b.deadline or 0) end)
  return list
end

-- Write the answer (temp file then rename, so the waiting server never reads half of it).
function A.decide(id, behavior)
  local res = A.dir .. "/" .. id .. ".res.json"
  if exists(res) then return end
  local f = assert(io.open(res .. ".tmp", "w"))
  f:write(hs.json.encode({ behavior = behavior }))
  f:close()
  os.rename(res .. ".tmp", res)
end

local showNext

local function close(req, behavior)
  if A.timer then A.timer:stop(); A.timer = nil end
  if A.wv then
    local wv = A.wv
    A.wv = nil
    hs.timer.doAfter(0, function() wv:delete() end)
  end
  A.showing = nil
  if req then
    A.decide(req.id, behavior)
    if A.hooks.onDone then A.hooks.onDone(req, behavior) end
  end
  showNext()
end

local function show(req)
  A.showing = req
  local fh = assert(io.open(A.page))
  local html = fh:read("a")
  fh:close()
  html = html:gsub("/%*__INIT__%*/null", function()
    return (hs.json.encode({ tool = req.tool or "?", detail = req.detail or "", deadline = req.deadline,
      waiting = #A.queue }):gsub("</", "<\\/"))
  end)
  local uc = hs.webview.usercontent.new("approve")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if (b.type == "allow" or b.type == "deny") and A.showing == req then close(req, b.type) end
  end)

  local w, h = 360, 280
  local a = A.hooks.anchor and A.hooks.anchor() or hs.screen.mainScreen():frame()
  local scr = hs.screen.find({ x = a.x + a.w / 2, y = a.y + a.h / 2, w = 1, h = 1 }) or hs.screen.mainScreen()
  local sf = scr:frame()
  local x, y = a.x + a.w / 2 - w / 2, a.y - h + 30
  if y < sf.y then y = a.y + a.h - h end
  x = math.max(sf.x + 4, math.min(sf.x + sf.w - w - 4, x))
  y = math.max(sf.y + 4, math.min(sf.y + sf.h - h - 4, y))
  A.wv = hs.webview.new({ x = x, y = y, w = w, h = h }, { developerExtrasEnabled = false }, uc)
    :windowStyle({ "borderless" })
    :transparent(true)
    :level(hs.drawing.windowLevels.floating)
    :behavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
    :html(html)
    :show()
  A.timer = hs.timer.doAfter(math.max(0, (req.deadline or 0) - os.time()), function()
    if A.showing == req then close(req, "deny") end
  end)
  if A.hooks.onShow then A.hooks.onShow(req) end
end

showNext = function()
  while #A.queue > 0 and not A.showing do
    local id = table.remove(A.queue, 1)
    local req = readJson(A.dir .. "/" .. id .. ".req.json")
    if req and (req.deadline or 0) > os.time() and not exists(A.dir .. "/" .. id .. ".res.json") then show(req) end
  end
end

-- A new request from the approval server. Returns "shown" or "queued".
function A.request(id)
  for _, q in ipairs(A.queue) do if q == id then return "queued" end end
  if A.showing and A.showing.id == id then return "shown" end
  A.queue[#A.queue + 1] = id
  if A.showing then return "queued" end
  showNext()
  return A.showing and "shown" or "queued"
end

A.page = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/approve.html"

return A
