-- The AIs the usage card can show, and the rules they share (no hs.* calls, so specs and
-- every module can load it). Each provider plugs in the same way: an entry in P.LIST plus,
-- when it has numbers to fetch, a module behind bin/ai-usage that prints the same one-line
-- JSON bin/claude-usage prints. config.lua's optional `usage` table picks which ones show,
-- their order, what each hides, how often each checks and the yellow and red levels; with
-- no `usage` table the card is Claude only, exactly as before.

local P = {}

local REST = { 60, 300, 900, 1800, 3600 } -- refresh choices for everything but Claude, seconds
P.LIST = {
  { id = "claude", name = "Claude", kind = "login", refresh = 300, min_refresh = 300,
    choices = { 300, 600, 900, 1800 }, fields = {}, fetch = false }, -- usage_widget.lua's own loop
  { id = "codex", name = "Codex", kind = "login", refresh = 300, min_refresh = 60, choices = REST, fields = {}, fetch = true },
  { id = "openrouter", name = "OpenRouter", kind = "key", refresh = 900, min_refresh = 60, choices = REST,
    fields = { "key", "budget" }, fetch = true },
  { id = "xai", name = "xAI credits", kind = "key", refresh = 1800, min_refresh = 60, choices = REST,
    fields = { "key", "team_id", "budget" }, fetch = true },
  { id = "grok_plan", name = "Grok", kind = "manual", fields = { "plan", "renews_day" }, fetch = false },
}
local BY_ID = {}
for _, e in ipairs(P.LIST) do BY_ID[e.id] = e end

function P.byId(id) return BY_ID[id] end

local function str(v) return type(v) == "string" and v ~= "" and v or nil end
local function positive(v) return type(v) == "number" and v > 0 and v or nil end

