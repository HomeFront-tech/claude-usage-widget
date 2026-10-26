-- "okay Buddy" in the chat panel: it opens without taking the keyboard, and a message said
-- out loud reaches the brain marked as spoken. The web view is a stand-in; nothing shows.
return function(t, dir)
  local key, seqKey = "claudeBuddy.chat", "claudeBuddy.chatSeq"
  local saved, savedSeq = hs.settings.get(key), hs.settings.get(seqKey)
  hs.settings.set(key, {})
  local realNew, realUC, realFocus = hs.webview.new, hs.webview.usercontent.new, hs.focus
  local calls, js, focus, callback = {}, {}, 0, nil
  local ok, err = pcall(function()
    hs.webview.new = function()
      return setmetatable({}, { __index = function(_, k)
        if k == "evaluateJavaScript" then return function(self, code) js[#js + 1] = code; return self end end
        return function(self) calls[k] = (calls[k] or 0) + 1; return self end
      end })
    end
    hs.webview.usercontent.new = function()
      return { setCallback = function(self, fn) callback = fn; return self end }
    end
    hs.focus = function() focus = focus + 1 end
    local C = dofile(dir .. "/chat.lua")
    C.setArchivePath(t.tmpdir() .. "/chat-archive.jsonl")
    t.eq(C.sendVoice("hi"), false, "nothing to send to without the panel")
    local asked
    C.open({ dir = dir, noFocus = true, anchor = function() return { x = 300, y = 600, w = 200, h = 170 } end,
      ask = function(history, done, meta) asked = { last = history[#history].content, meta = meta } end })
    t.eq(focus, 0, "noFocus leaves the keyboard alone")
    t.eq(calls.bringToFront, nil, "noFocus doesn't bring the panel in front")
    t.eq(C.sendVoice("what's the weather"), true, "sendVoice with the panel open")
    t.ok(js[#js]:match("^window%.voice%(") and js[#js]:match('"state":"send"'), "the page is told to send the box")
    callback({ body = { type = "send", text = "typed what's the weather", voice = true } })
    t.eq(asked and asked.last, "typed what's the weather", "the whole box is asked")
    t.eq(asked and asked.meta and asked.meta.voice, true, "marked as said out loud")
    callback({ body = { type = "send", text = "typed only" } })
    t.eq(asked and asked.meta, nil, "a typed message isn't")
    C.voice("listening", "partial words")
    t.ok(js[#js]:match('"state":"listening"') and js[#js]:match("partial words"), "live words go to the page")
    C.open({ dir = dir, noFocus = true, anchor = function() return { x = 0, y = 0, w = 1, h = 1 } end })
    t.eq(focus, 0, "a second wake with the panel open still leaves the keyboard alone")
    C.close()
  end)
  hs.webview.new, hs.webview.usercontent.new, hs.focus = realNew, realUC, realFocus
  hs.settings.set(key, saved)
  hs.settings.set(seqKey, savedSeq)
  t.ok(ok, "chat voice spec ran" .. (ok and "" or (": " .. tostring(err))))
end
