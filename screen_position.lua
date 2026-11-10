-- Keep the whole canvas on a connected display without changing its preferred spot.
local P = {}

function P.clamp(p, w, h, screen)
  if not screen then
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:frame()
      if p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h then screen = s; break end
    end
  end
  screen = screen or hs.screen.primaryScreen()
  local f = screen:frame()
  return { x = math.max(f.x, math.min(p.x, f.x + f.w - w)),
    y = math.max(f.y, math.min(p.y, f.y + f.h - h)) }
end

return P
