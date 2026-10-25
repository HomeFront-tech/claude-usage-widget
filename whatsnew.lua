-- What's new: the window that greets you after an update (Hammerspoon module)
--
-- The first time the widget starts on a newer version, updater.lua notes the version you
-- came from (markFrom) and, a few seconds later, asks this module to show what changed
-- since then (showPending). If whatsnew/releases.json has entries for those versions, a
-- window opens: a live Buddy in the release's skin, a few slides about the new features,
-- a page that asks how Buddy has been and takes ideas, and the full patch notes. Buddy's
-- right-click menu reopens it ("What's new"). The page itself is whatsnew.html, drawing
-- Buddy with buddy_draw.js; tools/whatsnew checks the releases file and tools/release
-- stamps its "next" entry with the version it releases.
--
-- Feedback goes only when you click Send (or pick a face and close the window): your
-- rating, your idea, a reply address if you typed one, and the Buddy and macOS versions.
-- It's posted to a small Cloudflare Worker (worker/feedback) that emails it to the
-- maintainer. With no Worker address set, Send opens a public GitHub issue with just
-- that text instead, for you to check and post yourself. At most 5 sends a day; when
-- you're offline they wait in a queue and go out later.
-- Try it: hs -c 'ClaudeWhatsNew.open("next")'

local W = {}

local REPO = "HomeFront-tech/claude-usage-widget" -- as in updater.lua; config.lua update_repo overrides
-- Where feedback is posted. Empty until the maintainer deploys worker/feedback; a fork
-- sets feedback_url in config.lua instead.
local FEEDBACK_URL = ""
local FROM_KEY = "claudeWidget.whatsNewFrom"     -- the version you updated from, until the window has shown
local DAY_KEY = "claudeWidget.feedbackDay"       -- { day = "YYYY-MM-DD", n = sends that day }
local QUEUE_KEY = "claudeWidget.feedbackQueue"   -- sends waiting for the network
local PER_DAY, QUEUE_MAX, QUEUE_DAYS = 5, 5, 3
local MAX = { title = 40, summary = 140, text = 220, slides = 8, notes = 12, idea = 2000, reply = 200 }
local SCENE_SKINS = { buddy = true, bubble = true } -- scene kinds drawn with one skin

-- Notes about skipped content go here (the console). Specs swap it out: a print inside
-- hs -c goes through hs.ipc, which shouldn't be leaned on mid-test.
W.log = function(msg) print("whatsnew: " .. msg) end

local function parse(v)
  local t = {}
  for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
  return t
end

