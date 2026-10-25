-- skins.lua: skins load from folders, broken files are skipped, the pick is saved and a
-- theme's wear wins until the next pick.
return function(t, dir)
  local Skins = dofile(dir .. "/skins.lua")
  local key = "claudeBuddy.skinTest-" .. hs.host.uuid()
  local tmp = t.tmpdir()
  local repo, user = tmp .. "/repo", tmp .. "/user"
  local function rgb(r, g, b) return { red = r, green = g, blue = b, alpha = 1 } end
  local base = {
    body = rgb(0.85, 0.47, 0.34), shade = rgb(0.70, 0.36, 0.26), shine = rgb(0.94, 0.62, 0.50), eye = rgb(0.10, 0.08, 0.08),
    white = rgb(0.97, 0.97, 0.97), grey = rgb(0.58, 0.60, 0.64), dark = rgb(0.20, 0.21, 0.24), red = rgb(0.86, 0.22, 0.22),
    yellow = rgb(0.99, 0.88, 0.55), gold = rgb(0.98, 0.78, 0.25), brown = rgb(0.48, 0.31, 0.19), blue = rgb(0.45, 0.75, 0.98),
    pink = rgb(0.97, 0.42, 0.58),
  }
  local EMIT = {
    heart = { rate = 2.5, glyphs = { "♥" }, color = "pink", size = 13, from = "head", vy = -30, spread = 36, life = 1.3 },
  }
  local function near(a, b) return math.abs(a - b) < 0.002 end
  local function same(a, b) return type(a) == "table" and type(b) == "table" and near(a.red, b.red) and near(a.green, b.green)
    and near(a.blue, b.blue) and near(a.alpha or 1, b.alpha or 1) end
  local function raw(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end

  t.writeJson(repo .. "/classic.json", { id = "classic", name = "Classic", group = "classic",
    lines = { click = { "Classic click", "Another" }, idle = { "Classic idle", "More" } } })
  t.writeJson(repo .. "/amber.json", { id = "amber", name = "Amber", group = "classic" })
  t.writeJson(repo .. "/mint.json", { id = "mint", name = "Mint", group = "classic", colors = { body = "#5fc3a0" },
    palette = { hat = "#3d2459" },
    top = { { 0, -1, 1, 1, "hat" }, { 1, -1, 1, 1, "gold" }, { 2, -1, 1, 1, "#ff000080" }, { 3, -1, 1, 1, "body" } },
    legs = false })
  t.writeJson(repo .. "/witch.json", { id = "witch", name = "Witch", group = "halloween", palette = { hat = "#3d2459" },
    top = { { -2, -1, 18, 1, "hat" }, { 7, -7, 3, 1, "hat" }, { 9, -8, 2, 1, "hat" } },
    hand = { fps = 2, frames = { { { 15, 5, 1, 1, "grey" } }, { { 15, 4, 1, 1, "grey" } }, { { 15, 3, 1, 1, "grey" } } } },
    reactions = { shaken = { glyphs = { "A" }, color = "hat" }, love = { glyphs = { "M" } }, heart = { glyphs = { "E" }, size = 20 },
      wave = { glyphs = { "W" } }, music = { glyphs = { "N" }, rate = 1000000000, size = 500, grow = -900 } } })
  t.writeJson(repo .. "/ghost.json", { id = "ghost", name = "Ghost", group = "halloween", float = 8, shadow = 24,
    hand = { fps = 0, frames = { { { 15, 5, 1, 1, "grey" } } } }, face = { fps = 3, frames = {} },
    legs = { fps = 0, frames = { { { 0, 10, 2, 1, "body" } } } } })
  raw(repo .. "/broken.json", "{nope")
  t.writeJson(repo .. "/badrect.json", { id = "badrect", name = "Bad rect", group = "memes", top = { { 0.5, -1, 2, 1, "eye" } } })
  t.writeJson(repo .. "/badcolor.json", { id = "badcolor", name = "Bad colour", group = "memes", top = { { 0, -1, 2, 1, "chartreuse" } } })
  t.writeJson(repo .. "/wrongid.json", { id = "other", name = "Wrong id", group = "memes" })

  local printed = {}
  local ok, K = pcall(Skins.new, { dirs = { repo, tmp .. "/nope" }, key = key, base = base,
    log = function(line) printed[#printed + 1] = line end })
  t.ok(ok, "missing user dir is fine")
  if not ok then return t.ok(false, "new: " .. tostring(K)) end

  -- list, groups and skipped files
  local list = K.list()
  local ids = {}
  for i, s in ipairs(list) do ids[s.id] = i end
  t.eq(#list, 5, "loads the five good skins")
  t.eq(list[1].id, "classic", "list puts classic first")
  t.eq(list[2].id, "amber", "then its group by name")
  t.eq(list[#list].group, "halloween", "halloween comes last")
  t.eq(list[1].name, "Classic", "list has names")
  t.ok(not ids.broken and not ids.badrect and not ids.badcolor and not ids.other and not ids.wrongid, "skips broken files")
  local skipped = {}
  for _, line in ipairs(printed) do
    local file = line:match("^%[buddy skins%] skipped .-/([%w]+%.json): .+")
    if file then skipped[file] = true end
  end
  t.ok(skipped["broken.json"] and skipped["badrect.json"] and skipped["badcolor.json"] and skipped["wrongid.json"],
    "each skipped file prints a line")
  local groups = K.groups()
  t.eq(#groups, 7, "seven groups")
  t.eq(groups[1].group .. "|" .. groups[1].label, "classic|Classic & colours", "classic group first")
  t.eq(groups[6].label, "Movies & TV", "screen label")
  t.eq(groups[7].group, "halloween", "halloween group last")

  -- pick, wear and the saved choice
  t.eq(K.current().id, "classic", "starts in classic")
  t.eq(K.name(), "Classic", "name")
  t.eq(K.lines("click")[1], "Classic click", "lines")
  t.eq(K.lines("nope"), nil, "no lines of an unknown kind")
  t.eq(K.pick("nope"), false, "pick unknown id")
  t.eq(K.pick("witch"), true, "pick witch")
  t.eq(hs.settings.get(key), "witch", "pick saves")
  t.eq(K.lines("click"), nil, "skin without lines")
  local K2 = Skins.new({ dirs = { repo }, key = key, base = base })
  t.eq(K2.current().id, "witch", "pick survives a new instance")
  K.pick("classic")
  K.wear("witch")
  t.eq(K.current().id, "witch", "wear overrides")
  t.eq(hs.settings.get(key), "classic", "wear isn't saved")
  K.wear("nope")
  t.eq(K.current().id, "witch", "wear unknown id is ignored")
  K.wear(nil)
  t.eq(K.current().id, "classic", "wear(nil) restores")
  K.wear("witch")
  K.pick("classic")
  t.eq(K.current().id, "classic", "pick clears wear")
  hs.settings.set(key, "deleted-skin")
  t.eq(Skins.new({ dirs = { repo }, key = key, base = base }).current().id, "classic", "unknown saved id falls back to classic")
  local E = Skins.new({ dirs = { tmp .. "/empty" }, key = key, base = base })
  t.eq(E.current().id .. "|" .. E.name(), "classic|Classic", "built-in Classic with no files")
  t.eq(#E.list(), 1, "built-in Classic is listed")

  -- user folder
  t.writeJson(user .. "/witch.json", { id = "witch", name = "My Witch", group = "halloween" })
  local U = Skins.new({ dirs = { repo, user }, key = key, base = base })
  U.wear("witch")
  t.eq(U.name(), "My Witch", "user dir overrides repo id")
  t.eq(#U.list(), 5, "no duplicate after override")

  -- colours and layers
  K.pick("mint")
  local P = K.colors()
  t.ok(same(P.body, rgb(0x5f / 255, 0xc3 / 255, 0xa0 / 255)), "colors override body")
  t.ok(same(P.shade, base.shade) and same(P.white, base.white), "colors override body only")
  t.ok(same(base.body, rgb(0.85, 0.47, 0.34)), "base untouched")
  t.ok(K.colors() == P and K.colors().body == P.body, "colors are the same tables every frame")
  local top = K.layer("top", 0)
  t.ok(same(top[1][5], rgb(0x3d / 255, 0x24 / 255, 0x59 / 255)), "layer resolves palette colours")
  t.ok(same(top[2][5], base.gold), "layer resolves base colours")
  t.ok(same(top[3][5], { red = 1, green = 0, blue = 0, alpha = 128 / 255 }), "layer resolves hex colours")
  t.ok(top[4][5] == P.body, "base names use the skin's colours")
  t.eq(top[1][1] .. "," .. top[1][2] .. "," .. top[1][3] .. "," .. top[1][4], "0,-1,1,1", "rect numbers")
  t.eq(K.layer("legs", 0), false, "legs false means no legs")
  t.eq(K.layer("face", 0), nil, "absent layer is nil")
  K.pick("witch")
  t.eq(K.layer("legs", 0), nil, "absent legs are nil")
  t.eq(K.layer("hand", 0)[1][2], 5, "animated layer frame 1")
  t.eq(K.layer("hand", 0.6)[1][2], 4, "animated layer picks frame by time")
  t.eq(K.layer("hand", 1.6)[1][2], 5, "animated layer wraps")
  t.eq(K.topRows(), 8, "topRows of a witch hat is 8")
  t.eq(K.float() .. "|" .. K.shadow(), "0|36", "float and shadow defaults")
  K.pick("ghost")
  local hand, face = K.layer("hand", 1), K.layer("face", 1)
  t.ok(type(hand) == "table" and #hand == 0, "bad animated layer (fps 0) is empty")
  t.ok(type(face) == "table" and #face == 0, "bad animated layer (no frames) is empty")
  t.eq(K.layer("legs", 1), nil, "a bad animated legs layer keeps the usual legs")
  t.eq(K.float() .. "|" .. K.shadow(), "8|24", "float and shadow")
  t.eq(K.topRows(), 0, "no top layer, no rows")

  -- particles
  K.pick("witch")
  t.eq(K.particle(EMIT, "heart", "shaken", "love").glyphs[1], "A", "particle prefers the action")
  t.eq(K.particle(EMIT, "heart", "joy", "love").glyphs[1], "M", "then the mood")
  t.eq(K.particle(EMIT, "heart", "joy", "idle").glyphs[1], "E", "then the emitter")
  t.eq(K.particle(EMIT, "heart", "joy", "love", true).glyphs[1], "E", "an action's own emitter skips the mood")
  t.eq(K.particle(EMIT, "heart", "shaken", "love", true).glyphs[1], "A", "but still takes the action's reaction")
  local e = K.particle(EMIT, "heart", nil, "idle")
  t.eq(e.rate .. "|" .. e.vy .. "|" .. e.size, "2.5|-30|20", "override merges over the base emitter")
  t.ok(same(e.color, base.pink), "base colour name resolved")
  t.ok(same(K.particle(EMIT, "heart", "shaken", nil).color, rgb(0x3d / 255, 0x24 / 255, 0x59 / 255)), "override colour resolved")
  t.ok(K.particle(EMIT, "heart", nil, "idle") == e, "same emitter table while nothing changes")
  t.eq(K.particle(EMIT, nil, nil, "idle"), nil, "no emitter, no reaction")
  local w = K.particle(EMIT, nil, "wave", "idle")
  t.ok(w and w.glyphs[1] == "W" and w.rate == 2 and w.size == 13 and w.from == "head" and w.vy == -24
    and w.spread == 50 and w.life == 1.2 and same(w.color, base.white), "particle for an action with no emitter uses the defaults")
  local m = K.particle(EMIT, nil, nil, "music")
  t.eq(m.rate .. "|" .. m.size .. "|" .. m.grow, "30|60|-30", "a runaway rate, size or shrink is capped")
  K.pick("classic")
  local c = K.particle(EMIT, "heart", "shaken", "love")
  t.eq(c.glyphs[1], "♥", "classic keeps the built-in emitter")
  t.ok(EMIT.heart.color == "pink", "EMIT untouched")

  -- a hostile user skin: huge glyphs dropped, long lines and names clipped, numbers clamped
  local many = {}
  for i = 1, 20 do many[i] = "g" .. i end
  local tooMany = {}
  for i = 1, 15 do tooMany[i] = "line " .. i end
  t.writeJson(tmp .. "/huge/huge.json", { id = "huge", name = string.rep("N", 100), group = "memes", float = 1e9, shadow = -5,
    reactions = { shaken = { glyphs = { string.rep("x", 100000), "ok" }, life = 1e9, vx = -1e9, vy = 1e9, spread = 1e9, grow = 99 },
      dizzy = { glyphs = many } },
    lines = { click = { string.rep("y", 500), "fine" }, idle = tooMany } })
  local H = Skins.new({ dirs = { tmp .. "/huge" }, key = key, base = base })
  H.wear("huge")
  local hp = H.particle(EMIT, nil, "shaken", nil)
  t.ok(hp and #hp.glyphs == 1 and hp.glyphs[1] == "ok", "a huge glyph is dropped")
  t.eq(#H.particle(EMIT, nil, "dizzy", nil).glyphs, 12, "at most 12 glyphs")
  t.eq(hp.life .. "|" .. hp.vx .. "|" .. hp.vy .. "|" .. hp.spread .. "|" .. hp.grow, "10|-200|200|200|30", "particle numbers clamped")
  local hl = H.lines("click")
  t.ok(utf8.len(hl[1]) == 60 and hl[1]:sub(-3) == "…" and hl[2] == "fine", "a long line is clipped to 60")
  t.eq(#H.lines("idle"), 12, "at most 12 lines")
  t.eq(utf8.len(H.name()), 40, "name clipped to 40")
  t.eq(H.float() .. "|" .. H.shadow(), "60|0", "float and shadow clamped")

  -- an unreadable folder skips just that folder
  local locked = tmp .. "/locked"
  t.writeJson(locked .. "/locked.json", { id = "locked", name = "Locked", group = "memes" })
  hs.execute("chmod 000 '" .. locked .. "'")
  local okL, L = pcall(Skins.new, { dirs = { repo, locked }, key = key, base = base })
  hs.execute("chmod 755 '" .. locked .. "'")
  t.ok(okL and #L.list() == 5, "an unreadable folder doesn't stop loading")

  -- colour emoji fade as images; plain glyphs stay text
  t.eq(K.emoji("♥"), nil, "a text glyph is not an emoji")
  t.eq(K.emoji("✦"), nil, "a sparkle is text")
  local img = K.emoji("🎃")
  t.ok(img ~= nil and img:size().w > 0, "an emoji renders to an image")
  t.ok(K.emoji("🎃") == img, "emoji images are cached")
  t.ok(K.emoji("⚡") ~= nil, "emoji-style symbols count")

  -- the brain hears about the costume
  local B = dofile(dir .. "/brain.lua").configure({}, "Sam", false)
  B.costume("Witch")
  t.ok(B.persona():find("You're dressed as Witch right now.", 1, true), "brain wears the costume")
  B.costume(nil)
  t.ok(not B.persona():find("dressed as", 1, true), "no costume for Classic")

  hs.settings.clear(key)
end
