-- Speech keeps private text silent and renders through a local executable.
return function(t, dir)
  local S = dofile(dir .. "/speech.lua")
  t.eq(S.speakable("Done. I opened it.\n```lua\nx=1\n```\nSee https://a.b/c"),
    "Done. I opened it.", "fences and links")
  t.eq(S.speakable("```\nonly code\n```"), nil, "code only is silent")
  t.eq(S.speakable("https://a.b/c"), nil, "link only is silent")
  t.eq(S.speakable("- first\n- second"), "first. second.", "list items are said without their markers")
  t.eq(S.speakable("1. Mow Tuesday.\n2) Invoice Friday"), "Mow Tuesday. Invoice Friday.", "numbered items too, each as a sentence")
  t.eq(S.speakable("Before `secret()` after."), "Before after.", "inline code is removed")
  t.eq(S.speakable("```\nunfinished code"), nil, "unfinished fence is silent")
  t.eq(S.speakable("Call 555-555-0100 today. It's sunny."), "It's sunny.", "phone sentence is silent")
  t.eq(S.speakable("One. Two. Three. Four."), "One. Two. Three. Four.", "every sentence is kept")
  local para = {}
  for i = 1, 40 do para[#para + 1] = "This is sentence number " .. i .. " of a long message." end
  local longText = table.concat(para, " ") .. "\n\n" .. table.concat(para, " ")
  t.eq(S.speakable(longText), table.concat(para, " ") .. " " .. table.concat(para, " "), "long text is not cut")
  local pieces = S.chunks(S.speakable(longText))
  t.ok(#pieces > 3, "long text splits into several pieces")
  t.ok(#pieces[1] <= 220, "first piece is short so speech starts fast")
  t.eq(table.concat(pieces, " "), S.speakable(longText), "pieces join back to the whole text")
  local num = string.rep("a", 200) .. " 12,500 people and 10:30 sharp " .. string.rep("b ", 120)
  for _, piece in ipairs(S.chunks(num)) do
    t.ok(not piece:match("%d,$") and not piece:match("%d:$"), "never splits a number or a time")
  end
  local one = string.rep("word ", 400)
  t.eq(table.concat(S.chunks(one), " "):gsub("%s+", " "), (one:gsub("%s+$", "")) .. "", "a sentence with no stops still splits without loss")
  t.eq(S.speakable("# Heading\n- item\nThe file is /tmp/test.txt. All done."),
    "item. All done.", "headings and paths are silent, list items are said")
  t.eq(S.speakable("Email me at test@example.com. Pay $20 today. Visit 12 Main St. Safe now."),
    "Safe now.", "private sentences are silent")
  t.eq(S.speakable("Hello 😊 there."), "Hello there.", "emoji is removed")
  t.eq(S.speakable("Use one and/or the other, 24/7. Done."), "Use one and/or the other, 24/7. Done.",
    "a slash between words isn't a path")
  local long = S.parseVoices("Daniel (English (UK)) en_GB    # Hello!\nDaniel (English (UK)) en_GB    # Hello!\n"
    .. "Fred                en_US    # Hello!\n")
  t.eq(#long, 2, "long names parse and duplicates go")
  t.eq(long[1].name, "Daniel (English (UK))", "long name kept whole")

  local voices = S.parseVoices("Albert  en_US # Hi\nAmélie  fr_CA # Salut\nAva (Premium)  en_US # Hello\n")
  t.eq(#voices, 3, "three system voices parsed")
  t.eq(voices[1].name, "Ava (Premium)", "premium English first")
  t.eq(voices[1].lang, "en_US", "voice language parsed")
  t.eq(voices[3].name, "Amélie", "non-English last")

  local home = t.tmpdir()
  local path = home .. "/Library/Application Support/claude-usage-widget/voices/kokoro"
  hs.fs.mkdir(home .. "/Library")
  hs.fs.mkdir(home .. "/Library/Application Support")
  hs.fs.mkdir(home .. "/Library/Application Support/claude-usage-widget")
  hs.fs.mkdir(home .. "/Library/Application Support/claude-usage-widget/voices")
  local script = assert(io.open(path, "w"))
  script:write("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\nprintf 'RIFF' > \"$2\"\n")
  script:close()
  local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
  local ok = os.execute("/bin/chmod 755 " .. quoted)
  t.ok(ok, "fake wrapper is executable")
  local engines = S.engines(home)
  t.eq(engines[1].id, "kokoro", "kokoro is listed")
  t.eq(engines[1].installed, true, "kokoro wrapper found")
  t.eq(engines[2].id, "piper", "piper is listed")
  t.eq(engines[2].installed, false, "missing piper wrapper")
  t.eq(engines[1].url, "https://github.com/hexgrad/kokoro", "kokoro download link")
  t.eq(engines[2].url, "https://github.com/OHF-Voice/piper1-gpl", "piper download link")
  t.ok(engines[1].setup:match("With %-%-voices"), "setup explains wrapper voices")

  S.configure({ home = home })
  local complete = false
  S.render("Hello there.", { engine = "kokoro", name = "warm" }, function(output, why)
    t.eq(why, nil, "fake wrapper rendered")
    t.ok(output ~= nil, "render returns output")
    if output then
      local args = assert(io.open(path .. ".args", "r"))
      local input, actualOutput, voice = args:read("*l"), args:read("*l"), args:read("*l")
      args:close()
      t.ok(input:match("%.txt$") ~= nil, "wrapper gets input first")
      t.eq(actualOutput, output, "wrapper gets output second")
      t.eq(voice, "warm", "wrapper gets voice third")
      t.ok(hs.fs.attributes(output) ~= nil, "rendered output exists")
      os.remove(output)
    end
    complete = true
  end)
  S.render("Hello", { engine = "piper" }, function(output, why)
    t.eq(output, nil, "missing wrapper gives no output")
    t.ok(why and why ~= "", "missing wrapper gives reason")
  end)
  return function() return complete end
end