-- Is version a newer than version b? (as updater.lua)
function W.newer(a, b)
  local x, y = parse(a), parse(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return false
end

local function numbered(v) return type(v) == "string" and v:match("^%d+%.%d+%.%d+$") ~= nil end

local function len(s) return utf8.len(s) or #s end

-- s cut to n characters (whole UTF-8 characters).
local function clip(s, n)
  if len(s) <= n then return s end
  return s:sub(1, (utf8.offset(s, n + 1) or (n + 1)) - 1)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function readFile(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local s = fh:read("a")
  fh:close()
  return s
end

local function decode(s)
  local ok, v = pcall(hs.json.decode, s or "")
  return ok and type(v) == "table" and v or nil
end

local function short(s, n) return s == nil or (type(s) == "string" and len(s) <= n) end

-- A release entry as the page can use it, or nil (with why) when it breaks the limits.
local function checked(r)
  if type(r) ~= "table" then return nil, "not an object" end
  if r.version ~= "next" and not numbered(r.version) then return nil, "bad version " .. tostring(r.version) end
  if type(r.title) ~= "string" or not short(r.title, MAX.title) then return nil, "title missing or over " .. MAX.title end
  if not short(r.summary, MAX.summary) then return nil, "summary over " .. MAX.summary end
  local out = copy(r)
  out.slides = {}
  for i, s in ipairs(type(r.slides) == "table" and r.slides or {}) do
    if #out.slides == MAX.slides then break end
    if type(s) == "table" and type(s.title) == "string" and short(s.title, MAX.title)
        and type(s.text) == "string" and short(s.text, MAX.text) then
      out.slides[#out.slides + 1] = copy(s)
    else
      W.log("v" .. r.version .. " slide " .. i .. " skipped (missing or too long)")
    end
  end
  out.notes = {}
  for _, group in ipairs({ "new", "better", "fixed" }) do
    local list = type(r.notes) == "table" and r.notes[group]
    if type(list) == "table" then
      out.notes[group] = {}
      for _, n in ipairs(list) do
        if type(n) == "string" and #out.notes[group] < MAX.notes then table.insert(out.notes[group], n) end
      end
    end
  end
  return out
end

-- The checked releases in dir/whatsnew/releases.json, and an error message when the
-- file is missing or broken (then the list is empty and the plain bubble stands in).
function W.load(dir)
  local text = readFile(dir .. "/whatsnew/releases.json")
  if not text then return {}, "no whatsnew/releases.json" end
  local data = decode(text)
  if not data or type(data.releases) ~= "table" then return {}, "whatsnew/releases.json isn't valid" end
  local list = {}
  for _, r in ipairs(data.releases) do
    local ok, why = checked(r)
    if ok then list[#list + 1] = ok
    else W.log("release skipped: " .. why) end
  end
  return list
end

local function newestFirst(list)
  table.sort(list, function(a, b) return W.newer(a.version, b.version) end)
  return list
end

-- The numbered releases after from, up to and including current, newest first.
function W.pick(releases, from, current)
  local out = {}
  for _, r in ipairs(releases or {}) do
    if numbered(r.version) and W.newer(r.version, from) and not W.newer(r.version, current) then out[#out + 1] = r end
  end
  return newestFirst(out)
end

-- What the menu shows: the release named want, else the newest numbered one at or below
-- current, else the "next" draft (a checkout that hasn't been released yet).
function W.forMenu(releases, current, want)
  local best, draft
  for _, r in ipairs(releases or {}) do
    if want then
      if r.version == want then return { r } end
    elseif r.version == "next" then
      draft = r
    elseif not W.newer(r.version, current) and (not best or W.newer(r.version, best.version)) then
      best = r
    end
  end
  if want then return {} end
  return { best or draft }
end

-- Everything the page needs, inlined (the page has no file access): the releases with
-- missing skins swapped for Classic or left out of grids, the skins' JSON, pictures as
-- data URIs, and which skins the Wear buttons may put on.
-- ctx: dir, version, from, repoURL, mode ("email" or "github"), canWear, skinFile(id),
-- encode(bytes) (base64, only needed for image scenes)
function W.pageData(list, ctx)
  local skins, images, wearable = {}, {}, {}
  local function have(id)
    if type(id) ~= "string" or not id:match("^[%w_-]+$") then return false end
    if skins[id] then return true end
    local path = ctx.skinFile and ctx.skinFile(id)
    local skin = path and decode(readFile(path))
    if skin then skins[id] = skin end
    return skin ~= nil
  end
  local function one(id) return have(id) and id or (have("classic") and "classic" or nil) end
  local releases = {}
  for _, src in ipairs(list or {}) do
    local r = copy(src)
    if type(r.hero) == "table" then r.hero.skin = one(r.hero.skin) end
    for _, s in ipairs(r.slides or {}) do
      local sc = type(s.scene) == "table" and s.scene or {}
      s.scene = sc
      if sc.kind == "skins" then
        local kept = {}
        for _, id in ipairs(type(sc.skins) == "table" and sc.skins or {}) do
          if have(id) then kept[#kept + 1] = id end
        end
        sc.skins = kept
      elseif SCENE_SKINS[sc.kind] or sc.skin then
        sc.skin = one(sc.skin)
      end
      if sc.kind == "image" and type(sc.file) == "string" and sc.file:match("^[%w_.-]+%.[pj][np]e?g$")
          and not images[sc.file] then
        local bytes = readFile(ctx.dir .. "/whatsnew/" .. sc.file)
        if bytes and #bytes <= 600 * 1024 and ctx.encode then
          images[sc.file] = "data:image/" .. (sc.file:match("%.png$") and "png" or "jpeg") .. ";base64," .. ctx.encode(bytes)
        end
      end
      if type(s.action) == "table" and ctx.canWear and have(s.action.skin) then wearable[s.action.skin] = true end
    end
    releases[#releases + 1] = r
  end
  return { releases = releases, skins = skins, images = images, wearable = wearable, mode = ctx.mode,
    repoURL = ctx.repoURL, version = ctx.version, from = ctx.from }
end

-- JSON for the page's init block; "</" escaped so no string can close the script tag.
function W.initJSON(data) return (hs.json.encode(data):gsub("</", "<\\/")) end

-- What a page message may send: rating 1-5, the idea (trimmed, at most 2000 characters),
-- a reply address only if it looks like one. nil, "empty" when there's nothing to send.
function W.form(b)
  b = type(b) == "table" and b or {}
  local f = {}
  local r = b.rating
  if type(r) == "number" and r == math.floor(r) and r >= 1 and r <= 5 then f.rating = math.tointeger(r) end
  if type(b.idea) == "string" then
    local idea = trim(b.idea)
    if idea ~= "" then f.idea = clip(idea, MAX.idea) end
  end
  if type(b.reply_to) == "string" then
    local addr = trim(b.reply_to)
    if #addr <= MAX.reply and addr:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then f.reply_to = addr end
  end
  if not f.rating and not f.idea then return nil, "empty" end
  return f
end

-- The JSON body the Worker takes. Fields left empty are left out.
function W.payload(form, version, macos)
  return { rating = form.rating, idea = form.idea, reply_to = form.reply_to, version = version, macos = macos }
end

local function enc(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- A new GitHub issue holding only what was typed, plus the versions. It's public, and
-- nothing is filed until the person clicks Submit on GitHub.
function W.issueURL(repoURL, form, version, macos)
  local first = (form.idea or ""):match("[^\n]*")
  local lines = { form.idea or "", "" }
  if form.rating then lines[#lines + 1] = "Rating: " .. form.rating .. "/5" end
  if form.reply_to then lines[#lines + 1] = "Reply to: " .. form.reply_to end
  lines[#lines + 1] = "Buddy v" .. version .. " · macOS " .. macos
  return repoURL .. "/issues/new?title=" .. enc("Idea: " .. clip(first, 60)) .. "&body=" .. enc(table.concat(lines, "\n"))
end

-- At most PER_DAY sends a day. store: { get(key), set(key, value) } (Hammerspoon settings).
function W.allow(store, today)
  local rec = store.get(DAY_KEY)
  return not (type(rec) == "table" and rec.day == today and (rec.n or 0) >= PER_DAY)
end

function W.count(store, today)
  local rec = store.get(DAY_KEY)
  local n = (type(rec) == "table" and rec.day == today) and (rec.n or 0) or 0
  store.set(DAY_KEY, { day = today, n = n + 1 })
end

function W.queued(store)
  local q = store.get(QUEUE_KEY)
  return type(q) == "table" and q or {}
end

function W.enqueue(store, payload, now)
  local q = W.queued(store)
  q[#q + 1] = { id = tostring(now) .. "-" .. math.random(1e6), at = now, p = payload }
  while #q > QUEUE_MAX do table.remove(q, 1) end
  store.set(QUEUE_KEY, q)
end

local function drop(store, id)
  local q = W.queued(store)
  for i, item in ipairs(q) do
    if item.id == id then table.remove(q, i); break end
  end
  store.set(QUEUE_KEY, q)
end

-- Send what's queued, oldest first, one at a time. post(payload, done(status)). Sent (2xx)
-- and refused (4xx other than 429) items leave the queue; anything else stops the flush
-- and waits for the next one. Items older than QUEUE_DAYS are dropped unsent.
function W.flush(store, post, now)
  local q = W.queued(store)
  local fresh = {}
  for _, item in ipairs(q) do
    if type(item) == "table" and type(item.at) == "number" and now - item.at <= QUEUE_DAYS * 86400 then fresh[#fresh + 1] = item end
  end
  if #fresh ~= #q then store.set(QUEUE_KEY, fresh) end
  local function step(i)
    local item = fresh[i]
    if not item then return end
    post(item.p, function(status)
      if (status >= 200 and status < 300) or (status >= 400 and status < 500 and status ~= 429) then
        drop(store, item.id)
        step(i + 1)
      end
    end)
  end
  step(1)
end

-- The window -------------------------------------------------------------------------

local SHARE_TEXT = "Buddy is a little pixel Claude that lives on your desktop and shows your Claude usage."
-- menu title, key in hs.sharing.builtinSharingServices
local SHARE = { { "Messages", "composeMessage" }, { "Mail", "composeEmail" }, { "AirDrop", "sendViaAirDrop" } }

function W.macos()
  local v = hs.host.operatingSystemVersion()
  return string.format("%d.%d", v.major, v.minor) .. ((v.patch or 0) > 0 and ("." .. v.patch) or "")
end

function W.today() return os.date("%Y-%m-%d") end

-- One window's feedback: the face picked, and whether it has gone out. gen counts
-- windows, so a reply that arrives after its window closed doesn't reach the next one.
W.gen = 0
function W.reset() W.state = {} end
W.reset()

function W.say(text) if ClaudeBuddy and ClaudeBuddy.say then ClaudeBuddy.say(text, true) end end

local function retryable(status) return status < 200 or status >= 500 or status == 429 end

-- Post one payload now; a network or server failure queues it for later. A refusal
-- gives this window's rating back, so it can go again.
local function deliver(payload, deps, reply)
  local gen = W.gen
  local function tell(r) if reply and W.gen == gen then reply(r) end end
  deps.post(payload, function(status)
    if status >= 200 and status < 300 then
      tell({ ok = true, text = "Sent. Thanks!" })
    elseif retryable(status) then
      W.enqueue(W.store, payload, os.time())
      deps.retry()
      tell({ ok = true, text = "Saved. I'll send it when you're back online." })
    else
      if payload.rating and W.gen == gen then W.state.ratingSent = false end
      tell({ ok = false, text = "That didn't go through. Sorry!" })
    end
  end)
end

local function send(b, deps)
  local form = W.form(b)
  if form and W.state.ratingSent then form.rating = nil end
  if form and not form.rating and not form.idea then form = nil end
  if not W.feedbackURL then -- no Worker: a public issue they check and post themselves
    if not form or not form.idea then return deps.reply({ ok = false, text = "Type your idea first." }) end
    form.reply_to = nil -- never put an email address in a public issue
    deps.openURL(W.issueURL(W.repoURL, form, W.version, W.macos()))
    if form.rating then W.state.ratingSent = true end
    return deps.reply({ ok = true, text = "Opened on GitHub. Click Submit there to post it." })
  end
  if not form then return deps.reply({ ok = false, text = "Type your idea first." }) end
  if not W.allow(W.store, W.today()) then return deps.reply({ ok = false, text = "That's plenty for today. Thanks!" }) end
  W.count(W.store, W.today())
  if form.rating then W.state.ratingSent = true end
  deliver(W.payload(form, W.version, W.macos()), deps, deps.reply)
end

-- The window is closing: a face picked but never sent goes now, quietly, once.
function W.finish(deps)
  if W.state.finished then return end
  W.state.finished = true
  local r = W.state.rating
  if not r or W.state.ratingSent or not W.feedbackURL or not W.allow(W.store, W.today()) then return end
  W.count(W.store, W.today())
  W.state.ratingSent = true
  deliver(W.payload({ rating = r }, W.version, W.macos()), deps)
end

-- A message from the page. deps: post, openURL, reply, copy, copiedNote, share, wear,
-- close, retry (the real ones are below; the spec passes fakes).
function W.handle(b, deps)
  b = type(b) == "table" and b or {}
  if b.type == "send" then
    send(b, deps)
  elseif b.type == "rate" then
    local f = W.form({ rating = b.rating })
    W.state.rating = f and f.rating or nil
  elseif b.type == "wear" and type(b.skin) == "string" then
    deps.wear(b.skin)
  elseif b.type == "copy" then
    deps.copy(W.repoURL)
    deps.copiedNote("Copied the link")
  elseif b.type == "share" then
    deps.share(SHARE_TEXT, W.repoURL)
  elseif b.type == "open" and type(b.url) == "string" and b.url:sub(1, #W.repoURL + 10) == W.repoURL .. "/releases/" then
    deps.openURL(b.url)
  elseif b.type == "close" then
    W.finish(deps)
    deps.close()
  end
end

function W.retry()
  if #W.queued(W.store) == 0 then
    if W.hourTimer then W.hourTimer:stop(); W.hourTimer = nil end
    return
  end
  W.flush(W.store, W.post, os.time())
end

-- Hourly retries while something waits in the queue.
local function keepRetrying()
  W.hourTimer = W.hourTimer or hs.timer.doEvery(3600, W.retry)
end

function W.post(payload, done)
  hs.http.asyncPost(W.feedbackURL, hs.json.encode(payload),
    { ["Content-Type"] = "application/json", ["User-Agent"] = "claude-usage-widget/" .. W.version },
    function(status) done(status) end)
end

local function js(fn, data)
  if not W.wv then return end
  local arg = type(data) == "table" and hs.json.encode(data) or hs.json.encode({ data }):sub(2, -2)
  W.wv:evaluateJavaScript(fn .. "(" .. arg .. ")")
end

local function close()
  W.closeTimer = hs.timer.doAfter(0, function()
    if W.wv then W.wv:delete() end
    W.wv = nil
  end)
end

local function share(text, url)
  local function via(key)
    local id = hs.sharing.builtinSharingServices[key]
    W.share = id and hs.sharing.newShare(id)
    if W.share then W.share:shareItems({ text, hs.sharing.URL and hs.sharing.URL(url) or url }) end
  end
  local items = {}
  for _, s in ipairs(SHARE) do items[#items + 1] = { title = s[1], fn = function() via(s[2]) end } end
  W.menu = W.menu or hs.menubar.new(false)
  W.menu:setMenu(items)
  W.menu:popupMenu(hs.mouse.absolutePosition(), true)
end

W.deps = {
  post = function(p, done) W.post(p, done) end,
  openURL = function(u) hs.urlevent.openURL(u) end,
  reply = function(r) js("window.sent", r) end,
  copy = function(text) hs.pasteboard.setContents(text) end,
  copiedNote = function(text) js("window.copied", text) end,
  share = share,
  wear = function(id) if ClaudeBuddy and ClaudeBuddy.wearSkin then ClaudeBuddy.wearSkin(id) end end,
  close = close,
  retry = keepRetrying,
}

local function userSkin(id)
  for _, path in ipairs({ os.getenv("HOME") .. "/Library/Application Support/claude-usage-widget/skins/" .. id .. ".json",
      W.dir .. "/skins/" .. id .. ".json" }) do
    if hs.fs.attributes(path) then return path end
  end
end

-- Open the window on these releases (newest first). Brings it forward if it's open.
function W.show(list, from)
  if W.wv then
    W.wv:show():bringToFront(true)
    hs.focus()
    return
  end
  W.reset()
  W.gen = W.gen + 1
  local data = W.pageData(list, { dir = W.dir, version = W.version, from = from, repoURL = W.repoURL,
    mode = W.feedbackURL and "email" or "github", skinFile = userSkin, encode = function(s) return hs.base64.encode(s) end,
    canWear = ClaudeBuddy ~= nil and ClaudeBuddy.wearSkin ~= nil })
  local html = assert(readFile(W.dir .. "/whatsnew.html"))
  local draw = assert(readFile(W.dir .. "/buddy_draw.js"))
  html = html:gsub("/%*__BUDDY_DRAW__%*/", function() return draw end)
  html = html:gsub("/%*__INIT__%*/null", function() return W.initJSON(data) end)

  local uc = hs.webview.usercontent.new("buddy")
  uc:setCallback(function(msg) W.handle(msg.body, W.deps) end)
  local scr = hs.screen.mainScreen():frame()
  local w, h = 600, 520
  W.wv = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + math.max(40, (scr.h - h) / 3), w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable" })
    :windowTitle("What's new in Buddy")
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.floating)
    :deleteOnClose(true)
    :windowCallback(function(action)
      if action == "closing" then
        W.finish(W.deps)
        W.wv = nil
      end
    end)
    :html(html)
    :show()
  W.wv:bringToFront(true)
  hs.focus()
end

-- Read VERSION and config.lua (feedback_url, update_repo) once, and pick up any feedback
-- still waiting from before. Returns W, so calls can chain.
function W.init(dir)
  if W.dir == dir then return W end
  W.dir = dir
  local fh = io.open(dir .. "/VERSION")
  W.version = fh and (fh:read("l") or ""):match("[%d.]+") or "0.0.0"
  if fh then fh:close() end
  local chunk = loadfile(dir .. "/config.lua")
  local ok, cfg = pcall(chunk or function() end)
  cfg = ok and type(cfg) == "table" and cfg or {}
  W.repoURL = "https://github.com/" .. (type(cfg.update_repo) == "string" and cfg.update_repo or REPO)
  local url = type(cfg.feedback_url) == "string" and cfg.feedback_url ~= "" and cfg.feedback_url or FEEDBACK_URL
  W.feedbackURL = url ~= "" and url or nil
  W.store = { get = hs.settings.get, set = hs.settings.set }
  if W.feedbackURL and #W.queued(W.store) > 0 then
    W.retryTimer = hs.timer.doAfter(30, W.retry)
    keepRetrying()
  end
  return W
end

-- updater.lua, on the first start after an update: remember where we came from.
function W.markFrom(old) W.store.set(FROM_KEY, old) end

-- A few seconds after that start: open the window on what's new since then. False when
-- there's nothing to show (then updater.lua's plain bubble line stands in).
function W.showPending()
  local from = W.store.get(FROM_KEY)
  if not from then return false end
  W.store.set(FROM_KEY, nil)
  local list = W.pick(W.load(W.dir), from, W.version)
  if #list == 0 then return false end
  W.show(list, from)
  W.say("I got updated! Come see what's new.")
  return true
end

-- The menu's "What's new": this version's release, or the one named (ClaudeWhatsNew.open("next")
-- previews the draft). False when there's nothing to show.
function W.open(want)
  -- just updated and the window hasn't popped up yet: show that one, so it can't pop up later
  if not want and W.store.get(FROM_KEY) and W.showPending() then return true end
  local list = W.forMenu(W.load(W.dir), W.version, want)
  if #list == 0 then return false end
  W.show(list, nil)
  return true
end

return W
