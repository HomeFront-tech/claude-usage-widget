-- A task may terminate before Hammerspoon delivers its last stdout chunk.
return function(t, dir)
  local originalNew, originalAfter = hs.task.new, hs.timer.doAfter
  local completion, streaming, input, timers
  local A = dofile(dir .. "/agent.lua").configure({ agent_dir = t.tmpdir() }, dir)
  hs.task.new = function(_, done, stream)
    completion, streaming = done, stream
    return { setEnvironment = function() end, setInput = function(_, text) input = text end,
      start = function() return true end }
  end
  hs.timer.doAfter = function(delay, callback)
    local timer = { delay = delay, callback = callback, stopped = false }
    function timer:stop() self.stopped = true end
    timers[#timers + 1] = timer
    return timer
  end
  local function start(partial)
    timers = {}
    local result = { calls = 0 }
    A.run({ kind = "chat", system = "rules", prompt = "hello" }, function(text, err)
      result.calls, result.text, result.error = result.calls + 1, text, err
    end, partial or function() end)
    return result
  end
  local function tick()
    for _, timer in ipairs(timers) do
      if not timer.stopped then timer.callback() end
    end
  end
  local ok, err = pcall(function()
    local result = start()
    t.eq(input:sub(-1), "\n", "request is one JSON line even when stdin stays open")
    completion(0, "", "")
    t.eq(result.calls, 0, "termination waits briefly for the last stream chunk")
    t.ok(#timers == 1 and timers[1].delay <= 1, "missing final result has a short grace timer")
    streaming(nil, hs.json.encode({ ok = true, text = "Trailing answer" }) .. "\n")
    t.eq(result.text, "Trailing answer", "final JSON after termination supplies the answer")
    tick()
    completion(0, "", "")
    streaming(nil, hs.json.encode({ ok = true, text = "Duplicate" }) .. "\n")
    t.eq(result.calls, 1, "late chunks and duplicate termination never call done twice")

    result = start()
    local answer = hs.json.encode({ ok = true, text = "Split final" })
    streaming(nil, answer:sub(1, 12))
    completion(0, "", "")
    streaming(nil, answer:sub(13))
    t.eq(result.text, "Split final", "split final JSON without newline completes after termination")
    tick()
    t.eq(result.calls, 1, "a split result also finishes once")

    result = start()
    streaming(nil, hs.json.encode({ ok = true, text = "Before exit" }) .. "\n")
    t.eq(result.calls, 0, "stdout alone waits for task termination")
    completion(0, "", "")
    t.eq(result.text, "Before exit", "normal stream order still completes immediately")
    t.eq(result.calls, 1, "normal result delivered once")

    result = start()
    completion(0, "", "")
    tick()
    t.eq(result.calls, 1, "a missing final result releases the caller after grace")
    t.eq(result.error, "Claude didn't answer.", "missing final result reports failure")
    streaming(nil, hs.json.encode({ ok = true, text = "Too late" }) .. "\n")
    tick()
    t.eq(result.calls, 1, "result after grace does not answer twice")

    result = start(function() error("preview failed") end)
    streaming(nil, hs.json.encode({ partial = "preview" }) .. "\n")
    completion(0, "", "")
    streaming(nil, hs.json.encode({ ok = true, text = "Final survives" }) .. "\n")
    t.eq(result.text, "Final survives", "preview callback failure does not disable final parsing")
    t.eq(result.calls, 1, "failed preview still finishes once")
  end)
  hs.task.new, hs.timer.doAfter = originalNew, originalAfter
  if not ok then error(err) end
end
