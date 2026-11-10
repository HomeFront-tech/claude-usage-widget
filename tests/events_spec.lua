-- Folder names may be reused, and a replacement log can have the same length.
return function(t, dir)
  local now, folderCallback, tick = 100, nil, nil
  local content, inode = "old\n", 1
  local fake = {
    fs = { attributes = function(path)
      if path == "/fake/log" then return { size = #content, dev = 1, ino = inode } end
      return {}
    end },
    timer = { secondsSinceEpoch = function() return now end,
      doEvery = function(_, cb) tick = cb; return {} end },
    pathwatcher = { new = function(_, cb)
      folderCallback = cb
      return { start = function(self) return self end }
    end },
  }
  local fakeIO = { open = function()
    local offset = 0
    return { seek = function(_, _, n) offset = n end,
      read = function(_, n) return content:sub(offset + 1, offset + n) end,
      close = function() end }
  end }
  local env = setmetatable({ hs = fake, io = fakeIO }, { __index = _G })
  local E = assert(loadfile(dir .. "/events.lua", "t", env))()
  local heard = {}
  E.start({ system_events = false, events = {
    { folder = "/fake/folder", match = "build", cooldown = 10 },
    { log = "/fake/log", match = "hit", cooldown = 0 },
  } }, function(ev) heard[#heard + 1] = ev end)
  local flag = { itemIsFile = true, itemCreated = true }
  folderCallback({ "/fake/folder/build", "/fake/folder/build" }, { flag, flag })
  t.eq(#heard, 1, "one reaction per folder event burst")
  now = now + 11
  folderCallback({ "/fake/folder/build" }, { flag })
  t.eq(#heard, 2, "a reused filename reacts after the cooldown")
  content, inode = "hit\n", 2
  tick()
  t.eq(#heard, 3, "an equal-size replacement is read from its beginning")
  t.eq(heard[3] and heard[3].text, "hit\n", "the rotated log match is delivered")
  tick()
  t.eq(#heard, 3, "the same log generation is not replayed")
  content, inode = "hit\nextra\n", 3
  tick()
  t.eq(#heard, 4, "a larger replacement also starts at zero")
end
