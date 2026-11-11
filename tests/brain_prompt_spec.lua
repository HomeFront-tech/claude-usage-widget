-- Live context belongs in the newest user turn; the prompt prefix stays stable.
return function(t, dir)
  local agentDir = t.tmpdir() .. "/agent"
  local B = dofile(dir .. "/brain.lua").configure({ engine = "ollama",
    agent_dir = agentDir }, "Sam", false)
  B.setPrivacy({ watching = function() return true end, private = function() return false end })
  local history = {}
  for i = 1, 31 do
    history[#history + 1] = { seq = i, role = i % 2 == 1 and "user" or "assistant", content = "line " .. i, at = 1 }
  end
  history[#history + 1] = { seq = 32, role = "note", content = "📝 Noted: x", at = 2 }
  local turns = B.turns(history)
  t.ok(turns[1].content:find("line 11", 1, true), "window starts at a ten-line boundary")
  t.ok(not turns[1].content:find("line 1\n", 1, true), "older entries omitted")
  for _, turn in ipairs(turns) do t.ok(not turn.content:find("Noted", 1, true), "note lines omitted") end
  -- his bubble lines aren't conversation: a month of real chats had nine of them to every
  -- real line, and they pushed what was said out of the window
  local busy = {}
  for i = 1, 12 do
    busy[#busy + 1] = { seq = #busy + 1, role = "user", content = "ask " .. i, at = 1 }
    busy[#busy + 1] = { seq = #busy + 1, role = "assistant", content = "answer " .. i, at = 1 }
    for _ = 1, 6 do busy[#busy + 1] = { seq = #busy + 1, role = "assistant", content = "quip", said = true, at = 1 } end
  end
  busy[#busy + 1] = { seq = #busy + 1, role = "assistant", content = "newest quip", said = true, at = 1 }
  busy[#busy + 1] = { seq = #busy + 1, role = "user", content = "what did you", at = 2 }
  busy[#busy + 1] = { seq = #busy + 1, role = "user", content = "just say", at = 2 }
  turns = B.turns(busy)
  local all = {}
  for _, turn in ipairs(turns) do all[#all + 1] = turn.content end
  all = table.concat(all, "\n")
  t.ok(all:find("ask 5", 1, true), "twenty lines of conversation fit, however many bubble lines came between")
  t.ok(not all:find("ask 1\n", 1, true), "and the window still slides")
  t.ok(not all:find("\nquip", 1, true) and not all:find("^quip"), "old bubble lines are left out")
  t.ok(all:find("newest quip", 1, true), "the bubble line they're answering stays")
  t.eq(turns[#turns].content, "what did you\njust say", "a message sent in pieces is one turn")
  t.eq(turns[#turns - 1].content:match("[^\n]+$"), "newest quip", "with that bubble line right before it")
  local sent = {}
  local post = hs.http.asyncPost
  hs.http.asyncPost = function(_, body, _, done)
    sent[#sent + 1] = hs.json.decode(body)
    done(200, hs.json.encode({ message = { content = "Okay" } }))
  end
  local chat = { { role = "user", content = "hello", at = 1, seq = 1 } }
  B.chat(chat, { app = "Finder", title = "One" }, function() end)
  B.chat(chat, { app = "Safari", title = "Two" }, function() end)
  B.chat(chat, { app = "Safari", title = "Two", voice = true }, function() end)
  B.chat(chat, { app = "Safari", title = "Two", voice = true, dump = true }, function() end)
  B.setPrivacy({ watching = function() return true end, private = function() return true end })
  B.chat(chat, { app = "Private editor", title = "Hidden draft", winId = 7 }, function() end)
  B.quip({ kind = "screen", app = "Private editor", title = "Hidden draft", winId = 7 }, function() end)
  local pending, answered = nil, false
  local savedNotes = hs.settings.get("claudeBuddy.notes")
  hs.http.asyncPost = function(_, _, _, done) pending = done end
  B.chat(chat, {}, function() answered = true end)
  local file = assert(io.open(agentDir .. "/notes-new.jsonl", "w"))
  file:write('{"note":"old queued note"}\n'); file:close()
  B.forget()
  pending(200, hs.json.encode({ message = { content = "Old answer" } }))
  t.eq(answered, false, "Forget drops an Ollama answer already in flight")
  t.eq(hs.fs.attributes(agentDir .. "/notes-new.jsonl"), nil, "Forget clears queued notes with Ollama configured too")
  hs.settings.set("claudeBuddy.notes", savedNotes)
  hs.http.asyncPost = post
  t.ok(sent[3].messages[1].content:find("one or two short spoken sentences", 1, true), "said out loud: a short answer")
  t.ok(not sent[3].messages[1].content:find("brain dump", 1, true), "a short message isn't a brain dump")
  t.ok(sent[4].messages[1].content:find("brain dump", 1, true), "a brain dump is called one")
  t.ok(sent[4].messages[1].content:find("misheard words", 1, true), "with dictation's mistakes in mind")
  t.ok(not sent[4].messages[1].content:find("one or two short spoken sentences", 1, true), "and a little more room")
  t.eq(sent[1].messages[1].content, sent[2].messages[1].content, "system prompt stable across windows")
  t.ok(sent[2].messages[2].content:find("Safari", 1, true), "changing window in newest turn")
  t.ok(not sent[5].messages[2].content:find("Hidden draft", 1, true), "private title never enters chat")
  t.ok(not sent[5].messages[2].content:find("Private editor", 1, true), "private app never enters chat")
  t.ok(not sent[6].messages[2].content:find("Hidden draft", 1, true), "private title never enters quips")
  t.ok(sent[6].messages[2].content:find("generic greeting", 1, true), "private quip gets a neutral request")
end
