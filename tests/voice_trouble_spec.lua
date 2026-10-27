-- voice.lua when things go wrong: "voice = true" in config.lua falls back to the defaults,
-- the same helper error is said once per run (no speak, rebuild, error loop), and a fatal
-- error stops the restarts and says why once. Stand-in helpers; no mic, no speakers.
return function(t, dir)
  local V = dofile(dir .. "/voice.lua")
  local ok, s = pcall(function() return V.configure({ voice = true }).settings() end)
  t.ok(ok, "voice = true in config.lua doesn't break the settings")
  t.eq(ok and s.phrase, "okay Buddy", "and the defaults apply")
  V.configure({})

  local key, pidKey = "claudeBuddy.voice.spec-" .. hs.host.uuid(), "claudeBuddy.voicePid.spec"
  V.settingsKey = key -- never the running buddy's switches
  local saved = nil
  hs.settings.set(key, { listen = false, answers = true, outLoud = 0 })
  local root = t.tmpdir()
  local function script(name, body)
    local path = root .. "/" .. name .. "-fake-ear"
    local f = assert(io.open(path, "w"))
    f:write("#!/bin/sh\n" .. body)
    f:close()
    os.execute("/bin/chmod 755 '" .. path .. "'")
    return path
  end
  -- says the same error twice around ready, then waits to be told to quit
  local noisy = script("noisy", [[
printf '%s\n' '{"ev":"error","why":"no usable microphone","fatal":false}' '{"ev":"ready"}'
printf '%s\n' '{"ev":"error","why":"no usable microphone","fatal":false}'
while IFS= read -r line; do case "$line" in *quit*) exit 0;; esac; done
]])
  -- a fatal error, then gone; every start leaves a line in `starts`
  local starts = root .. "/starts"
  local fatal = script("fatal", "echo x >> '" .. starts .. "'\n"
    .. [[printf '%s\n' '{"ev":"error","why":"Dictation isn'"'"'t available.","fatal":true}']] .. "\nexit 1\n")
  local troubles = {}
  local function opts(bin)
    return { dir = dir, bin = bin, pidKey = pidKey, muted = function() return false end,
      onTrouble = function(m) troubles[#troubles + 1] = m end }
  end
  local function count(path)
    local n, f = 0, io.open(path)
    if f then for _ in f:lines() do n = n + 1 end f:close() end
    return n
  end
  local function finish()
    V.stop()
    hs.settings.set(key, saved)
    hs.settings.set(pidKey, nil)
  end
  local started = pcall(V.start, opts(noisy))
  if not started then finish(); t.ok(false, "noisy helper started"); return end
  local stage, since = "noisy", hs.timer.secondsSinceEpoch()
  return function()
    local waited = hs.timer.secondsSinceEpoch() - since
    if stage == "noisy" and waited > 1 then
      t.eq(#troubles, 1, "the same helper error is said once per run")
      troubles = {}
      V.start(opts(fatal))
      stage, since = "fatal", hs.timer.secondsSinceEpoch()
    elseif stage == "fatal" and waited > 3 then
      t.eq(count(starts), 1, "a fatal error isn't restarted")
      t.eq(troubles[1], "Dictation isn't available.", "and its reason is said")
      t.eq(#troubles, 1, "once")
      finish()
      return true
    end
    return false
  end
end
