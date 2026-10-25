-- Notes migrate from old text and accept small JSON edits without losing earlier facts.
return function(t, dir)
  local key, saved = "claudeBuddy.notes", hs.settings.get("claudeBuddy.notes")
  hs.settings.set(key, { text = "- Likes tea\n- Has a cat", at = 0 })
  local B = dofile(dir .. "/brain.lua").configure({ engine = "ollama", notes_limit = 32,
    agent_dir = t.tmpdir() .. "/agent" }, "Sam", false)
  t.ok(B.notes():find("1. Likes tea", 1, true), "old lines become entries")
  local noticed, noticeVia = {}, nil
  B.onNote(function(line, via) noticed[#noticed + 1], noticeVia = line, via end)
  local post = hs.http.asyncPost
  hs.http.asyncPost = function(_, _, _, done)
    done(200, hs.json.encode({ message = { content = hs.json.encode({
      remove = { "cat" }, replace = { { old = "tea", new = "coffee" } }, add = { "Likes walks", string.rep("x", 40) },
    }) } }))
  end
  local ok, err = pcall(B.remember, { { role = "user", content = "I like coffee and walks", at = 1 } })
  hs.http.asyncPost = post
  t.ok(ok, "edit model reply applied: " .. tostring(err))
  t.ok(B.notes():find("Likes coffee", 1, true), "substring replaced")
  t.ok(B.notes():find("Likes walks", 1, true), "new note added")
  t.ok(not B.notes():find("cat", 1, true), "old note removed")
  t.ok(not B.notes():find(string.rep("x", 40), 1, true), "over limit addition dropped")
  t.ok(#noticed >= 1, "quiet note line emitted")
  t.eq(B.command("/forget"), "Use /forget followed by a note number, such as /forget 3. Use /notes to see them.", "bare command explains")
  t.eq(B.command("/forget 9"), "I don't have a note with that number. Use /notes to see them.", "bad number")
  t.eq(B.command("/forget 1", "telegram"), true, "remove by number")
  t.eq(noticeVia, "telegram", "command carries its channel")
  local before = B.notes()
  hs.http.asyncPost = function(_, _, _, done)
    done(200, hs.json.encode({ message = { content = "not JSON" } }))
  end
  pcall(B.remember, { { role = "user", content = "hello", at = 2 } })
  hs.http.asyncPost = post
  t.eq(B.notes(), before, "bad JSON changes nothing")
  B.forget()
  t.eq(#hs.settings.get(key).entries, 0, "forget clears notes")
  hs.settings.set(key, saved)
end
