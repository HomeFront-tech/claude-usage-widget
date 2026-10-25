-- The card's API value row, minus the drawing: dollars per period, the "× your plan" line,
-- when a new fun comparison is due, and filling its number in. Plain functions, so the
-- tests can check them; usage_widget.lua draws the row and keeps the saved comparisons.
-- The dollars come from bin/claude-tokens (`periods` in its summary).

local V = {}

V.PERIODS = {
  { key = "session", label = "Session" },
  { key = "today", label = "Today" },
  { key = "week", label = "Week" },
  { key = "month", label = "Month" },
  { key = "ytd", label = "Year to date" },
  { key = "all", label = "All time" },
}

local SAME_WITHIN = 600 -- plan reset times wobble by a second between checks
local MIN_PRICE, MAX_PRICE = 0.01, 1e12

local MAX_LINE = 90

function V.figure(p, includeBuddy)
  return (p.value or 0) + (includeBuddy and (p.buddy or 0) or 0)
end

local function commas(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- "$26.40" under $100, "$1,284" from there up.
function V.money(x)
  if x < 100 then return string.format("$%.2f", x) end
  return "$" .. commas(x)
end

function V.multiple(p, figure)
  if type(p.paid) ~= "number" or p.paid <= 0 then return nil end
  return string.format("%.1f× your plan", figure / p.paid)
end

-- How far the dollars must move before a new comparison: how much such periods usually
-- vary, or a quarter of the figure (at least $1) until there's enough history to tell.
function V.threshold(p, figure)
  if type(p.spread) == "number" and p.spread > 0 then return p.spread end
  return math.max(1, 0.25 * figure)
end

-- saved: { from, at, text } for this period, or nil. "rollover" means the period started
-- over: clear its line and ask again with nil. A rolling window (the last 5 hours, when the
-- plan's session isn't known) moves all the time and never starts over.
-- A rolling window only asks again when it climbs; as it drains, "rebase" means: keep the
-- line, lower its baseline to the figure. Nothing is ever asked at $0.
function V.due(saved, p, figure)
  if saved and not V.same(saved.from, p.from) and not p.rolling then return "rollover" end
  if figure <= 0 then return nil end
  local at = saved and saved.at or 0
  if p.rolling and saved then
    if figure - at >= V.threshold(p, figure) then return "new" end
    if figure < at then return "rebase" end
    return nil
  end
  if math.abs(figure - at) >= V.threshold(p, figure) then return "new" end
  return nil
end

-- Two period starts within minutes of each other are the same period.
function V.same(a, b)
  return type(a) == "number" and type(b) == "number" and math.abs(a - b) < SAME_WITHIN
end

-- A percent with two significant digits, never in exponent form: 0.50, 63, 0.0000041.
local function percent(x)
  local decimals = math.max(0, 1 - math.floor(math.log(x, 10)))
  local scale = 10 ^ decimals
  return string.format("%." .. decimals .. "f", math.floor(x * scale + 0.5) / scale)
end

-- reply: { emoji, thing, price, count, part }. A count of things when the figure buys at
-- least one, otherwise a percentage of one. Nil when the reply can't make a tidy line.
function V.fill(reply, figure)
  if type(figure) ~= "number" or figure <= 0 then return nil end
  if type(reply) ~= "table" or type(reply.price) ~= "number" then return nil end
  if not (reply.price >= MIN_PRICE and reply.price <= MAX_PRICE) then return nil end
  if reply.emoji and reply.emoji ~= "" and not V.emojiOk(reply.emoji) then return nil end
  local text, n
  if reply.price * 2 <= figure then -- two or more; "1 lattes" reads wrong, so one and a bit is a percentage
    text, n = reply.count, commas(math.floor(figure / reply.price))
  else
    text, n = reply.part, percent(figure / reply.price * 100) .. "%"
  end
  if type(text) ~= "string" or not text:find("{n}", 1, true) then return nil end
  text = text:gsub("{n}", function() return n end)
  local emoji = type(reply.emoji) == "string" and reply.emoji ~= "" and (reply.emoji .. " ") or ""
  local line = emoji .. text
  if (utf8.len(line) or #line) > MAX_LINE then return nil end
  return line
end

-- One short emoji (a flag or skin-tone sequence at most), not words.
function V.emojiOk(e)
  return type(e) == "string" and #e >= 1 and #e <= 28 and not e:find("[%w%s]")
end

return V
