-- approve.lua: which approval requests are still waiting, and writing the owner's answer.
return function(t, dir)
  local tmp = t.tmpdir()
  local A = dofile(dir .. "/approve.lua").configure(tmp)
  t.writeJson(tmp .. "/approvals/a.req.json", { id = "a", tool = "Bash", detail = "rm x", deadline = os.time() + 60 })
  t.writeJson(tmp .. "/approvals/b.req.json", { id = "b", tool = "Edit", detail = "/tmp/y", deadline = os.time() - 1 })
  t.writeJson(tmp .. "/approvals/c.req.json", { id = "c", tool = "Write", detail = "/tmp/z", deadline = os.time() + 60 })
  t.writeJson(tmp .. "/approvals/c.res.json", { behavior = "allow" })
  local p = A.pending()
  t.eq(#p, 1, "only unanswered, unexpired") -- what gets re-shown after a reload
  t.eq(p[1] and p[1].id, "a", "the live one")
  A.decide("a", "deny")
  t.eq((t.readJson(tmp .. "/approvals/a.res.json") or {}).behavior, "deny", "decision written")
  t.eq(#A.pending(), 0, "answered drops out")
  A.decide("a", "allow")
  t.eq((t.readJson(tmp .. "/approvals/a.res.json") or {}).behavior, "deny", "first answer stands")
  t.eq(#dofile(dir .. "/approve.lua").configure(tmp .. "/none").pending(), 0, "no folder yet")
end
