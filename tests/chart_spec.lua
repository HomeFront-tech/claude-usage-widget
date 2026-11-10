-- Real refreshes never cross into the screenshot demo.
return function(t, dir)
  local K = dofile(dir .. "/chart.lua")
  local calls = 0
  K.wv = { evaluateJavaScript = function() calls = calls + 1 end }
  K.demo = true
  K.push({ t = 123, v = {} }, { plan = "real" })
  K.pushTokens(nil)
  t.eq(calls, 0, "demo ignores real usage and token refreshes")
  K.demo = false
  K.push({ t = 123, v = {} }, { plan = "real" })
  t.eq(calls, 1, "normal charts receive usage refreshes")
end
