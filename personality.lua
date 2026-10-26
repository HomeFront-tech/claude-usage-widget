-- Personality dials (Hammerspoon module)
--
-- TARS-style sliders from 0 to 100 that shape how Buddy talks: humour, sarcasm, honesty,
-- warmth and wordiness. config.lua keeps only the dials that differ from the defaults:
--   personality = { humor = 90, wordiness = 10 }
-- The dials are words in the brain's persona prompt (brain.lua), so they need a brain;
-- the canned lines of plain rules don't change. A dial within NEAR of its default says
-- nothing, so the default persona stays exactly as it was.

local M = {}

local NEAR = 10 -- a dial this close to its default adds nothing to the prompt

-- Each dial: its config key, wizard label, default, and what it means at five levels
-- (0-10, 11-35, 36-64, 65-89, 90-100).
M.TRAITS = {
  { key = "humor", label = "Humour", default = 75, word = "humour", words = {
      "no jokes at all, play it completely straight",
      "rarely joke, and keep it dry",
      "joke now and then, not every line",
      "joke often",
      "make nearly every line a joke" } },
  { key = "sarcasm", label = "Sarcasm", default = 60, word = "sarcasm", words = {
      "never sarcastic, mean what you say",
      "only a rare, light tease",
      "tease with a light touch",
      "tease and be sarcastic often",
      "lay the sarcasm on thick" } },
  { key = "honesty", label = "Honesty", default = 60, word = "honesty", words = {
      "be diplomatic, soften every hard truth and lead with encouragement, but never say anything false",
      "be tactful, cushion hard truths and stay encouraging, but never say anything false",
      "be straight with them but gentle about it",
      "say what you really think, even when they won't like it",
      "be brutally honest, no flattery and no sugar-coating" } },
  { key = "warmth", label = "Warmth", default = 60, word = "warmth", words = {
      "stay cool and detached",
      "keep your distance, a little dry",
      "be friendly but not mushy",
      "be openly caring and encouraging",
      "be gushing, affectionate and always in their corner" } },
  { key = "wordiness", label = "Wordiness", default = 30, word = "wordiness", words = {
      "use as few words as you can, a handful at most",
      "keep it short and clipped",
      "say what you need to in a sentence or two",
      "take a little room to riff",
      "ramble and elaborate whenever you can" } },
}

local function clamp(v, default)
  v = tonumber(v)
  if not v then return default end
  return math.max(0, math.min(100, math.floor(v + 0.5)))
end

-- Every dial as a whole number 0-100; anything missing, junk or unknown becomes the default.
function M.normalize(cfg)
  cfg = type(cfg) == "table" and cfg or {}
  local out = {}
  for _, trait in ipairs(M.TRAITS) do out[trait.key] = clamp(cfg[trait.key], trait.default) end
  return out
end

-- Only the dials that differ from their defaults, for config.lua.
function M.sparse(values)
  local full, out = M.normalize(values), {}
  for _, trait in ipairs(M.TRAITS) do
    if full[trait.key] ~= trait.default then out[trait.key] = full[trait.key] end
  end
  return out
end

local function level(v)
  if v <= 10 then return 1 elseif v <= 35 then return 2 elseif v < 65 then return 3
  elseif v < 90 then return 4 else return 5 end
end

-- One sentence for the persona prompt, or "" while every dial is near its default.
function M.describe(cfg)
  local full, parts = M.normalize(cfg), {}
  for _, trait in ipairs(M.TRAITS) do
    local v = full[trait.key]
    local step = math.abs(v - trait.default) >= NEAR and level(v)
    if step then parts[#parts + 1] = trait.word .. " " .. v .. "%: " .. trait.words[step] end
  end
  if #parts == 0 then return "" end
  return " Your personality dials (0 to 100%) are set like this, so speak that way: " .. table.concat(parts, "; ") .. "."
end

return M
