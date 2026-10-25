-- Buddy's Halloween corner: dates, skits and the little pixel world.
-- Skit files live in skits/ or the user's matching Application Support folder.
-- skits.lua checks their data once; this module keeps the live state and draws it.

local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
-- The skit engine loads the first time the theme needs it, so an off theme loads nothing.
local K = setmetatable({}, { __index = function(proxy, key)
  local engine = dofile(dir .. "/skits.lua")
  setmetatable(proxy, { __index = engine })
  return engine[key]
end })
local H = {}

local START_DAY, END_DAY, MONTH = 24, 31, 10
local TOGGLE_KEY, DRESSED_KEY = "claudeBuddy.halloween", "claudeBuddy.halloweenDressed"
local GAPS = { chatty = { 75, 150 }, normal = { 180, 300 }, quiet = { 600, 900 } }
local IDLE_LIMIT, EVENING_HOUR, RECENT_LIMIT, CHAIN_WINDOW = 60, 17, 8, 180
local LINE_CHANCE, HALLOWEEN_GAP_SCALE = 0.5, 0.5
local LOOK_REFRESH = 0.3
local EMIT_SIZE, EMIT_VY, EMIT_SPREAD, EMIT_LIFE = 13, -26, 50, 1.4
local CALM = { idle = true, browsing = true, generic = true, reading = true, mail = true,
  watching = true, chat = true, chatting = true, curious = true, music = true }
local PROPS = { "laptop", "popcorn", "controller", "mug", "envelope", "wrench", "shovel", "phone" }
local GROUPS = { { "bats", "Bats" }, { "spider", "Spider" }, { "visitors", "Visitors" }, { "movies", "Movie night" } }
local WEEK = "It's Halloween week and you love it. Now and then, slip in a spooky pun or a nod to a classic horror movie."
local DAY = "Today is Halloween, your favourite day of the year. Now and then, slip in a spooky pun or a nod to a classic horror movie."
local WEB_X, WEB_Y, WEB_R = 2, 2, 62
local SPOKES, RINGS = { 0, 22, 45, 68, 90 }, { 0.35, 0.6, 0.85 }
local WEB_SAG, WEB_WIDTH, WEB_BLUR, WEB_SHADOW_ALPHA = 0.86, 1.2, 1.5, 0.5
local WEB_COLOR, THREAD_COLOR = "#eaecf4d9", "#eaecf4b3"
local SPIDER_X = WEB_X + math.cos(math.rad(45)) * WEB_R * 0.85
local SPIDER_Y = WEB_Y + math.sin(math.rad(45)) * WEB_R * 0.85
local SPIDER_REST, SPIDER_BOB, SPIDER_CYCLE = 96, 4, 30
local SPIDER_HANG, SPIDER_TOP, SPIDER_PAUSE, SPIDER_DROP = 26, 27.6, 28.4, 28.9
local PAIL_COL, PAIL_ROW, HAND_COL, FACE_ROW = 15, 4, 17, 5

local LINES = {
  idle = { "A little spooky, a lot cozy.", "The shadows have excellent timing.", "Was that a creak? I approve.",
    "This corner has atmosphere.", "I call dibs on the moonlight.", "The web is growing on me.",
    "Quiet night. Suspiciously quiet.", "I brought my brave face. Mostly.", "The candy is under guard.", "Boo, but politely." },
  sleepy = { "Even ghosts need a nap.", "Wake me if the candy moves.", "One eye open. Maybe.",
    "The web can take first watch.", "I'm resting my spooky bones.", "Just a tiny haunted snooze.",
    "Night night, little shadows.", "My hat is my sleep mask.", "Dreaming of extra candy.", "No jump scares before coffee." },
  morning = { "Morning, my little pumpkin.", "The bats have clocked out.", "Fresh day, same spooky hat.",
    "I survived the night. Barely.", "Breakfast candy counts, right?", "Even the web has morning dew.",
    "The shadows look less smug now.", "A bright day for dark jokes.", "My broom needs a charge.", "Good morning. Boo gently." },
  click = { "Boo! Oh, it's you.", "Careful, I spook easily.", "You found my hiding spot.",
    "Hands off the candy tax.", "That was almost a jump scare.", "My hat has a personal bubble.",
    "I was practicing my glare.", "Trick, treat, or tiny chat?", "The spider saw that.", "You rang the haunted bell." },
  joke = { "Why did the ghost skip the party? It had no body to go with.",
    "My broom asked for a day off. I said, sweep on it.",
    "I tried to scare a pumpkin. It just gave me a hollow stare.",
    "The spider opened a shop. Business is web based.",
    "I offered the bat a snack. It said it was hanging in there.",
    "The skeleton quit hide and seek. Everyone saw right through it.",
    "My hat knows every secret. It keeps them under wraps.",
    "The candy pail is shy. It only comes out for treats.",
    "I told a spooky pun. The room gave me a cold shoulder.",
    "The moon asked for privacy. The bats kept circling back." },
}

