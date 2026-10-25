-- The short settings transcript is also written to a bounded, searchable archive.
return function(t, dir)
  local key, seqKey = "claudeBuddy.chat", "claudeBuddy.chatSeq"
  local saved, savedSeq = hs.settings.get(key), hs.settings.get(seqKey)
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
  C.forget()
  t.eq(io.open(archive, "r"), nil, "forget removes archive")
  hs.settings.set(key, saved)
  hs.settings.set(seqKey, savedSeq)
end
