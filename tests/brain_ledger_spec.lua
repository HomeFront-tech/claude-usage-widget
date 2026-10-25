-- Ollama replies record their model and token counts in Buddy's ledger.
return function(t, dir)
  local agentDir = t.tmpdir() .. "/nested/agent"
  local B = dofile(dir .. "/brain.lua").configure({ engine = "ollama", model = "gemma3:4b", agent_dir = agentDir }, "Sam", false)
  local entry = B.ollamaEntry("quip", { prompt_eval_count = 50, eval_count = 9 }, 0)
  t.eq(entry.engine, "ollama", "engine")
  t.eq(entry.kind, "quip", "kind")
  t.eq(entry.model, "gemma3:4b", "model")
  t.eq(entry.models["ollama:gemma3:4b"][1], 50, "prompt tokens")
  t.eq(entry.models["ollama:gemma3:4b"][2], 9, "reply tokens")
  t.eq(B.ollamaEntry("quip", {}, 0.75).at, entry.at, "fractional epoch timestamp")
  local relativeDirs = B.agentDirs("logs/agent")
  t.eq(relativeDirs[1], "logs", "relative directory starts without slash")
  t.eq(relativeDirs[2], "logs/agent", "relative nested directory")

  local originalPost = hs.http.asyncPost
  hs.http.asyncPost = function(_, _, _, callback)
    callback(200, hs.json.encode({ message = { content = "Hello" }, prompt_eval_count = 50, eval_count = 9 }))
  end
  local ok, err = pcall(function()
    B.quip({ kind = "event", what = "a window opened" }, function() end)
  end)
  t.ok(ok, "Ollama reply logged: " .. tostring(err))
  local file = io.open(agentDir .. "/usage.jsonl", "r")
  t.ok(file, "ledger created")
  if file then
    local line = file:read("*l")
    t.eq(file:read("*l"), nil, "one ledger line")
    file:close()
    t.ok(type(line) == "string" and line ~= "", "ledger line written")
    if line and line ~= "" then
      local logged = hs.json.decode(line)
      t.eq(logged.kind, "quip", "logged kind")
      t.eq(logged.models["ollama:gemma3:4b"][1], 50, "logged prompt tokens")
    end
  end

  local cwd = hs.fs.currentDir()
  local relativeRoot = t.tmpdir()
  local relativeReply = false
  local relativeOk, relativeErr = pcall(function()
    assert(hs.fs.chdir(relativeRoot))
    B.configure({ engine = "ollama", model = "gemma3:4b", agent_dir = "rel/agent" }, "Sam", false)
    B.quip({ kind = "event", what = "a window opened" }, function(text)
      relativeReply = text == "Hello"
    end)
  end)
  hs.fs.chdir(cwd)
  t.ok(relativeOk, "relative agent directory reply: " .. tostring(relativeErr))
  t.ok(relativeReply, "relative agent directory callback")
  local relativeFile = io.open(relativeRoot .. "/rel/agent/usage.jsonl", "r")
  t.ok(relativeFile, "relative agent directory ledger created")
  if relativeFile then relativeFile:close() end

  -- rawget: inside `hs -c`, `print` is a per-call IPC wrapper that must not outlive the call
  local originalOpen, originalPrint = io.open, rawget(_G, "print")
  local errors = {}
  local writeReply = false
  B.configure({ engine = "ollama", model = "gemma3:4b", agent_dir = relativeRoot .. "/failure/agent" }, "Sam", false)
  io.open = function(path, mode)
    if mode == "a" then
      return { write = function() return nil, "disk full" end,
               close = function() return nil, "close failed" end }
    end
    return originalOpen(path, mode)
  end
  rawset(_G, "print", function(message) errors[#errors + 1] = message end)
  local writeOk, writeErr = pcall(function()
    B.quip({ kind = "event", what = "a window opened" }, function(text)
      writeReply = text == "Hello"
    end)
  end)
  io.open = originalOpen
  rawset(_G, "print", originalPrint)
  hs.http.asyncPost = originalPost
  t.ok(writeOk, "failed ledger write does not throw: " .. tostring(writeErr))
  t.ok(writeReply, "failed ledger write still delivers reply")
  t.eq(errors[1], "ClaudeBuddy brain: disk full", "failed ledger write is logged")
  t.eq(errors[2], "ClaudeBuddy brain: close failed", "failed ledger close is logged")
end
