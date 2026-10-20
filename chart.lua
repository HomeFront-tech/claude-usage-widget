-- Usage chart window (Hammerspoon module, opened by clicking the usage card)
--
-- Two views of your Claude use over time, in 1D / 5D / 1M / ALL ranges:
--   Tokens: Claude Code's token use from its own logs (bin/claude-tokens), as stacked
--     bars by token type or by model, with replies, sessions and API-price value.
--   Plan limits: the card's history file (one sample per usage check) as candlesticks
--     with a burn pane, moving average, reset markers and an "at this pace" projection.
-- Everything stays on this Mac. The page itself is chart.html.
-- ClaudeUsage.chart(true) opens it with demo data.

local K = {}

local function readAll(path)
  local f = path and io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- A JSON object file (tokens.json from bin/claude-tokens, billing.json), or "{}" if it
-- isn't there, is mid-write or doesn't parse.
local function tokensJSON(path)
  local s = readAll(path)
  if not (s and s:match("^%s*{.*}%s*$")) then return "{}" end
  return pcall(hs.json.decode, s) and s or "{}"
end

-- opts: dir, history (path of history.jsonl), tokens (path of tokens.json), billing (path of
-- your own billing.json, optional), current (latest usage JSON), demo, importHistory (the
-- older history is being brought in; without it the History tab says how to turn it on)
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
    .. ',"importHistory":' .. tostring(opts.importHistory == true)
    .. ',"current":' .. hs.json.encode(opts.current or {})
    .. ',"tokens":' .. tokensJSON(opts.tokens)
    .. ',"billing":' .. tokensJSON(opts.billing)
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
  local w, h = math.min(1000, scr.w - 80), math.min(740, scr.h - 80)
  K.wv = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 3, w = w, h = h },
      { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle(opts.demo and "Claude Usage (demo data)" or "Claude Usage")
    :deleteOnClose(true)
    -- the window being replaced (demo <-> real) reports closing after its successor exists
    :windowCallback(function(action, wv) if action == "closing" and K.wv == wv then K.wv = nil end end)
    :html(html)
    :show()
  K.wv:bringToFront(true)
  hs.focus()
end

-- The token tallies were updated: hand the open chart the new file.
function K.pushTokens(path)
  if K.wv and not K.demo then
    K.wv:evaluateJavaScript("window.onTokens && window.onTokens(" .. tokensJSON(path) .. ")")
  end
end

-- A new sample arrived: add it to the open chart.
function K.push(point, current)
  if K.wv then
    K.wv:evaluateJavaScript("window.onPoint && window.onPoint(" .. hs.json.encode(point)
      .. "," .. hs.json.encode(current or {}) .. ")")
  end
end

return K