function H.active(d, cfg, saved)
  if type(cfg) == "table" and type(cfg.halloween) == "boolean" then return cfg.halloween end
  local season = d.month == MONTH and d.day >= START_DAY and d.day <= END_DAY
  if season and type(saved) == "table" and saved.year == d.year and type(saved.on) == "boolean" then
    return saved.on
  end
  return season
end

local function rounded(v) return math.floor(v + 0.5) end

local function point(radius, degrees)
  return { x = WEB_X + radius * math.cos(math.rad(degrees)),
    y = WEB_Y + radius * math.sin(math.rad(degrees)) }
end

local function segments(coords, color, width, shadow)
  local el = { type = "segments", action = "stroke", coordinates = coords, strokeColor = color, strokeWidth = width }
  if shadow then
    el.withShadow = true
    el.shadow = { blurRadius = WEB_BLUR, color = { red = 0, green = 0, blue = 0, alpha = WEB_SHADOW_ALPHA },
      offset = { h = 0, w = 0 } }
  end
  return el
end

-- Each sagging arc is evaluated from the approved quadratic's cubic control points.
local function webElements(color)
  local out = {}
  for _, angle in ipairs(SPOKES) do
    out[#out + 1] = segments({ { x = WEB_X, y = WEB_Y }, point(WEB_R, angle) }, color, WEB_WIDTH, true)
  end
  for _, k in ipairs(RINGS) do
    local coords = {}
    for i = 1, #SPOKES - 1 do
      local a, b = SPOKES[i], SPOKES[i + 1]
      local p0, p1 = point(WEB_R * k, a), point(WEB_R * k, b)
      local q = point(WEB_SAG * WEB_R * k, (a + b) / 2)
      local c1 = { x = p0.x + 2 / 3 * (q.x - p0.x), y = p0.y + 2 / 3 * (q.y - p0.y) }
      local c2 = { x = p1.x + 2 / 3 * (q.x - p1.x), y = p1.y + 2 / 3 * (q.y - p1.y) }
      if i == 1 then coords[#coords + 1] = p0 end
      for step = 1, 6 do
        local t = step / 6
        local u = 1 - t
        coords[#coords + 1] = { x = u^3 * p0.x + 3 * u^2 * t * c1.x + 3 * u * t^2 * c2.x + t^3 * p1.x,
          y = u^3 * p0.y + 3 * u^2 * t * c1.y + 3 * u * t^2 * c2.y + t^3 * p1.y }
      end
    end
    out[#out + 1] = segments(coords, color, WEB_WIDTH, true)
  end
  return out
end

local function spriteRects(add, item)
  if item.thread then
    local th = item.thread
    add(segments({ { x = th.x1, y = th.y1 }, { x = th.x2, y = th.y2 } }, K.hex(THREAD_COLOR), 1),
      item.key .. ":thread")
  end
  local pixel = item.pixel
  for i, run in ipairs(item.frame.runs) do
    local rx = item.flip and item.frame.w - run.x - run.n or run.x
    add({ type = "rectangle", action = "fill", fillColor = run.color,
      frame = { x = item.x + rx * pixel, y = item.y + run.y * pixel, w = run.n * pixel, h = pixel } },
      item.key .. ":" .. i)
  end
end

-- The little spider hangs for most of each thirty-second cycle.
local function spiderTop(at)
  local phase = at % SPIDER_CYCLE
  if phase < SPIDER_HANG then return SPIDER_REST + SPIDER_BOB * math.sin(1.3 * at), "hang" end
  if phase < SPIDER_TOP then
    local p = (phase - SPIDER_HANG) / (SPIDER_TOP - SPIDER_HANG)
    return SPIDER_REST + (SPIDER_Y + 6 - SPIDER_REST) * p, "climb"
  end
  if phase < SPIDER_PAUSE then return SPIDER_Y + 6, "climb" end
  if phase < SPIDER_DROP then
    local p = (phase - SPIDER_PAUSE) / (SPIDER_DROP - SPIDER_PAUSE)
    return SPIDER_Y + 6 + (SPIDER_REST - SPIDER_Y - 6) * p, "hang"
  end
  return SPIDER_REST - 4 * math.sin((phase - SPIDER_DROP) / (SPIDER_CYCLE - SPIDER_DROP) * math.pi), "hang"
end

function H.configure(opts)
  local cfg, skins, palette = opts.cfg or {}, opts.skins, opts.palette or {}
  local settings, hooks = opts.settings or {}, opts.hooks or {}
  local now, date = opts.now or os.time, opts.date or os.date
  local random, log = opts.random or math.random, opts.log or print
  local S, ground = opts.S or 5, opts.ground or 158
  local web -- built the first time it's drawn
  local theme, loaded, broken, enabled, lastSeen = {}, false, false, false, nil
  local library, skits, byId = {}, {}, {}
  local playing, chain, nextAt, runTween, look, pailGone, spiderAway = nil, nil, nil, nil, nil, false, false
  local recent, session, pailShown, pailDrawn = {}, nil, true, false

  local function get(key) return settings.get and settings.get(key) or nil end
  local function set(key, value) if settings.set then settings.set(key, value) end end
  local function color(name) return palette[name] or K.hex(name) end
  local function read(path)
    local f = io.open(path)
    if not f then return nil, "can't read it" end
    local raw = f:read("a")
    f:close()
    local ok, value = pcall(hs.json.decode, raw)
    if not ok or value == nil then return nil, "not valid JSON" end
    return value
  end
  local function skipped(path, why) log("[buddy skits] skipped " .. path .. ": " .. tostring(why)) end

  -- Later folders replace an id from an earlier folder, like user skins do.
  local function loadLibrary()
    if loaded then return end
    loaded = true
    for _, folder in ipairs(opts.dirs or {}) do
      if hs.fs.attributes(folder, "mode") == "directory" then
        local ok, err = pcall(function()
          local names = {}
          for name in hs.fs.dir(folder) do
            if name:match("^[^.].*%.json$") then names[#names + 1] = name end
          end
          table.sort(names)
          for _, name in ipairs(names) do
            if name == "sprites.json" then
              local path = folder .. "/" .. name
              local defs, why = read(path)
              if not defs then skipped(path, why)
              else
                local compiled = K.sprites(defs, color, function(message) skipped(path, message) end)
                for id, sprite in pairs(compiled) do library[id] = sprite end
              end
            end
          end
          for _, name in ipairs(names) do
            if name ~= "sprites.json" then
              local path = folder .. "/" .. name
              local def, why = read(path)
              if def then
                if def.id ~= name:sub(1, -6) then def, why = nil, "id must match the file name"
                else
                  local okc, sk, reason = pcall(K.compile, def, library, color)
                  if okc then def, why = sk, reason else def, why = nil, sk end
                end
              end
              if not def then skipped(path, why)
              else byId[def.id] = def end
            end
          end
        end)
        if not ok then log("[buddy skits] couldn't read " .. folder .. ": " .. tostring(err)) end
      end
    end
    for _, sk in pairs(byId) do skits[#skits + 1] = sk end
    table.sort(skits, function(a, b) return a.id < b.id end)
  end

  local function gap()
    local range = GAPS[cfg.chatter or "chatty"]
    if not range then return nil end
    local scale = date("*t").month == MONTH and date("*t").day == END_DAY and HALLOWEEN_GAP_SCALE or 1
    return (range[1] + random() * (range[2] - range[1])) * scale
  end
  local function schedule(t)
    local seconds = gap()
    nextAt = seconds and t + seconds or nil
  end
  local function reset()
    playing, chain, runTween, look = nil, nil, nil, nil
    pailGone, spiderAway, pailShown = false, false, true
  end
  local function enter(t)
    enabled = true
    loadLibrary()
    local d = date("*t")
    local declined = get(DRESSED_KEY)
    if skins.current().group ~= "halloween" and not (type(declined) == "table" and declined.year == d.year and declined.declined) then
      skins.wear("witch")
    end
    lastSeen = skins.current().id
    schedule(t)
  end
  local function leave()
    if not enabled then return end
    reset()
    nextAt, enabled, lastSeen = nil, false, nil
    skins.wear(nil)
  end
  local function desired()
    if session ~= nil then return session end
    return H.active(date("*t"), cfg, get(TOGGLE_KEY))
  end
  local function refresh(t)
    if broken then return end
    if desired() then
      if not enabled then enter(t) end
    else leave() end
  end
  local function guard(fn, fallback)
    if broken then return fallback end
    local ok, value = pcall(fn)
    if ok then return value end
    broken = true
    log("[buddy halloween] switched off after an error: " .. tostring(value))
    reset()
    nextAt, enabled = nil, false
    skins.wear(nil)
    return fallback
  end
  local function tweenAt(t)
    if not runTween then return 0 end
    local p = math.max(0, math.min(1, (t - runTween.start) / runTween.secs))
    return rounded(runTween.from + (runTween.to - runTween.from) * K.ease("inout", p))
  end
  local function canStart(state)
    return state and state.away == "active" and (state.idle or math.huge) < IDLE_LIMIT
      and CALM[state.mood] and not state.event and not state.action and not state.dragging
  end
  local function begin(sk, t)
    playing = { skit = sk, start = t, last = -1 }
    chain = nil
    recent[#recent + 1] = sk.id
    while #recent > RECENT_LIMIT do table.remove(recent, 1) end
  end
  local function finish(natural, t)
    if not playing then return end
    local sk = playing.skit
    playing, runTween, look, spiderAway = nil, nil, nil, false
    local follow = natural and sk.next and byId[sk.next.skit]
    if follow and random() < (sk.next.chance or 1) then
      local after = sk.next.after
      local lo, hi = after[1] or after.lo, after[2] or after.hi
      chain = { id = follow.id, due = t + lo + random() * (hi - lo), deadline = t + CHAIN_WINDOW }
    else
      chain, pailGone = nil, false
    end
    if not natural and hooks.act then hooks.act(nil, 0) end
    schedule(t)
  end

  -- Each cue is delivered once even when a frame skips over several cue times.
  local function cue(c, p, ox, oy, cx)
    local secs = c["for"]
    if c.action then
      if hooks.act then hooks.act(c.action, secs) end
    elseif c.say then
      local words = c.say
      if type(words) == "table" then words = words[math.min(#words, math.floor(random() * #words) + 1)] end
      if hooks.say then hooks.say(words) end
    elseif c.look then
      look = { target = c.look, untilTime = p.start + c.t + secs }
    elseif c.run then
      local at = p.start + c.t
      runTween = { start = at, secs = secs, from = tweenAt(at), to = c.run }
      if hooks.act then hooks.act("trot", secs) end
    elseif c.prop then
      if hooks.act then hooks.act("prop:" .. c.prop, secs) end
    elseif c.pail then pailGone = c.pail == "gone"
    elseif c.spider then spiderAway = c.spider == "away"
    elseif c.emit and hooks.burst then
      local e = c.emit
      hooks.burst({ glyphs = e.glyphs, color = color(e.color), size = EMIT_SIZE,
        from = e.from == "hand" and "mug" or e.from, vy = EMIT_VY, spread = EMIT_SPREAD,
        life = EMIT_LIFE }, e.count, ox, oy, cx)
    end
  end
  local function anchors(ox, oy, cx, at)
    local sy = spiderTop(at)
    return { top = { x = cx, y = oy - skins.topRows() * S }, head = { x = cx, y = oy },
      face = { x = cx, y = oy + FACE_ROW * S }, hand = { x = ox + HAND_COL * S, y = oy + PAIL_ROW * S },
      feet = { x = cx, y = ground }, web = { x = SPIDER_X, y = SPIDER_Y },
      spider = { x = SPIDER_X, y = sy } }
  end
  local function advance(ox, oy, cx, at)
    local p = playing
    if not p then return end
    local elapsed = math.max(0, now() - p.start)
    for _, c in ipairs(K.cues(p.skit, p.last, math.min(elapsed, p.skit.length))) do cue(c, p, ox, oy, cx) end
    p.last = elapsed
    if look and hooks.look then
      if now() >= look.untilTime then look = nil
      else
        local target = look.target
        local xy = type(target) == "string" and anchors(ox, oy, cx, at)[target]
          or { x = target[1], y = target[2] }
        if xy then hooks.look(xy.x, xy.y, LOOK_REFRESH) end
      end
    end
    if elapsed >= p.skit.length then finish(true, p.start + p.skit.length) end
  end
  local function resting(add, at)
    if spiderAway then return end
    local sprite = library.spider
    if not sprite then return end
    local top, anim = spiderTop(at)
    local a = sprite.anims[anim] or sprite.anims[sprite.default]
    local frame = a.frames[math.floor(at * a.fps) % #a.frames + 1]
    local pixel = sprite.pixel
    local x = rounded(SPIDER_X - frame.w * pixel / 2)
    local y = rounded(top)
    add(segments({ { x = SPIDER_X, y = SPIDER_Y }, { x = SPIDER_X, y = y } }, K.hex(THREAD_COLOR), 1),
      "spider-thread:" .. y)
    spriteRects(add, { x = x, y = y, pixel = pixel, frame = frame, flip = false,
      key = "spider:" .. anim .. ":" .. y .. ":" .. math.floor(at * a.fps) % #a.frames })
  end
  local function actors(add, layer, ox, oy, cx, at)
    if not playing then return end
    local elapsed = now() - playing.start
    for _, item in ipairs(K.sample(playing.skit, elapsed, anchors(ox, oy, cx, at))) do
      if item.layer == layer then spriteRects(add, item) end
    end
  end

  theme.actions = { duck = { eyes = "closed", arms = "up", body = "duck" },
    flee = { eyes = "wide", mouth = "o", arms = "up", body = "sway" },
    eat = { eyes = "happy", mouth = "talk" }, lookUp = { eyes = "up" }, trot = { body = "sway" } }
  for _, prop in ipairs(PROPS) do theme.actions["prop:" .. prop] = { prop = prop, arms = "hold" } end
  function theme.on() return enabled and not broken end
  function theme.busy() return playing ~= nil end
  function theme.offset() return guard(function() return theme.on() and tweenAt(now()) or 0 end, 0) end
  function theme.status()
    return { on = theme.on(), playing = playing and playing.skit.id or nil, pail = not pailGone,
      spider = not spiderAway, offset = theme.offset(), chain = chain and chain.id or nil,
      nextIn = nextAt and math.max(0, nextAt - now()) or nil }
  end
  function theme.interrupt()
    return guard(function()
      if playing then finish(false, now()) end
      chain, pailGone, spiderAway, runTween, look = nil, false, false, nil, nil
    end)
  end
  function theme.skit(id)
    return guard(function()
      if not theme.on() then return false end
      local sk = byId[id]
      if not sk then return false end
      theme.interrupt()
      begin(sk, now())
      return true
    end, false)
  end
  function theme.set(value)
    return guard(function()
      session = value
      refresh(now())
    end)
  end
  local function needsMet(sk)
    if not sk then return false end
    if sk.needs.pail and not (pailShown and not pailGone) then return false end
    return not sk.needs.evening or date("*t").hour >= EVENING_HOUR
  end
  function theme.tick(t, state)
    return guard(function()
      refresh(t)
      if not theme.on() then return end
      -- the theme only dresses Buddy when it starts, so any other change is a pick from the
      -- Skin menu: it sticks for the rest of the season, even across a reload
      if skins.current().id ~= lastSeen then
        set(DRESSED_KEY, { year = date("*t").year, declined = true })
        lastSeen = skins.current().id
      end
      if playing and (state and (state.event or state.dragging or state.away == "asleep" or state.away == "bored")) then
        theme.interrupt()
      elseif playing and t >= playing.start + playing.skit.length then
        finish(true, playing.start + playing.skit.length)
      end
      if chain then
        if t > chain.deadline then chain, pailGone = nil, false
        elseif t >= chain.due and canStart(state) and not playing and needsMet(byId[chain.id]) then
          begin(byId[chain.id], t)
        end
        return
      end
      if not nextAt then schedule(t) end
      if not playing and nextAt and t >= nextAt and canStart(state) then
        local d = date("*t")
        local sk = K.pick(skits, { pail = pailShown and not pailGone, evening = d.hour >= EVENING_HOUR, recent = recent }, random)
        if sk then begin(sk, t) else schedule(t) end
      end
    end)
  end
  function theme.line(kind)
    if not theme.on() or not LINES[kind] or random() >= LINE_CHANCE then return nil end
    local pool = LINES[kind]
    return pool[math.min(#pool, math.floor(random() * #pool) + 1)]
  end
  function theme.persona()
    if not theme.on() then return nil end
    local d = date("*t")
    return d.month == MONTH and d.day == END_DAY and DAY or WEEK
  end
  function theme.menu()
    if not theme.on() and not (date("*t").month == MONTH and date("*t").day >= START_DAY
      and date("*t").day <= END_DAY) then return nil end
    local forced = type(cfg.halloween) == "boolean"
    local groups = {}
    for _, pair in ipairs(GROUPS) do
      local entries = {}
      for _, sk in ipairs(skits) do
        if sk.group == pair[1] then
          local id = sk.id
          entries[#entries + 1] = { title = sk.name, fn = function() theme.skit(id) end }
        end
      end
      table.sort(entries, function(a, b) return a.title:lower() < b.title:lower() end)
      groups[#groups + 1] = { title = pair[2], menu = entries }
    end
    return { title = "Halloween", menu = {
      { title = forced and "Halloween theme (set in config.lua)" or "Halloween theme", checked = theme.on(),
        disabled = forced, fn = function()
          if forced then return end
          local on = not theme.on()
          set(TOGGLE_KEY, { year = date("*t").year, on = on })
          session = nil
          refresh(now())
        end },
      { title = "Spooky surprise", fn = function()
        if not theme.on() then return end
        local d = date("*t")
        local sk = K.pick(skits, { pail = pailShown and not pailGone,
          evening = d.hour >= EVENING_HOUR, recent = recent }, random)
        if sk then theme.skit(sk.id) end
      end },
      { title = "-" }, { title = "Skits", menu = groups },
    } }
  end
  function theme.behind(add, ox, oy, cx, at)
    return guard(function()
      if not theme.on() then return end
      advance(ox, oy, cx, at)
      pailDrawn = false -- pail() sets it when the pose leaves a hand free; front() keeps the answer
      web = web or webElements(K.hex(WEB_COLOR))
      for _, el in ipairs(web) do add(el, "web") end
      resting(add, at)
      actors(add, "behind", ox, oy, cx, at)
    end)
  end
  function theme.pail(add, ox, oy)
    return guard(function()
      if not theme.on() or pailGone then pailShown = false; return false end
      local sprite = library.pail
      if not sprite then pailShown = false; return false end
      local anim = sprite.anims.idle or sprite.anims[sprite.default]
      spriteRects(add, { x = ox + PAIL_COL * S, y = oy + PAIL_ROW * S, pixel = sprite.pixel,
        frame = anim.frames[1], flip = false, key = "held-pail:" .. ox .. ":" .. oy })
      pailDrawn = true
      return true
    end, false)
  end
  function theme.front(add, ox, oy, cx, at)
    return guard(function()
      if not theme.on() then return end
      pailShown = pailDrawn
      actors(add, "front", ox, oy, cx, at)
    end)
  end

  refresh(now())
  return theme
end

return H
