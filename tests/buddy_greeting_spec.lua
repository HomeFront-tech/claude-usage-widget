-- He introduces himself once. A restart (an update, a reload) gets a short word, not the
-- introduction all over again: in a month of real use the introduction was his most repeated line.
return function(t, dir)
  local sandbox = dofile(dir .. "/tests/buddy_sandbox.lua")
  local function said(S, words)
    for _, line in ipairs(S.said) do
      if line:find(words, 1, true) then return line end
    end
  end
  local settings = {}
  local A = sandbox(dir, {}, { settings = settings })
  t.ok(said(A, "I'm your Claude buddy"), "the first start is an introduction")
  A.done()
  local B = sandbox(dir, {}, { settings = settings })
  t.eq(said(B, "I'm your Claude buddy"), nil, "a restart is not")
  t.ok(said(B, "I'm back!") or said(B, "Back again.") or said(B, "Miss me?"), "a restart gets a short word")
  B.done()
end
