-- "okay Buddy" in the chat panel: it opens without taking the keyboard, and a message said
-- out loud reaches the brain marked as spoken. The web view is a stand-in; nothing shows.
return function(t, dir)
  local key, seqKey = "claudeBuddy.chat", "claudeBuddy.chatSeq"
  local saved, savedSeq = hs.settings.get(key), hs.settings.get(seqKey)
  hs.settings.set(key, {})
  local realNew, realUC, realFocus = hs.webview.new, hs.webview.usercontent.new, hs.focus
  local calls, js, focus, callback, html = {}, {}, 0, nil, nil
  local ok, err = pcall(function()
    hs.webview.new = function()
      return setmetatable({}, { __index = function(_, k)
        if k == "evaluateJavaScript" then return function(self, code) js[#js + 1] = code; return self end end
        if k == "html" then return function(self, h) html = h; return self end end
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

    -- "okay Buddy" opens the panel and says "live" before the page has loaded: the page
    -- gets it in its INIT instead
    local L = dofile(dir .. "/chat.lua")
    L.setArchivePath(t.tmpdir() .. "/chat-archive-live.jsonl")
    L.voice("live")
    html = nil
    local dictating = {}
    local failMic
    L.setDictate({ start = function(fail) failMic = fail; return true end,
      stop = function(done) done(nil) end, cancel = function() end })
    L.open({ dir = dir, noFocus = true, anchor = function() return { x = 300, y = 600, w = 200, h = 170 } end,
      ask = function() end, onDictate = function(on) dictating[#dictating + 1] = on end })
    t.ok(html and html:match('"live"%s*:%s*"live"'), "a live chat opened by voice is in the page's INIT")
    L.voice("hold")
    t.eq(L.live, "hold", "held while another app has the mic")
    L.voice("liveoff")
    t.eq(L.live, nil, "liveoff forgets it")
    L.voice("live")

    -- the recording dies on its own (no microphone permission): voice listens again
    callback({ body = { type = "listen" } })
    t.eq(dictating[#dictating], true, "holding space pauses voice")
    js = {}
    failMic("I can't hear you.")
    t.eq(dictating[#dictating], false, "a dictation that fails on its own resumes voice")
    t.ok(js[#js] and js[#js]:match("^window%.heard%(") and js[#js]:match("can't hear"), "and the page is told why")
    L.close()
    t.eq(L.live, nil, "closing the panel forgets the live chat")
  end)
  hs.webview.new, hs.webview.usercontent.new, hs.focus = realNew, realUC, realFocus
  hs.settings.set(key, saved)
  hs.settings.set(seqKey, savedSeq)
  t.ok(ok, "chat voice spec ran" .. (ok and "" or (": " .. tostring(err))))
end
