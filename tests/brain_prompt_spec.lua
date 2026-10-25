-- Live context belongs in the newest user turn; the prompt prefix stays stable.
return function(t, dir)
  local B = dofile(dir .. "/brain.lua").configure({ engine = "ollama",
    agent_dir = t.tmpdir() .. "/agent" }, "Sam", false)
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
  local sent = {}
  local post = hs.http.asyncPost
  hs.http.asyncPost = function(_, body, _, done)
    sent[#sent + 1] = hs.json.decode(body)
    done(200, hs.json.encode({ message = { content = "Okay" } }))
  end
  local chat = { { role = "user", content = "hello", at = 1, seq = 1 } }
  B.chat(chat, { app = "Finder", title = "One" }, function() end)
  B.chat(chat, { app = "Safari", title = "Two" }, function() end)
  hs.http.asyncPost = post
  t.eq(sent[1].messages[1].content, sent[2].messages[1].content, "system prompt stable across windows")
  t.ok(sent[2].messages[2].content:find("Safari", 1, true), "changing window in newest turn")
end
