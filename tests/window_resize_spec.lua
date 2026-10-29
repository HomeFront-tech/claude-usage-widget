-- Resizing the chat panel (any edge or corner, with a minimum size and the screen as the
-- limit) and the usage card (its bottom-right corner scales the whole card). The geometry
-- is pure; the panel's open() is driven with a stand-in web view so nothing shows.
return function(t, dir)
  local C = dofile(dir .. "/chat.lua")
  local f0 = { x = 100, y = 100, w = 320, h = 400 }
  local screen = { x = 0, y = 25, w = 1440, h = 875 }
  local min = C.MIN

  local f = C.resizeFrame(f0, "e", 80, 0, screen)
  t.eq(f.w, 400, "east edge widens")
  t.ok(f.x == 100 and f.y == 100 and f.h == 400, "east edge leaves the rest alone")
  f = C.resizeFrame(f0, "w", -50, 0, screen)
  t.ok(f.x == 50 and f.w == 370, "west edge moves the left side out")
  f = C.resizeFrame(f0, "n", 60, 60, screen)
  t.ok(f.y == 160 and f.h == 340 and f.x == 100 and f.w == 320, "north edge only moves the top")
  f = C.resizeFrame(f0, "se", 30, 70, screen)
  t.ok(f.w == 350 and f.h == 470 and f.x == 100 and f.y == 100, "a corner changes both")
  f = C.resizeFrame(f0, "nw", 20, 30, screen)
  t.ok(f.x == 120 and f.y == 130 and f.w == 300 and f.h == 370, "the opposite corner stays put")
  f = C.resizeFrame(f0, "e", -500, 0, screen)
  t.eq(f.w, min.w, "never narrower than the minimum")
  f = C.resizeFrame(f0, "s", 0, -900, screen)
  t.eq(f.h, min.h, "never shorter than the minimum")
  f = C.resizeFrame(f0, "w", 500, 0, screen)
  t.ok(f.w == min.w and f.x + f.w == 420, "shrinking from the left keeps the right edge")
  f = C.resizeFrame(f0, "se", 5000, 5000, screen)
  t.ok(f.x + f.w <= screen.x + screen.w and f.y + f.h <= screen.y + screen.h, "the screen caps a corner drag")
  f = C.resizeFrame(f0, "nw", -5000, -5000, screen)
  t.ok(f.x >= screen.x and f.y >= screen.y, "and a drag off the top-left")
  f = C.resizeFrame(f0, "se", 5000, 5000, nil)
  t.ok(f.w == 5320 and f.h == 5400, "no screen, no cap")

  -- the panel opens at the size it was last dragged to, never below the minimum
  local sizeKey, posKey = "claudeBuddy.chatSize", "claudeBuddy.chatOffset"
  local savedSize, savedPos = hs.settings.get(sizeKey), hs.settings.get(posKey)
  local realNew, realUC = hs.webview.new, hs.webview.usercontent.new
  local opened, callback, frames
  local ok, err = pcall(function()
    hs.webview.new = function(frame)
      opened = frame
      return setmetatable({}, { __index = function(_, k)
        if k == "frame" then return function(self, fr) if fr then frames[#frames + 1] = fr end; return opened end end
        return function(self) return self end
      end })
    end
    hs.webview.usercontent.new = function()
      return { setCallback = function(self, fn) callback = fn; return self end }
    end
    local anchor = function() return { x = 700, y = 600, w = 200, h = 170 } end
    hs.settings.clear(posKey)
    hs.settings.set(sizeKey, { w = 500, h = 620 })
    local P = dofile(dir .. "/chat.lua")
    P.setArchivePath(t.tmpdir() .. "/chat-archive.jsonl")
    P.open({ dir = dir, noFocus = true, anchor = anchor, ask = function() end })
    t.ok(opened and opened.w == 500 and opened.h == 620, "opens at the remembered size")
    P.close()
    hs.settings.set(sizeKey, { w = 10, h = 10 })
    local Q = dofile(dir .. "/chat.lua")
    Q.setArchivePath(t.tmpdir() .. "/chat-archive.jsonl")
    Q.open({ dir = dir, noFocus = true, anchor = anchor, ask = function() end })
    t.ok(opened and opened.w == min.w and opened.h == min.h, "a tiny remembered size is raised to the minimum")
    t.ok(type(callback) == "function", "the page's messages reach the panel")
    Q.close()
  end)
  hs.webview.new, hs.webview.usercontent.new = realNew, realUC
  if savedSize ~= nil then hs.settings.set(sizeKey, savedSize) else hs.settings.clear(sizeKey) end
  if savedPos ~= nil then hs.settings.set(posKey, savedPos) else hs.settings.clear(posKey) end
  t.ok(ok, "chat resize spec ran: " .. tostring(err))

  -- the card: its corner dragged to (cx, cy) from its top-left picks a scale along the diagonal
  local W = dofile(dir .. "/usage_widget.lua")
  t.eq(W.scaleFor(264, 400, 264, 400), 1, "the corner where it is: as drawn")
  t.eq(W.scaleFor(396, 600, 264, 400), 1.5, "half again as far: 1.5x")
  t.eq(W.scaleFor(264 * 0.8, 400 * 0.8, 264, 400), 0.8, "pulled in: smaller")
  t.eq(W.scaleFor(10, 10, 264, 400), W.SCALE.min, "never below the minimum")
  t.eq(W.scaleFor(9000, 9000, 264, 400), W.SCALE.max, "never above the maximum")
  t.eq(W.scaleFor(528, 400, 264, 400), 1.5, "a sideways-only pull still counts")
end
