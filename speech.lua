-- Turn short, safe text into a local speech file.
local S = {}

local home = os.getenv("HOME") or ""
local tasks = {}

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

local function noEmoji(s)
  local out = {}
  local ok = pcall(function()
    for _, code in utf8.codes(s) do
      if not ((code >= 0x1F000 and code <= 0x1FAFF) or
          (code >= 0x2600 and code <= 0x27BF) or
          code == 0xFE0F or code == 0x200D) then
        out[#out + 1] = utf8.char(code)
      end
    end
  end)
  return ok and table.concat(out) or s
end

local streetTypes = { "st", "ave", "rd", "dr", "blvd", "way", "cres", "crt" }

local function private(s)
  if s:match("[%w%.%+_%-]+@[%w%.%-]+%.[%a]+") or
      s:match("%d%d%d[-. ]%d%d%d[-. ]%d%d%d%d") or
      s:match("%$%s*%d") then return true end
  local words = {}
  for word in s:lower():gmatch("[%w']+") do words[#words + 1] = word end
  for i, word in ipairs(words) do
    if word:match("^%d+$") then
      for j = i + 1, math.min(i + 4, #words) do
        for _, kind in ipairs(streetTypes) do
          if words[j] == kind then return true end
        end
      end
    end
  end
  return false
end

-- Keep every sentence that is suitable for speaking (no length cap).
function S.speakable(text)
  text = tostring(text or "")
  text = text:gsub("```.-```", " "):gsub("```.*", " "):gsub("`[^`]*`", " ")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if not line:match("^%s*#") and not line:match("^%s*[-*+]%s+") and
        not line:match("^%s*%d+[.)]%s+") then
      lines[#lines + 1] = line
    end
  end
  text = noEmoji(table.concat(lines, " ")):gsub("%s+", " ")
  local keep = {}
  local at = 1
  while at <= #text do
    local a, b = text:find("[%.%!%?]+%s+", at)
    local sentence
    if a then
      sentence = text:sub(at, b):gsub("%s+$", "")
      at = b + 1
    else
      sentence = text:sub(at)
      at = #text + 1
    end
    sentence = trim(sentence)
    if sentence ~= "" and not private(sentence) and
        not sentence:match("https?://") and not sentence:match("www%.") and
        not sentence:match("^[~%.]*/[%w%._%-]") and not sentence:match("%s[~%.]*/[%w%._%-]") and
        not sentence:match("[%a]:\\[%w%._~\\%-]+") then
      sentence = trim(sentence:gsub("[%s%p]+$", function(p)
        return p:match("[%.%!%?]") and p:match("[%.%!%?]") or ""
      end))
      if sentence:match("[%w\128-\255]") then keep[#keep + 1] = sentence end
    end
  end
  if #keep == 0 then return nil end
  return table.concat(keep, " ")
end

-- Split spoken text into pieces for rendering one after another: a short first piece so
-- the voice starts quickly, then bigger ones. Pieces break at sentence ends; nothing is dropped.
local function splitLong(sentence, max)
  local parts = {}
  while #sentence > max do
    local cut
    for at = max, math.floor(max / 2), -1 do
      -- only at a space, or a comma/colon followed by one: never inside 12,500 or 10:30
      if sentence:sub(at, at):match("%s") or sentence:sub(at, at + 1):match("^[,;:]%s") then
        cut = at; break
      end
    end
    cut = cut or max
    -- never cut in the middle of a UTF-8 character
    while cut < #sentence and sentence:byte(cut + 1) and sentence:byte(cut + 1) >= 128 and
        sentence:byte(cut + 1) < 192 do cut = cut + 1 end
    parts[#parts + 1] = trim(sentence:sub(1, cut))
    sentence = trim(sentence:sub(cut + 1))
  end
  if sentence ~= "" then parts[#parts + 1] = sentence end
  return parts
end

function S.chunks(text, firstMax, max)
  firstMax, max = firstMax or 220, max or 600
  local out, current = {}, ""
  local function limit() return #out == 0 and firstMax or max end
  local function flush()
    if current ~= "" then out[#out + 1] = current; current = "" end
  end
  local at = 1
  text = tostring(text or "")
  while at <= #text do
    local a, b = text:find("[%.%!%?]+%s+", at)
    local sentence
    if a then sentence = text:sub(at, b); at = b + 1
    else sentence = text:sub(at); at = #text + 1 end
    sentence = trim(sentence)
    if sentence ~= "" then
      local pieces = #sentence > limit() and splitLong(sentence, limit()) or { sentence }
      for _, piece in ipairs(pieces) do
        if current ~= "" and #current + 1 + #piece > limit() then flush() end
        current = current == "" and piece or (current .. " " .. piece)
        if #current >= limit() then flush() end
      end
    end
  end
  flush()
  return out
end

function S.parseVoices(output)
  local voices = {}
  local seen = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    -- long names leave one space before the language: "Daniel (English (UK)) en_GB    # Hello!"
    local name, lang = line:match("^%s*(.-)%s+(%a%a[_%-]%a%a)%s+#")
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      voices[#voices + 1] = { name = name, lang = lang }
    end
  end
  table.sort(voices, function(a, b)
    local function rank(v)
      local premium = v.name:match("%(Premium%)") or v.name:match("%(Enhanced%)")
      return (v.lang:lower():match("^en") and 0 or 2) + (premium and 0 or 1)
    end
    local ar, br = rank(a), rank(b)
    if ar ~= br then return ar < br end
    return a.name:lower() < b.name:lower()
  end)
  return voices
end

local known = {
  { id = "kokoro", name = "Kokoro", url = "https://github.com/hexgrad/kokoro" },
  { id = "piper", name = "Piper", url = "https://github.com/OHF-Voice/piper1-gpl" },
}

local function wrapper(id, root)
  return root .. "/Library/Application Support/claude-usage-widget/voices/" .. id
end

local function executable(path)
  local attr = hs.fs.attributes(path)
  return attr and attr.mode == "file" and (attr.permissions or ""):find("x") ~= nil or false
end

function S.configure(opts)
  if opts and opts.home then home = opts.home end
  return S
end

function S.engines(root)
  root = root or home
  local result = {}
  for _, engine in ipairs(known) do
    local name, url, id = engine.name, engine.url, engine.id
    result[#result + 1] = {
      id = id, name = name, url = url, installed = executable(wrapper(id, root)),
      setup = "Set up the " .. name .. " text-to-speech engine (" .. url ..
        ") on this Mac for Claude Buddy. Install it in its own folder under " ..
        "~/Library/Application Support/claude-usage-widget/voices/" .. id ..
        "-engine, then create an executable script at " ..
        "~/Library/Application Support/claude-usage-widget/voices/" .. id ..
        ". With --voices it prints the available voice names, one per line. " ..
        "With <input.txt> <output.wav> [voice] it reads the text file, writes " ..
        "the speech to the wav file and exits 0. Test it on one sentence and " ..
        "play the result with afplay. Don't change anything in the " ..
        "claude-usage-widget folder.",
    }
  end
  return result
end

-- The caller owns the resulting audio file and removes it after playback.
function S.render(text, choice, done)
  choice = choice or { engine = "system" }
  local engine = choice.engine or "system"
  local command = engine == "system" and "/usr/bin/say" or wrapper(engine, home)
  if engine ~= "system" and not executable(command) then
    return done(nil, "Voice engine " .. engine .. " is not installed.")
  end
  local temp = hs.fs.temporaryDirectory() or "/tmp"
  local base = temp:gsub("/$", "") .. "/claude-buddy-speech-" .. hs.host.uuid()
  local input = base .. ".txt"
  local output = base .. (engine == "system" and ".aiff" or ".wav")
  local file, why = io.open(input, "w")
  if not file then return done(nil, why or "Couldn't write speech text.") end
  file:write(text)
  file:close()
  local args
  if engine == "system" then
    args = {}
    if choice.name and choice.name ~= "" then args[#args + 1] = "-v"; args[#args + 1] = choice.name end
    args[#args + 1] = "-f"; args[#args + 1] = input
    args[#args + 1] = "-o"; args[#args + 1] = output
  else
    args = { input, output }
    if choice.name and choice.name ~= "" then args[#args + 1] = choice.name end
  end
  local task
  task = hs.task.new(command, function(code, _, err)
    tasks[task] = nil
    os.remove(input)
    if code == 0 and hs.fs.attributes(output, "mode") == "file" then return done(output) end
    os.remove(output)
    done(nil, trim(err) ~= "" and trim(err) or "Speech rendering failed.")
  end, args)
  if not task or not task:start() then
    os.remove(input)
    os.remove(output)
    return done(nil, "Speech renderer couldn't start.")
  end
  tasks[task] = true
end

return S
