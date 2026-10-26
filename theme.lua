-- Shared window colours and dimensions. Keep these in step with theme.css.
-- The canvas uses native colour tables; web views inline the CSS before adding data.

local M = { colors = {}, radius = { control = 8, card = 12, panel = 16 }, space = { 4, 8, 12, 16, 24 } }
for name, hex in pairs({
  bg = "1f1e1d", panel = "262624", raised = "30302e", ink = "faf9f5",
  secondary = "b0aea5", muted = "9c9a92", line = "3a3935", edge = "53514a",
  accent = "d97757", hover = "e58b6d", pressed = "c6613f", accentInk = "1a1310",
  warn = "e5b567", danger = "ed877c", success = "99bd9a",
  blue = "91b6cf", purple = "b2a2cf", pink = "d99caf",
}) do
  M.colors[name] = { red = tonumber(hex:sub(1, 2), 16) / 255,
    green = tonumber(hex:sub(3, 4), 16) / 255, blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = 1 }
end

function M.inline(html, dir)
  local f = assert(io.open(dir .. "/theme.css"))
  local css = f:read("a"); f:close()
  local page = html:gsub("/%*__THEME__%*/", function() return css end)
  return page
end

return M
