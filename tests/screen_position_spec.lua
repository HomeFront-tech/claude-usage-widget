-- Recovery uses the actual canvas bounds and leaves saved preferences to the caller.
return function(t, dir)
  local P = dofile(dir .. "/screen_position.lua")
  local small = { frame = function() return { x = 0, y = 25, w = 800, h = 575 } end }
  local other = { frame = function() return { x = -1200, y = 25, w = 1200, h = 875 } end }
  local realAll, realPrimary = hs.screen.allScreens, hs.screen.primaryScreen
  local ok, err = pcall(function()
    hs.screen.allScreens = function() return { small, other } end
    hs.screen.primaryScreen = function() return small end
    local preferred = { x = 760, y = 550 }
    local p = P.clamp(preferred, 528, 400)
    t.ok(p.x == 272 and p.y == 200, "scaled card fits after a resolution change")
    t.eq(preferred.x, 760, "clamping preserves the preferred point")
    p = P.clamp({ x = 1800, y = 900 }, 200, 170)
    t.ok(p.x == 600 and p.y == 430, "a disconnected screen falls back inside the primary")
    p = P.clamp({ x = -50, y = 100 }, 200, 170)
    t.eq(p.x, -200, "negative screen coordinates are supported")
    p = P.clamp({ x = -50, y = 100 }, 200, 170, small)
    t.eq(p.x, 0, "an explicit destination screen wins")
    p = P.clamp({ x = 40, y = 40 }, 1000, 900, small)
    t.ok(p.x == 0 and p.y == 25, "an oversized canvas keeps its top-left accessible")
  end)
  hs.screen.allScreens, hs.screen.primaryScreen = realAll, realPrimary
  t.ok(ok, "screen recovery spec ran: " .. tostring(err))
end
