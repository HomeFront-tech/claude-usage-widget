-- Buddy's skit engine: compile sprite and skit data, then sample a scene in canvas points.
-- The format is in docs/superpowers/specs/2026-10-24-buddy-halloween-theme-design.md.
-- Colours, files and drawing belong to the caller; this module has no Hammerspoon calls.

local K = {}
K.GROUPS = { "bats", "spider", "visitors", "movies" }
K.ANCHORS = { "top", "head", "face", "hand", "feet", "web", "spider" }

local function set(list)
  local out = {}
  for _, v in ipairs(list) do out[v] = true end
  return out
end

local GROUP = set(K.GROUPS)
local ANCHOR = set(K.ANCHORS)
local BASE = set({ "body", "shade", "shine", "eye", "white", "grey", "dark", "red", "yellow", "gold", "brown", "blue", "pink" })
local EASE = set({ "linear", "in", "out", "inout" })
local ACTION = set({ "joy", "startle", "hop", "wave", "look", "stretch", "dance", "blush", "ponder", "talk",
  "shaken", "dizzy", "grumpy", "duck", "flee", "eat", "lookUp", "trot" })
local PROP = set({ "laptop", "popcorn", "controller", "mug", "envelope", "wrench", "shovel", "phone" })
local CUE = { "action", "say", "look", "run", "prop", "pail", "spider", "emit" }

local function number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function integer(v, lo, hi)
  return number(v) and v == math.floor(v) and v >= lo and v <= hi
end

local function list(v)
  if type(v) ~= "table" then return false end
  local n = #v
  for k in pairs(v) do
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then return false end
  end
  return true
end

local function object(v)
  if type(v) ~= "table" then return false end
  for k in pairs(v) do if type(k) ~= "string" then return false end end
  return true
end

local function fields(v, allowed, where)
  for k in pairs(v) do
    if not allowed[k] then return nil, where .. ": unknown field " .. tostring(k) end
  end
  return true
end

local function validText(s, lo, hi)
  if type(s) ~= "string" then return false end
  local n = utf8.len(s)
  return n and n >= lo and n <= hi
end

