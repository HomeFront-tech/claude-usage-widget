-- The short settings transcript is also written to a bounded, searchable archive.
return function(t, dir)
  local key, seqKey = "claudeBuddy.chat", "claudeBuddy.chatSeq"
  local saved, savedSeq = hs.settings.get(key), hs.settings.get(seqKey)
  local savedDraft = hs.settings.get("claudeBuddy.chatDraft")
  hs.settings.set(key, {})
  local C = dofile(dir .. "/chat.lua")
  local archive = t.tmpdir() .. "/chat-archive.jsonl"
  C.setArchivePath(archive)
  C.post("user", "hello", "telegram")
  C.post("assistant", "hi")
  local file = assert(io.open(archive, "r"))
  local first = hs.json.decode(file:read("*l"))
  local second = hs.json.decode(file:read("*l"))
  file:close()
  t.eq(first.via, "telegram", "archive keeps channel")
  t.eq(first.content, "hello", "archive keeps text")
  t.ok(C.history()[2].seq > C.history()[1].seq, "sequence increases")
  t.eq(second.role, "assistant", "archive keeps speaker")
  file = assert(io.open(archive, "w"))
  local line = hs.json.encode({ role = "user", content = string.rep("x", 1000) }) .. "\n"
  for _ = 1, 5400 do file:write(line) end
  file:close()
  C.post("assistant", "newest")
  t.ok(hs.fs.attributes(archive, "size") <= 2.5 * 1024 * 1024, "trim retains at most half the limit")
  file = assert(io.open(archive, "r"))
  local last
  for row in file:lines() do last = hs.json.decode(row) end
  file:close()
  t.eq(last.content, "newest", "trim keeps whole lines in order")
  t.eq(io.open(archive .. ".tmp"), nil, "trim replaces temporary archive")
  -- bubble lines: the oldest go first, so chatter can't push the conversation out
  C.post("user", "the question")
  C.post("assistant", "the answer")
  for i = 1, 100 do C.said("quip " .. i) end
  local kept, quips = {}, 0
  for _, h in ipairs(C.history()) do
    kept[h.content] = true
    if h.said then quips = quips + 1 end
  end
  t.ok(kept["the question"] and kept["the answer"], "a hundred bubble lines later the conversation is still kept")
  t.eq(quips, 12, "only the newest bubble lines are kept")
  t.ok(kept["quip 100"] and not kept["quip 88"], "the oldest bubble lines go first")
  local shown = C.recent()
  t.eq(shown[#shown].content, "quip 100", "opening the panel shows his newest bubble line")
  t.eq(shown[#shown - 2].content, "the answer", "two of them at most, after the last real answer")
  C.post("user", "next")
  C.post("assistant", "reply")
  shown = C.recent()
  local between = false
  for _, h in ipairs(shown) do between = between or h.said == true end
  t.eq(between, false, "bubble lines between answers stay out of the opened panel")
  t.eq(shown[#shown].content, "reply", "which ends on the last answer")
  hs.settings.set("claudeBuddy.chatDraft", "unsent words")
  local cleared
  C.wv = { evaluateJavaScript = function(_, script) cleared = script end }
  C.forget()
  C.wv = nil
  t.eq(io.open(archive, "r"), nil, "forget removes archive")
  t.eq(hs.settings.get("claudeBuddy.chatDraft"), nil, "forget removes unsent draft")
  t.ok(cleared and cleared:find("window.thinking(false)", 1, true), "forget resets visible chat")
  hs.settings.set(key, saved)
  hs.settings.set(seqKey, savedSeq)
  hs.settings.set("claudeBuddy.chatDraft", savedDraft)
end
