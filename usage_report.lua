-- Plain-text report of Buddy's own usage (the menu's "Buddy's usage"), from the JSON
-- that bin/buddy-usage prints: today, the last 7 days and this month, each with calls,
-- cost, which models did the work and what it was for. Pure formatting; no side effects.

local R = {}

local PERIODS = { { "today", "Today" }, { "week", "Last 7 days" }, { "month", "This month" } }

-- claude-haiku-5-5 -> Haiku 5.5; ollama:gemma3:4b -> gemma3:4b (this Mac); unknown -> Claude (older)
function R.label(model)
  if model == "unknown" then return "Claude (older)" end
  local local_model = model:match("^ollama:(.+)$")
  if local_model then return local_model .. " (this Mac)" end
  local name, major, minor = model:match("^claude%-(%a+)%-(%d+)%-(%d%d?)$")
  if name then return name:sub(1, 1):upper() .. name:sub(2) .. " " .. major .. "." .. minor end
  name, major = model:match("^claude%-(%a+)%-(%d+)$")
  if name then return name:sub(1, 1):upper() .. name:sub(2) .. " " .. major end
  return model
end

-- "Haiku 5.5 81%, Opus 5.5 19%": biggest first, by tokens.
local function shares(group, labelOf)
  local total, list = 0, {}
  for name, v in pairs(group or {}) do
    total = total + (v.tokens or 0)
    list[#list + 1] = { name = name, tokens = v.tokens or 0 }
  end
  if total <= 0 then return nil end
  table.sort(list, function(a, b)
    if a.tokens ~= b.tokens then return a.tokens > b.tokens end
    return a.name < b.name
  end)
  local parts = {}
  for _, e in ipairs(list) do
    if e.tokens > 0 then
      parts[#parts + 1] = string.format("%s %d%%", labelOf(e.name), math.floor(e.tokens / total * 100 + 0.5))
    end
  end
  return table.concat(parts, ", ")
end

function R.format(report)
  if type(report) ~= "table" or type(report.periods) ~= "table" then return "I can't read my usage right now." end
  local lines = {}
  for _, p in ipairs(PERIODS) do
    local d = report.periods[p[1]]
    if type(d) == "table" and (d.calls or 0) > 0 then
      local line = string.format("%s: %d call%s, ≈$%.2f", p[2], d.calls, d.calls == 1 and "" or "s", d.cost or 0)
      if (d.local_calls or 0) > 0 then line = line .. string.format(" (%d on this Mac)", d.local_calls) end
      lines[#lines + 1] = line
      local models = shares(d.models, R.label)
      if models then lines[#lines + 1] = "  Models: " .. models end
      local kinds = shares(d.kinds, function(k) return k end)
      if kinds then lines[#lines + 1] = "  Used for: " .. kinds end
    end
  end
  if #lines == 0 then return "I haven't used any Claude yet." end
  return table.concat(lines, "\n")
end

return R
