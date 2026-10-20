-- Usage chart window (Hammerspoon module, opened by clicking the usage card)
--
-- A stock-market style chart of your Claude usage over time: candlesticks per period,
-- a burn (volume) pane, a moving average, reset markers, a crosshair readout and an
-- "at this pace" projection, with tabs for each limit and 1D / 5D / 1M / ALL ranges.
-- The data is the card's history file (one sample per usage check, kept on this Mac).
-- The page itself is chart.html. ClaudeUsage.chart(true) opens it with demo data.

local K = {}

-- opts: dir, history (path of history.jsonl), current (latest usage JSON), demo
function K.open(opts)
  local demo = opts.demo == true
  if K.wv and K.demo == demo then
    K.wv:show():bringToFront(true)
    hs.focus()
    return
  end
  if K.wv then K.wv:delete() end -- switching between real and demo data
  K.demo = demo
  local lines = {}
  local f = io.open(opts.history)
  if f then
    for line in f:lines() do
      if line:match("^%s*{.*}%s*$") then lines[#lines + 1] = line end -- skip a half-written last line
    end
    f:close()
  end
  local init = '{"demo":' .. tostring(opts.demo == true)
    .. ',"current":' .. hs.json.encode(opts.current or {})
    .. ',"points":[' .. table.concat(lines, ",") .. "]}"

  local fh = assert(io.open(opts.dir .. "/chart.html"))
  local html = fh:read("a")
  fh:close()
  html = html:gsub("/%*__INIT__%*/null", function() return (init:gsub("</", "<\\/")) end)

  local uc = hs.webview.usercontent.new("chart")
  uc:setCallback(function(msg)
    if (msg.body or {}).type == "close" then
      K.closeTimer = hs.timer.doAfter(0, function()
        if K.wv then K.wv:delete() end
        K.wv = nil
      end)
    end
  end)

  local scr = hs.screen.mainScreen():frame()
  local w, h = math.min(980, scr.w - 80), math.min(640, scr.h - 80)
  K.wv = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 3, w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle(opts.demo and "Claude Usage (demo data)" or "Claude Usage")
    :deleteOnClose(true)
    :windowCallback(function(action) if action == "closing" then K.wv = nil end end)
    :html(html)
    :show()
  K.wv:bringToFront(true)
  hs.focus()
end

-- A new sample arrived: add it to the open chart.
function K.push(point, current)
  if K.wv then
    K.wv:evaluateJavaScript("window.onPoint && window.onPoint(" .. hs.json.encode(point)
      .. "," .. hs.json.encode(current or {}) .. ")")
  end
end

return K