-- The usage settings from config.lua, every field checked on its own (a bad one falls back
-- to its default). order: the enabled ids, top first; lead: the provider drawn in full
-- (Claude whenever it's on); rest: the others, drawn small.
function P.settings(cfg)
  local u = type(cfg) == "table" and type(cfg.usage) == "table" and cfg.usage or {}
  local s = { warn_at = 70, hot_at = 90, alert_red = u.alert_red == true, order = {}, rest = {}, providers = {} }
  -- each level defaults on its own (the wizard saves only the one that moved), then the pair
  -- must make sense or both fall back
  local warn = type(u.warn_at) == "number" and u.warn_at or s.warn_at
  local hot = type(u.hot_at) == "number" and u.hot_at or s.hot_at
  if warn >= 1 and warn < hot and hot <= 100 then s.warn_at, s.hot_at = warn, hot end
  local seen = {}
  for _, id in ipairs(type(u.order) == "table" and u.order or {}) do
    if BY_ID[id] and not seen[id] then s.order[#s.order + 1], seen[id] = id, true end
  end
  if #s.order == 0 then s.order = { "claude" } end
  s.claudeOn = false
  for _, id in ipairs(s.order) do if id == "claude" then s.claudeOn = true end end
  s.lead = s.claudeOn and "claude" or s.order[1]
  for _, id in ipairs(s.order) do if id ~= s.lead then s.rest[#s.rest + 1] = id end end
  s.claudeOnly = #s.order == 1 and s.claudeOn
  local given = type(u.providers) == "table" and u.providers or {}
  for _, e in ipairs(P.LIST) do
    local p = type(given[e.id]) == "table" and given[e.id] or {}
    local ps = { hide = {}, budget = positive(p.budget), team_id = str(p.team_id), plan = str(p.plan) }
    if e.refresh then
      ps.refresh = type(p.refresh) == "number" and math.max(e.min_refresh, math.min(86400, p.refresh)) or e.refresh
    end
    local day = type(p.renews_day) == "number" and math.tointeger(p.renews_day)
    if day and day >= 1 and day <= 31 then ps.renews_day = day end
    for _, label in ipairs(type(p.hide) == "table" and p.hide or {}) do
      if type(label) == "string" then ps.hide[label] = true end
    end
    s.providers[e.id] = ps
  end
  return s
end

-- "ok", "warn" or "hot" for a bar: the user's levels, or the API's own severity when higher.
function P.level(pct, severity, s)
  pct = tonumber(pct) or 0
  if severity == "critical" or pct >= s.hot_at then return "hot" end
  if severity == "warning" or pct >= s.warn_at then return "warn" end
  return "ok"
end

-- The limits then credits a result shows, each marked with its kind; hidden labels and
-- anything without a label and a number are left out.
function P.visible(res, hide)
  local items = {}
  hide = hide or {}
  if type(res) ~= "table" then return items end
  for _, key in ipairs({ "limits", "credits" }) do
    for _, it in ipairs(type(res[key]) == "table" and res[key] or {}) do
      if type(it) == "table" and type(it.label) == "string" and type(it.pct) == "number" and not hide[it.label] then
        local c = {}
        for k, v in pairs(it) do c[k] = v end
        c.kind = key == "limits" and "limit" or "credit"
        if type(c.resets_at) ~= "number" then c.resets_at = nil end
        items[#items + 1] = c
      end
    end
  end
  return items
end

-- The shown limit or credit nearest its cap (facts never count), or nil.
function P.tightest(res, hide)
  local best
  for _, it in ipairs(P.visible(res, hide)) do
    if not best or it.pct > best.pct then best = it end
  end
  return best
end

local function isCredit(it) return type(it.used) == "number" end
local function pct(it) return string.format("%d%%", math.floor(it.pct + 0.5)) end

-- The figure on a full row: "41%", or dollars the way Claude's credit rows show them.
function P.figure(it)
  if not isCredit(it) then return pct(it) end
  if type(it.limit) == "number" then return string.format("$%.2f / $%d", it.used, math.floor(it.limit)) end
  return string.format("$%.2f", it.used)
end

-- The figure on a small row: "41% wk", "$18 / $50" (cents only under $10).
local SUFFIX = { Week = "wk", ["This week"] = "wk", ["5-hour"] = "5h", Today = "today", ["This month"] = "mo" }
function P.short(it)
  if not isCredit(it) then
    local suffix = SUFFIX[it.label]
    return pct(it) .. (suffix and " " .. suffix or "")
  end
  local used = it.used < 10 and string.format("$%.2f", it.used) or string.format("$%d", math.floor(it.used + 0.5))
  if type(it.limit) == "number" then return used .. string.format(" / $%d", math.floor(it.limit)) end
  return used
end

-- Numbers older than three checks have missed some and show grey.
function P.isStale(fetched_at, refresh, now)
  return (now or os.time()) - (fetched_at or 0) > 3 * refresh
end

-- The arguments after bin/ai-usage for one provider.
function P.args(id, ps, keyOnStdin)
  local args = { id }
  ps = ps or {}
  if str(ps.team_id) then args[#args + 1], args[#args + 2] = "--team-id", ps.team_id end
  if positive(ps.budget) then args[#args + 1], args[#args + 2] = "--budget", string.format("%g", ps.budget) end
  if keyOnStdin then args[#args + 1] = "--key-stdin" end
  return args
end

-- The Grok subscription ------------------------------------------------------------------
-- xAI shares no usage for consumer plans, so it shows the plan you typed in and the next
-- renewal: midnight on your day of the month, or the month's last day when it's shorter.

local function lastDay(y, m) return os.date("*t", os.time({ year = y, month = m + 1, day = 0, hour = 12 })).day end

function P.nextRenewal(day, now)
  local t = os.date("*t", now or os.time())
  local y, m = t.year, t.month
  if math.min(day, lastDay(y, m)) < t.day then
    y, m = m == 12 and y + 1 or y, m % 12 + 1
  end
  return os.time({ year = y, month = m, day = math.min(day, lastDay(y, m)), hour = 0 })
end

function P.grokPlan(ps, now)
  now = now or os.time()
  ps = ps or {}
  local facts = {}
  if ps.renews_day then
    local at = P.nextRenewal(ps.renews_day, now)
    facts[1] = os.date("%x", at) == os.date("%x", now) and "Renews today"
      or "Renews " .. (os.date("%b %d", at):gsub(" 0", " "))
  end
  return { ok = true, provider = "grok_plan", plan = ps.plan, fetched_at = now, limits = {}, credits = {}, facts = facts }
end

-- Words ------------------------------------------------------------------------------------

-- Claude's part of the answer, worded exactly as it always was.
local function claudeText(d, hide)
  local parts, session = {}, nil
  for _, l in ipairs(type(d) == "table" and type(d.limits) == "table" and d.limits or {}) do
    if type(l) == "table" and type(l.pct) == "number" and not hide[l.label] then
      if l.label == "Current session" then
        parts[#parts + 1] = string.format("Session %d%%", math.floor(l.pct + 0.5))
        session = session or l.pct
      elseif l.label == "Week · all models" then
        parts[#parts + 1] = string.format("week %d%%", math.floor(l.pct + 0.5))
      end
    end
  end
  if #parts == 0 then return "I can't see your usage right now." end
  local pct = session or 0
  return table.concat(parts, ", ") .. "." .. (pct >= 80 and " Running hot!" or pct >= 50 and " Halfway there." or " Plenty left!")
end

-- One provider in a sentence: "Codex: Week 41%." Its last numbers win over an error.
function P.summary(name, res, err, hide)
  local body
  if type(res) == "table" then
    local top = P.tightest(res, hide)
    if res.blocked then body = "blocked right now"
    elseif top then body = top.label .. " " .. P.figure(top)
    else
      local parts = { str(res.plan) }
      for _, f in ipairs(type(res.facts) == "table" and res.facts or {}) do
        if type(f) == "string" then parts[#parts + 1] = #parts > 0 and (f:gsub("^%u", string.lower)) or f end
      end
      if #parts > 0 then body = table.concat(parts, ", ") end
    end
  end
  return name .. ": " .. (body or err or "no numbers yet") .. "."
end

-- The answer to /usage and "how's my usage?": Claude as always, then every other AI that's on.
-- others: { { id, name, res, err } }, in the user's order.
function P.usageText(claude, others, s)
  local sentences = {}
  if s.claudeOn then sentences[1] = claudeText(claude, s.providers.claude.hide) end
  for _, o in ipairs(others or {}) do
    sentences[#sentences + 1] = P.summary(o.name, o.res, o.err, (s.providers[o.id] or {}).hide)
  end
  if #sentences == 0 then return "I can't see your usage right now." end
  return table.concat(sentences, " ")
end

-- The setup wizard's pill after a check: "Working · Week 41%", or what went wrong.
function P.checkText(res, hide)
  if type(res) ~= "table" then return "Couldn't run the check" end
  if not res.ok then return str(res.error) or "Couldn't run the check" end
  local top = P.tightest(res, hide)
  if top then return "Working · " .. top.label .. " " .. P.figure(top) end
  local fact = type(res.facts) == "table" and res.facts[1]
  if type(fact) == "string" then return "Working · " .. fact end
  return "Working"
end

-- What the brain's status line calls the usage text.
function P.statusLabel(s) return s.claudeOnly and "Claude plan usage: " or "AI usage: " end

return P
