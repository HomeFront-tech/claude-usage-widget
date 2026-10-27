-- grok.lua G.ask: one send through gbot, then poll the thread for Grok's reply.
-- Runs against tests/fakes/gbot through a per-case wrapper that sets its environment.
return function(t, dir)
  -- opts: delivery, reply (text of a new bot message), old (an untagged bot message from
  -- just before the send), sendMode ("hang" | "silent124"), gbot (path override)
  local function case(opts)
    local tmp = t.tmpdir()
    local c = { log = tmp .. "/sends.log", sent = tmp .. "/sent.txt", thread = tmp .. "/thread.json", statuses = {} }
    local before = {}
    if opts.old then before[1] = { kind = "message", role = "assistant", timestampMs = (os.time() - 2) * 1000, text = opts.old } end
    t.writeJson(c.thread, { messages = before })
    local after = { table.unpack(before) }
    if opts.reply then after[#after + 1] = { kind = "message", role = "assistant", timestampMs = (os.time() + 100) * 1000, text = opts.reply } end
    t.writeJson(tmp .. "/after.json", { messages = after }) -- the thread once the bot has answered
    local wrapper = tmp .. "/gbot"
    local f = assert(io.open(wrapper, "w"))
    f:write(string.format("#!/bin/sh\nexport FAKE_GBOT_LOG='%s' FAKE_GBOT_SENT='%s' FAKE_GBOT_THREAD='%s' FAKE_GBOT_AFTER='%s' FAKE_GBOT_DELIVERY='%s' FAKE_GBOT_SEND_MODE='%s'\nexec '%s' \"$@\"\n",
      c.log, c.sent, c.thread, tmp .. "/after.json", opts.delivery or "delivered", opts.sendMode or "", dir .. "/tests/fakes/gbot"))
    f:close()
    os.execute("chmod +x '" .. wrapper .. "'")
    c.G = dofile(dir .. "/grok.lua").configure({ gbot = opts.gbot or wrapper, app = false, poll = 1, wait = 6 }, "Sam")
    c.hooks = { status = function(kind, detail) c.statuses[#c.statuses + 1] = { kind = kind, detail = detail } end }
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
  local function final(c) local k = last(c).kind; return k == "reply" or k == "unknown" or k == "error" end

  local ok = case({ reply = "4" })
  t.ok(ok.G.ask("what's 2+2?", ok.hooks), "ask accepted")
  t.ok(not ok.G.ask("again?", ok.hooks), "ask_busy_refuses_second")
  local unk = case({ delivery = "unknown" })
  unk.G.ask("hello?", unk.hooks)
  local missing = case({ gbot = "/nonexistent/gbot" })
  missing.G.ask("hi", missing.hooks)
  local hang = case({ sendMode = "hang", reply = "late" })
  hang.G.ask("hi", hang.hooks)
  local silent = case({ sendMode = "silent124", reply = "got it anyway" })
  silent.G.ask("hi", silent.hooks)
  local stale = case({ old = "answer to the last question" })
  stale.G.ask("follow-up", stale.hooks)

  return function()
    for _, c in ipairs({ ok, unk, missing, hang, silent, stale }) do if not final(c) then return false end end
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
    -- a missing gbot says so and doesn't leave the chat busy
    t.eq(last(missing).kind, "error", "missing gbot is an error")
    t.ok((last(missing).detail or ""):find("gbot", 1, true), "error names gbot")
    t.ok(not missing.G.busy(), "missing gbot frees the chat")
    -- a send that never returns ends at the wait limit, once, and frees the chat
    t.eq(last(hang).kind, "unknown", "hung send ends as unknown")
    t.ok(not hang.G.busy(), "hung send frees the chat")
    -- a send that dies without saying what happened may still have gone: look anyway
    t.eq(last(silent).kind, "reply", "silent failure still polls")
    t.eq(last(silent).detail, "got it anyway", "and finds the reply")
    t.eq(sends(silent), 1, "silent failure never resends")
    -- an earlier reply isn't passed off as the answer to the new question
    t.eq(last(stale).kind, "unknown", "stale reply ignored")
    return true
  end
end
