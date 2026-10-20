-- Short, single-line notices for standing job speech bubbles.
local function shortName(name, max)
  name = tostring(name or "job"):gsub("[%c%s]+", " "):gsub("^ ", ""):gsub(" $", "")
  if name == "" then name = "job" end
  local len = utf8.len(name)
  if not len then
    name = name:gsub("[\128-\255]", "?")
    len = #name
  end
  if len <= max then return name end
  return name:sub(1, utf8.offset(name, max) - 1) .. "…"
end

return function(name, ok)
  local prefix = ok and "Your " or ""
  local suffix = ok and " is up." or " didn't come through."
  local maxName = 140 - #prefix - #suffix
  return prefix .. shortName(name, maxName) .. suffix
end
