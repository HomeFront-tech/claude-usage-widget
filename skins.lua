-- Buddy's skins: costumes and colour swaps, kept as data files (Hammerspoon module)
--
-- A skin is a JSON file, skins/<id>.json, or one of your own in
-- ~/Library/Application Support/claude-usage-widget/skins (the same id replaces the
-- repo's). The format is in docs/superpowers/specs/2026-10-24-buddy-skins-design.md and
-- tools/check-skins checks it. Every file is checked once, when it loads: a broken one is
-- skipped with a console line, so drawing never has to check anything and never fails.
--
-- buddy.lua makes the one instance (ClaudeBuddy.skins). The menu calls pick(id), which
-- is saved; a theme calls wear(id) for a while and wear(nil) when it ends, which isn't.
-- Rects come back as { col, row, w, h, colour } with the colour already an hs colour
-- table. Tables handed out are shared and stay the same between frames (buddy.lua only
-- redraws when something changes), so don't modify them.

local M = {}

local GROUPS = {
  { group = "classic", label = "Classic & colours" },
  { group = "outfits", label = "Outfits" },
  { group = "memes", label = "Memes" },
  { group = "heroes", label = "Heroes" },
  { group = "games", label = "Games & anime" },
  { group = "screen", label = "Movies & TV" },
  { group = "halloween", label = "Halloween" },
}
local GROUP_ORDER = {}
for i, g in ipairs(GROUPS) do GROUP_ORDER[g.group] = i end
local BASE_NAMES = { body = true, shade = true, shine = true, eye = true, white = true, grey = true, dark = true,
                     red = true, yellow = true, gold = true, brown = true, blue = true, pink = true }
local BODY_COLORS = { "body", "shade", "shine", "eye" }
local LAYERS = { "behind", "legs", "body", "face", "hand", "top" }
local FROM = { head = true, side = true, sky = true, mug = true }
local NUMBERS = { size = true, rate = true, vy = true, vx = true, spread = true, life = true, grow = true }
local NO_BASE = { rate = 2, size = 13, from = "head", vy = -24, spread = 50, life = 1.2 } -- a reaction on an action with no emitter
local MIN_COL, MAX_COL, MIN_ROW, MAX_ROW = -6, 20, -9, 12
local GLYPH = 48 -- emoji are drawn once at this height, then scaled
-- Limits on what a hand-made skin can ask for, applied as it loads, so even a hostile
-- file can't freeze the frame loop.
local RANGES = { life = { 0.1, 10 }, vx = { -200, 200 }, vy = { -200, 200 }, spread = { 0, 200 }, grow = { -30, 30 } }
local MAX_GLYPH, MAX_GLYPHS = 8, 12  -- characters per glyph (longer ones dropped), glyphs per reaction
local MAX_LINE, MAX_LINES = 60, 12   -- characters per line (clipped), lines per kind
local MAX_NAME = 40

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- s cut to n characters, ending in "…" when it was longer; nil if it isn't valid UTF-8.
local function clip(s, n)
  local len = utf8.len(s)
  if not len then return nil end
  if len <= n then return s end
  return s:sub(1, utf8.offset(s, n) - 1) .. "…"
end

-- "#rrggbb" or "#rrggbbaa" -> an hs colour table, or nil.
local function hex(s)
  if type(s) ~= "string" then return nil end
  local r, g, b, a = s:match("^#(%x%x)(%x%x)(%x%x)(%x*)$")
  if not r or (a ~= "" and #a ~= 2) then return nil end
  return { red = tonumber(r, 16) / 255, green = tonumber(g, 16) / 255, blue = tonumber(b, 16) / 255,
           alpha = a ~= "" and tonumber(a, 16) / 255 or 1 }
end

-- A JSON array (an empty one counts), not an object.
local function isList(v)
  if type(v) ~= "table" then return false end
  local n = #v
  for k in pairs(v) do
    if math.type(k) ~= "integer" or k < 1 or k > n then return false end
  end
  return true
end

local function int(v)
  return type(v) == "number" and v == math.floor(v) and math.tointeger(v) or nil
end

local function strings(v)
  if not isList(v) then return false end
  for _, s in ipairs(v) do
    if type(s) ~= "string" or s == "" then return false end
  end
  return true
end

-- Turns a decoded skin file into what drawing needs, every colour resolved up front.
-- Returns the skin, or nil and why it can't be used. warn(text) reports a layer that's
-- dropped instead.
local function prepare(d, id, base, warn)
  if type(d) ~= "table" or isList(d) then return nil, "not a JSON object" end
  if d.id ~= id then return nil, "id must match the file name (" .. id .. ")" end
  local name = type(d.name) == "string" and d.name ~= "" and clip(d.name, MAX_NAME)
  if not name then return nil, "name is required" end
  if not GROUP_ORDER[d.group] then return nil, "unknown group " .. tostring(d.group) end

  local colors = {}
  for k, v in pairs(base) do colors[k] = v end
  if d.colors ~= nil then
    if type(d.colors) ~= "table" then return nil, "colors must be an object" end
    for _, k in ipairs(BODY_COLORS) do
      local v = d.colors[k]
      if v ~= nil then
        colors[k] = hex(v) or BASE_NAMES[v] and base[v]
        if not colors[k] then return nil, "colors." .. k .. ": bad colour" end
      end
    end
  end
  local palette = {}
  if d.palette ~= nil then
    if type(d.palette) ~= "table" or (isList(d.palette) and next(d.palette)) then return nil, "palette must be an object" end
    for k, v in pairs(d.palette) do
      palette[k] = hex(v) or BASE_NAMES[v] and colors[v]
      if not palette[k] then return nil, "palette." .. tostring(k) .. ": bad colour" end
    end
  end
  local function color(name)
    if type(name) ~= "string" then return nil end
    return palette[name] or BASE_NAMES[name] and colors[name] or hex(name)
  end

  local function rects(list, where)
    local out = {}
    for i, q in ipairs(list) do
      if not isList(q) or #q ~= 5 then return nil, where .. " rect " .. i .. ": not [col, row, w, h, colour]" end
      local c, r, w, h = int(q[1]), int(q[2]), int(q[3]), int(q[4])
      if not (c and r and w and h) then return nil, where .. " rect " .. i .. ": numbers must be whole" end
      if w < 1 or h < 1 or c < MIN_COL or c + w - 1 > MAX_COL or r < MIN_ROW or r + h - 1 > MAX_ROW then
        return nil, where .. " rect " .. i .. ": outside cols -6..20, rows -9..12"
      end
      local col = color(q[5])
      if not col then return nil, where .. " rect " .. i .. ": unknown colour " .. tostring(q[5]) end
      out[i] = { c, r, w, h, col }
    end
    return out
  end

  -- each layer: nil (absent), false (legs only: none) or { fps = n or nil, frames = { rects, … } }
  local layers, topRow = {}, 0
  for _, name in ipairs(LAYERS) do
    local v = d[name]
    if v == false and name == "legs" then
      layers.legs = false
    elseif v ~= nil then
      if type(v) ~= "table" then return nil, name .. " must be a list of rects" end
      if isList(v) then
        local list, err = rects(v, name)
        if not list then return nil, err end
        layers[name] = { frames = { list } }
      else -- animated: { fps, frames }; a bad one draws nothing rather than failing mid-frame
        local fps, frames = v.fps, v.frames
        local ok = type(fps) == "number" and fps > 0 and isList(frames) and #frames > 0
        for _, fr in ipairs(ok and frames or {}) do ok = ok and isList(fr) end
        if ok then
          local out = { fps = fps, frames = {} }
          for i, fr in ipairs(frames) do
            local list, err = rects(fr, name .. " frame " .. i)
            if not list then return nil, err end
            out.frames[i] = list
          end
          layers[name] = out
        elseif name == "legs" then -- a typo in a legs animation shouldn't leave Buddy legless
          warn("legs needs fps above 0 and at least one frame; drawing the usual legs")
        else
          warn(name .. " needs fps above 0 and at least one frame; drawing nothing for it")
          layers[name] = { frames = { {} } }
        end
      end
      if name == "top" then
        for _, fr in ipairs(layers.top.frames) do
          for _, q in ipairs(fr) do topRow = math.min(topRow, q[2]) end
        end
      end
    end
  end

  local reactions = {}
  if d.reactions ~= nil then
    if type(d.reactions) ~= "table" then return nil, "reactions must be an object" end
    for key, r in pairs(d.reactions) do
      local where = "reactions." .. tostring(key)
      if type(r) ~= "table" or (isList(r) and next(r)) then return nil, where .. " must be an object" end
      local out = {}
      for k, v in pairs(r) do -- unknown fields are ignored here; tools/check-skins reports them
        if k == "glyphs" then
          if not strings(v) or #v == 0 then return nil, where .. ".glyphs must be a list of strings" end
          local keep = {}
          for _, g in ipairs(v) do
            local n = utf8.len(g)
            if n and n <= MAX_GLYPH and #keep < MAX_GLYPHS then keep[#keep + 1] = g end
          end
          out.glyphs = #keep > 0 and keep or nil
        elseif k == "color" then
          out.color = color(v)
          if not out.color then return nil, where .. ".color: unknown colour " .. tostring(v) end
        elseif k == "from" then
          if not FROM[v] then return nil, where .. ".from must be head, side, sky or mug" end
          out.from = v
        elseif NUMBERS[k] then
          if type(v) ~= "number" then return nil, where .. "." .. k .. " must be a number" end
          out[k] = v
        end
      end
      for k, range in pairs(RANGES) do
        if out[k] and (k ~= "life" or out.life > 0) then out[k] = clamp(out[k], range[1], range[2]) end
      end
      if (out.size and out.size <= 0) or (out.life and out.life <= 0) then return nil, where .. ": size and life must be above 0" end
      reactions[key] = out
    end
  end

  local lines = {}
  if d.lines ~= nil then
    if type(d.lines) ~= "table" then return nil, "lines must be an object" end
    for _, kind in ipairs({ "click", "idle" }) do
      local v = d.lines[kind]
      if v ~= nil and not strings(v) then return nil, "lines." .. kind .. " must be a list of strings" end
      local keep = {}
      for _, l in ipairs(v or {}) do
        local s = clip(l, MAX_LINE)
        if s and #keep < MAX_LINES then keep[#keep + 1] = s end
      end
      if #keep > 0 then lines[kind] = keep end
    end
  end

  for _, k in ipairs({ "float", "shadow" }) do
    if d[k] ~= nil and type(d[k]) ~= "number" then return nil, k .. " must be a number" end
  end

  return { id = id, name = name, group = d.group, colors = colors, layers = layers, reactions = reactions,
           lines = lines, float = clamp(d.float or 0, 0, 60), shadow = clamp(d.shadow or 36, 0, 60), top = -topRow }
end

local function readFile(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- Colour emoji ignore the text colour's alpha, so they'd pop out instead of fading. A
-- glyph counts as one if it's outside the Basic Multilingual Plane, asks for emoji
-- style (U+FE0F, or a joiner), or is a symbol that's emoji style by default.
local EMOJI_BMP = {}
for _, cp in ipairs({ 0x231A, 0x231B, 0x23E9, 0x23EA, 0x23EB, 0x23EC, 0x23F0, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615,
    0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3,
    0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2753, 0x2754, 0x2755, 0x2757, 0x2795,
    0x2796, 0x2797, 0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55 }) do EMOJI_BMP[cp] = true end
for cp = 0x2648, 0x2653 do EMOJI_BMP[cp] = true end -- the zodiac

function M.isEmoji(s)
  if type(s) ~= "string" or not utf8.len(s) then return false end
  for _, cp in utf8.codes(s) do
    if cp >= 0x1F000 or cp == 0xFE0F or cp == 0x200D or EMOJI_BMP[cp] then return true end
  end
  return false
end

-- One emoji drawn into an image on a canvas that's never shown, as wide as the glyph
-- needs (an emoji pair is wider than one); false if that fails.
local function render(ch)
  local ok, img = pcall(function()
    local text = hs.styledtext.new(ch, { font = { name = hs.styledtext.defaultFonts.system.name, size = GLYPH * 0.75 },
      paragraphStyle = { alignment = "center" } })
    local w = math.max(GLYPH, math.ceil(hs.drawing.getTextDrawingSize(text).w) + 8)
    local c = hs.canvas.new({ x = 0, y = 0, w = w, h = GLYPH })
    c[1] = { type = "text", frame = { x = 0, y = 0, w = w, h = GLYPH }, text = text }
    local im = c:imageFromCanvas()
    c:delete()
    return im
  end)
  return ok and img or false
end

-- opts: dirs = { repoDir, userDir, … } (later ones replace earlier ids), key = the
-- hs.settings key for the pick, base = buddy.lua's colours.
function M.new(opts)
  local log = opts.log or print -- where skipped-file notes go (specs pass their own; never swap the global print)
  opts = type(opts) == "table" and opts or {}
  local base, key = opts.base or {}, opts.key or "claudeBuddy.skin"
  local skins = {}
  local function scan(dir)
    if hs.fs.attributes(dir, "mode") == "directory" then
      local names = {}
      for name in hs.fs.dir(dir) do
        if name:match("^[^.].*%.json$") then names[#names + 1] = name end
      end
      table.sort(names)
      for _, name in ipairs(names) do
        local path = dir .. "/" .. name
        local notes, skin, why = {}, nil, nil
        local text = hs.fs.attributes(path, "mode") == "file" and readFile(path)
        if not text then
          why = "can't read it"
        else
          local okd, d = pcall(hs.json.decode, text) -- nil (and a LuaSkin console error) when it isn't JSON
          if not okd or d == nil then why = "not valid JSON"
          else
            local ok, s, err = pcall(prepare, d, name:sub(1, -6), base, function(w) notes[#notes + 1] = w end)
            if ok then skin, why = s, err else why = "couldn't load it: " .. tostring(s) end
          end
        end
        if skin then
          skins[skin.id] = skin
          for _, w in ipairs(notes) do log(string.format("[buddy skins] %s: %s", path, w)) end
        else
          log(string.format("[buddy skins] skipped %s: %s", path, why))
        end
      end
    end
  end
  for _, dir in ipairs(opts.dirs or {}) do
    local ok, err = pcall(scan, dir) -- an unreadable folder skips that folder, nothing else
    if not ok then log(string.format("[buddy skins] couldn't read %s: %s", dir, tostring(err))) end
  end
  skins.classic = skins.classic or prepare({ id = "classic", name = "Classic", group = "classic" }, "classic", base, log)

  local K = {}
  local picked = hs.settings.get(key) -- may name a skin that's gone; then it's Classic until it's back
  local worn = nil                    -- a theme's costume, not saved
  local particles, emoji = {}, {}

  function K.current()
    return worn and skins[worn] or picked and skins[picked] or skins.classic
  end

  function K.pick(id)
    if type(id) ~= "string" or not skins[id] then return false end
    picked, worn = id, nil
    hs.settings.set(key, id)
    return true
  end

  function K.wear(id)
    if id == nil then worn = nil
    elseif skins[id] then worn = id end
  end

  -- Every skin as { id, name, group }: Classic first, then by group in menu order and name.
  function K.list()
    local out = {}
    for id, s in pairs(skins) do out[#out + 1] = { id = id, name = s.name, group = s.group } end
    table.sort(out, function(a, b)
      if (a.id == "classic") ~= (b.id == "classic") then return a.id == "classic" end
      if a.group ~= b.group then return GROUP_ORDER[a.group] < GROUP_ORDER[b.group] end
      if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
      return a.id < b.id
    end)
    return out
  end

  function K.groups()
    local out = {}
    for i, g in ipairs(GROUPS) do out[i] = { group = g.group, label = g.label } end
    return out
  end

  function K.colors() return K.current().colors end

  -- A layer's rects at time t (seconds): nil when the skin doesn't have it, false for
  -- legs: false (no legs).
  function K.layer(name, t)
    local l = K.current().layers[name]
    if not l then return l end
    local n = #l.frames
    if n == 1 or not l.fps then return l.frames[1] end
    return l.frames[math.floor((t or 0) * l.fps) % n + 1]
  end

  function K.topRows() return K.current().top end
  function K.float() return K.current().float end
  function K.shadow() return K.current().shadow end

  -- The emitter to use: emit[emitName] with the skin's reaction for the action, else the
  -- mood, else the emitter laid over it, colour resolved. actionEmits: the emitter is the
  -- action's own (ponder's "?"), so the mood's reaction is skipped. The same table comes
  -- back while nothing changes. nil when there's nothing to emit.
  function K.particle(emit, emitName, actionName, moodName, actionEmits)
    local s = K.current()
    local R = s.reactions
    if actionEmits then moodName = nil end
    local which = actionName and R[actionName] and actionName or moodName and R[moodName] and moodName
      or emitName and R[emitName] and emitName or nil
    local from = emitName and type(emit) == "table" and emit[emitName] or nil
    if not from and not which then return nil end
    local ck = s.id .. "|" .. (from and emitName or "") .. "|" .. (which or "")
    local hit = particles[ck]
    if hit == nil then
      hit = {}
      for k, v in pairs(from or NO_BASE) do hit[k] = v end
      for k, v in pairs(which and R[which] or {}) do hit[k] = v end
      if type(hit.color) == "string" then hit.color = s.colors[hit.color] or hex(hit.color) end
      if type(hit.color) ~= "table" then hit.color = s.colors.white or { red = 1, green = 1, blue = 1, alpha = 1 } end
      -- sane limits: a runaway rate would stall the frame loop, a glyph can't shrink past nothing
      hit.rate = math.max(0, math.min(30, hit.rate or 0))
      hit.size = math.max(1, math.min(60, hit.size or 13))
      if hit.grow then hit.grow = math.max(1 - hit.size, math.min(60 - hit.size, hit.grow)) end
      if not strings(hit.glyphs) or #hit.glyphs == 0 then hit = false end
      particles[ck] = hit
    end
    return hit or nil
  end

  function K.lines(kind) return K.current().lines[kind] end
  function K.name() return K.current().name end

  -- An emoji glyph as an image, so it can fade with imageAlpha; nil for plain glyphs.
  function K.emoji(ch)
    local hit = emoji[ch]
    if hit == nil then
      hit = M.isEmoji(ch) and render(ch) or false
      emoji[ch] = hit
    end
    return hit or nil
  end

  return K
end

return M
