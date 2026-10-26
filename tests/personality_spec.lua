-- personality.lua: TARS-style dials (0-100) that shape Buddy's speech; defaults change nothing.
return function(t, dir)
  local P = dofile(dir .. "/personality.lua")

  -- normalising: whole numbers 0-100, defaults for anything missing or junk
  local n = P.normalize(nil)
  for _, trait in ipairs(P.TRAITS) do t.eq(n[trait.key], trait.default, trait.key .. " defaults") end
  n = P.normalize({ humor = 150, sarcasm = -4, honesty = "90", warmth = "x", wordiness = 44.6, bogus = 1 })
  t.eq(n.humor, 100, "clamped to 100")
  t.eq(n.sarcasm, 0, "clamped to 0")
  t.eq(n.honesty, 90, "numeric strings count")
  t.eq(n.warmth, 60, "junk falls back to the default")
  t.eq(n.wordiness, 45, "rounded")
  t.eq(math.type(n.wordiness), "integer", "stored as integers")
  t.eq(n.bogus, nil, "unknown keys dropped")
  t.eq(P.normalize("nope").humor, 75, "a non-table is the defaults")

  -- the saved form keeps only what differs from the defaults
  t.eq(next(P.sparse(P.normalize({}))), nil, "all defaults saves nothing")
  local s = P.sparse({ humor = 90, sarcasm = 60 })
  t.eq(s.humor, 90, "changed dial kept")
  t.eq(s.sarcasm, nil, "default dial dropped")

  -- default dials add nothing to the prompt
  t.eq(P.describe(nil), "", "no config, no sentence")
  t.eq(P.describe({}), "", "defaults, no sentence")
  t.eq(P.describe({ humor = 70, warmth = 65 }), "", "small nudges say nothing")

  -- a moved dial speaks in TARS style and in plain words
  local hi = P.describe({ humor = 100 })
  t.ok(hi:find("humour 100%", 1, true), "percent in the prompt")
  t.ok(hi:find("every line", 1, true), "plain words at the top")
  local lo = P.describe({ humor = 0 })
  t.ok(lo:find("humour 0%", 1, true) and lo:find("straight", 1, true), "plain words at the bottom")
  local two = P.describe({ sarcasm = 5, wordiness = 90 })
  t.ok(two:find("sarcasm 5%", 1, true) and two:find("wordiness 90%", 1, true), "every moved dial listed")
  t.ok(not two:find("humour", 1, true), "untouched dials left out")
  -- low honesty means tactful, never lying
  local kind = P.describe({ honesty = 10 })
  t.ok(kind:find("never say anything false", 1, true), "low honesty still tells the truth")

  -- the persona carries it; the default persona is unchanged
  local plain = dofile(dir .. "/brain.lua").configure({}, "Sam", false)
  local before = plain.persona()
  t.ok(not before:find("dials", 1, true), "no dials by default")
  plain.setPersonality({ humor = 100 })
  t.ok(plain.persona():find("humour 100%", 1, true), "persona gets the dial")
  t.ok(plain.assistant():find("humour 100%", 1, true), "so does the assistant prompt")
  plain.setPersonality(nil)
  t.eq(plain.persona(), before, "clearing the dials restores the persona")
end
