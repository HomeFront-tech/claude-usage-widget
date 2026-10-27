-- How a live voice chat ends, through voice.lua's real lifecycle and chat.lua's panel:
-- locking the screen ends it once ("away"), holding space to dictate doesn't, the helper
-- dying ends it once ("trouble") and counts one exit, the menu switch ends it ("off") and
-- closing the panel ends it ("closed"). A stand-in helper says "okay Buddy" every time it
-- is told to listen; no mic, no speakers.
return function(t, dir)
  local V = dofile(dir .. "/voice.lua")
  V.configure({})
  local key, pidKey = "claudeBuddy.voice.spec-" .. hs.host.uuid(), "claudeBuddy.voicePid.livespec"
  V.settingsKey = key -- never the running buddy's switches
  hs.settings.set(key, { listen = true, answers = false, outLoud = 0, live = true })
  local root = t.tmpdir()
  local bin = root .. "/live-fake-ear"
  local f = assert(io.open(bin, "w"))
  f:write([=[#!/bin/sh
trap 'exit 0' HUP INT TERM
n=0
printf '%s\n' '{"ev":"ready"}'
while IFS= read -r line; do
  case "$line" in *quit*) exit 0;; esac
  if printf '%s' "$line" | grep -q '"listen"' && printf '%s' "$line" | grep -Eq '"on"[[:space:]]*:[[:space:]]*true'; then
    n=$((n + 1))
    printf '{"ev":"start","utt":%s}\n{"ev":"end","utt":%s,"text":"okay Buddy"}\n' "$n" "$n"
  fi
done
]=])
  f:close()
  os.execute("/bin/chmod 755 '" .. bin .. "'")

  local starts, ends, closes = 0, {}, 0
  local function endsSaid(why)
    local n = 0
    for _, w in ipairs(ends) do if w == why then n = n + 1 end end
    return n
  end
  local ok = pcall(V.start, { dir = dir, bin = bin, pidKey = pidKey, muted = function() return false end,
    speech = { speakable = function() return nil end },
    onWake = function() end, onLiveStart = function() starts = starts + 1 end,
    onLiveEnd = function(why) ends[#ends + 1] = why end })
  local function finish()
    V.stop()
    hs.settings.set(key, nil)
    hs.settings.set(pidKey, nil)
  end
  if not ok then finish(); t.ok(false, "live helper started"); return end

  local stage, since = "first", hs.timer.secondsSinceEpoch()
  local function go(s) stage, since = s, hs.timer.secondsSinceEpoch() end
  return function()
    local waited = hs.timer.secondsSinceEpoch() - since
    if stage == "first" and starts == 1 then
      t.ok(V.live, "okay Buddy opens a live chat")
      V.pause("lock")
      t.eq(table.concat(ends, ","), "away", "locking the screen ends it, once")
      t.ok(not V.live, "and it's over")
      V.resume("lock")
      go("lock")
    elseif stage == "lock" and starts == 2 then
      V.pause("dictate")
      t.eq(#ends, 1, "holding space to dictate doesn't end it")
      V.resume("dictate")
      go("dictate")
    elseif stage == "dictate" and waited > 0.5 then
      t.eq(#ends, 1, "nor does letting go (okay Buddy again is just noise)")
      t.ok(V.live, "still live after dictating")
      t.eq(#(V.exits or {}), 0, "no helper exits yet")
      os.execute("/bin/kill -TERM " .. V.task:pid())
      go("exit")
    elseif stage == "exit" and endsSaid("trouble") > 0 then
      t.eq(endsSaid("trouble"), 1, "the helper dying ends it, once")
      t.eq(#(V.exits or {}), 1, "and counts one exit")
      go("restart")
    elseif stage == "restart" and starts == 3 then
      t.eq(endsSaid("trouble"), 1, "the restarted helper is live again without another ending")
      V.set("live", false)
      t.eq(ends[#ends], "off", "the menu switch ends it")
      t.eq(endsSaid("off"), 1, "once")
      V.set("live", true)
      V.pause("x"); V.resume("x") -- the helper hears okay Buddy again
      go("panel")
    elseif stage == "panel" and starts == 4 then
      local realNew, realUC = hs.webview.new, hs.webview.usercontent.new
      local done, err = pcall(function()
        hs.webview.new = function()
          return setmetatable({}, { __index = function() return function(self) return self end end })
        end
        hs.webview.usercontent.new = function() return { setCallback = function(self) return self end } end
        local C = dofile(dir .. "/chat.lua")
        C.setArchivePath(root .. "/chat-archive.jsonl")
        C.open({ dir = dir, noFocus = true, anchor = function() return { x = 300, y = 600, w = 200, h = 170 } end,
          ask = function() end,
          onClose = function() closes = closes + 1; V.endLive("closed") end, -- as buddy.lua wires it
          onDictate = function(on) if on then V.pause("dictate") else V.resume("dictate") end end })
        C.close()
      end)
      hs.webview.new, hs.webview.usercontent.new = realNew, realUC
      t.ok(done, "panel opened and closed" .. (done and "" or (": " .. tostring(err))))
      t.eq(closes, 1, "closing the panel calls onClose once")
      t.eq(ends[#ends], "closed", "and ends the live chat")
      t.eq(table.concat(ends, ","), "away,trouble,off,closed", "each ending said exactly once")
      finish()
      return true
    elseif waited > 6 then
      t.ok(false, "live end spec stuck at " .. stage .. " (starts " .. starts .. ", ends "
        .. table.concat(ends, ",") .. ")")
      finish()
      return true
    end
    return false
  end
end
