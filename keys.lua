-- API keys for the usage card's other AIs (Hammerspoon module), kept in this Mac's
-- Keychain and never in config.lua: one generic password per AI, service
-- claude-buddy-<id>, under the account telegram.lua uses. Saved through security's own
-- prompt on stdin, so a key never shows in a process list. bin/ai-usage reads them back.

local K = { security = "/usr/bin/security" }
K.ACCOUNT = (os.getenv("USER") or ""):match("^[%w._-]+$") or "buddy"
local tasks = {} -- running security calls, kept referenced until they finish

function K.service(id) return "claude-buddy-" .. id end

-- A pasted key without the spaces and newline copying adds.
function K.clean(s)
  if type(s) ~= "string" then return "" end
  local trimmed = s:gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

-- Key-shaped: no spaces or quotes, which would split security's stdin line.
function K.valid(key)
  return type(key) == "string" and #key >= 8 and #key <= 512 and key:match("^[%w%-_.:]+$") ~= nil
end

local function security(args, input, done)
  local task
  local ok, created = pcall(hs.task.new, K.security, function(code, out)
    tasks[task] = nil
    done(code == 0, out or "", code)
  end, args)
  if not ok or not created then return done(false, "", -1) end
  task = created
  if input then task:setInput(input) end
  tasks[task] = true
  if not task:start() then
    tasks[task] = nil
    done(false, "", -1)
  end
end

-- done(true) when the AI has a key saved (the key itself isn't read).
function K.has(id, done)
  security({ "find-generic-password", "-s", K.service(id), "-a", K.ACCOUNT }, nil, function(ok) done(ok) end)
end

-- done(true) once the Keychain reads back the same key.
function K.save(id, key, done)
  if not K.valid(key) then return done(false) end
  local svc = K.service(id)
  security({ "-i" }, string.format("add-generic-password -U -s %s -a %s -w %s\n", svc, K.ACCOUNT, key), function()
    security({ "find-generic-password", "-s", svc, "-a", K.ACCOUNT, "-w" }, nil, function(ok, out)
      done(ok and (out:gsub("%s+$", "")) == key)
    end)
  end)
end

-- done(true) once the key is gone (or was never there: security says 44, not found).
function K.forget(id, done)
  security({ "delete-generic-password", "-s", K.service(id), "-a", K.ACCOUNT }, nil, function(_, _, code)
    if done then done(code == 0 or code == 44) end
  end)
end

return K
