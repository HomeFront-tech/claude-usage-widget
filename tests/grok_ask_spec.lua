-- grok.lua G.ask: one send through gbot, then poll the thread for Grok's reply.
-- Runs against tests/fakes/gbot through a per-case wrapper that sets its environment.
return function(t, dir)
  local function case(name, delivery, replyText)
    local tmp = t.tmpdir()
    local c = { log = tmp .. "/sends.log", sent = tmp .. "/sent.txt", thread = tmp .. "/thread.json", statuses = {} }
    if replyText then
      t.writeJson(c.thread, { messages = {
        { kind = "message", role = "assistant", timestampMs = (os.time() + 100) * 1000, text = replyText } } })
    end
    local wrapper = tmp .. "/gbot"
    local f = assert(io.open(wrapper, "w"))
    f:write(string.format("#!/bin/sh\nexport FAKE_GBOT_LOG='%s' FAKE_GBOT_SENT='%s' FAKE_GBOT_THREAD='%s' FAKE_GBOT_DELIVERY='%s'\nexec '%s' \"$@\"\n",
      c.log, c.sent, c.thread, delivery, dir .. "/tests/fakes/gbot"))
    f:close()
    os.execute("chmod +x '" .. wrapper .. "'")
    c.G = dofile(dir .. "/grok.lua").configure({ gbot = wrapper, app = false, poll = 1, wait = 4 }, "Sam")
    c.hooks = { status = function(kind, detail) c.statuses[#c.statuses + 1] = { kind = kind, detail = detail } end }
    c.name = name
    return c
  end
  local function sends(c)
    local fh = io.open(c.log)
    if not fh then return 0 end
    local n = select(2, fh:read("a"):gsub("send", ""))
    fh:close()
    return n
  end
  local function last(c) return c.statuses[#c.statuses] or {} end

  local ok = case("reply", "delivered", "4")
  t.ok(ok.G.ask("what's 2+2?", ok.hooks), "ask accepted")
  t.ok(not ok.G.ask("again?", ok.hooks), "ask_busy_refuses_second")

  local unk = case("unknown", "unknown", nil)
  unk.G.ask("hello?", unk.hooks)

  return function()
    local doneOk = last(ok).kind == "reply"
    local doneUnk = last(unk).kind == "unknown" or last(unk).kind == "reply"
    if not (doneOk and doneUnk) then return false end
    -- ask_delivers_reply
    t.eq(last(ok).detail, "4", "reply text")
    t.eq(ok.statuses[1].kind, "sending", "sending first")
    t.eq(sends(ok), 1, "one send")
    t.ok(not ok.G.busy(), "free again after the reply")
    -- wrapped_message_has_only_owner_words
    local fh = io.open(ok.sent)
    local body = fh and fh:read("a") or ""
    if fh then fh:close() end
    t.eq(body, ok.G.wrap("what's 2+2?", ok.G.marker), "sent exactly the wrapped owner words")
    -- ask_never_resends_on_unknown
    t.eq(last(unk).kind, "unknown", "unknown when nothing comes back")
    t.eq(sends(unk), 1, "never resends")
    return true
  end
end