local function sameColor(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.red == b.red and a.green == b.green and a.blue == b.blue and a.alpha == b.alpha
end

local function chars(s)
  if type(s) ~= "string" or not utf8.len(s) then return nil end
  local out = {}
  for _, code in utf8.codes(s) do out[#out + 1] = utf8.char(code) end
  return out
end

function K.hex(s)
  if type(s) ~= "string" then return nil end
  local r, g, b, a = s:match("^#(%x%x)(%x%x)(%x%x)(%x*)$")
  if not r or (a ~= "" and #a ~= 2) then return nil end
  return { red = tonumber(r, 16) / 255, green = tonumber(g, 16) / 255,
    blue = tonumber(b, 16) / 255, alpha = a ~= "" and tonumber(a, 16) / 255 or 1 }
end

function K.ease(kind, p)
  p = math.max(0, math.min(1, p))
  if kind == "in" then return p * p end
  if kind == "out" then return 1 - (1 - p) * (1 - p) end
  if kind == "inout" then return p * p * (3 - 2 * p) end
  return p
end

local function sprite(d, color)
  if not object(d) then return nil, "must be an object" end
  local ok, why = fields(d, set({ "pixel", "colors", "anims" }), "sprite")
  if not ok then return nil, why end
  local pixel = d.pixel or 3
  if not integer(pixel, 1, 8) then return nil, "pixel must be an integer from 1 to 8" end
  if not object(d.colors) then return nil, "colors must be an object" end
  local colors = {}
  for char, name in pairs(d.colors) do
    if type(char) ~= "string" or utf8.len(char) ~= 1 or char == "." or char == " " then
      return nil, "colors need single lit characters"
    end
    if type(name) ~= "string" or not (K.hex(name) or BASE[name]) then return nil, "bad colour for " .. char end
    local resolved = color(name)
    if not resolved then return nil, "unresolved colour " .. name end
    colors[char] = resolved
  end
  if not object(d.anims) or not next(d.anims) then return nil, "anims must be a non-empty object" end
  local out = { pixel = pixel, anims = {} }
  local names = {}
  for name, a in pairs(d.anims) do
    if type(name) ~= "string" or not object(a) then return nil, "bad animation " .. tostring(name) end
    ok, why = fields(a, set({ "fps", "frames" }), "anim " .. name)
    if not ok then return nil, why end
    local fps = a.fps or 6
    if not number(fps) or fps < 1 or fps > 12 then return nil, "anim " .. name .. ": fps must be 1..12" end
    if not list(a.frames) or #a.frames == 0 then return nil, "anim " .. name .. ": frames must be a non-empty list" end
    local frames, counts = {}, {}
    for i, rows in ipairs(a.frames) do
      local first = list(rows) and chars(rows[1])
      if not first or #rows < 1 or #rows > 24 or #first < 1 or #first > 24 then
        return nil, "anim " .. name .. " frame " .. i .. ": size must be 1..24 by 1..24"
      end
      local w, runs, lit = #first, {}, 0
      for y, row in ipairs(rows) do
        local pixels = chars(row)
        if not pixels or #pixels ~= w then return nil, "anim " .. name .. " frame " .. i .. ": uneven rows" end
        local x = 1
        while x <= w do
          local char = pixels[x]
          if char == "." or char == " " then x = x + 1
          else
            local c = colors[char]
            if not c then return nil, "anim " .. name .. " frame " .. i .. ": unknown colour character " .. char end
            local start = x
            repeat x = x + 1 until x > w or not sameColor(c, colors[pixels[x]])
            local n = x - start
            runs[#runs + 1] = { x = start - 1, y = y - 1, n = n, color = c }
            lit = lit + n
          end
        end
      end
      frames[i], counts[i] = { w = w, h = #rows, runs = runs }, lit
    end
    if fps > 3 and #counts > 1 then
      local least, most = counts[1], counts[1]
      for i = 2, #counts do least = math.min(least, counts[i]); most = math.max(most, counts[i]) end
      if most - least > most / 2 then return nil, "anim " .. name .. ": lit pixels change too fast" end
    end
    out.anims[name] = { fps = fps, frames = frames }
    names[#names + 1] = name
  end
  table.sort(names)
  out.default = names[1]
  return out
end

function K.sprites(defs, color, warn)
  local out = {}
  warn = warn or function() end
  if not object(defs) then warn("sprites must be an object"); return out end
  for name, def in pairs(defs) do
    local ok, compiled, why = pcall(sprite, def, color)
    if not ok then why, compiled = tostring(compiled), nil end
    if compiled and type(name) == "string" then out[name] = compiled
    else warn("sprite " .. tostring(name) .. ": " .. (why or "bad name")) end
  end
  return out
end

local TOP = set({ "id", "name", "group", "length", "weight", "eveningWeight", "needs", "next", "sprites", "actors", "buddy" })
local ACTOR = set({ "sprite", "layer", "keys", "bob", "thread" })
local KEY = set({ "t", "x", "y", "at", "dx", "dy", "ease", "anim", "flip", "hide" })
local CUE_FIELDS = set({ "t", "action", "say", "look", "run", "prop", "pail", "spider", "emit", "for" })

local function checkPosition(k, first, where)
  local xy = k.x ~= nil or k.y ~= nil
  if xy and (not number(k.x) or not number(k.y) or k.at ~= nil or k.dx ~= nil or k.dy ~= nil) then
    return nil, where .. ": position needs x and y, without an anchor"
  end
  if k.at ~= nil then
    if not ANCHOR[k.at] or k.x ~= nil or k.y ~= nil then return nil, where .. ": unknown or mixed anchor" end
    if (k.dx ~= nil and not number(k.dx)) or (k.dy ~= nil and not number(k.dy)) then
      return nil, where .. ": dx and dy must be numbers"
    end
  elseif k.dx ~= nil or k.dy ~= nil then return nil, where .. ": dx and dy need an anchor" end
  if first and not xy and k.at == nil then return nil, where .. ": first key needs a position" end
  return true
end

local function compileActor(d, sprites, length, index)
  local where = "actor " .. index
  if not object(d) then return nil, where .. " must be an object" end
  local ok, why = fields(d, ACTOR, where)
  if not ok then return nil, why end
  if type(d.sprite) ~= "string" or not sprites[d.sprite] then return nil, where .. ": unknown sprite " .. tostring(d.sprite) end
  if d.layer ~= "front" and d.layer ~= "behind" then return nil, where .. ": layer must be front or behind" end
  if not list(d.keys) or #d.keys == 0 then return nil, where .. ": keys must be a non-empty list" end
  local art = sprites[d.sprite]
  local keys, prev = {}, -1
  for i, k in ipairs(d.keys) do
    local kw = where .. " key " .. i
    if not object(k) then return nil, kw .. " must be an object" end
    ok, why = fields(k, KEY, kw)
    if not ok then return nil, why end
    if not number(k.t) or k.t <= prev or k.t < 0 or k.t > length then return nil, kw .. ": t out of order or length" end
    ok, why = checkPosition(k, i == 1, kw)
    if not ok then return nil, why end
    if k.ease ~= nil and not EASE[k.ease] then return nil, kw .. ": unknown ease" end
    if k.anim ~= nil and not art.anims[k.anim] then return nil, kw .. ": unknown anim" end
    if (k.flip ~= nil and type(k.flip) ~= "boolean") or (k.hide ~= nil and type(k.hide) ~= "boolean") then
      return nil, kw .. ": flip and hide must be booleans"
    end
    keys[i], prev = k, k.t
  end
  local animCount = 0
  for _ in pairs(art.anims) do animCount = animCount + 1 end
  if animCount > 1 and keys[1].anim == nil then return nil, where .. ": first key needs anim" end
  if d.bob ~= nil then
    if not object(d.bob) or not fields(d.bob, set({ "amp", "hz" }), where .. ".bob") or
      not number(d.bob.amp) or d.bob.amp < 0 or d.bob.amp > 20 or
      not number(d.bob.hz) or d.bob.hz < 0 or d.bob.hz > 3 then
      return nil, where .. ": bob needs amp 0..20 and hz 0..3"
    end
  end
  if d.thread ~= nil and d.thread ~= "web" then return nil, where .. ": thread must be web" end
  return { sprite = d.sprite, layer = d.layer, keys = keys, bob = d.bob, thread = d.thread, art = art }
end

local function checkCue(c, length, index, color)
  local where = "cue " .. index
  if not object(c) then return nil, where .. " must be an object" end
  local ok, why = fields(c, CUE_FIELDS, where)
  if not ok then return nil, why end
  if not number(c.t) or c.t < 0 or c.t > length then return nil, where .. ": t outside length" end
  local kind, count
  count = 0
  for _, name in ipairs(CUE) do
    if c[name] ~= nil then kind, count = name, count + 1 end
  end
  if count ~= 1 then return nil, where .. ": needs exactly one cue kind" end
  local duration = kind == "action" or kind == "look" or kind == "run" or kind == "prop"
  if duration then
    if not number(c["for"]) or c["for"] <= 0 or c["for"] > length then return nil, where .. ": for must be in (0, length]" end
  elseif c["for"] ~= nil then return nil, where .. ": for has no effect on this cue" end
  if kind == "action" and not ACTION[c.action] then return nil, where .. ": unknown action" end
  if kind == "say" then
    if type(c.say) == "string" then
      if not validText(c.say, 1, 40) then return nil, where .. ": say must be 1..40 characters" end
    elseif list(c.say) and #c.say > 0 then
      for _, line in ipairs(c.say) do
        if not validText(line, 1, 40) then return nil, where .. ": say lines must be 1..40 characters" end
      end
    else return nil, where .. ": say must be a line or non-empty list" end
  end
  if kind == "look" then
    if type(c.look) == "string" then
      if not ANCHOR[c.look] then return nil, where .. ": unknown look anchor" end
    elseif not (list(c.look) and #c.look == 2 and number(c.look[1]) and number(c.look[2])) then
      return nil, where .. ": look needs an anchor or [x, y]"
    end
  end
  if kind == "run" and (not number(c.run) or c.run < -200 or c.run > 200) then return nil, where .. ": run must be -200..200" end
  if kind == "prop" and not PROP[c.prop] then return nil, where .. ": unknown prop" end
  if kind == "pail" and c.pail ~= "gone" and c.pail ~= "back" then return nil, where .. ": pail must be gone or back" end
  if kind == "spider" and c.spider ~= "away" and c.spider ~= "home" then return nil, where .. ": spider must be away or home" end
  if kind == "emit" then
    local e = c.emit
    if not object(e) then return nil, where .. ": emit must be an object" end
    ok, why = fields(e, set({ "glyphs", "color", "count", "from" }), where .. ".emit")
    if not ok then return nil, why end
    if not list(e.glyphs) or #e.glyphs == 0 then return nil, where .. ": emit glyphs must be a non-empty list" end
    for _, glyph in ipairs(e.glyphs) do if type(glyph) ~= "string" or glyph == "" then return nil, where .. ": bad emit glyph" end end
    if type(e.color) ~= "string" or not (K.hex(e.color) or BASE[e.color]) or not color(e.color) then
      return nil, where .. ": bad emit colour"
    end
    if not integer(e.count, 1, 12) then return nil, where .. ": emit count must be 1..12" end
    if not set({ "head", "side", "sky", "hand" })[e.from] then return nil, where .. ": bad emit from" end
  end
  return c
end

local function compile(def, lib, color)
  if not object(def) then return nil, "skit must be an object" end
  local ok, why = fields(def, TOP, "skit")
  if not ok then return nil, why end
  if not validText(def.id, 1, math.huge) then return nil, "id is required" end
  if not validText(def.name, 1, 30) then return nil, "name must be 1..30 characters" end
  if not GROUP[def.group] then return nil, "unknown group " .. tostring(def.group) end
  if not number(def.length) or def.length <= 0 or def.length > 30 then return nil, "length must be in (0, 30]" end
  if def.weight ~= nil and (not number(def.weight) or def.weight < 0) then return nil, "weight must be non-negative" end
  if def.eveningWeight ~= nil and (not number(def.eveningWeight) or def.eveningWeight < 0) then return nil, "eveningWeight must be non-negative" end
  local needs = {}
  if def.needs ~= nil then
    if not list(def.needs) then return nil, "needs must be a list" end
    for _, need in ipairs(def.needs) do
      if need ~= "pail" and need ~= "evening" then return nil, "unknown need " .. tostring(need) end
      needs[need] = true
    end
  end
  local following
  if def.next ~= nil then
    if not object(def.next) then return nil, "next must be an object" end
    ok, why = fields(def.next, set({ "skit", "after", "chance" }), "next")
    if not ok then return nil, why end
    if not validText(def.next.skit, 1, math.huge) then return nil, "next.skit needs an id" end
    local after = def.next.after
    if number(after) then after = { after, after } end
    if not list(after) or #after ~= 2 or not number(after[1]) or not number(after[2]) or
      after[1] < 0 or after[1] > after[2] or after[2] > 150 then return nil, "next.after must be 0..150 or [lo, hi]" end
    local chance = def.next.chance == nil and 1 or def.next.chance
    if not number(chance) or chance <= 0 or chance > 1 then return nil, "next.chance must be in (0, 1]" end
    following = { skit = def.next.skit, after = { after[1], after[2] }, chance = chance }
  end
  local sprites = {}
  if not object(lib) then return nil, "sprite library must be an object" end
  for name, art in pairs(lib) do sprites[name] = art end
  if def.sprites ~= nil then
    if not object(def.sprites) then return nil, "local sprites must be an object" end
    local warning
    local localSprites = K.sprites(def.sprites, color, function(msg) warning = msg end)
    if warning then return nil, warning end
    for name, art in pairs(localSprites) do sprites[name] = art end
  end
  if def.actors ~= nil and not list(def.actors) then return nil, "actors must be a list" end
  local actors = {}
  for i, actorDef in ipairs(def.actors or {}) do
    local actor, err = compileActor(actorDef, sprites, def.length, i)
    if not actor then return nil, err end
    actors[i] = actor
  end
  if def.buddy ~= nil and not list(def.buddy) then return nil, "buddy must be a list" end
  local cues, previous, lastRun, pailGone = {}, -1, nil, false
  for i, cue in ipairs(def.buddy or {}) do
    local checked, err = checkCue(cue, def.length, i, color)
    if not checked then return nil, err end
    if cue.t < previous then return nil, "cue " .. i .. ": t out of order" end
    previous, cues[i] = cue.t, cue
    if cue.run ~= nil then lastRun = cue end
    if cue.pail == "gone" then pailGone = true elseif cue.pail == "back" then pailGone = false end
  end
  if lastRun and (lastRun.run ~= 0 or lastRun.t + lastRun["for"] > def.length) then
    return nil, "last run must return home by length"
  end
  if pailGone and not following then return nil, "pail gone needs a later back cue or next skit" end
  return { id = def.id, name = def.name, group = def.group, length = def.length, weight = def.weight == nil and 2 or def.weight,
    eveningWeight = def.eveningWeight, needs = needs, next = following, actors = actors, cues = cues }
end

function K.compile(def, lib, color)
  local ok, result, why = pcall(compile, def, lib, color)
  if not ok then return nil, tostring(result) end
  return result, why
end

local function position(keys, index, anchors)
  for i = index, 1, -1 do
    local k = keys[i]
    if k.at then
      local a = anchors[k.at]
      if not a then return nil end
      return a.x + (k.dx or 0), a.y + (k.dy or 0)
    end
    if k.x ~= nil then return k.x, k.y end
  end
end

function K.sample(skit, time, anchors)
  local items = {}
  for _, actor in ipairs(skit.actors) do
    local keys = actor.keys
    if time >= keys[1].t and time <= keys[#keys].t then
      local index = 1
      while index < #keys and keys[index + 1].t <= time do index = index + 1 end
      local current = keys[index]
      local x, y = position(keys, index, anchors)
      if x and index < #keys then
        local following = keys[index + 1]
        local tx, ty = position(keys, index + 1, anchors)
        if tx then
          local p = K.ease(following.ease or "linear", (time - current.t) / (following.t - current.t))
          x, y = x + (tx - x) * p, y + (ty - y) * p
        end
      end
      local anim, flip, hide = actor.art.default, false, false
      for i = 1, index do
        local k = keys[i]
        if k.anim ~= nil then anim = k.anim end
        if k.flip ~= nil then flip = k.flip end
        if k.hide ~= nil then hide = k.hide end
      end
      if x and not hide then
        local a = actor.art.anims[anim]
        local frameIndex = math.floor(time * a.fps) % #a.frames + 1
        local frame, pixel = a.frames[frameIndex], actor.art.pixel
        y = y - (actor.bob and actor.bob.amp * math.sin(2 * math.pi * actor.bob.hz * time) or 0)
        local left = math.floor(x - frame.w * pixel / 2 + 0.5)
        local top = math.floor(y - frame.h * pixel + 0.5)
        local thread
        if actor.thread then
          local anchor = anchors[actor.thread]
          if anchor then thread = { x1 = math.floor(anchor.x + 0.5), y1 = math.floor(anchor.y + 0.5),
            x2 = math.floor(x + 0.5), y2 = top } end
        end
        items[#items + 1] = { layer = actor.layer, x = left, y = top, pixel = pixel, frame = frame, flip = flip,
          thread = thread, key = actor.sprite .. anim .. frameIndex .. "@" .. left .. "," .. top .. (flip and "f" or "") }
      end
    end
  end
  return items
end

function K.cues(skit, from, to)
  local out = {}
  for _, cue in ipairs(skit.cues) do
    if cue.t > from and cue.t <= to then out[#out + 1] = cue end
  end
  return out
end

function K.pick(skits, state, random)
  state = state or {}
  local recent = state.recent or {}
  local seen, eligible = {}, {}
  for _, id in ipairs(recent) do seen[id] = true end
  for _, skit in ipairs(skits) do
    local weight = state.evening and skit.eveningWeight or nil
    if weight == nil then weight = skit.weight end
    if weight > 0 and (not skit.needs.pail or state.pail) and (not skit.needs.evening or state.evening) then
      eligible[#eligible + 1] = { skit = skit, weight = weight }
    end
  end
  if #eligible == 0 then return nil end
  local fresh = {}
  for _, e in ipairs(eligible) do if not seen[e.skit.id] then fresh[#fresh + 1] = e end end
  if #fresh == 0 then
    local last = recent[#recent]
    for _, e in ipairs(eligible) do if e.skit.id ~= last then fresh[#fresh + 1] = e end end
    if #fresh == 0 then return nil end
  end
  local total = 0
  for _, e in ipairs(fresh) do total = total + e.weight end
  local r = math.max(0, math.min(1 - 1e-12, random())) * total
  for _, e in ipairs(fresh) do
    if r < e.weight then return e.skit end
    r = r - e.weight
  end
  return fresh[#fresh].skit
end

return K
