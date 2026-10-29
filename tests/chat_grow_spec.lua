-- The chat box wraps and grows while you talk or type: the page says how much taller it got
-- ("size"), the window grows upward by that much so the box stays put, stops at the room the
-- screen allows, comes back down after a send, and a drag while it is tall still remembers the
-- one-line spot. The web view and the screen are stand-ins; nothing shows.
return function(t, dir)
  local key, seqKey, posKey = "claudeBuddy.chat", "claudeBuddy.chatSeq", "claudeBuddy.chatOffset"
  local saved, savedSeq, savedPos = hs.settings.get(key), hs.settings.get(seqKey), hs.settings.get(posKey)
  hs.settings.set(key, {})
  hs.settings.set(posKey, nil)
  local real = { new = hs.webview.new, uc = hs.webview.usercontent.new, focus = hs.focus,
    screens = hs.screen.allScreens, main = hs.screen.mainScreen, every = hs.timer.doEvery,
    mouse = hs.mouse.absolutePosition, buttons = hs.eventtap.checkMouseButtons }
  -- hs.screen.find (the no-saved-spot path) asks every screen for its fullFrame
  local function fakeScreen(w, h)
    local f = { x = 0, y = 0, w = w, h = h }
    return { frame = function() return f end, fullFrame = function() return f end, name = function() return "fake" end }
  end
  local screen = fakeScreen(1440, 900)
  local frames, callback, html, topLeft, dragTick = {}, nil, nil, nil, nil
  local mouse, down = { x = 100, y = 100 }, false
  local ok, err = pcall(function()
    hs.screen.allScreens = function() return { screen } end
    hs.screen.mainScreen = function() return screen end
    hs.focus = function() end
    hs.timer.doEvery = function(_, fn) dragTick = fn; return { stop = function() dragTick = nil end } end
    hs.mouse.absolutePosition = function() return mouse end
    hs.eventtap.checkMouseButtons = function() return { left = down } end
    hs.webview.new = function(frame)
      topLeft = { x = frame.x, y = frame.y }
      frames[#frames + 1] = frame
      return setmetatable({}, { __index = function(_, k)
        if k == "html" then return function(self, h) html = h; return self end end
        if k == "frame" then return function(self, f) frames[#frames + 1] = f; topLeft = { x = f.x, y = f.y }; return self end end
        if k == "topLeft" then return function(self, p) if p then topLeft = { x = p.x, y = p.y }; return self end return topLeft end end
        return function(self) return self end
      end })
    end
    hs.webview.usercontent.new = function()
      return { setCallback = function(self, fn) callback = fn; return self end }
    end
    local function last() return frames[#frames] end
    local function eqFrame(f, x, y, w, h, what) -- %d: placement maths leaves whole floats (540.0)
      t.eq(string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h), string.format("%d,%d %dx%d", x, y, w, h), what)
    end
    local function xy(p) return string.format("%d,%d", p.x, p.y) end

    local C = dofile(dir .. "/chat.lua")
    C.setArchivePath(t.tmpdir() .. "/chat-archive.jsonl")
    -- above the buddy: 320x400 centred on it, 40 px overlap; half of a 900 px screen is less
    -- than eight more lines, so the floor of 160 px wins
    C.open({ dir = dir, noFocus = true, anchor = function() return { x = 600, y = 700, w = 200, h = 170 } end, ask = function() end })
    eqFrame(last(), 540, 340, 320, 400, "opens one line tall above the buddy")
    t.ok(html and html:match('"grow"%s*:%s*160'), "the page is told how much room it has")
    callback({ body = { type = "size", grow = 60 } })
    eqFrame(last(), 540, 280, 320, 460, "a taller box grows the window upward")
    local n = #frames
    callback({ body = { type = "size", grow = 60 } })
    t.eq(#frames, n, "the same height again changes nothing")
    callback({ body = { type = "size", grow = 500 } })
    eqFrame(last(), 540, 180, 320, 560, "it stops at the room it was given")
    -- dragged while tall: the one-line spot moves by the same amount
    callback({ body = { type = "drag" } })
    mouse, down = { x = 110, y = 130 }, true
    dragTick()
    t.eq(xy(topLeft), "550,210", "the window follows the mouse")
    down = false
    dragTick()
    local pos = hs.settings.get(posKey)
    t.eq(pos and xy(pos), "-50,-330", "the saved spot is the one-line window's, not the tall one's")
    callback({ body = { type = "size", grow = 0 } })
    eqFrame(last(), 550, 370, 320, 400, "after a send it comes back to one line where you left it")
    callback({ body = { type = "size", grow = -20 } })
    eqFrame(last(), 550, 370, 320, 400, "never shorter than one line")
    C.close()

    -- no room above: beside the buddy near the top of the screen, growing stops at the edge
    hs.settings.set(posKey, nil)
    local T = dofile(dir .. "/chat.lua")
    T.setArchivePath(t.tmpdir() .. "/chat-archive-top.jsonl")
    T.open({ dir = dir, noFocus = true, anchor = function() return { x = 600, y = 50, w = 200, h = 170 } end, ask = function() end })
    eqFrame(last(), 790, 4, 320, 400, "beside the buddy, pinned to the top edge")
    callback({ body = { type = "size", grow = 100 } })
    eqFrame(last(), 790, 4, 320, 500, "at the top edge it grows downward instead")
    T.close()

    -- a tall screen: half of it
    screen = fakeScreen(2560, 1415)
    local B = dofile(dir .. "/chat.lua")
    B.setArchivePath(t.tmpdir() .. "/chat-archive-big.jsonl")
    B.open({ dir = dir, noFocus = true, anchor = function() return { x = 600, y = 1200, w = 200, h = 170 } end, ask = function() end })
    t.ok(html and html:match('"grow"%s*:%s*307'), "on a tall screen the panel may reach half of it")
    B.close()
  end)
  hs.webview.new, hs.webview.usercontent.new, hs.focus = real.new, real.uc, real.focus
  hs.screen.allScreens, hs.screen.mainScreen, hs.timer.doEvery = real.screens, real.main, real.every
  hs.mouse.absolutePosition, hs.eventtap.checkMouseButtons = real.mouse, real.buttons
  hs.settings.set(key, saved)
  hs.settings.set(seqKey, savedSeq)
  hs.settings.set(posKey, savedPos)
  t.ok(ok, "chat grow spec ran" .. (ok and "" or (": " .. tostring(err))))
end
