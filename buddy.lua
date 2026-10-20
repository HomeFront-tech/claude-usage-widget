-- Claude buddy: a little pixel Claude that lives on the desktop (Hammerspoon module)
--
-- It watches which app and window you're in and plays a matching animation with a
-- short line: a laptop for terminals (sparkles while Claude Code is working, a wave
-- when it's your turn), popcorn for YouTube, a side-eye for ChatGPT, a shovel for
-- snow forecasts. It knows your Claude Code sessions by name, says something when you
-- click into one, and tells you when one in the background finishes. It reacts to
-- things happening on the Mac too (events.lua): wake-ups, gadgets, downloads, crashes,
-- and log lines or folders you point it at. Its eyes follow the mouse; it gets bored
-- after 3 min away, falls asleep after 10, and sweats when the Claude session is nearly
-- used up (read from the usage card).
--
-- Plain rules by default. With `ai` in config.lua it gets a brain (brain.lua, a small
-- vision model on this Mac through Ollama): it looks at windows it doesn't know and
-- cracks a joke about them, riffs on your sessions, and chats in a panel (chat.lua)
-- where you can type or hold space and talk (dictate.lua). Every line from its speech
-- bubble shows up in the chat too, and it keeps notes so the next chat picks up.
--
-- Click: chat (or a hello, without a brain). Shift-click: "what do you see?".
-- Cmd-click: a new Claude Code session in Terminal. Right-click or Ctrl-click: its
-- menu. Option-click: the setup wizard. Drag it to move it; shake it and it gets dizzy.
--
-- Window titles come from the window list, which needs Hammerspoon to have Screen
-- Recording permission; without it the buddy still reacts to each app. No
-- Accessibility permission is needed. Try a mood: hs -c 'ClaudeBuddy.test("love")'
-- or an event: hs -c 'ClaudeBuddy.event("crash", "Safari")'.
-- Personal tweaks (your name, extra rules, lines and events) go in config.lua next to
-- this file; the setup wizard (setup.lua) writes it.

local M = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local CFG = (function()
  local chunk = loadfile(DIR .. "/config.lua")
  local ok, cfg = pcall(chunk or function() end)
  return ok and type(cfg) == "table" and cfg or {}
end)()

local HOME = os.getenv("HOME")
local POS_KEY = "claudeBuddy.topLeft"
local NAME = CFG.name or ""      -- used in greetings
local ON_TOP = CFG.buddy_on_top  -- true floats it above windows instead of sitting on the desktop
local FPS = 12
local W, H = 200, 170    -- canvas
local S = 5              -- one pixel of the character, in screen points
local BODY_TOP = 98      -- body top inside the canvas, before animation offsets
local GROUND = BODY_TOP + 12 * S
local SAY_MIN, SAY_MAX = 3.5, 9 -- seconds a speech bubble stays up; longer lines stay longer
local WRAP = 27                 -- characters per bubble line (up to 4 lines)
local CHATTER = { chatty = 4, normal = 12, quiet = 45, silent = -1 }
local AMBIENT = { chatty = 50, normal = 150, quiet = 600 }
local QUIET_FOR = CHATTER[CFG.chatter or "chatty"] or 4 -- seconds between unprompted lines; -1 = only when clicked
local AMBIENT_EVERY = AMBIENT[CFG.chatter or "chatty"] or -1 -- quiet this long and it pipes up by itself
local SLEEP_AFTER = (CFG.sleep_after or 10) * 60        -- seconds without keyboard or mouse; 0 = never naps
local BORED_AFTER = SLEEP_AFTER > 0 and math.min(180, SLEEP_AFTER / 2) or 180
local USED_KEY, TAUGHT_KEY = "claudeBuddy.appSeconds", "claudeBuddy.askedToTeach"
local TEACH_AFTER = 20 * 60 -- seconds in an app it doesn't know before it asks to be taught
local EVENT_FOR = 6         -- seconds an event's mood shows
local HAMMERSPOON = "org.hammerspoon.Hammerspoon"
local TERMINAL_APP = CFG.terminal or "Terminal" -- where Cmd-click opens Claude Code (Terminal or iTerm)

-- The optional brain; see brain.lua. AI.peek_every: seconds between unprompted looks
-- at the screen (0 = only windows it doesn't know).
local AI = type(CFG.ai) == "table" and CFG.ai or nil
local Brain = AI and dofile(DIR .. "/brain.lua").configure(AI, NAME) or nil
local PEEK_EVERY = AI and AI.peek_every or 0
local Events = dofile(DIR .. "/events.lua")
local Chat = dofile(DIR .. "/chat.lua") -- the chat panel, and the transcript it shares with the bubble

local FONT = hs.styledtext.defaultFonts.system.name
local BOLD = hs.styledtext.defaultFonts.boldSystem.name

local C = {
  body   = { red = 0.85, green = 0.47, blue = 0.34, alpha = 1 }, -- Claude orange
  shade  = { red = 0.70, green = 0.36, blue = 0.26, alpha = 1 },
  shine  = { red = 0.94, green = 0.62, blue = 0.50, alpha = 1 },
  eye    = { red = 0.10, green = 0.08, blue = 0.08, alpha = 1 },
  pink   = { red = 0.97, green = 0.42, blue = 0.58, alpha = 1 },
  blush  = { red = 0.97, green = 0.42, blue = 0.58, alpha = 0.55 },
  white  = { red = 0.97, green = 0.97, blue = 0.97, alpha = 1 },
  grey   = { red = 0.58, green = 0.60, blue = 0.64, alpha = 1 },
  dark   = { red = 0.20, green = 0.21, blue = 0.24, alpha = 1 },
  red    = { red = 0.86, green = 0.22, blue = 0.22, alpha = 1 },
  yellow = { red = 0.99, green = 0.88, blue = 0.55, alpha = 1 },
  gold   = { red = 0.98, green = 0.78, blue = 0.25, alpha = 1 },
  brown  = { red = 0.48, green = 0.31, blue = 0.19, alpha = 1 },
  blue   = { red = 0.45, green = 0.75, blue = 0.98, alpha = 1 },
  shadow = { red = 0, green = 0, blue = 0, alpha = 0.28 },
  bubble = { red = 1, green = 1, blue = 1, alpha = 0.95 },
  ink    = { red = 0.12, green = 0.12, blue = 0.13, alpha = 1 },
}
local TEXT_SHADOW = { offset = { h = -1, w = 0 }, blurRadius = 2, color = { red = 0, green = 0, blue = 0, alpha = 0.7 } }

-- What it does in each situation. eyes: track (follow mouse) | scan | down | ahead |
-- squint | happy | hearts | wide | sleepy | closed. "%s" in a line becomes the app name,
-- " {name}" becomes your name from config.lua (or nothing).
local MOODS = {
  idle       = { eyes = "track", body = "breathe", arms = "rest",
                 lines = { "Hi {name}!", "What are we up to?", "Ready when you are.", "Nice desktop.",
                           "I'm just gonna stand here.", "Psst. Got any tasks?", "Need a hand? I have two pixels." } },
  sleepy     = { eyes = "sleepy", body = "breathe", arms = "rest",
                 lines = { "It's getting late…", "*yawn*", "Bedtime soon?", "Burning the midnight oil?", "Five more minutes?" } },
  morning    = { eyes = "track", body = "breathe", arms = "rest", prop = "mug", emit = "steam",
                 lines = { "Morning! Coffee?", "Rise and shine!", "Big day today?", "Coffee first, code later.",
                           "Good morning {name}!", "Let's crush today." } },
  coding     = { eyes = "down", body = "type", arms = "type", prop = "laptop",
                 lines = { "Let's build.", "*clack clack clack*", "Terminal time!", "Ship it!", "Works on my machine!",
                           "Commit early, commit often.", "Hacker mode: on." } },
  claudeWork = { eyes = "down", body = "type", arms = "type", prop = "laptop", emit = "spark",
                 lines = { "Claude's cooking!", "Big brain time.", "Thinking, thinking…", "Go team!", "Tokens go brrr.",
                           "Don't rush genius.", "Claude's in the zone." } },
  claudeWait = { eyes = "track", body = "breathe", arms = "wave",
                 lines = { "Claude's done! Your turn.", "Waiting on you, boss.", "Ready for more!", "Your move {name}.",
                           "Ball's in your court." } },
  love       = { eyes = "hearts", body = "bounce", arms = "up", blush = true, emit = "heart",
                 lines = { "Ooh, Claude!", "My favourite app!", "Hey, that's family!", "Ah, the good AI.", "Home sweet home." } },
  jealous    = { eyes = "squint", body = "breathe", arms = "rest", mouth = "flat",
                 lines = { "Oh. Them.", "I can do that too…", "Hmph.", "Seeing other AIs?", "I'm right here, you know.",
                           "Fine. Ask them.", "I won't tell Claude." } },
  watching   = { eyes = "ahead", body = "breathe", arms = "rest", prop = "popcorn",
                 lines = { "Movie time!", "Pass the popcorn.", "Ooh, what's on?", "One more episode?", "No spoilers!",
                           "Is this research?" } },
  gaming     = { eyes = "down", body = "jitter", arms = "type", prop = "controller",
                 lines = { "Game on!", "Get 'em!", "Player two ready!", "Behind you!", "Just one more match.", "Press X to win." } },
  mail       = { eyes = "track", body = "breathe", arms = "rest", prop = "envelope",
                 lines = { "You've got mail!", "Anything good?", "Inbox time.", "Inbox zero or bust!", "Reply-all? Brave." } },
  chat       = { eyes = "happy", body = "breathe", arms = "wave",
                 lines = { "Who's texting?", "Say hi for me!", "Ooh, gossip?", "Typing… typing…", "Send a pixel heart!" } },
  reading    = { eyes = "ahead", body = "breathe", arms = "rest", glasses = true,
                 lines = { "Crunching numbers…", "Hmm, let me see.", "Very serious reading.", "Spreadsheet wizard!",
                           "Glasses on. Business mode." } },
  curious    = { eyes = "scan", body = "breathe", arms = "rest", emit = "question",
                 lines = { "What's in here?", "Looking for something?", "Ooh, files!", "So many folders.", "Lost something?" } },
  tinker     = { eyes = "down", body = "breathe", arms = "hold", prop = "wrench",
                 lines = { "Fixing things!", "Careful in there…", "Tweak, tweak.", "Don't break anything!",
                           "Off and on again?" } },
  browsing   = { eyes = "scan", body = "breathe", arms = "rest",
                 lines = { "Surfing the web!", "Find anything good?", "So many tabs…", "Research or rabbit hole?",
                           "Don't click that ad." } },
  snow       = { eyes = "track", body = "breathe", arms = "rest", prop = "shovel", emit = "snow",
                 lines = { "Snow day? Let's go!", "Shovels ready!", "Checking the forecast?", "Brr! Bundle up.", "How many cm?" } },
  proud      = { eyes = "happy", body = "bounce", arms = "up", blush = true, emit = "spark", -- point your own site at it in config.lua
                 lines = { "Hey, that's us!", "Looking sharp!", "Ooh, fancy.", "Best in the business!" } },
  music      = { eyes = "happy", body = "sway", arms = "up", emit = "note",
                 lines = { "Turn it up!", "Dance break!", "This one's a bop.", "Volume to eleven!", "I've got moves." } },
  home       = { eyes = "happy", body = "breathe", arms = "wave",
                 lines = { "That's where I live!", "Peeking at my code?", "Be nice to my code!" } },
  generic    = { eyes = "track", body = "breathe", arms = "rest",
                 lines = { "Ooh, %s!", "What's %s for?", "%s, huh?", "Never seen %s before.", "%s? Teach me!" } },
  worried    = { eyes = "wide", body = "jitter", arms = "up", mouth = "o", emit = "bang",
                 lines = { "Uh oh…", "That's not good.", "Yikes!", "Everything okay?" } },
  money      = { eyes = "happy", body = "bounce", arms = "up", blush = true, emit = "coin",
                 lines = { "Cha-ching!", "Money money money!", "Payday!", "Make it rain!" } },
  call       = { eyes = "wide", body = "jitter", arms = "hold", prop = "phone", emit = "bang",
                 lines = { "Ring ring!", "Phone's buzzing!", "Somebody wants you!" } },
  chatting   = { eyes = "happy", body = "breathe", arms = "rest", lines = {} }, -- the chat panel is open
  bored      = { eyes = "sleepy", body = "breathe", arms = "rest", mouth = "yawn",
                 lines = { "*yawn*", "Still there?", "Hello-o?", "I'll just wait here.", "Tap tap. Is this on?" } },
  sleep      = { eyes = "closed", body = "sleep", arms = "rest", emit = "z", lines = {} },
}

-- Short moves layered over the mood (clicks, waking up, idle fidgets, thinking).
local ACTIONS = {
  joy     = { eyes = "happy", body = "bounce", arms = "up", blush = true, emit = "heart" },
  startle = { eyes = "wide", mouth = "o", body = "hop", arms = "up" },
  hop     = { body = "hop" },
  wave    = { arms = "wave", eyes = "happy" },
  look    = { eyes = "scan" },
  stretch = { arms = "up", eyes = "closed", mouth = "yawn" },
  dance   = { body = "sway", arms = "up", eyes = "happy", emit = "note" },
  blush   = { eyes = "happy", blush = true },
  ponder  = { eyes = "scan", glasses = true, emit = "question" }, -- looking at your screen
  talk    = { mouth = "talk" },
  shaken  = { eyes = "dizzy", mouth = "o", arms = "up", body = "jitter", emit = "snow" }, -- a snow globe
  dizzy   = { eyes = "dizzy", mouth = "flat", arms = "rest", body = "sway", emit = "stars" },
  grumpy  = { eyes = "squint", mouth = "flat", arms = "rest", body = "breathe" },
}
local TRICKS = { { "hop", 0.7 }, { "wave", 1.6 }, { "look", 2.2 }, { "stretch", 1.4 }, { "dance", 2 }, { "blush", 1.5 } }
local CLICK_LINES = { "Hehe!", "Boop!", "Hi!", "That tickles!", "Need something?", "Right-click me for more!" }
local JOKES = {
  "Why do programmers like dark mode? Light attracts bugs.",
  "I told Codex a joke. It's still compiling.",
  "A SQL query walks into a bar and asks two tables: can I join you?",
  "I'd tell you a UDP joke, but you might not get it.",
  "Debugging: a crime movie where you're also the murderer.",
  "ChatGPT walked into a bar. It hallucinated the bartender.",
  "What's a pixel's favourite drink? Sprite.",
  "Why did the snowplow get promoted? Outstanding in its field.",
  "There's no place like 127.0.0.1.",
  "My diet is going well. I'm down to my last thousand tokens.",
}
local FRESH_LINES = { "Fresh session! Let's go!", "Usage reset. Clean slate!", "New session, who dis?" }
local SHAKE_LINES = { "Whoa whoa whoa!", "Earthquake!!", "Aaaah!", "I'm not a snow globe!", "Put me dowwwn!" }
local DIZZY_LINES = { "Everything's spinning…", "I see stars…", "Which way is up?", "Ugh, I'm gonna be sick.",
                      "Do that again. Kidding. Don't." }
local GRUMPY_LINES = { "Okay, that's enough shaking!", "Rude.", "I'm telling Claude.", "Shake the ChatGPT window instead." }

local EMIT = {
  heart    = { rate = 2.5, glyphs = { "♥" }, color = "pink", size = 13, from = "head", vy = -30, spread = 36, life = 1.3 },
  spark    = { rate = 2, glyphs = { "✦", "✧", "✶" }, color = "body", size = 12, from = "head", vy = -24, spread = 60, life = 1.2 },
  note     = { rate = 1.5, glyphs = { "♪", "♫" }, color = "white", size = 15, from = "head", vy = -26, spread = 50, life = 1.5 },
  z        = { rate = 0.6, glyphs = { "z" }, color = "white", size = 11, from = "side", vy = -12, vx = 7, spread = 0, life = 2.6, grow = 8 },
  snow     = { rate = 3, glyphs = { "❄", "•", "*" }, color = "white", size = 10, from = "sky", vy = 22, spread = 0, life = 5 },
  steam    = { rate = 1.2, glyphs = { "~" }, color = "white", size = 13, from = "mug", vy = -14, spread = 4, life = 1.2 },
  question = { rate = 0.35, glyphs = { "?" }, color = "white", size = 18, from = "head", vy = -12, spread = 30, life = 2 },
  coin     = { rate = 3, glyphs = { "$" }, color = "gold", size = 15, from = "head", vy = -30, spread = 50, life = 1.3 },
  bang     = { rate = 1.5, glyphs = { "!" }, color = "red", size = 17, from = "head", vy = -18, spread = 36, life = 1 },
  stars    = { rate = 4, glyphs = { "★", "✦", "✧" }, color = "yellow", size = 11, from = "head", vy = -8, spread = 80, life = 0.9 },
}

-- Which mood an app or window gets. Browser titles are checked in order; first match wins.
local TERMINALS = { ["com.apple.Terminal"] = true, ["com.mitchellh.ghostty"] = true,
                    ["com.googlecode.iterm2"] = true, ["dev.warp.Warp-Stable"] = true }
local TERMINAL_NAMES = { Terminal = true, Ghostty = true, iTerm2 = true, Warp = true } -- window-list owner names
local BROWSERS = { ["com.google.Chrome"] = true, ["com.apple.Safari"] = true, ["org.mozilla.firefox"] = true,
                   ["ru.yandex.desktop.yandex-browser"] = true, ["company.thebrowser.Browser"] = true }
local TITLE_RULES = {
  { "youtube", "watching" }, { "netflix", "watching" }, { "twitch", "watching" },
  { "gmail", "mail" }, { "inbox", "mail" }, { "outlook", "mail" },
  { "chatgpt", "jealous" }, { "grok", "jealous" }, { "gemini", "jealous" },
  { "claude", "love" },
  { "github", "coding" }, { "localhost", "coding" }, { "cloudflare", "coding" },
  { "google sheets", "reading" }, { "google docs", "reading" }, { "invoice", "reading" }, { ".pdf", "reading" },
  { "snow", "snow" }, { "weather", "snow" }, { "forecast", "snow" },
  { "spotify", "music" }, { "soundcloud", "music" },
}
local APPS = { -- bundle id or app name
  ["com.anthropic.claudefordesktop"] = "love",
  ["com.openai.codex"] = "jealous", ["com.openai.chat"] = "jealous", ["ChatGPT"] = "jealous",
  ["Grok"] = "jealous",
  ["Cursor"] = "coding", ["com.microsoft.VSCode"] = "coding", ["com.apple.dt.Xcode"] = "coding",
  ["Obsidian"] = "reading", ["LibreOffice"] = "reading", ["com.microsoft.Excel"] = "reading",
  ["com.apple.iWork.Numbers"] = "reading", ["com.apple.Preview"] = "reading",
  ["com.apple.MobileSMS"] = "chat", ["Telegram"] = "chat", ["com.apple.mail"] = "mail",
  ["com.apple.finder"] = "curious",
  ["com.apple.systempreferences"] = "tinker", ["Activity Monitor"] = "tinker", ["Stats"] = "tinker",
  ["Battle.net"] = "gaming", ["RemotePlay"] = "gaming", ["Steam"] = "gaming",
  ["Stremio"] = "watching", ["com.apple.TV"] = "watching", ["VLC"] = "watching", ["IINA"] = "watching",
  ["com.apple.Music"] = "music", ["Spotify"] = "music",
  [HAMMERSPOON] = "home",
}
-- Claude Code puts ✳ in the window title while it waits and a spinner while it works,
-- followed by the session's name.
local SPINNER = { "◐", "◓", "◑", "◒", "✢", "✶", "✻", "✽" }

-- Words in a Claude Code session's name -> extra lines for it. %t is the session name.
local SESSION_TOPICS = {
  { { "quote", "estimate", "bid", "pricing" }, { "Quote time. Let's make money!", "Price it right!", "%t. Cha-ching?" } },
  { { "invoice", "billing", "payment", "collections", "revenue" }, { "Money stuff! Love it.", "%t: show me the money!" } },
  { { "snow", "weather", "forecast", "storm" }, { "Snow talk! Shovels ready.", "%t: is it snowing yet?" } },
  { { "buddy", "widget", "hammerspoon" }, { "Hey, that's me you're working on!", "Make me cooler, please.", "Be gentle with my code!" } },
  { { "fix", "bug", "debug", "broken", "error", "crash" }, { "Bug hunt! Get it!", "Squash that bug!", "%t: who broke it?" } },
  { { "test", "eval", "verify", "audit", "review" }, { "Testing, testing…", "Fingers crossed on %t!" } },
  { { "website", "site", "seo", "landing" }, { "Making the website shine?", "%t: ooh, web stuff." } },
  { { "email", "gmail", "reply", "draft" }, { "Wording things nicely?", "%t: be polite!" } },
  { { "game", "ps5", "remote play", "steam", "xbox", "nintendo" }, { "Gaming research, huh?", "%t: for work, right?" } },
  { { "imessage", "sms", "texts", "whatsapp", "slack" }, { "Texting robots? Fancy.", "%t: keep those texts flowing." } },
  { { "voice", "phone", "call", "audio" }, { "Phone stuff! Say hi for me.", "%t: who's calling?" } },
  { { "plan", "design", "research", "brainstorm", "strategy" }, { "Big thinking on %t.", "Planning mode. Fancy." } },
}
local SESSION_LINES = {
  work = { "%t is still cooking.", "Back to %t? Claude's on it.", "Shh, Claude's thinking about %t." },
  wait = { "%t is waiting on you!", "Back to %t. Your move!", "Ah, %t. Where were we?" },
}
local DONE_LINES = { "%t is done!", "Psst, %t finished!", "%t is waiting on you." }
local DONE_LONG = { "%t finished after %m min!", "%m minutes later, %t is done!" }
local DONE_HERE = { "Done with %t! Your turn.", "%t is ready for you!", "Claude's done! Your move." }

-- config.lua additions: its title rules and session topics go first, its apps win over
-- everything, its lines replace built-ins.
local CFG_APPS = CFG.apps or {}
for i, r in ipairs(CFG.title_rules or {}) do table.insert(TITLE_RULES, i, r) end
for i, r in ipairs(CFG.session_topics or {}) do table.insert(SESSION_TOPICS, i, r) end
for k, v in pairs(CFG.lines or {}) do if MOODS[k] then MOODS[k].lines = v end end

local t0 = hs.timer.secondsSinceEpoch()
local mood, moodApp, lastPid = "idle", nil, nil
local action, actionStart, actionUntil = nil, 0, 0
local bubble, bubbleUntil, lastSaid, talkUntil = nil, 0, 0, 0
local particles, emitClock, lastEmit = {}, 0, nil
local nextBlink, blinkUntil, nextTrick = 0, 0, 0
local away = "active" -- active | bored | asleep
local lookAt, lookUntil, winCenter = nil, 0, nil
local lastUsageWarn, pinnedUntil, lastFrame, lastSig = 0, 0, nil, nil
local eventMood, eventUntil, mutedUntil, lastPct = nil, 0, 0, nil
local lastReal, lastWinId, winSince, lastPeek, lastDone = nil, nil, 0, 0, 0
local sessions, commented, peeked = {}, {}, {} -- Claude Code windows on screen; when it last spoke about each
local shakes = {} -- when it was shaken lately
local sizeCache = {}
local used = hs.settings.get(USED_KEY) or {}    -- seconds spent in each app, by bundle id
local taught = hs.settings.get(TAUGHT_KEY) or {} -- apps it already asked about
local unsaved = 0

local function now() return hs.timer.secondsSinceEpoch() end
local function pick(list) return list[math.random(#list)] end
local function literal(s) return (s:gsub("%%", "%%%%")) end

local function clip(s, n)
  local len = utf8.len(s)
  if not len or len <= n then return s end
  return s:sub(1, utf8.offset(s, n) - 1) .. "…"
end

-- " {name}" -> your name; %s -> the app; %t -> a session's name; %m -> minutes;
-- %f -> a file name; %1..%9 -> an event's details.
local function fill(line, appName, vars)
  vars = vars or {}
  line = line:gsub(" {name}", literal(NAME ~= "" and " " .. NAME or ""))
  return (line:gsub("%%([stfm%d])", function(k)
    if k == "s" then return appName or "this" end
    if k == "t" then return vars.t or "this one" end
    if k == "m" then return vars.m or "a few" end
    if k == "f" then return vars.f or "it" end
    local v = vars[tonumber(k)]
    return v and (tostring(v):gsub("^%l", string.upper)) or ""
  end))
end

local function wrap(text)
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    if cur == "" then cur = word
    elseif (utf8.len(cur) or #cur) + 1 + (utf8.len(word) or #word) <= WRAP then cur = cur .. " " .. word
    else lines[#lines + 1] = cur; cur = word end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  if #lines > 4 then lines = { lines[1], lines[2], lines[3], lines[4] .. "…" } end
  return table.concat(lines, "\n")
end

local function lineFor(m, appName)
  local spec = MOODS[m]
  if m == "idle" then
    local h = os.date("*t").hour
    if h >= 23 or h < 5 then spec = MOODS.sleepy elseif h < 10 then spec = MOODS.morning end
  end
  if not spec or #spec.lines == 0 then return nil end
  return fill(pick(spec.lines), appName)
end

-- force: true skips the gap between lines; "user" (you asked) also talks while muted.
local function say(text, force)
  local t = now()
  if not text or text == "" then return end
  if force ~= "user" and t < mutedUntil then return end
  if not force and (QUIET_FOR < 0 or t - lastSaid < QUIET_FOR) then return end
  bubble, lastSaid = wrap(text), t
  bubbleUntil = t + math.min(SAY_MAX, math.max(SAY_MIN, #text * 0.075))
  talkUntil = t + math.min(2.5, #text * 0.05)
  Chat.said(text)
end

local function doAction(name, dur)
  local t = now()
  action, actionStart, actionUntil = name, t, t + dur
end

local function setMood(m, appName, quiet)
  local changed = m ~= mood or (m == "generic" and appName ~= moodApp)
  mood, moodApp = m, appName
  if changed then
    if not quiet then say(lineFor(m, appName)) end
    if m == "love" or m == "proud" or m == "claudeWait" then doAction("hop", 0.7) end
  end
end

-- Claude Code's title: a spinner (working) or ✳ (waiting), then the session's name.
-- Terminal.app wraps it as "folder — ◐ Name — claude — 80×24".
local function claudeTitle(title)
  local state, rest
  local _, j = title:find("✳", 1, true)
  if j then state, rest = "wait", title:sub(j + 1) end
  if not state then
    for _, g in ipairs(SPINNER) do
      _, j = title:find(g, 1, true)
      if j then state, rest = "work", title:sub(j + 1); break end
    end
  end
  if not state then return nil end
  local topic = rest:match("^%s*(.-)%s+— ") or rest:match("^%s*(.-)%s*$")
  return state, topic ~= "" and topic or "Claude Code"
end

local function sessionLine(s)
  local l, pool = s.topic:lower(), {}
  for _, rule in ipairs(SESSION_TOPICS) do
    for _, w in ipairs(rule[1]) do
      if l:find(w, 1, true) then
        for _, x in ipairs(rule[2]) do pool[#pool + 1] = x end
        break
      end
    end
  end
  for _, x in ipairs(SESSION_LINES[s.state]) do pool[#pool + 1] = x end
  local mins = s.workSince and math.floor((now() - s.workSince) / 60) or 0
  if s.state == "work" and mins >= 5 then pool[#pool + 1] = "%t: %m min and counting!" end
  return fill(pick(pool), nil, { t = clip(s.topic, 26), m = tostring(mins) })
end

local function sessionDone(s, here, secs)
  local t = now()
  local vars = { t = clip(s.topic, 26), m = tostring(math.floor(secs / 60)) }
  if here then return say(fill(pick(DONE_HERE), nil, vars), true) end
  if t - lastDone < 15 then return end
  lastDone = t
  doAction("wave", 2)
  say(fill(pick(secs >= 180 and DONE_LONG or DONE_LINES), nil, vars), true)
end

-- One pass over the window list: the front window (title, centre, id) and every
-- Claude Code session on screen, noticing when one finishes.
local function scanWindows(app)
  local pid, t = app and app:pid(), now()
  local front, alive, finished = nil, {}, {}
  for _, w in ipairs(hs.window.list(false) or {}) do
    local b = w.kCGWindowBounds
    if w.kCGWindowLayer == 0 and b and b.Width > 80 and b.Height > 80 then
      if not front and w.kCGWindowOwnerPID == pid then
        front = { title = w.kCGWindowName or "", center = { x = b.X + b.Width / 2, y = b.Y + b.Height / 2 }, id = w.kCGWindowNumber }
      end
      if TERMINAL_NAMES[w.kCGWindowOwnerName] then
        local state, topic = claudeTitle(w.kCGWindowName or "")
        if state then
          local id = w.kCGWindowNumber
          local s = sessions[id]
          alive[id] = true
          if not s then
            sessions[id] = { topic = topic, state = state, workSince = state == "work" and t or nil }
          else
            if s.state == "work" and state == "wait" and s.workSince then finished[#finished + 1] = { s = s, id = id, secs = t - s.workSince } end
            if s.state ~= state then s.workSince = state == "work" and t or nil end
            s.state, s.topic = state, topic
          end
        end
      end
    end
  end
  for id in pairs(sessions) do if not alive[id] then sessions[id] = nil end end
  for _, f in ipairs(finished) do sessionDone(f.s, front and front.id == f.id, f.secs) end
  return front
end

-- The built-in reaction for an app, before config.lua and window titles (the wizard shows it).
local function builtinMood(bid, name)
  if TERMINALS[bid] then return "coding" end
  if BROWSERS[bid] then return "browsing" end
  local m = APPS[bid] or APPS[name]
  if m then return m end
  local lname = (name or ""):lower()
  if lname:find("chiaki", 1, true) or lname:find("remote play", 1, true) then return "gaming" end
  return "generic"
end

local function classify(app, title)
  local bid, name = app:bundleID() or "", app:name() or ""
  local lname, ltitle = name:lower(), title:lower()
  if bid == HAMMERSPOON then -- the chat panel, or nothing at all after a panel closes
    if Chat.isOpen() then return "chatting" end
    if title == "" then return mood end
  end
  if CFG_APPS[bid] or CFG_APPS[name] then return CFG_APPS[bid] or CFG_APPS[name] end
  if TERMINALS[bid] then
    local state = claudeTitle(title)
    if state then return state == "wait" and "claudeWait" or "claudeWork" end
    return "coding"
  end
  if BROWSERS[bid] then
    for _, r in ipairs(TITLE_RULES) do
      if ltitle:find(r[1], 1, true) then return r[2] end
    end
    return "browsing"
  end
  if bid == "com.apple.finder" and title == "" then return "idle" end -- clicked the desktop
  if APPS[bid] or APPS[name] then return APPS[bid] or APPS[name] end
  if lname:find("chiaki", 1, true) or lname:find("remote play", 1, true) then return "gaming" end
  return "generic"
end

local function usageData() return ClaudeUsage and ClaudeUsage.current and ClaudeUsage.current() end

-- Current-session percentage from the usage card, or nil before it has numbers.
local function sessionPct()
  local d = usageData()
  for _, l in ipairs(d and d.limits or {}) do
    if l.label == "Current session" then return l.pct end
  end
  return nil
end

-- The brain ---------------------------------------------------------------------

-- Look at the window you're in and say something about it. byUser: you asked, so it
-- explains when it can't. Returns true when a request went out.
local function peek(kind, byUser)
  local t, w = now(), lastReal
  if not Brain or Brain.busy() then return false end
  if not byUser and (QUIET_FOR < 0 or t < mutedUntil) then return false end
  if not (w and w.id) then
    if byUser then say("I can't see a window right now.", "user") end
    return false
  end
  if Brain.private(w.app, w.title) then
    if byUser then say("That looks private. Not peeking!", "user") end
    return false
  end
  lastPeek = t
  doAction("ponder", 8)
  return Brain.quip({ kind = kind or "screen", app = w.app, title = w.title, winId = w.id }, function(line)
    if action == "ponder" then action = nil end
    if not line then
      if byUser then say("My brain's not answering. Is Ollama running?", "user") end
    elseif byUser or (lastReal and lastReal.id == w.id) then -- skip it if you've moved on
      say(line, byUser and "user" or true)
    end
  end)
end

-- Something about the Claude Code session you just clicked into (once per 4 min each;
-- false when it's too soon).
local function sessionComment(s)
  local t = now()
  if commented[s.topic] and t - commented[s.topic] < 240 then return false end
  commented[s.topic] = t
  if Brain and not Brain.busy() and QUIET_FOR >= 0 and t >= mutedUntil then
    local topic = s.topic
    doAction("look", 3)
    local mins = s.workSince and math.floor((t - s.workSince) / 60) or nil
    Brain.quip({ kind = "session", topic = topic, state = s.state, mins = mins }, function(line)
      local cur = lastWinId and sessions[lastWinId]
      if cur and cur.topic == topic then say(line or sessionLine(cur), true) end
    end)
  else
    say(sessionLine(s), true)
  end
  return true
end

-- Quiet for a while: pipe up with a look at the screen, a session update or a mood line.
local function ambient(t, bid)
  lastSaid = t -- whatever happens, wait another round
  if Brain and PEEK_EVERY > 0 and t - lastPeek >= PEEK_EVERY and bid ~= HAMMERSPOON and peek("screen") then return end
  local s = lastWinId and sessions[lastWinId]
  if s and math.random() < 0.6 then return say(sessionLine(s), true) end
  local working = 0
  for _, x in pairs(sessions) do if x.state == "work" then working = working + 1 end end
  if working >= 2 and math.random() < 0.4 then return say(working .. " Claudes cooking at once!", true) end
  say(lineFor(mood, moodApp), true)
end

local function tellJoke()
  local w = lastReal or {}
  doAction("blush", 1.5)
  if Brain and not Brain.private(w.app, w.title) and Brain.quip({ kind = "joke", app = w.app, title = w.title, winId = w.id },
      function(line) say(line or pick(JOKES), "user") end) then
    return doAction("ponder", 6)
  end
  say(pick(JOKES), "user")
end

local function openChat()
  if not Brain then return say("I need a brain to chat. See config.example.lua.", "user") end
  local w = lastReal or {}
  Chat.open({
    dir = DIR, anchor = function() return M.canvas:frame() end, title = w.app,
    -- each message looks at the window you were in last (the panel itself doesn't count)
    ask = function(history, done) Brain.chat(history, lastReal or {}, done) end,
    opener = function(done)
      local cur = lastReal or {}
      if not Brain.quip({ kind = "screen", app = cur.app, title = cur.title, winId = cur.id }, done) then
        done(pick({ "Hey! What's up?", "Oh hi! What are we looking at?", "You rang?" }))
      end
    end,
    onReply = function() doAction("talk", 2.5) end,
    remember = Brain.remember,
    dictation = AI.dictation,
  })
end

-- Menu and actions ----------------------------------------------------------------

local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- A new Terminal window running Claude Code in dir (home by default). A throwaway
-- .command file needs no Automation permission, unlike AppleScript.
local function newSession(dir)
  dir = dir or HOME
  local tmp = hs.fs.temporaryDirectory() or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  local path = string.format("%sclaude-buddy-%d.command", tmp, math.floor(now() * 1000))
  local f = io.open(path, "w")
  if not f then return say("Couldn't open a terminal. Hmm.", "user") end
  f:write("#!/bin/zsh\nrm -f ", shq(path), "\ncd ", shq(dir), " || exit 1\n",
    "command -v claude >/dev/null && exec claude\nexec \"$HOME/.local/bin/claude\"\n")
  f:close()
  hs.execute("chmod +x " .. shq(path))
  hs.task.new("/usr/bin/open", nil, { "-a", TERMINAL_APP, path }):start()
  doAction("joy", 1.6)
  say(pick({ "New Claude, coming up!", "Spinning up a fresh Claude!", "Fresh session. Let's go!" }), "user")
end

-- Folders for "New Claude Code session in…": config.lua `projects`, or the most
-- recently touched folders in ~/dev, ~/Projects, ~/code or ~/src.
local function projectDirs()
  local list = {}
  for _, d in ipairs(CFG.projects or {}) do list[#list + 1] = { path = (d:gsub("^~", HOME)) } end
  if #list == 0 then
    for _, root in ipairs({ HOME .. "/dev", HOME .. "/Projects", HOME .. "/code", HOME .. "/src" }) do
      if hs.fs.attributes(root, "mode") == "directory" then
        for name in hs.fs.dir(root) do
          local p = root .. "/" .. name
          if not name:find("^%.") and hs.fs.attributes(p, "mode") == "directory" then
            list[#list + 1] = { path = p, t = hs.fs.attributes(p, "modification") or 0 }
          end
        end
      end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
  end
  local out = {}
  for i = 1, math.min(10, #list) do out[i] = list[i].path end
  return out
end

local function sessionReport()
  local work, wait, waiting = 0, 0, {}
  for _, s in pairs(sessions) do
    if s.state == "work" then work = work + 1 else wait = wait + 1; waiting[#waiting + 1] = clip(s.topic, 22) end
  end
  if work + wait == 0 then return say("No Claude Code sessions on screen.", "user") end
  local text = string.format("%d cooking, %d waiting on you.", work, wait)
  if #waiting > 0 then text = text .. " Waiting: " .. table.concat(waiting, ", ", 1, math.min(2, #waiting)) end
  say(text, "user")
end

local function usageReport()
  local d, parts = usageData(), {}
  for _, l in ipairs(d and d.limits or {}) do
    if l.label == "Current session" then parts[#parts + 1] = string.format("Session %d%%", math.floor(l.pct + 0.5))
    elseif l.label == "Week · all models" then parts[#parts + 1] = string.format("week %d%%", math.floor(l.pct + 0.5)) end
  end
  if #parts == 0 then return say("I can't see your usage right now.", "user") end
  local pct = sessionPct() or 0
  say(table.concat(parts, ", ") .. "." .. (pct >= 80 and " Running hot!" or pct >= 50 and " Halfway there." or " Plenty left!"), "user")
end

local function toggleMute()
  if now() < mutedUntil then
    mutedUntil = 0
    say("I'm back! Did you miss me?", "user")
  else
    say("Okay, quiet for an hour. Shh.", "user")
    mutedUntil = now() + 3600
  end
end

local function showMenu()
  local sub = { { title = "Home folder", fn = function() newSession(HOME) end } }
  for _, p in ipairs(projectDirs()) do
    sub[#sub + 1] = { title = p:match("([^/]+)$"), fn = function() newSession(p) end }
  end
  local items = {}
  if Brain then
    items[#items + 1] = { title = "Chat with me", fn = openChat }
    items[#items + 1] = { title = "What do you see?", fn = function() peek("screen", true) end }
  end
  items[#items + 1] = { title = "Tell me a joke", fn = tellJoke }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "New Claude Code session", menu = sub }
  items[#items + 1] = { title = "How are my Claude sessions?", fn = sessionReport }
  items[#items + 1] = { title = "How's my usage?", fn = usageReport }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = now() < mutedUntil and "Talk again" or "Quiet for an hour", fn = toggleMute }
  items[#items + 1] = { title = "Setup…", fn = function() M.setup() end }
  M.menu = M.menu or hs.menubar.new(false)
  M.menu:setMenu(items)
  M.menu:popupMenu(hs.mouse.absolutePosition(), true)
end

-- An event from events.lua: show its mood for a few seconds and say one of its lines
-- (or, with `ai` on the event and a brain, a line made up about it).
local function react(ev)
  local t = now()
  if away == "asleep" then return end
  if MOODS[ev.mood] then eventMood, eventUntil = ev.mood, t + EVENT_FOR
  elseif ACTIONS[ev.mood] then doAction(ev.mood, 1.6) end
  if QUIET_FOR < 0 then return end
  local vars = { f = ev.file }
  for i, c in ipairs(ev.caps or {}) do vars[i] = c end
  local line = ev.lines and #ev.lines > 0 and fill(pick(ev.lines), nil, vars) or nil
  if ev.ai and Brain and not Brain.busy() and t >= mutedUntil then
    local ok = Brain.quip({ kind = "event", what = fill(ev.ai, nil, vars) }, function(made) say(made or line, true) end)
    if ok then return end
  end
  say(line, true)
end

local function currentSpec(t)
  local base
  if away == "asleep" then base = MOODS.sleep
  elseif away == "bored" then base = MOODS.bored
  elseif t < eventUntil and MOODS[eventMood] then base = MOODS[eventMood]
  else
    base = MOODS[mood] or MOODS.idle
    if mood == "idle" then
      local h = os.date("*t").hour
      if h >= 23 or h < 5 then base = MOODS.sleepy elseif h < 10 then base = MOODS.morning end
    end
  end
  local spec = {}
  for k, v in pairs(base) do spec[k] = v end
  if action and t < actionUntil then
    for k, v in pairs(ACTIONS[action]) do spec[k] = v end
  else
    action = nil
  end
  spec.sweat = (sessionPct() or 0) >= 80
  return spec
end

local function poll()
  local t = now()
  if t < pinnedUntil then return end

  local idle = hs.host.idleTime()
  if SLEEP_AFTER > 0 and idle >= SLEEP_AFTER then
    away = "asleep"
  elseif idle >= BORED_AFTER then
    if away == "active" then say(lineFor("bored")) end
    if away ~= "asleep" then away = "bored" end
  elseif away ~= "active" then
    if away == "asleep" then
      doAction("startle", 1.2)
      say(pick({ "Oh! You're back!", "Wha—? I was awake!", "Welcome back!" }), true)
    end
    away = "active"
  end

  local app = hs.application.frontmostApplication()
  local bid = app and app:bundleID() or ""
  if app then
    local win = scanWindows(app) or { title = "" }
    local title = win.title
    if win.center then winCenter = win.center end
    if app:pid() ~= lastPid then lookAt, lookUntil = win.center, t + 1.5 end
    lastPid = app:pid()
    if bid ~= HAMMERSPOON then -- remember the last real window, for looks and chat
      if not lastReal or lastReal.id ~= win.id or lastReal.title ~= title then winSince = t end
      lastReal = { id = win.id, app = app:name(), title = title }
    end
    local sess = win.id and sessions[win.id]
    local entered = sess and win.id ~= lastWinId
    if bid ~= HAMMERSPOON then lastWinId = win.id end
    setMood(classify(app, title), app:name(), entered)
    if entered and away == "active" and not sessionComment(sess) then say(lineFor(mood, app:name())) end

    -- learn which apps you live in; ask to be taught about busy ones it doesn't know
    if bid ~= "" and away == "active" then
      used[bid] = (used[bid] or 0) + 1
      unsaved = unsaved + 1
      if unsaved >= 60 then unsaved = 0; hs.settings.set(USED_KEY, used) end
      if mood == "generic" and used[bid] >= TEACH_AFTER and not taught[bid] then
        taught[bid] = true
        hs.settings.set(TAUGHT_KEY, taught)
        say(fill("You use %s a lot! Option-click me to teach me.", app:name()), true)
      end
    end

    -- a window it doesn't know: have a look after a few seconds (once per 20 min each)
    if Brain and AI.unknown ~= false and away == "active" and (mood == "generic" or mood == "browsing")
        and t - winSince >= 6 and t - lastPeek >= 30 and lastReal then
      local key = (lastReal.app or "") .. "|" .. (lastReal.title or "")
      if (not peeked[key] or t - peeked[key] > 1200) and peek("screen") then peeked[key] = t end
    end
  end

  local pct = sessionPct()
  if pct then
    if lastPct and lastPct >= 20 and pct < 3 then doAction("joy", 1.6); say(pick(FRESH_LINES), true) end
    if lastPct and lastPct < 50 and pct >= 50 then say("Half the session's used. Pace yourself!", true) end
    lastPct = pct
    if pct >= 95 and t - lastUsageWarn > 1800 then
      lastUsageWarn = t
      say("We're almost out of Claude!", true)
    end
  end

  if away == "active" and AMBIENT_EVERY > 0 and t - lastSaid > AMBIENT_EVERY and not Chat.isOpen() then
    ambient(t, bid)
  end

  if away == "active" and not action and t > nextTrick then
    nextTrick = t + 12 + math.random() * 18
    local calm = { idle = 1, browsing = 1, generic = 1, reading = 1, mail = 1, watching = 1, chatting = 1 }
    if calm[mood] then
      local trick = pick(TRICKS)
      doAction(trick[1], trick[2])
    end
  end
end

-- Drawing -----------------------------------------------------------------------

local function withAlpha(c, a)
  return { red = c.red, green = c.green, blue = c.blue, alpha = (c.alpha or 1) * a }
end

local function styled(s, size, color, font, align)
  return hs.styledtext.new(s, { font = { name = font or BOLD, size = size }, color = color,
    paragraphStyle = { alignment = align or "center" }, shadow = TEXT_SHADOW })
end

local function bodyOffset(kind, t)
  if kind == "breathe" then return 0, math.floor(math.sin(t * 2.2) * 1.5 + 0.5) end
  if kind == "bounce" then return 0, -math.floor(math.abs(math.sin(t * 7)) * 10) end
  if kind == "type" then return 0, math.floor(t * 10) % 2 end
  if kind == "sway" then return math.floor(math.sin(t * 4) * 5 + 0.5), -math.floor(math.abs(math.sin(t * 8)) * 3) end
  if kind == "jitter" then return (math.floor(t * 14) % 2 == 0) and -1 or 1, 0 end
  if kind == "sleep" then return 0, 2 + math.floor(math.sin(t * 1.2) * 1.5 + 0.5) end
  if kind == "hop" then
    local p = (now() - actionStart) / math.max(actionUntil - actionStart, 0.1)
    return 0, -math.floor(math.sin(math.min(p, 1) * math.pi) * 14)
  end
  return 0, 0
end

local function drawEyes(px, kind, dx, dy, blinking, spin)
  local open = { track = true, scan = true, down = true, ahead = true }
  if blinking and (open[kind] or kind == "squint") then
    px(3 + dx, 4 + dy, 2, 1, C.eye); px(9 + dx, 4 + dy, 2, 1, C.eye)
  elseif open[kind] then
    for _, c in ipairs({ 3, 9 }) do
      px(c + dx, 3 + dy, 2, 3, C.eye)
      px(c + dx, 3 + dy, 1, 1, C.white)
    end
  elseif kind == "squint" then
    px(3 + dx, 4, 2, 1, C.eye); px(9 + dx, 4, 2, 1, C.eye)
  elseif kind == "closed" then
    px(3, 5, 2, 1, C.eye); px(9, 5, 2, 1, C.eye)
  elseif kind == "sleepy" then
    px(3 + dx, 4, 2, 2, C.eye); px(9 + dx, 4, 2, 2, C.eye)
  elseif kind == "wide" then
    for _, c in ipairs({ 3, 9 }) do px(c, 2, 2, 4, C.eye); px(c, 2, 1, 1, C.white) end
  elseif kind == "happy" then
    for _, o in ipairs({ 0, 6 }) do
      px(2 + o, 4, 1, 1, C.eye); px(3 + o, 3, 2, 1, C.eye); px(5 + o, 4, 1, 1, C.eye)
    end
  elseif kind == "hearts" then
    for _, o in ipairs({ 1, 8 }) do
      px(o + 1, 2, 1, 1, C.pink); px(o + 3, 2, 1, 1, C.pink)
      px(o, 3, 5, 1, C.pink); px(o + 1, 4, 3, 1, C.pink); px(o + 2, 5, 1, 1, C.pink)
    end
  elseif kind == "dizzy" then -- an X and a + taking turns, so the eyes look like they spin
    for _, c in ipairs({ 2, 8 }) do
      if spin % 2 == 0 then
        px(c, 3, 1, 1, C.eye); px(c + 2, 3, 1, 1, C.eye); px(c + 1, 4, 1, 1, C.eye)
        px(c, 5, 1, 1, C.eye); px(c + 2, 5, 1, 1, C.eye)
      else
        px(c + 1, 3, 1, 3, C.eye); px(c, 4, 3, 1, C.eye)
      end
    end
  end
end

local function drawArms(px, kind, f)
  if kind == "up" then
    local hand = 2 - f % 2
    px(-1, 4, 1, 1, C.body); px(-2, 3, 1, 1, C.body); px(-2, hand, 1, 1, C.body)
    px(14, 4, 1, 1, C.body); px(15, 3, 1, 1, C.body); px(15, hand, 1, 1, C.body)
  elseif kind == "wave" then
    px(-1, 5, 1, 2, C.body)
    px(14, 4, 1, 1, C.body); px(15, 3, 1, 1, C.body); px(15 + f % 2, 2, 1, 1, C.body)
  elseif kind == "type" then
    px(-1, 5 + f % 2, 1, 2, C.body); px(14, 6 - f % 2, 1, 2, C.body)
  elseif kind == "hold" then
    px(-1, 5, 1, 2, C.body); px(14, 6, 1, 1, C.body); px(15, 7, 1, 1, C.body)
  else
    px(-1, 5, 1, 2, C.body); px(14, 5, 1, 2, C.body)
  end
end

local PROPS = {
  laptop = function(px)
    px(2, 6, 10, 4, C.grey); px(1, 10, 12, 1, C.dark); px(6, 7, 2, 2, C.white)
  end,
  popcorn = function(px)
    px(15, 6, 3, 4, C.white); px(15, 6, 1, 4, C.red); px(17, 6, 1, 4, C.red)
    px(15, 4, 3, 2, C.yellow); px(16, 3, 1, 1, C.yellow)
  end,
  controller = function(px, f)
    px(3, 7, 8, 3, C.dark); px(2, 8, 1, 3, C.dark); px(11, 8, 1, 3, C.dark)
    px(4, 8, 1, 1, C.grey); px(9, 8 - f % 2, 1, 1, C.red); px(8, 7 + f % 2, 1, 1, C.blue)
  end,
  mug = function(px)
    px(15, 6, 3, 4, C.white); px(18, 7, 1, 2, C.white); px(15, 6, 3, 1, C.brown)
  end,
  envelope = function(px)
    px(15, 3, 5, 4, C.white)
    for i, r in ipairs({ 3, 4, 5, 4, 3 }) do px(14 + i, r, 1, 1, C.grey) end
  end,
  wrench = function(px, f)
    local y = f % 2
    px(17, 3 + y, 1, 2, C.grey); px(19, 3 + y, 1, 2, C.grey); px(18, 4 + y, 1, 1, C.grey)
    px(18, 5 + y, 1, 1, C.grey); px(17, 6 + y, 1, 1, C.grey); px(16, 7 + y, 1, 1, C.grey)
  end,
  shovel = function(px)
    px(15, -1, 3, 1, C.brown); px(16, 0, 1, 9, C.brown); px(15, 9, 3, 3, C.grey)
  end,
  phone = function(px, f)
    px(15, 2 - f % 2, 2, 5, C.dark); px(15, 3 - f % 2, 2, 2, C.blue)
  end,
}

local function spawn(e, ox, oy, cx)
  local x, y
  if e.from == "head" then x, y = cx + (math.random() - 0.5) * e.spread, oy - 4
  elseif e.from == "side" then x, y = ox + 14 * S + 6, oy + 6
  elseif e.from == "sky" then x, y = math.random(8, W - 8), 4
  else x, y = ox + 16.5 * S + (math.random() - 0.5) * e.spread, oy + 4 * S end
  if #particles < 16 then
    particles[#particles + 1] = { ch = pick(e.glyphs), color = C[e.color], size = e.size, grow = e.grow or 0,
      x = x, y = y, vx = (e.vx or 0) + (math.random() - 0.5) * 8, vy = e.vy, age = 0, life = e.life }
  end
end

local function frame()
  if not M.canvas then return end
  local t = now()
  local dt = math.min(t - (lastFrame or t), 0.25)
  lastFrame = t
  local spec = currentSpec(t)
  local at = t - t0
  local f = math.floor(at * 6)

  local bx, by = bodyOffset(spec.body, at)
  local ox, oy = math.floor((W - 14 * S) / 2) + bx, BODY_TOP + by
  local cx = ox + 7 * S

  local els, sig = {}, {}
  local function px(c, r, w, h, color, track)
    local fr = { x = ox + c * S, y = oy + r * S, w = w * S, h = h * S }
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = color, frame = fr, trackMouseDown = track }
    sig[#sig + 1] = fr.x .. "," .. fr.y .. "," .. fr.w .. "," .. fr.h .. tostring(color)
  end

  -- shadow on the ground shrinks as it jumps
  local lift = math.max(0, -by)
  els[#els + 1] = { type = "oval", action = "fill", fillColor = C.shadow,
    frame = { x = cx - (36 - lift), y = GROUND - 3, w = 2 * (36 - lift), h = 7 } }
  sig[#sig + 1] = "s" .. lift

  -- legs (alternate when dancing), body, face
  for i, c in ipairs({ 2, 4, 9, 11 }) do
    local up = spec.body == "sway" and ((i + f) % 2 == 0) and 1 or 0
    px(c, 10, 1, 2 - up, C.shade)
  end
  px(1, 0, 12, 10, C.body, true); px(0, 1, 1, 8, C.body, true); px(13, 1, 1, 8, C.body, true)
  px(1, 9, 12, 1, C.shade); px(2, 1, 2, 1, C.shine)
  if spec.blush then px(1, 6, 2, 1, C.blush); px(11, 6, 2, 1, C.blush) end

  if t > nextBlink then blinkUntil, nextBlink = t + 0.14, t + 2.5 + math.random() * 4 end
  local dx, dy = 0, 0
  if spec.eyes == "track" or spec.eyes == "down" then
    local tl = M.canvas:topLeft()
    local target = (t < lookUntil and lookAt) or hs.mouse.absolutePosition()
    local ex, ey = target.x - (tl.x + cx), target.y - (tl.y + oy + 4 * S)
    dx = math.abs(ex) > 60 and (ex > 0 and 1 or -1) or 0
    dy = spec.eyes == "down" and 1 or (math.abs(ey) > 80 and (ey > 0 and 1 or -1) or 0)
  elseif spec.eyes == "scan" then
    dx = math.max(-1, math.min(1, math.floor(math.sin(at * 1.6) * 1.5 + 0.5)))
  elseif spec.eyes == "squint" and winCenter then
    dx = winCenter.x > M.canvas:topLeft().x + cx and 1 or -1
  end
  drawEyes(px, spec.eyes, dx, dy, t < blinkUntil, math.floor(at * 10))

  -- mouth; it moves while a line is being said
  local talking = spec.mouth == "talk" or (not spec.mouth and t < talkUntil and spec.eyes ~= "closed")
  if talking then
    if f % 2 == 0 then px(6, 7, 2, 2, C.eye) else px(6, 8, 2, 1, C.eye) end
  elseif spec.mouth == "o" then px(6, 7, 2, 2, C.eye)
  elseif spec.mouth == "flat" then px(6, 8, 2, 1, C.eye)
  elseif spec.mouth == "yawn" and at % 6 < 2 then px(6, 7, 2, 2 + f % 2, C.eye)
  elseif spec.eyes == "happy" or spec.eyes == "hearts" then
    px(5, 7, 1, 1, C.eye); px(6, 8, 2, 1, C.eye); px(8, 7, 1, 1, C.eye)
  end
  if spec.glasses then
    for _, c in ipairs({ 2, 8 }) do
      px(c, 2, 4, 1, C.dark); px(c, 6, 4, 1, C.dark); px(c, 2, 1, 5, C.dark); px(c + 3, 2, 1, 5, C.dark)
    end
    px(6, 3, 2, 1, C.dark)
  end
  if spec.sweat then
    local drip = math.floor(at * 1.5) % 3
    px(15, drip, 1, 1, C.blue); px(14, 1 + drip, 2, 1, C.blue)
  end

  drawArms(px, spec.arms, f)
  if spec.prop and PROPS[spec.prop] then PROPS[spec.prop](px, f) end

  -- floating particles
  local e = EMIT[spec.emit]
  if spec.emit ~= lastEmit then emitClock, lastEmit = 0, spec.emit end
  if e and away ~= "bored" then
    emitClock = emitClock + dt * e.rate
    while emitClock >= 1 do emitClock = emitClock - 1; spawn(e, ox, oy, cx) end
  end
  local alive = {}
  for _, p in ipairs(particles) do
    p.age = p.age + dt
    if p.age < p.life then
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      local a = 1 - p.age / p.life
      local size = p.size + p.grow * (p.age / p.life)
      els[#els + 1] = { type = "text", text = styled(p.ch, size, withAlpha(p.color, a)),
        frame = { x = math.floor(p.x - 12), y = math.floor(p.y - 12), w = 24, h = 26 } }
      sig[#sig + 1] = p.ch .. math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. math.floor(a * 10)
      alive[#alive + 1] = p
    end
  end
  particles = alive

  -- speech bubble
  if bubble and t > bubbleUntil then bubble = nil end
  if bubble then
    local st = styled(bubble, 11.5, C.ink, FONT)
    local size = sizeCache[bubble] or hs.drawing.getTextDrawingSize(st)
    sizeCache[bubble] = size
    local bw, bh = math.min(W - 6, math.ceil(size.w) + 18), math.ceil(size.h) + 10
    local bxp = math.max(3, math.min(W - bw - 3, cx - bw / 2))
    local byp = math.max(2, BODY_TOP - bh - 22)
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.bubble,
      roundedRectRadii = { xRadius = 9, yRadius = 9 }, frame = { x = bxp, y = byp, w = bw, h = bh } }
    els[#els + 1] = { type = "segments", action = "fill", fillColor = C.bubble, closed = true, coordinates = {
      { x = cx - 6, y = byp + bh - 1 }, { x = cx + 6, y = byp + bh - 1 }, { x = cx - 1, y = byp + bh + 8 } } }
    els[#els + 1] = { type = "text", text = st, frame = { x = bxp + 4, y = byp + 5, w = bw - 8, h = bh - 6 } }
    sig[#sig + 1] = "b" .. bubble
  end

  local key = table.concat(sig, "|")
  if key ~= lastSig then
    lastSig = key
    M.canvas:replaceElements(els)
  end
end

-- Placement and mouse ------------------------------------------------------------

local function onAScreen(p)
  for _, s in ipairs(hs.screen.allScreens()) do
    local fr = s:frame()
    if p.x >= fr.x - 40 and p.x < fr.x + fr.w - 60 and p.y >= fr.y - 40 and p.y < fr.y + fr.h - 60 then return true end
  end
  return false
end

-- Saved spot if its screen is connected; otherwise beside the usage card.
local function place()
  local p = hs.settings.get(POS_KEY)
  if not (p and onAScreen(p)) then
    local card = ClaudeUsage and ClaudeUsage.canvas and ClaudeUsage.canvas:topLeft()
    if card then
      p = { x = card.x + 264, y = card.y + 96 }
    else
      local fr = hs.screen.primaryScreen():frame()
      p = { x = fr.x + 24, y = fr.y + 24 }
    end
  end
  M.canvas:topLeft(p)
end

-- One axis of mouse movement: true each time it turns back at least `min` points from
-- the furthest it got. Four turns inside 0.9 s is a shake.
local function reversals(min)
  local dir, peak = 0, nil
  return function(v)
    if not peak then peak = v; return false end
    if dir == 0 then
      if math.abs(v - peak) >= min then dir, peak = v > peak and 1 or -1, v end
      return false
    end
    if (v - peak) * dir > 0 then peak = v; return false end           -- still going the same way
    if (peak - v) * dir >= min then dir, peak = -dir, v; return true end -- turned back
    return false
  end
end

local function onShake()
  local t = now()
  while shakes[1] and t - shakes[1] > 300 do table.remove(shakes, 1) end
  shakes[#shakes + 1] = t
  doAction("shaken", 0.6)
  say(pick(SHAKE_LINES), "user")
end

-- Let go after a shake: dizzy, or grumpy after a few shakes in five minutes.
local function afterShake()
  if #shakes >= 3 then
    doAction("grumpy", 3)
    say(pick(GRUMPY_LINES), "user")
  else
    doAction("dizzy", 3.5)
    say(pick(DIZZY_LINES), "user")
  end
end

-- Same polling drag as the usage card (no Accessibility permission needed). A press
-- that doesn't move is a click: chat with a brain, a hello without one. Shaking it
-- while you hold it makes it dizzy.
local function startDrag()
  if M.dragTimer then M.dragTimer:stop() end
  local m0, p0, moved = hs.mouse.absolutePosition(), M.canvas:topLeft(), false
  local turnX, turnY, flips, shaken = reversals(25), reversals(25), {}, false
  M.dragTimer = hs.timer.doEvery(1 / 60, function()
    local m, t = hs.mouse.absolutePosition(), now()
    if not hs.eventtap.checkMouseButtons().left then
      M.dragTimer:stop()
      M.dragTimer = nil
      if moved then
        local p = M.canvas:topLeft()
        hs.settings.set(POS_KEY, { x = p.x, y = p.y })
      end
      if shaken then
        afterShake()
      elseif not moved then
        doAction("joy", 1.6)
        if Brain then
          if Chat.isOpen() then Chat.close() else openChat() end
        else
          say(pick(CLICK_LINES), "user")
        end
      end
      return
    end
    if math.abs(m.x - m0.x) + math.abs(m.y - m0.y) > 3 then moved = true end
    if moved then
      M.canvas:topLeft({ x = p0.x + m.x - m0.x, y = p0.y + m.y - m0.y })
      local tx, ty = turnX(m.x), turnY(m.y)
      if tx or ty then flips[#flips + 1] = t end
      while flips[1] and t - flips[1] > 0.9 do table.remove(flips, 1) end
      if #flips >= 4 and not shaken then shaken = true; onShake() end
      if shaken and #flips >= 2 then doAction("shaken", 0.4) end
    end
  end)
end

local function onMouseDown()
  local mods, buttons = hs.eventtap.checkKeyboardModifiers(), hs.eventtap.checkMouseButtons()
  if mods.alt then M.setup()
  elseif mods.ctrl or buttons.right then M.menuTimer = hs.timer.doAfter(0, showMenu)
  elseif mods.cmd then newSession()
  elseif mods.shift then
    if Brain then peek("screen", true) else say("Give me a brain first! See config.example.lua.", "user") end
  else startDrag() end
end

function M.start()
  math.randomseed(os.time())
  M.canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = H })
  -- desktopIcon + 1: Finder's desktop window shares the desktop-icon level and would eat clicks
  M.canvas:level(ON_TOP and hs.canvas.windowLevels.floating or hs.canvas.windowLevels.desktopIcon + 1)
  M.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  M.canvas:clickActivating(false)
  M.canvas:mouseCallback(function(_, msg)
    if msg == "mouseDown" then onMouseDown() end
  end)
  place()
  M.canvas:show()

  poll()
  say(fill("Hi {name}! I'm your Claude buddy."), true)
  if not hs.fs.attributes(DIR .. "/config.lua") and not hs.settings.get("claudeBuddy.setupSeen") then
    M.setupTimer = hs.timer.doAfter(3, function() M.setup(true) end) -- first run
  end
  M.frameTimer = hs.timer.doEvery(1 / FPS, frame)
  M.pollTimer = hs.timer.doEvery(1, poll)
  M.appWatcher = hs.application.watcher.new(function(_, ev)
    if ev == hs.application.watcher.activated then poll() end
  end):start()
  M.screenWatcher = hs.screen.watcher.new(function()
    M.placeTimer = hs.timer.doAfter(2, place)
  end):start()
  M.sleepWatcher = hs.caffeinate.watcher.new(function(ev) -- no animating to a dark screen
    if ev == hs.caffeinate.watcher.screensDidSleep then M.frameTimer:stop()
    elseif ev == hs.caffeinate.watcher.screensDidWake then M.frameTimer:start() end
  end):start()
  M.events = Events.start(CFG, react)
  return M
end

-- Preview a mood (and optional action) for a few seconds, e.g. ClaudeBuddy.test("love").
function M.test(m, secs, act)
  pinnedUntil = now() + (secs or 8)
  away = "active"
  setMood(m, "Test")
  say(lineFor(m, "Test"), true)
  if act then doAction(act, secs or 8) end
end

-- Fire an event by hand: ClaudeBuddy.event("usb", "Keyboard"), or "screenshot",
-- "download", "crash", "offline", "online", "wake", "headphones", "drive".
function M.event(id, detail) Events.test(id, detail) end

-- Open the setup wizard (setup.lua). It saves config.lua and reloads Hammerspoon.
function M.setup(firstRun)
  hs.settings.set("claudeBuddy.setupSeen", true)
  hs.settings.set(USED_KEY, used)
  M.wizard = M.wizard or dofile(DIR .. "/setup.lua")
  M.wizard.open({ dir = DIR, config = CFG, builtinMood = builtinMood, firstRun = firstRun })
  say(firstRun and "Let's get to know each other!" or "Teach me stuff!", "user")
end

M.say = say
M.peek = function() return peek("screen", true) end
M.chat = function() openChat() end
-- Wipe the chat transcript and what the brain remembers about you.
M.forget = function()
  Chat.forget()
  if Brain then Brain.forget() end
end
M.joke = tellJoke
M.newSession = newSession
return M
