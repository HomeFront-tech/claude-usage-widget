-- "Tell me when one turns red" (config.lua usage.alert_red): which limits to announce. A
-- limit is announced when its bar turns red, at the red level or when the provider itself
-- says critical, and then stays quiet until it falls back below yellow: usage only climbs
-- within a window, so a drop like that is a reset or a raised cap. That works for limits
-- with no reset time too. The state ({ ["codex|Week"] = true }) is kept by the caller.

local A = {}
local P = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/providers.lua")

-- items: the limits and credits that show (P.visible, so hidden ones never alert).
-- Returns the items to announce now and the state, updated in place.
function A.check(state, id, items, s)
  local fires = {}
  if not s.alert_red then return fires, state end
  for _, it in ipairs(items or {}) do
    local key, level = id .. "|" .. it.label, P.level(it.pct, it.severity, s)
    if level == "hot" and not state[key] then
      state[key] = true
      fires[#fires + 1] = it
    elseif level == "ok" then
      state[key] = nil
    end
  end
  return fires, state
end

-- "Heads up: Codex Week is at 91%. Resets Mon 9:00 AM."
function A.line(name, it, resetPhrase)
  local line = string.format("Heads up: %s %s is at %d%%.", name, it.label, math.floor(it.pct + 0.5))
  if resetPhrase and resetPhrase ~= "" then line = line .. " " .. resetPhrase .. "." end
  return line
end

return A
