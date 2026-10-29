-- Two voice.lua instances in one Hammerspoon share hs.settings: the buddy's and a spec's
-- sandbox, or the wizard's. When the second one starts it must not kill the helper the first
-- one runs. It did: the saved PID looked like a helper left over from an earlier Hammerspoon,
-- and the buddy lost his ears once per sandbox the specs built.
-- The stand-in helper is a symlink to /bin/cat named fake-ear: V.start only kills a process
-- whose command name is buddy-ear or fake-ear, and ps names a shell script's interpreter
-- (/bin/sh), so tests/fakes/fake-ear could never be killed that way. A copy of cat would be
-- killed by macOS on launch (code signing); the link runs the real file under the checked
-- name. cat stays quiet on its pipe and ends when its input closes, like the real helper.
return function(t, dir)
  local A, B = dofile(dir .. "/voice.lua"), dofile(dir .. "/voice.lua")
  local key, pidKey = "claudeBuddy.voice.spec-" .. hs.host.uuid(), "claudeBuddy.voicePid.ownedspec"
  A.settingsKey, B.settingsKey = key, key
  local fake = t.tmpdir() .. "/fake-ear"
  os.execute("/bin/ln -s /bin/cat '" .. fake .. "'")
  local function alive(pid)
    return pid ~= nil and (hs.execute("/bin/ps -p " .. pid .. " -o pid= 2>/dev/null") or ""):find("%d") ~= nil
  end
  local function opts()
    return { dir = dir, bin = fake, pidKey = pidKey, muted = function() return false end, onTrouble = function() end }
  end
  local function cleanup()
    pcall(B.stop); pcall(A.stop)
    hs.settings.set(pidKey, nil)
    hs.settings.set(key, nil)
  end
  -- listening, so the helper is started without --no-listen (cat would refuse the option)
  hs.settings.set(key, { listen = true, answers = true, outLoud = 0, voice = { engine = "system" } })
  hs.settings.set(pidKey, nil)
  local ok, err = pcall(function()
    A.start(opts())
    local aPid = A.task and A.task:pid()
    t.eq(tonumber(hs.settings.get(pidKey)), aPid, "the first instance saves its helper's PID")
    t.ok(alive(aPid), "the first helper runs")
    B.start(opts())
    local since, finished = hs.timer.secondsSinceEpoch(), false
    return function()
      local elapsed = hs.timer.secondsSinceEpoch() - since
      if elapsed < 0.5 then return false end
      local safe, why = pcall(function()
        if not finished then
          t.ok(alive(aPid), "a second instance's start leaves the first one's helper running")
          t.ok(B.task ~= nil and B.task:pid() ~= aPid, "the second instance runs its own helper")
          t.eq(#(A.exits or {}), 0, "the first instance saw no exit")
          B.stop(); A.stop()
          finished = true
          since = hs.timer.secondsSinceEpoch()
          return false
        end
        if elapsed < 0.7 then return false end
        t.ok(not alive(aPid), "stop ends the first helper")
        cleanup()
        return true
      end)
      if not safe then t.ok(false, "two instances: " .. tostring(why)); cleanup(); return true end
      return why
    end
  end)
  if not ok then cleanup(); t.ok(false, "two instances setup: " .. tostring(err)); return end
  return err -- the poll function
end
