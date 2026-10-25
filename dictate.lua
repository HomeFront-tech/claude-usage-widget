-- Hold-space dictation for the buddy's chat panel (Hammerspoon module)
--
-- Like Claude Code's voice mode: hold space in the chat box and talk, let go and the
-- words land in the box. ffmpeg records the default microphone, whisper.cpp turns it
-- into text, both on this Mac; the recording is deleted straight after. Hammerspoon
-- asks for the microphone the first time. Needs: brew install ffmpeg whisper-cpp, plus
-- a ggml model in ~/.cache/whisper.cpp (see README). Set `ai.dictation` in config.lua
-- to pick the model or language, or `ai.dictation = false` to turn it off. D.file turns
-- a voice note from Telegram (telegram.lua) into text the same way.

local D = {}

local HOME = os.getenv("HOME")
local BINS = { "/opt/homebrew/bin/", "/usr/local/bin/" }
local MODEL_DIR = HOME .. "/.cache/whisper.cpp"
-- Picked in this order when config.lua doesn't name one.
local MODELS = { "large-v3-turbo", "large-v3-turbo-q5_0", "medium.en", "small.en", "base.en", "small", "base", "tiny.en" }
local SILENT = 1600 -- loudest sample below this (out of 32767) means nobody spoke
local MIN_SECS = 0.4

local FFMPEG, WHISPER, MODEL, LANG
local rec, onStop, failed -- the running recording, what to do once it stops, why it died

local function now() return hs.timer.secondsSinceEpoch() end
local function exists(p) return p and hs.fs.attributes(p) ~= nil end

local function bin(name)
  for _, d in ipairs(BINS) do
    if exists(d .. name) then return d .. name end
  end
end

local function findModel()
  for _, m in ipairs(MODELS) do
    local p = MODEL_DIR .. "/ggml-" .. m .. ".bin"
    if exists(p) then return p end
  end
  local ok, iter, dir = pcall(hs.fs.dir, MODEL_DIR)
  if not ok or not iter then return nil end
  for f in iter, dir do
    if f:match("^ggml%-.+%.bin$") then return MODEL_DIR .. "/" .. f end
  end
end

-- cfg: config.lua's ai.dictation, e.g. { model = "~/models/ggml-base.en.bin", language = "auto" }
function D.configure(cfg)
  cfg = type(cfg) == "table" and cfg or {}
  FFMPEG, WHISPER = bin("ffmpeg"), bin("whisper-cli")
  MODEL = cfg.model and cfg.model:gsub("^~", HOME) or findModel()
  LANG = cfg.language or "en"
  return D
end

-- Why dictation can't run, or nil when it can.
function D.missing()
  if not FFMPEG then return "Dictation needs ffmpeg: brew install ffmpeg" end
  if not WHISPER then return "Dictation needs whisper.cpp: brew install whisper-cpp" end
  if not exists(MODEL) then return "Dictation needs a whisper model in ~/.cache/whisper.cpp (see the README)." end
end

-- Loudest 16-bit sample in a WAV file (every 4th one is plenty).
local function peak(file)
  local f = io.open(file, "rb")
  if not f then return 0 end
  local data = f:read("a")
  f:close()
  local at = data:find("data", 13, true)
  if not at then return 0 end
  local top = 0
  for i = at + 8, #data - 1, 8 do
    local v = math.abs((string.unpack("<i2", data, i)))
    if v > top then top = v end
  end
  return top
end

-- whisper.cpp marks silence and noises in brackets: [BLANK_AUDIO], (wind blowing).
local function tidy(s)
  s = (s or ""):gsub("%b[]", ""):gsub("%b()", ""):gsub("%s+", " ")
  return s:match("^%s*(.-)%s*$")
end

local function transcribe(file, done, silent)
  if peak(file) < SILENT then
    os.remove(file)
    return done(nil, silent or "Didn't hear anything. Check the mic, and that Hammerspoon has it in Privacy & Security.")
  end
  local task = hs.task.new(WHISPER, function(code, out)
    os.remove(file)
    local text = code == 0 and tidy(out) or ""
    if text == "" then return done(nil, code == 0 and "Didn't catch that. Try again?" or "whisper.cpp couldn't read that.") end
    done(text)
  end, { "-m", MODEL, "-f", file, "-l", LANG, "-nt", "-np" })
  if not task:start() then
    os.remove(file)
    done(nil, "whisper.cpp didn't start.")
  end
end

-- Start recording. fail(why) runs if the microphone gives out before D.stop.
function D.start(fail)
  if rec then return true end
  local why = D.missing()
  if why then return nil, why end
  local tmp = hs.fs.temporaryDirectory() or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  local file, t0 = string.format("%sclaude-buddy-%d.wav", tmp, math.floor(now() * 1000)), now()
  failed = nil
  rec = hs.task.new(FFMPEG, function(code, _, err)
    rec = nil
    local done = onStop
    onStop = nil
    if not done then -- died on its own (no microphone permission?) or was cancelled
      os.remove(file)
      if code ~= 0 and code ~= 255 then
        print("ClaudeBuddy dictation: " .. (err or ""):gsub("%s+$", ""))
        failed = "I can't hear you. Give Hammerspoon the microphone in System Settings > Privacy & Security."
        if fail then fail(failed) end
      end
      return
    end
    if now() - t0 < MIN_SECS then os.remove(file); return done(nil) end
    transcribe(file, done)
  end, { "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", ":default", "-ac", "1", "-ar", "16000", "-y", file })
  if not rec:start() then
    rec = nil
    return nil, "ffmpeg didn't start."
  end
  return true
end

-- Stop recording and transcribe it: done(text) or done(nil, why).
function D.stop(done)
  if not rec then return done(nil, failed) end
  onStop = done
  rec:interrupt() -- ffmpeg finishes the file on Ctrl-C
end

function D.cancel()
  if rec then onStop = nil; rec:terminate() end
end

function D.recording() return rec ~= nil end

-- Transcribe an audio file ffmpeg can read, like a Telegram voice note: done(text) or
-- done(nil, why). The file itself is left alone.
function D.file(input, done)
  local why = D.missing()
  if why then return done(nil, why) end
  local tmp = hs.fs.temporaryDirectory() or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  local wav = string.format("%sclaude-buddy-note-%d.wav", tmp, math.floor(now() * 1000))
  D.fileTask = hs.task.new(FFMPEG, function(code)
    D.fileTask = nil
    if code ~= 0 then os.remove(wav); return done(nil, "ffmpeg couldn't read that recording.") end
    transcribe(wav, done, "That one sounded silent to me.")
  end, { "-hide_banner", "-loglevel", "error", "-i", input, "-ac", "1", "-ar", "16000", "-y", wav })
  if not D.fileTask:start() then
    D.fileTask = nil
    done(nil, "ffmpeg didn't start.")
  end
end

return D
