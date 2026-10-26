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
-- Plain rules by default. With `ai` in config.lua it gets a Claude or local Ollama
-- brain (brain.lua): it looks at windows it doesn't know, riffs on your sessions,
-- and chats in a panel (chat.lua) where you can type or hold space and talk
-- (dictate.lua). Every bubble line shows up in chat, and it keeps notes for next time.
-- Pair a Telegram bot in the wizard and you can text it from your phone (telegram.lua).
-- The new wizard can enable app learning, running facts and separate health check-ins;
-- Watching and Never look control screen learning, and Forget clears what it learned.
--
-- Click: chat (or a hello, without a brain); click its speech bubble and the chat opens
-- on that line. Shift-click: "what do you see?".
-- Cmd-click: a new Claude Code session in Terminal. Right-click or Ctrl-click: its
-- menu, which also files bug reports (report.lua) and changes its skin. Option-click:
-- the setup wizard. Drag it to move it; shake it and it gets dizzy.
--
-- Skins (skins.lua) are costumes and colour swaps kept as JSON in skins/, plus your own
-- in ~/Library/Application Support/claude-usage-widget/skins. A skin also themes the
-- little things that float off it and adds a few lines of its own.
--
-- Window titles come from the window list, which needs Hammerspoon to have Screen
-- Recording permission; without it the buddy still reacts to each app. No
-- Accessibility permission is needed. Try a mood: hs -c 'ClaudeBuddy.test("love")'
-- or an event: hs -c 'ClaudeBuddy.event("crash", "Safari")'.
-- Personal tweaks (your name, extra rules, lines and events) go in config.lua next to
-- this file; the setup wizard (setup.lua) writes it.

local M = {}
M.tgCommands = {} -- optional features add their commands before Telegram starts
-- Through a function: a loop at the top of this file would add locals to its main chunk,
-- which is already near Lua's limit of 200.
function M.addTgCommands(list)
  for _, command in ipairs(list) do M.tgCommands[#M.tgCommands + 1] = command end
end

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
local PRESENT_FOR = 60      -- seconds of idle time that still counts as here
local HAMMERSPOON = "org.hammerspoon.Hammerspoon"
local TERMINAL_APP = CFG.terminal or "Terminal" -- where Cmd-click opens Claude Code (Terminal or iTerm)

-- The optional brain; see brain.lua. AI.peek_every: seconds between unprompted looks
-- at the screen (0 = only windows it doesn't know).
local AI = type(CFG.ai) == "table" and CFG.ai or nil
local Brain = AI and dofile(DIR .. "/brain.lua").configure(AI, NAME, type(CFG.grok) == "table",
  CFG.health == true or type(CFG.health) == "table", { tasks = CFG.tasks ~= false, projects = CFG.projects }) or nil
local Agent = Brain and Brain.agent() or nil
local Privacy = dofile(DIR .. "/privacy.lua").configure(CFG) -- watching switch, pause, private windows
if Brain then Brain.setPrivacy(Privacy) Brain.setPersonality(CFG.personality) end
local FORGET_STORES = {} -- objects with :wipe(); later features add theirs, Forget empties them all
-- Counting (facts.lua): opens and minutes per app or site, and the lines made from them.
-- Its state and helpers live on one table, like HC below and LC and SUB further down,
-- because this file's main chunk is close to Lua's limit of 200 locals.
local FC = { lib = dofile(DIR .. "/facts.lua"), said = {}, dirty = false, lastSave = 0 }
FC.store = FC.lib.new(HOME .. "/Library/Application Support/claude-usage-widget/learn/facts.json")
FORGET_STORES[#FORGET_STORES + 1] = FC.store
-- The health sidekick (health.lua) is on only with `health = true` or a table in config.lua.
-- Health state and helpers (filled in below): meal = the meal it just asked about.
local HC = { lib = dofile(DIR .. "/health.lua"), lastPoll = 0, lastSave = 0, meal = nil, fullScreenAt = -math.huge, fullScreen = false }
local Health = (CFG.health == true or type(CFG.health) == "table")
  and HC.lib.new(HOME .. "/Library/Application Support/claude-usage-widget/health",
    type(CFG.health) == "table" and CFG.health or {}) or nil
if Health then
  FORGET_STORES[#FORGET_STORES + 1] = Health
  -- plain rules: sitting nudges only; a brain adds questions; Claude adds goals (health.lua allowed)
  Health:setAllow(function(kind) return HC.lib.allowed(Brain and Brain.engine() or nil, kind) end)
end
local Automations = Agent and dofile(DIR .. "/automations.lua").configure({ present = PRESENT_FOR,
  watch_min = AI.watch_min, watch_runs = AI.watch_runs }) or nil
local PEEK_EVERY = AI and AI.peek_every or 0
local Events = dofile(DIR .. "/events.lua")
local Chat = dofile(DIR .. "/chat.lua") -- the chat panel, and the transcript it shares with the bubble
local jobLine = dofile(DIR .. "/job_line.lua")
-- Grok Bot as a teammate (grok.lua, approve.lua, bin/buddy-opus): only with a grok table
local GROK = type(CFG.grok) == "table" and CFG.grok or nil
local Grok = GROK and dofile(DIR .. "/grok.lua").configure(GROK, NAME) or nil
local GROK_STATE = HOME .. "/Library/Application Support/claude-usage-widget/grok"
local Approve -- the Approve / Deny panel, set up in M.start
-- Texting from your phone (telegram.lua): only once the wizard has paired a chat. The
-- wizard pairs through the same module, so opening it loads the module too.
local TG = type(CFG.telegram) == "table" and CFG.telegram or nil
local Telegram = TG and dofile(DIR .. "/telegram.lua") or nil
if Brain then Brain.onNote(function(line, via)
  Chat.post("note", line, via)
  if via == "telegram" and Telegram and Telegram.running() then Telegram.send(line) end
end) end
-- Claude Code sessions for a job you hand Buddy (tasks.lua), on unless config.lua says
-- tasks = false. Helpers live on this table (filled in after Telegram, below), like HC.
-- stopped: sessions you just stopped, so "it ended" isn't said twice.
local TK = { cfg = type(CFG.tasks) == "table" and CFG.tasks or {}, stopped = {} }
TK.lib = CFG.tasks ~= false and dofile(DIR .. "/tasks.lua").configure({ terminal = TERMINAL_APP, owner = NAME,
  model = TK.cfg.model, effort = TK.cfg.effort,
  bot = function() return Telegram and Telegram.currentBot() end,
  approvals = function() return TG and TG.approvals ~= false and Telegram and Telegram.running() or false end }) or nil

local FONT = hs.styledtext.defaultFonts.system.name
local BOLD = hs.styledtext.defaultFonts.boldSystem.name

local C = {
  ui = assert(loadfile(DIR .. "/theme.lua"))(),
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
  green  = { red = 0.36, green = 0.70, blue = 0.34, alpha = 1 },
  blue   = { red = 0.45, green = 0.75, blue = 0.98, alpha = 1 },
  shadow = { red = 0, green = 0, blue = 0, alpha = 0.28 },
}
C.bubble, C.ink = C.ui.colors.ink, C.ui.colors.bg -- ivory bubble, warm near-black words
local TEXT_SHADOW = { offset = { h = -1, w = 0 }, blurRadius = 2, color = { red = 0, green = 0, blue = 0, alpha = 0.7 } }

-- The skin it's wearing. One instance, shared with themes as ClaudeBuddy.skins.
local Skins = dofile(DIR .. "/skins.lua").new({ base = C, key = "claudeBuddy.skin",
  dirs = { DIR .. "/skins", HOME .. "/Library/Application Support/claude-usage-widget/skins" } })
local wornId -- the skin the brain was last told about
local function dressBrain()
  local s = Skins.current()
  if s.id == wornId then return end
  wornId = s.id
  if Brain then Brain.costume(s.id ~= "classic" and s.name or nil) end
end
dressBrain()
local Theme -- the Halloween theme (halloween.lua), set up below once what it calls exists

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
  texting    = { eyes = "down", body = "breathe", arms = "hold", prop = "phone", -- answering you on Telegram
                 lines = { "Texting you back!", "On the phone with you.", "Thumbs typing…" } },
  health     = { eyes = "happy", body = "bounce", arms = "hold", prop = "dumbbell", emit = "spark",
                 lines = { "Stretch break?", "Water time!", "Quick walk?", "Posture check!", "Up and at 'em!" } },
  food       = { eyes = "happy", body = "sway", arms = "hold", prop = "apple", blush = true,
                 lines = { "Snack time?", "What's for lunch?", "Mmm, food.", "Don't forget to eat!" } },
  teammate   = { eyes = "happy", body = "breathe", arms = "wave", -- Grok, when it's on the team (config.lua grok)
                 lines = { "Hey, it's Grok!", "Say hi to Grok for me.", "Teammate!", "Cloud buddy!" } },
  grokWait   = { eyes = "scan", body = "breathe", arms = "hold", prop = "phone",
                 lines = { "Pinging Grok…", "Grok's thinking. Allegedly.", "Waiting on the cloud." } },
  opusForGrok = { eyes = "down", body = "type", arms = "type", prop = "laptop", emit = "spark",
                 lines = { "Lending Grok some Opus.", "Opus on loan to Grok.", "Big brain, borrowed." } },
  needsYou   = { eyes = "wide", body = "hop", arms = "wave",
                 lines = { "Grok's Opus run needs your OK!", "Approve or deny? Your call." } },
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
if GROK then -- Grok's on the team: a wave instead of the side-eye
  for _, r in ipairs(TITLE_RULES) do if r[1] == "grok" then r[2] = "teammate" end end
  APPS["Grok"], APPS["Grok Bot"] = "teammate", "teammate"
end
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
-- Auto reactions that learn (learn.lua) are on only with `auto_reactions = true` and a brain.
local LC = { lib = dofile(DIR .. "/learn.lua"), lastSave = 0, lastDecide = 0 }
function LC.on() return CFG.auto_reactions == true and Brain ~= nil end
do
  M.wizard = M.wizard or dofile(DIR .. "/setup.lua")
  local keys = {} -- every mood the wizard offers that exists here, but not the Grok teammate's
  for _, m in ipairs(M.wizard.MOOD_LABELS) do
    if m[1] ~= "teammate" and MOODS[m[1]] then keys[#keys + 1] = m[1] end
  end
  LC.store = LC.lib.new(HOME .. "/Library/Application Support/claude-usage-widget/learn/learn.json", LC.lib.moodList(keys))
end
FORGET_STORES[#FORGET_STORES + 1] = LC.store
FORGET_STORES[#FORGET_STORES + 1] = { wipe = function() used, taught, unsaved, peeked = {}, {}, 0, {} end }
local sitDown = hs.settings.get("claudeBuddy.sitDown")
if type(sitDown) ~= "table" then sitDown = {} end
local lastSitDownSave, lastJobCheck = 0, 0
local runs = Automations and Automations.loadRuns(Agent.dir()) or nil
M.pendingJobs = Automations and Automations.pending(runs, hs.timer.secondsSinceEpoch()) or {}

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
  -- with no name, a comma before it goes too: "Arr, {name}!" reads "Arr!"
  line = NAME ~= "" and line:gsub(" {name}", literal(" " .. NAME)) or line:gsub(",? {name}", "")
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

-- One of the skin's own lines ("click" or "idle") about one time in three, else nil.
local function skinLine(kind)
  local own = Skins.lines(kind)
  return own and math.random(3) == 1 and pick(own) or nil
end

local function lineFor(m, appName)
  local spec, kind = MOODS[m], m
  if m == "idle" then
    local h = os.date("*t").hour
    if h >= 23 or h < 5 then spec, kind = MOODS.sleepy, "sleepy" elseif h < 10 then spec, kind = MOODS.morning, "morning" end
  end
  local own = (spec == MOODS.idle and skinLine("idle")) or Theme.line(kind)
  if own then return fill(own, appName) end
  if not spec or #spec.lines == 0 then return nil end
  return fill(pick(spec.lines), appName)
end

-- force: true skips the gap between lines; "user" (you asked) also talks while muted.
-- quiet: keep it out of the chat transcript (the chat already shows it in full).
local function say(text, force, quiet)
  local t = now()
  if not text or text == "" then return end
  if force ~= "user" and t < mutedUntil then return end
  if not force and (QUIET_FOR < 0 or t - lastSaid < QUIET_FOR) then return end
  bubble, lastSaid = wrap(text), t
  bubbleUntil = t + math.min(SAY_MAX, math.max(SAY_MIN, #text * 0.075))
  talkUntil = t + math.min(2.5, #text * 0.05)
  if not quiet then Chat.said(text) end
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
      j = select(2, title:find(g, 1, true))
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
  Theme.interrupt()
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
  local claude, learned
  if TERMINALS[bid] then
    local state = claudeTitle(title)
    if state then claude = state == "wait" and "claudeWait" or "claudeWork" end
  end
  if LC.on() and Privacy.watching() then -- what it has learned about this app or site
    local key = FC.lib.keyFor(bid, name, title, BROWSERS[bid] or false, TITLE_RULES)
    learned = LC.store:moodFor(key, os.time())
    if not MOODS[learned or ""] then learned = nil end
  end
  local watching = Privacy.watching() -- with watching off, only your picks and the built-ins apply
  -- your picks, then Claude Code states, then what it learned, then the built-ins
  return LC.lib.reaction({ picked = CFG_APPS[bid] or CFG_APPS[name], claude = claude, learned = learned, watching = watching,
    builtin = function()
      if TERMINALS[bid] then return "coding" end
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
    end })
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
-- explains when it can't. Returns true when it handled the look.
local function peek(kind, byUser)
  local t, w = now(), lastReal
  if not Brain or Brain.busy() then return false end
  if not Privacy.watching() then
    if byUser then say("Watching's off. Right-click me to turn it on.", "user") end
    return false
  end
  if not byUser and (QUIET_FOR < 0 or t < mutedUntil) then return false end
  if not (w and w.id) then
    if byUser then say("I can't see a window right now.", "user") end
    return false
  end
  if Brain.private(w.app, w.title, w.bid) then
    if byUser then say("That looks private. Not peeking!", "user") end
    return false
  end
  lastPeek = t
  doAction("ponder", 8)
  local about = FC.store:aboutWindow(w, BROWSERS[w.bid] or false, TITLE_RULES, os.time()) -- what it has counted for this window
  local started = Brain.quip({ kind = kind or "screen", app = w.app, title = w.title, winId = w.id, bid = w.bid,
      facts = about, unprompted = not byUser }, function(line)
    if action == "ponder" then action = nil end
    if not line then
      if byUser then
        say("My brain's not answering." .. (Brain.engine() == "claude" and " Is Claude Code signed in?" or " Is Ollama running?"), "user")
      else
        say(lineFor(mood, moodApp), true)
      end
    elseif byUser or (lastReal and lastReal.id == w.id) then -- skip it if you've moved on
      say(line, byUser and "user" or true)
    end
  end)
  if not started then
    if action == "ponder" then action = nil end
    if not byUser then
      say(lineFor(mood, moodApp), true)
      return true
    end
  end
  return started
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
    local started = Brain.quip({ kind = "session", topic = topic, state = s.state, mins = mins, unprompted = true }, function(line)
      local cur = lastWinId and sessions[lastWinId]
      if cur and cur.topic == topic then say(line or sessionLine(cur), true) end
    end)
    if not started then say(sessionLine(s), true) end
  else
    say(sessionLine(s), true)
  end
  return true
end

-- Quiet for a while: pipe up with a look at the screen, a session update or a mood line.
local function ambient(t, bid)
  lastSaid = t -- whatever happens, wait another round
  if HC.progress(t, bid) then return end
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
  if Brain and not Brain.private(w.app, w.title, w.bid) and Brain.quip({ kind = "joke", app = w.app, title = w.title, winId = w.id, bid = w.bid, unprompted = false },
      function(line) say(line or pick(JOKES), "user") end) then
    return doAction("ponder", 6)
  end
  say(Theme.line("joke") or pick(JOKES), "user")
end

local askGrok -- "ask Grok…" in the chat (the Grok teammate section below)

function M.watchCommand(text, origin)
  local cmd = text:match("^%s*/(%a+)")
  if cmd ~= "watch" and cmd ~= "watches" and cmd ~= "unwatch" then return false end
  if not Automations then
    return true, "Watches need the Claude brain. Pick Claude in my setup."
  end
  local sources = {}
  for name, source in pairs(type(AI.sources) == "table" and AI.sources or {}) do
    if type(name) == "string" and type(source) == "table" then sources[#sources + 1] = name end
  end
  table.sort(sources)
  return Automations.command(text, origin, Agent.dir(), true, now(), sources)
end

function M.watchText(text, m)
  local handled, answer = M.watchCommand(text, "telegram")
  if not handled then return false end
  Chat.post("user", text, "telegram")
  Chat.post("assistant", answer, "telegram")
  M.tgSend(m, answer, { thread = m and m.thread })
  return true
end

local function openChat(opts)
  if not Brain then return say("I need a brain to chat. See config.example.lua.", "user") end
  if type(opts) ~= "table" then opts = {} end
  local w = lastReal or {}
  Chat.open({
    dir = DIR, anchor = function() return M.canvas:frame() end, title = w.app,
    offlineHint = Brain.engine() == "claude" and " Is Claude Code signed in?" or " Is Ollama running?",
    -- each message looks at the window you were in last (the panel itself doesn't count);
    -- one that asks for Grok goes to Grok instead
    ask = function(history, done)
      local last = history[#history]
      if Health and HC.meal and now() - HC.meal.at <= 1800 then -- answering the meal question
        Health:ate(HC.meal.meal, os.time())
        HC.meal = nil
      end
      if TK.lib and last and TK.handle(last.content, "chat", done) then return end
      if last then
        local handled, answer = M.watchCommand(last.content, "chat")
        if handled then return done(answer) end
      end
      if Grok and last and Grok.isFor(last.content) then return askGrok(last.content, done) end
      doAction("ponder", 30)
      local ctx = {}
      for k, v in pairs(lastReal or {}) do ctx[k] = v end
      if Privacy.watching() then ctx.status = "Claude Code sessions: " .. M.sessionText() .. " Claude plan usage: " .. M.usageText() end
      if Health then ctx.health = Health:summary(os.time()) end
      if TK.lib then ctx.tasks = TK.lib.summary() end
      local asked = now()
      Brain.chat(history, ctx, function(text, err)
        if action == "ponder" then action = nil end
        if Health then Health:absorb() end -- what Claude logged with its health tools
        done(text, err)
        if TK.lib then TK.afterBrain("chat", last and last.content, asked) end
      end)
    end,
    opener = not opts.quiet and function(done)
      local cur = lastReal or {}
      if Health and not HC.busy(cur.bid, cur.title) and Health:askGoal(os.time()) then
        return done("Quick one: any health or fitness goals you want me to keep you honest on?")
      end
      if not Brain.quip({ kind = "screen", app = cur.app, title = cur.title, winId = cur.id, unprompted = false }, done) then
        done(pick({ "Hey! What's up?", "Oh hi! What are we looking at?", "You rang?" }))
      end
    end,
    onReply = function() doAction("talk", 2.5) end,
    remember = Brain.remember,
    command = function(text) return Brain.command(text, "chat") end,
    dictation = AI.dictation,
  })
end

local function deliverJob(id, name)
  local run = runs[id]
  if not run or run.delivered or type(run.result) ~= "string" then return end
  local text = run.ok and run.result or (name .. " didn't come through: " .. run.result)
  local present = hs.host.idleTime() < PRESENT_FOR
  local phone = Automations.toPhone(Telegram and Telegram.running(), TG and TG.jobs ~= false,
    present, run.origin)
  if not present and not phone then return end
  if not run.posted then Chat.post("assistant", text); run.posted = true end
  if present and not run.shown then
    openChat({ quiet = true })
    say(jobLine(name, run.ok), "user", true)
    eventMood, eventUntil = "proud", now() + 3
    run.shown = true
  end
  if phone then
    if run.sending or (run.phoneRetryAt and now() < run.phoneRetryAt) then return end
    run.sending = true
    Telegram.send("🗓 " .. name .. ":\n" .. text, function(ok)
      run.sending = nil
      if not ok then
        run.phoneRetryAt = now() + 60
        Automations.saveRuns(Agent.dir(), runs)
        return
      end
      run.delivered, run.result = true, nil
      Automations.saveRuns(Agent.dir(), runs)
    end)
  else
    run.delivered, run.result = true, nil
  end
  Automations.saveRuns(Agent.dir(), runs)
end

local function pollJobs(t, idle)
  if not Automations then return end
  local present = idle < PRESENT_FOR
  if #M.pendingJobs > 0 then
    local pending = M.pendingJobs
    M.pendingJobs = {}
    local names = {}
    for _, job in ipairs(Automations.load(Agent.dir())) do names[job.id] = job.name or job.id end
    for _, id in ipairs(pending) do
      deliverJob(id, names[id] or (runs[id] and runs[id].name) or id)
      if runs[id] and not runs[id].delivered then M.pendingJobs[#M.pendingJobs + 1] = id end
    end
  end
  local armed, firedDay = sitDown.armed, sitDown.firedDay
  local fire = Automations.sitDown(sitDown, t, idle)
  if armed ~= sitDown.armed or firedDay ~= sitDown.firedDay or t - lastSitDownSave >= 60 then
    hs.settings.set("claudeBuddy.sitDown", sitDown)
    lastSitDownSave = t
  end
  if not fire and t - lastJobCheck < 30 then return end
  lastJobCheck = t
  local jobs, expired = Automations.expired(Automations.load(Agent.dir()), t)
  if expired then Automations.pruneExpired(Agent.dir(), t) end
  local due = Automations.due(jobs, runs, t, present, fire)
  local today = os.date("%Y-%m-%d", math.floor(t))
  for _, job in ipairs(due) do
    local id, name = job.id, job.name or job.id
    local watch = job.trigger and job.trigger.type == "every"
    if watch and not Automations.claimWatch(runs, t) then goto continueJob end
    local run = { day = today, startedAt = t, name = name, inFlight = true,
      lastResult = runs[id] and runs[id].lastResult, origin = job.origin }
    runs[id] = run
    Automations.saveRuns(Agent.dir(), runs)
    doAction("ponder", 8)
    if not watch then say(jobLine(name, "start"), "user") end
    Agent.run({ kind = "job", system = Brain.assistant(), prompt = Automations.prompt(job, t, run.lastResult),
      job_id = id, sources = job.sources }, function(text, err)
        if runs[id] ~= run then return end -- an older callback cannot replace a newer run
        run.inFlight = false
        run.finishedAt = now()
        run.ok = text ~= nil
        run.result = text or err or "Claude didn't answer."
        if watch and run.ok and Automations.nothingNew(run.result) then
          run.delivered, run.result, run.summary = true, nil, "NOTHING NEW"
          Automations.saveRuns(Agent.dir(), runs)
          return
        end
        if watch and run.ok then run.lastResult = run.result end
        run.summary = run.result
        run.delivered = false
        Automations.saveRuns(Agent.dir(), runs)
        deliverJob(id, name)
        if not run.delivered then M.pendingJobs[#M.pendingJobs + 1] = id end
      end)
    ::continueJob::
  end
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

function M.sessionText()
  local work, wait, waiting = 0, 0, {}
  for _, s in pairs(sessions) do
    if s.state == "work" then work = work + 1 else wait = wait + 1; waiting[#waiting + 1] = clip(s.topic, 22) end
  end
  if work + wait == 0 then return "No Claude Code sessions on screen." end
  local text = string.format("%d cooking, %d waiting on you.", work, wait)
  if #waiting > 0 then text = text .. " Waiting: " .. table.concat(waiting, ", ", 1, math.min(2, #waiting)) end
  return text
end
local function sessionReport() say(M.sessionText(), "user") end

function M.usageText()
  local d, parts = usageData(), {}
  for _, l in ipairs(d and d.limits or {}) do
    if l.label == "Current session" then parts[#parts + 1] = string.format("Session %d%%", math.floor(l.pct + 0.5))
    elseif l.label == "Week · all models" then parts[#parts + 1] = string.format("week %d%%", math.floor(l.pct + 0.5)) end
  end
  if #parts == 0 then return "I can't see your usage right now." end
  local pct = sessionPct() or 0
  return table.concat(parts, ", ") .. "." .. (pct >= 80 and " Running hot!" or pct >= 50 and " Halfway there." or " Plenty left!")
end
local function usageReport() say(M.usageText(), "user") end

local function toggleMute()
  if now() < mutedUntil then
    mutedUntil = 0
    say("I'm back! Did you miss me?", "user")
  else
    say("Okay, quiet for an hour. Shh.", "user")
    mutedUntil = now() + 3600
  end
end

local function pickSkin(id)
  if not Skins.pick(id) then return end
  doAction("joy", 1.6)
  local own = Skins.lines("click")
  say(fill(own and own[1] or "Ta-da!"), "user")
end

-- Skin ▸ Surprise me, then a submenu per group, ticked on the skin it's wearing.
local function skinMenu()
  local cur, groups, others = Skins.current().id, {}, {}
  for _, s in ipairs(Skins.list()) do
    groups[s.group] = groups[s.group] or {}
    table.insert(groups[s.group], { title = s.name == "-" and "–" or s.name, -- a lone "-" would be a separator
      checked = s.id == cur, fn = function() pickSkin(s.id) end })
    if s.id ~= cur then others[#others + 1] = s.id end
  end
  local items = { { title = "Surprise me", fn = function() pickSkin(#others > 0 and pick(others) or cur) end }, { title = "-" } }
  for _, g in ipairs(Skins.groups()) do
    if groups[g.group] then items[#items + 1] = { title = g.label, menu = groups[g.group] } end
  end
  return items
end

-- Right-click submenus (one table; see FC). "Brain ▸": Auto, a named Claude model, a model
-- on this Mac, or plain rules.
local SUB = {
  brains = {
    { "auto", "Auto (recommended)" }, { "haiku", "Haiku" }, { "sonnet", "Sonnet" },
    { "opus", "Opus" }, { "fable", "Fable" }, { "ollama", "Ollama on this Mac" }, { "plain", "Plain rules" },
  },
  claude = { auto = true, haiku = true, sonnet = true, opus = true, fable = true },
}
function SUB.brainChoice()
  if not AI then return "plain" end
  if AI.engine ~= "claude" then return "ollama" end
  local m = AI.model
  return SUB.claude[m] and m or "haiku"
end

function SUB.brain()
  local current, sub = SUB.brainChoice(), {}
  for _, b in ipairs(SUB.brains) do
    sub[#sub + 1] = { title = b[2], checked = b[1] == current or nil, fn = function() M.setBrain(b[1]) end }
  end
  return sub
end

-- Right-click "Watching ▸": pause it for a while, or switch it off for good.
function SUB.watching()
  local sub = {
    { title = "Pause for an hour", fn = function() M.pauseWatching(3600) end },
    { title = "Pause until morning", fn = function() M.pauseWatching() end },
  }
  if Privacy.pausedUntil() then
    sub[#sub + 1] = { title = "Resume watching", fn = function() M.resumeWatching() end }
  end
  local on = CFG.watch ~= false
  sub[#sub + 1] = { title = on and "Turn watching off" or "Turn watching on", fn = function() M.setWatching(not on) end }
  return sub
end

local function showMenu()
  local sub = { { title = "Home folder", fn = function() newSession(HOME) end } }
  for _, p in ipairs(projectDirs()) do
    sub[#sub + 1] = { title = p:match("([^/]+)$"), fn = function() newSession(p) end }
  end
  local items = {}
  if Brain then
    items[#items + 1] = { title = "Chat with me", fn = openChat }
    items[#items + 1] = { title = "What I remember about you…", fn = function()
      openChat({ quiet = true })
      Chat.post("assistant", Brain.notes())
    end }
    items[#items + 1] = { title = "What do you see?", fn = function() peek("screen", true) end }
    if Agent then
      items[#items + 1] = { title = "Jobs…", fn = function()
        openChat({ quiet = true })
        Agent.run({ kind = "chat", system = Brain.assistant(), prompt = "List my standing jobs." }, function(text, err)
          Chat.post("assistant", text or err or "Claude didn't answer.")
        end)
      end }
    end
  end
  items[#items + 1] = { title = "Tell me a joke", fn = tellJoke }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "New Claude Code session", menu = sub }
  items[#items + 1] = { title = "How are my Claude sessions?", fn = sessionReport }
  local taskMenu = TK.lib and TK.menu()
  if taskMenu then items[#items + 1] = { title = "Task sessions", menu = taskMenu } end
  items[#items + 1] = { title = "How's my usage?", fn = usageReport }
  items[#items + 1] = { title = "Buddy's usage", fn = function() M.buddyUsage() end }
  items[#items + 1] = { title = "Brain", menu = SUB.brain() }
  items[#items + 1] = { title = "Watching", menu = SUB.watching() }
  items[#items + 1] = { title = "Forget what you've learned about me…", fn = function() M.forgetAsk() end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = now() < mutedUntil and "Talk again" or "Quiet for an hour", fn = toggleMute }
  items[#items + 1] = { title = "Skin", menu = skinMenu() }
  local spooky = Theme.menu()
  if spooky then items[#items + 1] = spooky end
  items[#items + 1] = { title = "Setup…", fn = function() M.setup() end }
  items[#items + 1] = { title = "Report a bug…", fn = function() M.reportBug() end }
  items[#items + 1] = { title = "What's new", fn = function() M.whatsNew() end }
  M.menu = M.menu or hs.menubar.new(false)
  M.menu:setMenu(items)
  M.menu:popupMenu(hs.mouse.absolutePosition(), true)
end

-- An event from events.lua: show its mood for a few seconds and say one of its lines
-- (or, with `ai` on the event and a brain, a line made up about it).
local function react(ev)
  local t = now()
  if away == "asleep" then return end
  Theme.interrupt()
  if MOODS[ev.mood] then eventMood, eventUntil = ev.mood, t + EVENT_FOR
  elseif ACTIONS[ev.mood] then doAction(ev.mood, 1.6) end
  if QUIET_FOR < 0 then return end
  local vars = { f = ev.file }
  for i, c in ipairs(ev.caps or {}) do vars[i] = c end
  local line = ev.lines and #ev.lines > 0 and fill(pick(ev.lines), nil, vars) or nil
  if ev.ai and Brain and not Brain.busy() and t >= mutedUntil then
    local ok = Brain.quip({ kind = "event", what = fill(ev.ai, nil, vars), unprompted = true }, function(made) say(made or line, true) end)
    if ok then return end
  end
  say(line, true)
end

-- What to draw right now, and the name of the mood under it (a skin can theme each mood).
local function currentSpec(t)
  local name
  if eventMood == "love" and t < eventUntil then name = "love" -- a kind text lights up even while the Mac idles
  elseif away == "asleep" then name = "sleep"
  elseif away == "bored" then name = "bored"
  elseif t < eventUntil and MOODS[eventMood] then name = eventMood
  else
    name = MOODS[mood] and mood or "idle"
    if mood == "idle" then
      local h = os.date("*t").hour
      if h >= 23 or h < 5 then name = "sleepy" elseif h < 10 then name = "morning" end
    end
  end
  local spec = {}
  for k, v in pairs(MOODS[name]) do spec[k] = v end
  if action and t < actionUntil then
    for k, v in pairs(ACTIONS[action]) do spec[k] = v end
  else
    action = nil
  end
  spec.sweat = (sessionPct() or 0) >= 80
  return spec, name
end

-- Count what's in front (private windows and Buddy's own panel don't count) and, when
-- you open something again, say so (facts.lua). Talking is on only for configs the wizard
-- wrote (they have a `watch` key); older configs keep today's behaviour.
function FC.note(t, app, bid, title, countOnly)
  if bid == HAMMERSPOON then return end
  FC.dirty = true
  FC.lib.tick(FC.store, { t = t, bid = bid, app = app:name(), title = title, isBrowser = BROWSERS[bid] or false,
    rules = TITLE_RULES, mood = mood, privacy = Privacy, lines = FC.lib.talks(CFG),
    quiet = countOnly or QUIET_FOR < 0 or t < mutedUntil, brain = Brain, gate = HC.gate, say = say, said = FC.said })
end

-- Is the window in front full screen? (its focused window; one call, not a window list)
function HC.frontFullScreen()
  local app = hs.application.frontmostApplication()
  local ok, full = pcall(function()
    local w = app and app:focusedWindow()
    return w and w:isFullScreen()
  end)
  return ok and full == true
end

-- Auto reactions: count how long you stay in each app or site and, once it has seen
-- enough, ask the brain which mood fits (learn.lua), with a snapshot unless the window
-- is private or a call. A question it comes back with is said out loud, 3 a day at most.
function LC.tick(t, app, bid, title, win, countOnly)
  if not LC.on() or bid == HAMMERSPOON or bid == "" or not Privacy.watching() then return end
  local name = app:name()
  if Privacy.private(bid, name, title) then return end
  local key, label = FC.lib.keyFor(bid, name, title, BROWSERS[bid] or false, TITLE_RULES)
  LC.store:observe(key, label, title, t)
  if countOnly or Brain.busy() or t - LC.lastDecide < 30 or not LC.store:due(key, t) then return end
  LC.lastDecide = t
  LC.store:look(key, label, { t = t, facts = FC.store:describe(key, label, t), brain = Brain, privacy = Privacy,
    now = now,
    snapshot = function() -- only taken once the brain can start (not past the daily cap)
      return win.id and not Privacy.busy(bid, title, HC.frontFullScreen(), mood) and Brain.snapshot(win.id) or nil
    end,
    ponder = function(on) -- held for the 60 s a look can take
      if on then doAction("ponder", 60) elseif action == "ponder" then action = nil end
    end,
    hushed = function() return now() < mutedUntil or QUIET_FOR < 0 end,
    busy = function() -- asked again when the answer arrives: you may be in a call or full screen by then
      local cur = lastReal or {}
      return Privacy.busy(cur.bid, cur.title, HC.frontFullScreen(), mood)
    end,
    say = function(question) say(question, true) end }) -- this also puts it in the chat transcript
end

-- Health (health.lua): nudges after a long sit, a question at mealtimes, and a remark when
-- the window is about food or fitness. All of it waits while muted, on "Only when clicked",
-- or busy (a call, meeting, game, full screen).
HC.sitLines = { "%m minutes straight! Quick walk or ten push-ups?", "%m minutes in that chair! Stand up and stretch?",
                "Break time! %m minutes without moving. Water and a stretch?" }

-- Full screen is an Accessibility call that can stall, so it is asked only when something is
-- about to be said, and at most every 20 s.
function HC.busy(bid, title)
  local t = now()
  if QUIET_FOR < 0 or t < mutedUntil or Privacy.busy(bid or "", title or "", false, mood) then return true end
  if t - HC.fullScreenAt > 20 then HC.fullScreenAt, HC.fullScreen = t, HC.frontFullScreen() end
  return HC.fullScreen
end

-- The gates again at delivery: a brain reply can land after a call started, full screen,
-- a mute, "Only when clicked" or a pause. One fresh full-screen check per delivery.
function HC.gate()
  local cur = lastReal or {}
  local muted = now() < mutedUntil
  return { muted = muted, quietFor = QUIET_FOR, watching = Privacy.watching(),
    busy = muted or QUIET_FOR < 0 or Privacy.busy(cur.bid or "", cur.title or "", HC.frontFullScreen(), mood) }
end

-- A line from the brain while watching is on, else the plain one. kind: sit | food | fitness.
function HC.line(kind, what, plain)
  local deliver = HC.lib.late(kind, HC.gate, function(text) say(text, true) end)
  local started = Brain and Privacy.watching() and not Brain.busy()
    and Brain.quip({ kind = "health", what = what, unprompted = true }, function(line) deliver(line or plain) end)
  if not started then say(plain, true) end
end

function HC.speak(ev, t)
  if ev.kind == "sit" then
    doAction("stretch", 4)
    HC.line("sit", string.format("They've been at the computer %d minutes without a break. Nudge them to get up, stretch or walk.", ev.minutes),
      fill(pick(HC.sitLines), nil, { m = tostring(ev.minutes) }))
  elseif ev.kind == "meal" then
    HC.meal = { meal = ev.meal, at = t }
    say("Eaten yet? What's for " .. ev.meal .. "?", true)
  else -- food or fitness on screen
    local food = ev.kind == "food"
    eventMood, eventUntil = food and "food" or "health", t + EVENT_FOR
    HC.line(ev.kind, string.format("They're looking at a page called \"%s\". Ask them one short, friendly question about the %s.",
      clip(ev.what, 60), food and "food" or "workout"),
      food and "Ooh, food! What are we eating?"
        or (Brain and Brain.engine() == "claude" and "Workout time? Want me to log it?" or "Workout time? Nice!"))
  end
end

function HC.tick(t, idle)
  if not Health then return end
  if t - HC.lastPoll > 120 then Health:rest() end -- polling stopped: the Mac slept
  HC.lastPoll = t
  local cur = lastReal or {}
  local ev = Health:tick(t, idle, function() return HC.busy(cur.bid, cur.title) end)
  if ev then HC.speak(ev, t) end
  if Health.dirty and t - HC.lastSave >= 60 then
    HC.lastSave = t
    Health:save()
  end
end

-- Once a day, with health goals and Claude: a brain line on how they're doing against them.
-- Called at an ambient moment; false when it didn't start (health.lua decides if it's time).
function HC.progress(t, bid)
  if not Health or not Brain or Brain.busy() or not Privacy.watching() or bid == HAMMERSPOON then return false end
  local cur = lastReal or {}
  local what = Health:progress(os.time(), function() return HC.busy(cur.bid, cur.title) end)
  if not what then return false end
  local deliver = HC.lib.late("progress", HC.gate, function(text) say(text, true) end)
  return Brain.quip({ kind = "health", what = what, unprompted = true }, function(line)
    if line then deliver(line) end
  end) == true
end

-- Food or fitness in the front window's title; needs watching on, skips private windows and
-- terminals (a spinner title like "running tests" isn't a workout).
function HC.spot(t, app, bid, title)
  if not Health or bid == HAMMERSPOON or bid == "" or TERMINALS[bid] or not Privacy.watching() then return end
  local name = app:name()
  if Privacy.private(bid, name, title) then return end
  local ev = Health:spot(name, title, t, function() return HC.busy(bid, title) end)
  if ev then HC.speak(ev, t) end
end

-- Notices (notices.lua): lines other programs on this Mac hand Buddy, like a meal tracker's
-- check-ins. Each goes into the chat as Buddy's own line, so a reply from the phone has
-- context; into the bubble, with its mood, unless muted or busy; and to Telegram. Only with
-- `notices = true` in config.lua. M.start checks every 5 s. Bubble lines wait their turn in
-- NC.queue (one per check, once the bubble is free), so two at once don't hide each other.
local NC = CFG.notices == true and { lib = dofile(DIR .. "/notices.lua"), queue = {} } or nil
if NC then
  NC.store = NC.lib.new(HOME .. "/Library/Application Support/claude-usage-widget/notices-new.jsonl", { moods = MOODS })
  FORGET_STORES[#FORGET_STORES + 1] = NC.store
  function NC.deliver(n)
    Chat.post("assistant", n.text)
    if #NC.queue < 5 then NC.queue[#NC.queue + 1] = { line = n.bubble or n.text:match("^[^\n]+"), mood = n.mood, at = now() } end
    if n.telegram and Telegram and Telegram.running() then Telegram.send(n.text) end
  end
  function NC.poll()
    for _, n in ipairs(NC.store:poll(os.time())) do NC.deliver(n) end
    local t = now()
    if #NC.queue == 0 or t < bubbleUntil then return end
    local b = table.remove(NC.queue, 1)
    local g = HC.gate() -- muted or busy now: skip the bubble; the chat and Telegram have it
    if t - b.at > 600 or g.muted or g.busy then return end
    say(b.line, true, true) -- quiet: the chat already has it in full
    if b.mood then eventMood, eventUntil = b.mood, t + EVENT_FOR end
  end
end

-- Whole days since Buddy first started on this Mac; the brain gets more candid with them.
local function updateKnown()
  local met = tonumber(hs.settings.get("claudeBuddy.metAt"))
  if Brain and met then Brain.setKnown(math.floor((os.time() - met) / 86400)) end
end

local function poll()
  local t = now()
  pollJobs(t, hs.host.idleTime())
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
      lastReal = { id = win.id, app = app:name(), title = title, bid = bid }
    end
    local stage = FC.lib.stage(away) -- keeps counting while you watch a video hands-free
    if stage then
      FC.note(t, app, bid, title, stage == "count"); LC.tick(t, app, bid, title, win, stage == "count")
    end
    if away == "active" then HC.spot(t, app, bid, title) end
    local sess = win.id and sessions[win.id]
    local entered = sess and win.id ~= lastWinId
    if bid ~= HAMMERSPOON then lastWinId = win.id end
    setMood(classify(app, title), app:name(), entered)
    if entered and away == "active" and not sessionComment(sess) then say(lineFor(mood, app:name())) end

    -- learn which apps you live in; ask to be taught about busy ones it doesn't know
    if bid ~= "" and away == "active" and Privacy.watching() then
      used[bid] = (used[bid] or 0) + 1
      unsaved = unsaved + 1
      if unsaved >= 60 then unsaved = 0; hs.settings.set(USED_KEY, used) end
      if mood == "generic" and used[bid] >= TEACH_AFTER and not taught[bid] and not LC.on() then
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

  if FC.dirty and t - FC.lastSave >= 60 then
    FC.dirty, FC.lastSave = false, t
    FC.store:save()
    updateKnown()
  end

  if LC.store.dirty and t - LC.lastSave >= 60 then
    LC.lastSave = t
    LC.store:save()
  end

  HC.tick(t, idle)

  local pct = sessionPct()
  if pct then
    if lastPct and lastPct >= 20 and pct < 3 then Theme.interrupt(); doAction("joy", 1.6); say(pick(FRESH_LINES), true) end
    if lastPct and lastPct < 50 and pct >= 50 then Theme.interrupt(); say("Half the session's used. Pace yourself!", true) end
    lastPct = pct
    if pct >= 95 and t - lastUsageWarn > 1800 then
      lastUsageWarn = t
      Theme.interrupt()
      say("We're almost out of Claude!", true)
    end
  end

  -- the Halloween theme: dates, dress-up, and when its skits start and stop
  Theme.tick(t, { away = away, idle = idle, mood = mood, event = t < eventUntil, action = action,
    dragging = M.dragTimer ~= nil })

  if away == "active" and AMBIENT_EVERY > 0 and t - lastSaid > AMBIENT_EVERY and not Chat.isOpen() then
    ambient(t, bid)
  end

  if away == "active" and not action and t > nextTrick and not Theme.busy() then
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

-- The box a text particle needs: a single glyph fits 24x26, a word like "POW" doesn't.
-- Measured once per glyph and size.
local textBoxes = {}
local function textBox(ch, size)
  local k = ch .. "|" .. math.ceil(size)
  local b = textBoxes[k]
  if not b then
    local sz = hs.drawing.getTextDrawingSize(styled(ch, math.ceil(size), C.white))
    b = { w = math.max(24, math.ceil(sz.w) + 8), h = math.max(26, math.ceil(sz.h) + 4) }
    textBoxes[k] = b
  end
  return b
end

local function bodyOffset(kind, t)
  if kind == "breathe" then return 0, math.floor(math.sin(t * 2.2) * 1.5 + 0.5) end
  if kind == "bounce" then return 0, -math.floor(math.abs(math.sin(t * 7)) * 10) end
  if kind == "type" then return 0, math.floor(t * 10) % 2 end
  if kind == "sway" then return math.floor(math.sin(t * 4) * 5 + 0.5), -math.floor(math.abs(math.sin(t * 8)) * 3) end
  if kind == "jitter" then return (math.floor(t * 14) % 2 == 0) and -1 or 1, 0 end
  if kind == "sleep" then return 0, 2 + math.floor(math.sin(t * 1.2) * 1.5 + 0.5) end
  if kind == "duck" then return 0, 4 end
  if kind == "hop" then
    local p = (now() - actionStart) / math.max(actionUntil - actionStart, 0.1)
    return 0, -math.floor(math.sin(math.min(p, 1) * math.pi) * 14)
  end
  return 0, 0
end

local function drawEyes(px, kind, dx, dy, blinking, spin, P)
  if kind == "up" then dy = -1 end
  local open = { track = true, scan = true, down = true, ahead = true, up = true }
  if blinking and (open[kind] or kind == "squint") then
    px(3 + dx, 4 + dy, 2, 1, P.eye); px(9 + dx, 4 + dy, 2, 1, P.eye)
  elseif open[kind] then
    for _, c in ipairs({ 3, 9 }) do
      px(c + dx, 3 + dy, 2, 3, P.eye)
      px(c + dx, 3 + dy, 1, 1, C.white)
    end
  elseif kind == "squint" then
    px(3 + dx, 4, 2, 1, P.eye); px(9 + dx, 4, 2, 1, P.eye)
  elseif kind == "closed" then
    px(3, 5, 2, 1, P.eye); px(9, 5, 2, 1, P.eye)
  elseif kind == "sleepy" then
    px(3 + dx, 4, 2, 2, P.eye); px(9 + dx, 4, 2, 2, P.eye)
  elseif kind == "wide" then
    for _, c in ipairs({ 3, 9 }) do px(c, 2, 2, 4, P.eye); px(c, 2, 1, 1, C.white) end
  elseif kind == "happy" then
    for _, o in ipairs({ 0, 6 }) do
      px(2 + o, 4, 1, 1, P.eye); px(3 + o, 3, 2, 1, P.eye); px(5 + o, 4, 1, 1, P.eye)
    end
  elseif kind == "hearts" then
    for _, o in ipairs({ 1, 8 }) do
      px(o + 1, 2, 1, 1, C.pink); px(o + 3, 2, 1, 1, C.pink)
      px(o, 3, 5, 1, C.pink); px(o + 1, 4, 3, 1, C.pink); px(o + 2, 5, 1, 1, C.pink)
    end
  elseif kind == "dizzy" then -- an X and a + taking turns, so the eyes look like they spin
    for _, c in ipairs({ 2, 8 }) do
      if spin % 2 == 0 then
        px(c, 3, 1, 1, P.eye); px(c + 2, 3, 1, 1, P.eye); px(c + 1, 4, 1, 1, P.eye)
        px(c, 5, 1, 1, P.eye); px(c + 2, 5, 1, 1, P.eye)
      else
        px(c + 1, 3, 1, 3, P.eye); px(c, 4, 3, 1, P.eye)
      end
    end
  end
end

local function drawArms(px, kind, f, P)
  if kind == "up" then
    local hand = 2 - f % 2
    px(-1, 4, 1, 1, P.body); px(-2, 3, 1, 1, P.body); px(-2, hand, 1, 1, P.body)
    px(14, 4, 1, 1, P.body); px(15, 3, 1, 1, P.body); px(15, hand, 1, 1, P.body)
  elseif kind == "wave" then
    px(-1, 5, 1, 2, P.body)
    px(14, 4, 1, 1, P.body); px(15, 3, 1, 1, P.body); px(15 + f % 2, 2, 1, 1, P.body)
  elseif kind == "type" then
    px(-1, 5 + f % 2, 1, 2, P.body); px(14, 6 - f % 2, 1, 2, P.body)
  elseif kind == "hold" then
    px(-1, 5, 1, 2, P.body); px(14, 6, 1, 1, P.body); px(15, 7, 1, 1, P.body)
  else
    px(-1, 5, 1, 2, P.body); px(14, 5, 1, 2, P.body)
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
  dumbbell = function(px, f)
    local y = 6 - f % 2 -- a lift every other frame; columns 15-20, rows 5-8
    px(15, y, 1, 3, C.dark); px(16, y + 1, 4, 1, C.grey); px(20, y, 1, 3, C.dark)
  end,
  apple = function(px)
    px(15, 5, 2, 1, C.red); px(18, 5, 2, 1, C.red); px(15, 6, 5, 3, C.red); px(16, 9, 3, 1, C.red)
    px(16, 6, 1, 1, C.white); px(17, 4, 1, 2, C.brown); px(18, 4, 1, 1, C.green)
  end,
}

local function spawn(e, ox, oy, cx)
  local x, y
  if e.from == "head" then x, y = cx + (math.random() - 0.5) * e.spread, oy - 4
  elseif e.from == "side" then x, y = ox + 14 * S + 6, oy + 6
  elseif e.from == "sky" then x, y = math.random(8, W - 8), 4
  else x, y = ox + 16.5 * S + (math.random() - 0.5) * e.spread, oy + 4 * S end
  if #particles < 16 then
    local ch = pick(e.glyphs) -- e comes from Skins.particle, its colour already resolved
    local img = Skins.emoji(ch)
    local isz = img and img:size()
    particles[#particles + 1] = { ch = ch, img = img, aspect = isz and isz.w / isz.h, color = e.color, size = e.size,
      grow = e.grow or 0, x = x, y = y, vx = (e.vx or 0) + (math.random() - 0.5) * 8, vy = e.vy, age = 0, life = e.life }
  end
end

-- The Halloween theme: on by itself Oct 24–31 (config.lua `halloween` forces it). A theme
-- that fails to load or breaks later leaves Buddy as it was.
do -- a block, so its locals don't count toward the chunk's 200
  local ok, why = pcall(function()
    Theme = dofile(DIR .. "/halloween.lua").configure({ cfg = CFG, skins = Skins, palette = C, S = S, ground = GROUND,
      dirs = { DIR .. "/skits", HOME .. "/Library/Application Support/claude-usage-widget/skits" },
      settings = hs.settings, now = now, log = print, hooks = {
        say = function(s) say(s, true, true) end, -- in the bubble, not the chat
        act = doAction,
        look = function(x, y, secs) -- a point on the canvas
          local tl = M.canvas:topLeft()
          lookAt, lookUntil = { x = tl.x + x, y = tl.y + y }, now() + secs
        end,
        burst = function(e, n, ox, oy, cx) for _ = 1, n do spawn(e, ox, oy, cx) end end,
      } })
  end)
  if not ok then
    pcall(print, "[buddy] Halloween theme didn't load: " .. tostring(why)) -- a note, never a crash
    Theme = setmetatable({ actions = {}, offset = function() return 0 end }, { __index = function() return function() end end })
  end
end
for k, v in pairs(Theme.actions) do ACTIONS[k] = ACTIONS[k] or v end
if Brain then Brain.addPersona(Theme.persona) end

local function frame()
  if not M.canvas then return end
  local t = now()
  local dt = math.min(t - (lastFrame or t), 0.25)
  lastFrame = t
  local spec, moodName = currentSpec(t)
  local at = t - t0
  local f = math.floor(at * 6)
  dressBrain()
  local P = Skins.colors() -- body, shade, shine and eye in the skin's colours

  local bx, by = bodyOffset(spec.body, at)
  local ox, oy = math.floor((W - 14 * S) / 2) + bx + Theme.offset(), BODY_TOP + by - Skins.float()
  local cx = ox + 7 * S

  local els, sig = {}, {}
  local function px(c, r, w, h, color, track)
    local fr = { x = ox + c * S, y = oy + r * S, w = w * S, h = h * S }
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = color, frame = fr, trackMouseDown = track }
    sig[#sig + 1] = fr.x .. "," .. fr.y .. "," .. fr.w .. "," .. fr.h .. tostring(color)
  end
  -- one of the skin's layers, at this moment of its animation; returns it (nil = the skin
  -- has none). Clicks on a hat or cape count as clicks on Buddy, like the body.
  local function layer(name)
    local rects = Skins.layer(name, at)
    if rects then for _, q in ipairs(rects) do px(q[1], q[2], q[3], q[4], q[5], true) end end
    return rects
  end

  -- shadow on the ground shrinks as it jumps
  local lift = math.max(0, -by)
  local half = math.max(0, Skins.shadow() - lift)
  els[#els + 1] = { type = "oval", action = "fill", fillColor = C.shadow,
    frame = { x = cx - half, y = GROUND - 3, w = 2 * half, h = 7 } }
  sig[#sig + 1] = "s" .. half

  -- the Halloween world behind Buddy (web, spider, skit actors); it also moves the skit along
  local function add(el, key) els[#els + 1] = el; sig[#sig + 1] = key end
  Theme.behind(add, ox, oy, cx, at)

  -- the skin's back layer (capes, wings), legs (alternate when dancing; a skin can swap
  -- or drop them), body, the skin's markings on it
  layer("behind")
  if layer("legs") == nil then
    for i, c in ipairs({ 2, 4, 9, 11 }) do
      local up = spec.body == "sway" and ((i + f) % 2 == 0) and 1 or 0
      px(c, 10, 1, 2 - up, P.shade)
    end
  end
  px(1, 0, 12, 10, P.body, true); px(0, 1, 1, 8, P.body, true); px(13, 1, 1, 8, P.body, true)
  px(1, 9, 12, 1, P.shade); px(2, 1, 2, 1, P.shine)
  if spec.blush then px(1, 6, 2, 1, C.blush); px(11, 6, 2, 1, C.blush) end
  layer("body")

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
  drawEyes(px, spec.eyes, dx, dy, t < blinkUntil, math.floor(at * 10), P)

  -- mouth; it moves while a line is being said
  local talking = spec.mouth == "talk" or (not spec.mouth and t < talkUntil and spec.eyes ~= "closed")
  if talking then
    if f % 2 == 0 then px(6, 7, 2, 2, P.eye) else px(6, 8, 2, 1, P.eye) end
  elseif spec.mouth == "o" then px(6, 7, 2, 2, P.eye)
  elseif spec.mouth == "flat" then px(6, 8, 2, 1, P.eye)
  elseif spec.mouth == "yawn" and at % 6 < 2 then px(6, 7, 2, 2 + f % 2, P.eye)
  elseif spec.eyes == "happy" or spec.eyes == "hearts" then
    px(5, 7, 1, 1, P.eye); px(6, 8, 2, 1, P.eye); px(8, 7, 1, 1, P.eye)
  end
  layer("face") -- fangs, beards, masks: drawn over the face, which stays readable
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

  drawArms(px, spec.arms, f, P)
  -- the mood's prop, or the candy pail (Halloween) or the skin's hand-held thing when there's
  -- no prop and the arms are free
  if spec.prop then
    if PROPS[spec.prop] then PROPS[spec.prop](px, f) end
  elseif spec.arms == "rest" or spec.arms == "hold" then
    if not Theme.pail(add, ox, oy) then layer("hand") end
  end
  layer("top") -- hats, hair, ears

  -- floating particles, themed by the skin; a new emitter starts its count again
  local act = action and ACTIONS[action]
  local e = Skins.particle(EMIT, spec.emit, action, moodName, act and act.emit ~= nil)
  if e ~= lastEmit then emitClock, lastEmit = 0, e end
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
      if p.img then -- a colour emoji ignores text alpha, so it fades as an image
        local h = math.floor(size * 4 / 3)
        local w = math.floor(h * p.aspect)
        els[#els + 1] = { type = "image", image = p.img, imageAlpha = a,
          frame = { x = math.floor(p.x - w / 2), y = math.floor(p.y - 12), w = w, h = h } }
      else -- centred on the particle, as wide as the glyph or word
        local b = textBox(p.ch, size)
        els[#els + 1] = { type = "text", text = styled(p.ch, size, withAlpha(p.color, a)),
          frame = { x = math.floor(p.x - b.w / 2), y = math.floor(p.y + 1 - b.h / 2), w = b.w, h = b.h } }
      end
      sig[#sig + 1] = p.ch .. math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. math.floor(a * 10)
      alive[#alive + 1] = p
    end
  end
  particles = alive
  Theme.front(add, ox, oy, cx, at) -- skit actors in front of Buddy, under the bubble

  -- speech bubble
  if bubble and t > bubbleUntil then bubble = nil end
  if bubble then
    -- Particle text needs a shadow; the bubble's solid surface does not.
    -- wrap() fits 27 characters a line at 11.5 pt in 186 px; keep at least that much room
    local st = hs.styledtext.new(bubble, { font = { name = FONT, size = 11.5 }, color = C.ink,
      paragraphStyle = { alignment = "center", lineBreak = "truncateTail" } })
    local size = sizeCache[bubble] or hs.drawing.getTextDrawingSize(st)
    sizeCache[bubble] = size
    local bw, bh = math.min(W - 6, math.ceil(size.w) + 22), math.ceil(size.h) + 14
    local bxp = math.max(3, math.min(W - bw - 3, cx - bw / 2))
    local byp = math.max(2, BODY_TOP - Skins.topRows() * S - bh - 22)
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.shadow,
      roundedRectRadii = { xRadius = C.ui.radius.card, yRadius = C.ui.radius.card },
      frame = { x = bxp, y = byp + 3, w = bw, h = bh } }
    -- id "bubble": a click on it opens the chat (onMouseDown)
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = C.bubble, id = "bubble", trackMouseDown = true,
      roundedRectRadii = { xRadius = C.ui.radius.card, yRadius = C.ui.radius.card }, frame = { x = bxp, y = byp, w = bw, h = bh } }
    els[#els + 1] = { type = "segments", action = "fill", fillColor = C.bubble, closed = true, id = "bubble",
      trackMouseDown = true, coordinates = {
      { x = cx - 6, y = byp + bh - 1 }, { x = cx + 6, y = byp + bh - 1 }, { x = cx - 1, y = byp + bh + 8 } } }
    els[#els + 1] = { type = "text", text = st, id = "bubble", trackMouseDown = true,
      frame = { x = bxp + 3, y = byp + 7, w = bw - 6, h = bh - 10 } }
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
-- that doesn't move is a click: chat with a brain, a hello without one. A click on the
-- speech bubble opens the chat (never closes it) and the line moves into it. Shaking it
-- while you hold it makes it dizzy.
local function startDrag(onBubble)
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
        if Brain and onBubble then
          bubble = nil -- the chat shows the line now
          openChat({ quiet = true })
        elseif Brain then
          if Chat.isOpen() then Chat.close() else openChat() end
        else
          say(fill(skinLine("click") or Theme.line("click") or pick(CLICK_LINES)), "user")
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

local function onMouseDown(onBubble)
  Theme.interrupt() -- any click or drag ends a skit
  local mods, buttons = hs.eventtap.checkKeyboardModifiers(), hs.eventtap.checkMouseButtons()
  if mods.alt then M.setup()
  elseif mods.ctrl or buttons.right then M.menuTimer = hs.timer.doAfter(0, showMenu)
  elseif mods.cmd then newSession()
  elseif mods.shift then
    if Brain then peek("screen", true) else say("Give me a brain first! See config.example.lua.", "user") end
  else startDrag(onBubble) end
end

-- Grok teammate ---------------------------------------------------------------------
-- bin/buddy-opus and bin/buddy-opus-approve call these through `hs -c`.

local opusRuns = 0 -- Opus runs for Grok going right now

local function grokMood(m, secs) Theme.interrupt(); eventMood, eventUntil = m, now() + secs end

-- Back to normal, or to the right Grok pose if something is still going.
local function grokIdle()
  if Approve and Approve.showing then grokMood("needsYou", math.max(1, (Approve.showing.deadline or 0) - os.time()))
  elseif opusRuns > 0 then grokMood("opusForGrok", 3600)
  else eventUntil = 0 end
end

-- Pass the owner's words to Grok (grok.lua sends only those) and bring the reply back:
-- in full in the chat, the first sentence in the bubble.
askGrok = function(text, done)
  if Grok.busy() then return done("Still waiting on Grok from last time. Hang on.") end
  done("Passing it to Grok…")
  Grok.ask(text, { status = function(kind, detail)
    if kind == "sending" or kind == "waiting" then
      grokMood("grokWait", Grok.cfg.wait + 30)
    elseif kind == "reply" then
      grokIdle()
      Chat.post("grok", detail)
      doAction("wave", 1.6)
      say("Grok: " .. Grok.short(detail), "user", true)
    elseif kind == "unknown" then
      grokIdle()
      say("Not sure Grok got that. Check the Grok app.", "user")
    else
      grokIdle()
      say(detail or "Couldn't reach Grok.", "user")
    end
  end })
end

-- The settings buddy-opus needs, as JSON; "" when the feature is off.
function M.grokConfig()
  if not Grok then return "" end
  local c = Grok.cfg
  return hs.json.encode({ enabled = true, cap = c.opus_daily_cap, approve_timeout = c.approve_timeout,
    owner = NAME, deny_read = c.deny_read or {} })
end

-- kind: start (text = the request's first words), done, failed, capped.
function M.grokOpus(kind, text)
  if not Grok then return "" end
  text = text or ""
  if #text > 50 then text = text:sub(1, 49) .. "…" end
  if kind == "start" then
    opusRuns = opusRuns + 1
    grokMood("opusForGrok", 3600)
    say("Grok asked me for Opus: " .. text, "user")
  elseif kind == "done" or kind == "failed" then
    opusRuns = math.max(0, opusRuns - 1)
    grokIdle()
    if kind == "failed" then
      doAction("grumpy", 3)
      say("Opus run for Grok failed.", "user")
    else
      say("Sent Opus's answer back to Grok.", "user")
    end
  elseif kind == "capped" then
    Theme.interrupt()
    say("Grok wanted Opus again, but today's cap is used up.", "user")
  end
  return "ok"
end

-- A permission request from bin/buddy-opus-approve: "shown" or "queued".
function M.grokApprove(id)
  if not Approve then return "" end
  return Approve.request(id)
end

local function startGrok()
  M.approve = dofile(DIR .. "/approve.lua").configure(GROK_STATE, {
    anchor = function() return M.canvas:frame() end,
    onShow = function(req)
      grokMood("needsYou", math.max(1, (req.deadline or 0) - os.time()))
      doAction("hop", 0.7)
      say("Grok's Opus run needs your OK!", "user")
    end,
    onDone = function() grokIdle() end,
  })
  Approve = M.approve
  for _, req in ipairs(Approve.pending()) do Approve.request(req.id) end -- left open by a reload
end

-- Telegram ---------------------------------------------------------------------------

-- Messages from your phone (telegram.lua) join the chat panel's conversation and the brain
-- answers them knowing you're away from the screen. /usage and /sessions answer straight
-- from the card. Messages that come in while it's answering wait, then go in together.
local tgWaiting, tgBusy, tgDictate = {}, false, nil
M.tgHeld, M.tgMediaPending = {}, 0
TK.noteCommands = { notes = true, forget = true } -- add these to Telegram's command menu
local TG_HELP = "Text me anything. Quick checks: /usage for your Claude limits, /sessions for your Claude Code sessions."
  .. " /notes lists what I remember; /forget N removes a note."
  .. " /watch 30m and what to check keeps an eye on something; /watches lists them."
  .. (TK.lib and " /task and what it's for opens a Claude Code session for a bigger job; /tasks lists them." or "")
M.addTgCommands({
  { command = "help", description = "What Buddy can do" },
  { command = "usage", description = "Claude plan usage" },
  { command = "sessions", description = "Claude Code sessions" },
  { command = "task", description = "Start a task session", on = TK.lib ~= nil },
  { command = "tasks", description = "List task sessions", on = TK.lib ~= nil },
  { command = "stop", description = "Stop a task session", on = TK.lib ~= nil },
  { command = "notes", description = "What Buddy remembers about you", on = Brain ~= nil },
  { command = "forget", description = "Forget one note: /forget 3", on = Brain ~= nil },
  { command = "watch", description = "Check something every so often: /watch 30m …", on = Brain ~= nil },
  { command = "watches", description = "List your watches", on = Brain ~= nil },
  { command = "unwatch", description = "Stop a watch: /unwatch 2", on = Brain ~= nil },
})

function M.tgAffection(text)
  return Telegram.affection(text)
end

function M.tgSend(m, text, opts)
  opts = opts or { thread = m and m.thread }
  Telegram.send(text, function(ok)
    if m and m.message_id then Telegram.react(m.message_id, ok and (m.affection and "❤" or "👍") or "👎") end
    if ok and m and (TG.voice_replies == "always" or (m.voice and TG.voice_replies ~= false)) then
      Telegram.voiceReply(text, m.thread)
    end
  end, opts)
end

local function tgAnswer()
  if tgBusy or #tgWaiting == 0 then return end
  local m = table.remove(tgWaiting, 1)
  Chat.post("user", m.text, "telegram")
  local said, asked = m.text, now()
  tgBusy = true
  Telegram.typing(true)
  local stream = Brain.engine() == "claude" and TG.streaming ~= false
    and Telegram.stream(TG.streaming, m.thread, function() Telegram.typing(false) end) or nil
  if not m.affection then eventMood, eventUntil = "texting", now() + 180 end
  local status = "Claude Code sessions: " .. M.sessionText() .. " Claude plan usage: " .. M.usageText()
  Brain.chat(Chat.history(), { telegram = true, image = m.image, status = status, tasks = TK.lib and TK.lib.summary() or nil,
      health = Health and Health:summary(os.time()) or nil }, function(text, err)
    Telegram.typing(false)
    if Health then Health:absorb() end -- what Claude logged with its health tools, as in the chat panel
    if eventMood == "texting" then eventUntil = 0 end
    if text then Chat.post("assistant", text, "telegram") end
    -- a session it proposed is asked about once the answer is out, so the two arrive in order
    local answer = text or err or ("My brain's offline." .. (Brain.engine() == "claude" and " Is Claude Code signed in?" or " Is Ollama running?"))
    local function delivered(ok)
      Telegram.react(m.message_id, ok and text and (m.affection and "❤" or "👍") or "👎")
      if ok and (TG.voice_replies == "always" or (m.voice and TG.voice_replies ~= false)) then
        Telegram.voiceReply(answer, m.thread)
      end
      if TK.lib then TK.afterBrain("telegram", said, asked, m) end
      tgBusy = false
      tgAnswer()
    end
    if stream then stream:finish(answer, delivered)
    else Telegram.send(answer, delivered, { thread = m.thread }) end
    -- like closing the chat panel: once it goes quiet, note anything worth remembering
    if M.tgNotesTimer then M.tgNotesTimer:stop() end
    M.tgNotesTimer = hs.timer.doAfter(600, function() Brain.remember(Chat.history()) end)
  end, stream and function(delta) stream:update(delta) end or nil)
end

-- replyTo: the message it answers, when you swiped to reply (a session's update goes back to it).
function M.tgCommandText(text)
  local cmd = Telegram.command(text)
  if not cmd then return text end
  local rest = text:match("^%s*/%a+@[%w_]+(.*)$") or text:match("^%s*/%a+(.*)$") or ""
  local arg = rest:match("^%s*(.-)%s*$")
  return "/" .. cmd .. (arg ~= "" and (" " .. arg) or "")
end

local function tgText(text, replyTo, m)
  m.affection = M.tgAffection(text)
  if m.affection then Theme.interrupt(); eventMood, eventUntil = "love", now() + 5 end
  local cmd = Telegram.command(text)
  if not m.image then
    if cmd then text = M.tgCommandText(text) end
    if M.watchText(text, m) then return end
    if cmd == "usage" then return M.tgSend(m, M.usageText(), { thread = m.thread }) end
    if cmd == "sessions" then return M.tgSend(m, M.sessionText(), { thread = m.thread }) end
    if cmd == "start" or cmd == "help" then return M.tgSend(m, fill("Hi {name}! It's Buddy, on your Mac. ") .. TG_HELP, { thread = m.thread }) end
    local noteAnswer = Brain and TK.noteCommands[cmd] and Brain.command(text, "telegram"); if noteAnswer then
      if noteAnswer == true then return end
      return M.tgSend(m, noteAnswer, { thread = m.thread })
    end
    if TK.lib and TK.fromTelegram(text, replyTo, m) then return end
  end
  if not Brain then return M.tgSend(m, "I need a brain to chat. Pick one in my setup (Option-click me on the Mac). " .. TG_HELP, { thread = m.thread }) end
  m.text = text
  tgWaiting[#tgWaiting + 1] = m
  tgAnswer()
end

-- Voice notes are written down on this Mac with whisper.cpp, like hold-to-talk in the chat.
local function tgVoice(fileId, replyTo, m)
  tgDictate = tgDictate or dofile(DIR .. "/dictate.lua").configure(AI and AI.dictation)
  local why = AI and AI.dictation == false and "Voice notes are off (ai.dictation = false in config.lua)." or tgDictate.missing()
  if why then return M.tgSend(m, "I can't listen to voice notes yet. " .. why) end
  local tmp = hs.fs.temporaryDirectory() or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  local file = string.format("%sclaude-buddy-tg-%d.oga", tmp, math.floor(now() * 1000))
  Telegram.typing(true)
  Telegram.download(fileId, file, function(path, err)
    if not path then Telegram.typing(false); return M.tgSend(m, err) end
    tgDictate.file(path, function(text, missed)
      os.remove(path)
      Telegram.typing(false)
      if not text then return M.tgSend(m, missed or "Didn't catch that.") end
      Telegram.send("🎙 " .. text, nil, { thread = m.thread })
      tgText(text, replyTo, m)
    end)
  end)
end

function M.tgPhoto(m)
  if not Brain then return M.tgSend(m, "I need a brain to look at photos. Pick one in my setup (Option-click me on the Mac).") end
  -- Hold later updates at the gateway until this download has entered the chat queue.
  M.tgMediaPending = M.tgMediaPending + 1
  local function ready(text, err)
    if text then tgText(text, m.reply_to, m) else M.tgSend(m, err) end
    M.tgMediaPending = M.tgMediaPending - 1
    M.tgRelease()
  end
  local tmp = hs.fs.temporaryDirectory() or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  local path = tmp .. "buddy-photo-" .. tostring(math.floor(now() * 1000)) .. ".img"
  Telegram.download(m.photo, path, function(saved, err)
    if not saved then return ready(nil, err) end
    local ok, data = pcall(function()
      local image = hs.image.imageFromPath(saved)
      if not image then return nil end
      local size = image:size()
      if size.w > 768 then image = image:copy():size({ w = 768, h = math.floor(768 * size.h / size.w) }, true) end
      local url = image:encodeAsURLString(true, "JPEG")
      return url and url:match("^data:image/%w+;base64,(.+)$")
    end)
    os.remove(saved)
    m.image = ok and data or nil
    if not m.image then return ready(nil, "I couldn't read that photo.") end
    ready(m.caption and m.caption ~= "" and m.caption or "(a photo)")
  end)
end

function M.tgCallback(m)
  local id, choice = m.callback:match("^t:([^:]+):([yn])$")
  if id and TK.lib then
    local verdict, proposal, held = TK.lib.answerButton(id, choice == "y")
    if verdict then
      local label = verdict == "yes" and "▶️ Started" or "✖️ No"
      Telegram.answer(m.query, verdict == "yes" and "Starting it." or "Okay.")
      Telegram.edit(m.message_id, (held.question or "Question") .. "\n\n" .. label, false)
      Chat.post("user", verdict == "yes" and "yes" or "no", "telegram")
      if verdict == "yes" then TK.go(proposal, "telegram", function(s) TK.tell("telegram", s, nil, { incoming = m }) end, m)
      else TK.tell("telegram", "Okay, I won't.", nil, { incoming = m }) end
      return
    end
  elseif m.callback:match("^p:") and TK.permissionCallback and TK.permissionCallback(m) then return end
  Telegram.answer(m.query, "That one's done.")
end

local function onTelegram(m)
  if m.callback then return M.tgCallback(m) end
  if M.tgMediaPending > 0 then
    M.tgHeld[#M.tgHeld + 1] = m
    return
  end
  Telegram.react(m.message_id, "👀")
  m.affection = m.text and M.tgAffection(m.text) or false
  if m.text then return tgText(m.text, m.reply_to, m) end
  if m.voice then return tgVoice(m.voice, m.reply_to, m) end
  if m.photo then return M.tgPhoto(m) end
  M.tgSend(m, "I can read text, voice notes and photos.")
end

function M.tgRelease()
  while M.tgMediaPending == 0 and #M.tgHeld > 0 do
    onTelegram(table.remove(M.tgHeld, 1))
  end
end

local function telegramTrouble(why)
  say(why == "token" and "Telegram turned down my bot token. Set it up again in my setup."
    or "My Telegram token isn't in the Keychain. Set Telegram up again in my setup.", "user")
end

-- Task sessions (tasks.lua) -----------------------------------------------------------
-- A bigger job you hand Buddy gets its own Claude Code session in a new Terminal window,
-- with Remote Control on. The brain's task tools only propose; Buddy itself asks for your
-- yes. Updates come back where the job came from: the chat, or Telegram (and Telegram too
-- whenever you're away from the Mac).

-- Say text on a channel: the chat panel and the bubble, or Telegram. taskId: the session
-- it's about, so a Telegram reply to it goes to that session.
function TK.tell(channel, text, taskId, opts)
  opts = opts or {}
  local task = taskId and TK.lib.find(taskId)
  local thread = task and TK.lib.thread(task) or opts.incoming and opts.incoming.thread
  if channel == "telegram" and Telegram and Telegram.running() then
    Chat.post("assistant", text, "telegram")
    return Telegram.send(text, function(ok, ids)
      for _, id in ipairs(taskId and ids or {}) do TK.lib.remember(id, taskId) end
      if opts and opts.proposal and TK.lib.pending and TK.lib.pending.id == opts.proposal then
        TK.lib.pending.message_id = ids and ids[#ids]
      end
      if opts and opts.incoming then Telegram.react(opts.incoming.message_id,
        ok and (opts.incoming.affection and "❤" or "👍") or "👎") end
      if ok and (TG.voice_replies == "always" or (opts and opts.incoming and opts.incoming.voice and TG.voice_replies ~= false)) then
        Telegram.voiceReply(text, thread)
      end
    end, { buttons = opts.buttons, thread = thread, onMissingThread = function(missing)
      thread = nil
      if task then TK.missingThread(task)(missing) end
    end })
  end
  Chat.post("assistant", text)
  say(text:match("^[^\n]+"), "user", true)
end

function TK.buttons()
  local held = TK.lib and TK.lib.pending
  if not held then return nil end
  return { proposal = held.id, buttons = { { { text = "▶️ Start", data = "t:" .. held.id .. ":y" },
    { text = "✖️ No", data = "t:" .. held.id .. ":n" } } } }
end

-- Type text into session id: your own words, or a message you said yes to.
function TK.pass(id, text, channel, reply)
  reply = reply or function(s) TK.tell(channel, s) end
  local task = TK.lib.find(id)
  if channel == "telegram" and task and #(task.open_permits or {}) > 0 then
    return reply("It's waiting on your OK. Tap Allow or Deny above.")
  end
  TK.lib.send(id, text, function(info)
    local t = info.task or TK.lib.find(id) or {}
    if channel == "telegram" and not info.ok and #(t.open_permits or {}) > 0 then
      return reply("It's waiting on your OK. Tap Allow or Deny above.")
    end
    reply(info.ok and ("➡️ Sent to " .. (t.name or "it") .. ".") or ("Couldn't pass it on: " .. tostring(info.error)))
  end)
end

-- Do what you said yes to: open the session, or pass the message on.
function TK.go(p, channel, reply, incoming)
  if p.kind == "send" then return TK.pass(p.id, p.text, channel, reply) end
  reply("Opening " .. p.name .. "… I'll send its link when it's up.")
  doAction("joy", 1.6)
  local function start(thread)
    p.thread = thread
    p.thread_bot = thread and Telegram.currentBot() or nil
    TK.lib.start(p, channel, function(info)
      local t = info.task
      if not info.ok or not t then return reply("Couldn't start it: " .. tostring(info.error)) end
      local text = "🛠 " .. t.name .. " is up, in " .. TK.lib.tilde(t.folder) .. "."
        .. (t.url and ("\n📱 Drive it from your phone: " .. t.url)
          or "\nRemote Control hasn't connected yet, so for now it's in its Terminal window.")
        .. (channel == "telegram" and "\nI'll pass its updates on here. Reply to one to answer it." or "")
      TK.tell(channel, text, t.id, { incoming = incoming })
      if thread and channel ~= "telegram" then TK.tell("telegram", text, t.id) end
    end)
  end
  -- Create the topic before launch: a session can ask permission before its link is ready.
  if Telegram and Telegram.running() and TG.topics ~= false then Telegram.createTopic(p.name, start)
  else start(nil) end
end

-- A message for the sessions: your yes or no to Buddy's question, /task, /tasks or /stop.
-- True when it was handled here; reply(text) answers on the same channel. first() runs
-- before the reply when it's handled (Telegram puts your message in the transcript).
function TK.handle(text, channel, reply, first, incoming)
  local verdict, p, held = TK.lib.answer(text)
  local cmd, rest = (text or ""):match("^%s*/(%a+)%S*%s*(.-)%s*$")
  cmd = cmd and cmd:lower()
  if not verdict and cmd ~= "task" and cmd ~= "tasks" and cmd ~= "stop" then return false end
  if first then first() end
  if verdict and channel == "telegram" and held.message_id then
    Telegram.edit(held.message_id, held.question .. "\n\n" .. (verdict == "yes" and "▶️ Started" or "✖️ No"), false)
  end
  if verdict == "no" then reply("Okay, I won't.")
  elseif verdict == "yes" then TK.go(p, channel, reply, incoming)
  elseif cmd == "tasks" then reply(TK.lib.listText())
  elseif cmd == "task" then
    if rest == "" then reply("Tell me what it's for, like: /task add a dark mode to my app")
    else
      local question = TK.lib.ask({ kind = "start", task = rest, name = TK.lib.nameFor(rest), folder = HOME })
      if channel == "telegram" then
        local opts = TK.buttons()
        opts.incoming = incoming
        TK.tell(channel, question, nil, opts)
      else reply(question) end
    end
  else -- stop
    local t = TK.lib.find(rest)
    if not t or t.state == "ended" then
      reply(rest == "" and "Which one? Send /stop and its number from /tasks." or "No running session like that. /tasks lists them.")
    else
      TK.stopped[t.id] = true
      TK.lib.stop(t.id, function(info)
        reply(info.ok and ("Stopped " .. t.name .. ".") or ("Couldn't stop it: " .. tostring(info.error)))
      end)
    end
  end
  return true
end

-- From Telegram: a reply to a session's update goes straight to that session (your own
-- words need no yes); anything else might be for TK.handle.
function TK.fromTelegram(text, replyTo, incoming)
  local function first() Chat.post("user", text, "telegram") end
  local cmd = Telegram.command(text)
  if cmd == "task" or cmd == "tasks" or cmd == "stop" then
    return TK.handle(text, "telegram", function(s) TK.tell("telegram", s, nil, { incoming = incoming }) end, first, incoming)
  end
  local id = TK.lib.forThread(incoming and incoming.thread) or TK.lib.forMessage(replyTo)
  if id then
    first()
    TK.pass(id, text, "telegram", function(s) TK.tell("telegram", s, nil, { incoming = incoming }) end)
    return true
  end
  return TK.handle(text, "telegram", function(s) TK.tell("telegram", s, nil, { incoming = incoming }) end, first, incoming)
end

-- After the brain answered `said`: a session it proposed to start or message.
function TK.afterBrain(channel, said, since, incoming)
  local p = TK.lib.takeProposal(since)
  if not p then return end
  if p.kind == "send" and TK.lib.ownWords(p.text, said) then
    return TK.pass(p.id, p.text, channel, function(s) TK.tell(channel, s, nil, { incoming = incoming }) end)
  end
  local question = TK.lib.ask(p)
  local opts = channel == "telegram" and TK.buttons() or nil
  if opts then opts.incoming = incoming end
  TK.tell(channel, question, nil, opts)
end

function TK.closePermit(taskId, rid, reason)
  for _, m in ipairs(TK.lib.permitMessages(taskId, rid)) do
    Telegram.edit(m.message_id, (m.text or "Permission request") .. "\n\n" .. reason, false)
  end
end

function TK.permissionCallback(m)
  if not TK.lib or not TG or TG.approvals == false then return false end
  local rid, choice = m.callback:match("^p:([0-9a-f]+):([ad])$")
  if not rid or #rid ~= 12 then return false end
  local held = TK.lib.permitMessage(m.message_id, rid)
  if not held then return false end
  TK.lib.answerPermit(held.id, rid, choice == "a" and "allow" or "deny", function(info)
    local p = TK.lib.permit(held.id, rid)
    if info.ok and info.answered then
      -- Only the hook's closure confirms delivery. A pending edit could race that closure.
      Telegram.answer(m.query, "Passing it on…")
    elseif TK.lib.permitOpen(held.id, rid) then
      Telegram.answer(m.query, "Couldn't pass that on. Try again.")
    else
      Telegram.answer(m.query, "Already answered")
      if not p or p.state == "open" then TK.closePermit(held.id, rid, p and "Timed out" or "Already answered") end
    end
  end)
  return true
end

-- Clear only the topic that failed: a later task update might already name a new one.
function TK.missingThread(task)
  local bot = task.thread_bot
  return function(thread)
    task.thread, task.thread_bot = nil, nil
    TK.lib.clearThread(task.id, thread, bot)
  end
end

-- An update from a session (tasks.lua's poll): in the chat and the bubble, and on Telegram
-- when the job came from there or you're away from the Mac.
function TK.relay(task, ev)
  local name = task.name or "Your session"
  local text, line, buttons
  if ev.kind == "permit_closed" then
    local p = TK.lib.permit(task.id, ev.rid)
    if p and p.state == "closed" and Telegram and Telegram.running() then
      TK.closePermit(task.id, ev.rid, p.reason or "Answered on the Mac")
    end
    return
  elseif ev.kind == "permit" then
    if not TK.lib.permitOpen(task.id, ev.rid) then return end
    local p = TK.lib.permit(task.id, ev.rid)
    if not p or p.state ~= "open" then return end
    text = "🔐 " .. name .. " wants to run: " .. (p.summary or "Tool")
    buttons = { {} }
    if p.truncated then text = text .. "\n\nThis request is too long to show in full. Answer on the Mac."
    else buttons[1][1] = { text = "✅ Allow once", data = "p:" .. ev.rid .. ":a" } end
    buttons[1][#buttons[1] + 1] = { text = "❌ Deny", data = "p:" .. ev.rid .. ":d" }
    Chat.post("assistant", text)
    line = name .. " needs your OK!"
    Theme.interrupt()
    eventMood, eventUntil = "needsYou", now() + 8
  elseif ev.kind == "done" then
    local said = (ev.text or ""):match("^%s*(.-)%s*$")
    if said == "" then said = "(It finished its turn without a word.)" end
    Chat.post("task", said, nil, name)
    text = "🛠 " .. name .. ":\n" .. TK.lib.clip(said, 3500) .. "\n\n"
      .. (task.tmux and "↩️ Reply to this to answer it." or task.url and ("Answer it in the Claude app: " .. task.url) or "")
    line = clip(name .. ": " .. (said:match("^[^\n]+") or said), 100)
    lastDone = now() -- its Terminal title turns ✳ as well; one line about that is plenty
    doAction("wave", 2)
  elseif ev.kind == "asking" then
    for _, rid in ipairs(task.open_permits or {}) do
      if TK.lib.permitOpen(task.id, rid) then return end
    end
    text = "🔐 " .. name .. " needs your OK: " .. (ev.text or "") .. "\n"
      .. (task.url and ("Answer it in the Claude app: " .. task.url) or "Answer it in its Terminal window.")
    Chat.post("assistant", text)
    line = name .. " needs your OK!"
    Theme.interrupt()
    eventMood, eventUntil = "needsYou", now() + 8
  elseif ev.kind == "ended" then
    if TK.stopped[task.id] then TK.stopped[task.id] = nil; if not task.thread then return end end
    text, line = "🛠 " .. name .. " has ended.", name .. " has ended."
    Chat.post("assistant", text)
  else
    return
  end
  say(line, "user", true)
  local phone = Telegram and Telegram.running() and (task.origin == "telegram" or hs.host.idleTime() >= PRESENT_FOR
    or (ev.kind == "ended" and task.thread))
  if phone then
    local thread = TK.lib.thread(task)
    Telegram.send(text, function(ok, ids)
      for _, id in ipairs(ids or {}) do TK.lib.remember(id, task.id, ev.kind == "permit" and ev.rid or nil, text) end
      -- A Mac answer can arrive while sendMessage is still in flight.
      if ev.kind == "permit" then
        local p = TK.lib.permit(task.id, ev.rid)
        if p and p.state ~= "open" then TK.closePermit(task.id, ev.rid, p.reason or "Answered on the Mac") end
      end
      if ev.kind == "ended" and TK.lib.thread(task) then Telegram.editTopic(TK.lib.thread(task), "✔ " .. name) end
      if ok and TG.voice_replies == "always" then Telegram.voiceReply(text, TK.lib.thread(task)) end
    end, { thread = thread, buttons = buttons, onMissingThread = TK.missingThread(task) })
  end
end

-- The right-click menu's Task sessions submenu; nil when none are running.
function TK.menu()
  local out = {}
  for _, t in ipairs(TK.lib.list()) do
    if t.state ~= "ended" then
      local sub = {}
      if t.tmux then
        sub[#sub + 1] = { title = "Open its window", fn = function()
          TK.lib.open(t.id, function(info) if not info.ok then say(info.error, "user") end end)
        end }
      end
      if t.url then
        sub[#sub + 1] = { title = "Copy its phone link", fn = function()
          hs.pasteboard.setContents(t.url)
          say("Link copied!", "user")
        end }
      end
      sub[#sub + 1] = { title = "Stop it", fn = function()
        TK.stopped[t.id] = true
        TK.lib.stop(t.id, function(info) say(info.ok and ("Stopped " .. t.name .. ".") or info.error, "user") end)
      end }
      out[#out + 1] = { title = t.name .. " (" .. TK.lib.state(t) .. ")", menu = sub }
    end
  end
  return #out > 0 and out or nil
end

function M.start()
  math.randomseed(os.time())
  if not hs.settings.get("claudeBuddy.metAt") then hs.settings.set("claudeBuddy.metAt", os.time()) end
  updateKnown()
  M.canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = H })
  -- desktopIcon + 1: Finder's desktop window shares the desktop-icon level and would eat clicks
  M.canvas:level(ON_TOP and hs.canvas.windowLevels.floating or hs.canvas.windowLevels.desktopIcon + 1)
  M.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  M.canvas:clickActivating(false)
  M.canvas:mouseCallback(function(_, msg, id)
    if msg == "mouseDown" then onMouseDown(id == "bubble") end
  end)
  place()
  M.canvas:show()

  poll()
  say(fill("Hi {name}! I'm your Claude buddy."), true)
  if Privacy.willLook({ brain = Brain ~= nil, watching = Privacy.watching(), auto = CFG.auto_reactions == true,
        health = Health ~= nil }) and not hs.settings.get("claudeBuddy.toldWatching") then
    hs.settings.set("claudeBuddy.toldWatching", true)
    M.toldTimer = hs.timer.doAfter(8, function()
      say("Heads up: I peek at your screen now and then to learn. Right-click me to pause.", "user")
    end)
  end
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
  if Grok then startGrok() end
  if TG then M.telegram = Telegram.start(TG, onTelegram, telegramTrouble, M.tgCommands) end
  if TK.lib then
    M.taskTimer = hs.timer.doEvery(2, function() TK.lib.poll(TK.relay) end)
    -- a session that died without its SessionEnd hook: buddy-task list marks it ended
    M.taskSweep = hs.timer.doEvery(60, function() if TK.lib.summary() then TK.lib.sweep() end end)
  end
  if NC then M.noticeTimer = hs.timer.doEvery(5, NC.poll) end
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
  Telegram = Telegram or dofile(DIR .. "/telegram.lua")
  M.wizard.open({ dir = DIR, config = CFG, builtinMood = builtinMood, firstRun = firstRun, telegram = Telegram })
  say(firstRun and "Let's get to know each other!" or "Teach me stuff!", "user")
end

-- Switch the brain from the menu. Claude model to Claude model takes effect on the next
-- request; any other change needs a reload (config.lua is rewritten first).
function M.setBrain(choice)
  M.wizard = M.wizard or dofile(DIR .. "/setup.lua")
  local key, label, claude = M.wizard.brainInfo(choice)
  M.wizard.setBrain(DIR, CFG, key ~= "plain" and key)
  if claude and AI and AI.engine == "claude" and Agent and pcall(Agent.setModel, key) then
    AI.model = key
    return say("Brain: " .. label .. ".", "user")
  end
  say("Brain: " .. label .. ". One moment…", "user")
  M.reloadTimer = hs.timer.doAfter(1.5, function() hs.reload() end)
end

-- "Buddy's usage": today, the last week and this month of Buddy's own Claude use, from
-- bin/buddy-usage, shown in the chat (or an alert when there's no brain to chat with).
function M.buddyUsage()
  M.usageReport = M.usageReport or dofile(DIR .. "/usage_report.lua")
  if M.usageTask and M.usageTask:isRunning() then return end
  M.usageTask = hs.task.new("/usr/bin/python3", function(_, out)
    local ok, report = pcall(hs.json.decode, out or "")
    local text = M.usageReport.format(ok and type(report) == "table" and report.ok and report or nil)
    if Brain then
      Chat.post("assistant", text)
      openChat({ quiet = true })
    else
      hs.dialog.blockAlert("Buddy's usage", text)
    end
  end, { "-I", DIR .. "/bin/buddy-usage" })
  M.usageTask:start()
end

-- "Forget what you've learned about me…": asks first, since it can't be undone.
function M.forgetAsk()
  local answer = hs.dialog.blockAlert("Forget what I've learned about you?",
    "My notes, app habits, health goals, chat and chat archive go. This can't be undone.", "Forget", "Cancel")
  if answer ~= "Forget" then return end
  M.forget()
  say("Done. We're strangers again.", "user")
end

-- Watching: pauses apply at once; turning it off or on rewrites config.lua and reloads.
function M.pauseWatching(seconds)
  if seconds then Privacy.pause(seconds) else Privacy.pauseUntilMorning() end
  say(seconds and "Okay, eyes shut for an hour." or "Okay, eyes shut until morning.", "user")
end

function M.resumeWatching()
  Privacy.resume()
  say("Watching again.", "user")
end

function M.setWatching(on)
  M.wizard = M.wizard or dofile(DIR .. "/setup.lua")
  CFG = M.wizard.setOption(DIR, CFG, "watch", on)
  say(on and "Watching's on. One moment…" or "Watching's off. One moment…", "user")
  M.reloadTimer = hs.timer.doAfter(1.5, function() hs.reload() end)
end

-- Open a new GitHub issue for the widget in the browser, filled in with versions,
-- settings and recent errors (report.lua). Nothing is filed until Submit is clicked there.
function M.reportBug()
  M.report = M.report or dofile(DIR .. "/report.lua")
  M.report.open(DIR, CFG)
  say("Tell them what I broke! I filled in the boring bits.", "user")
end

-- The What's New window (whatsnew.lua) on version v ("next" previews the draft), or on
-- this version's release.
function M.whatsNew(v)
  ClaudeWhatsNew = ClaudeWhatsNew or dofile(DIR .. "/whatsnew.lua")
  if not ClaudeWhatsNew.init(DIR).open(v) then say("Nothing new to show yet.", "user") end
end

-- Put on a skin the way the Skin menu does (saved, with a cheer). False if there's no such skin.
function M.wearSkin(id)
  for _, s in ipairs(Skins.list()) do
    if s.id == id then pickSkin(id); return true end
  end
  return false
end

M.say = say
M.skins = Skins -- pick(id), wear(id) / wear(nil) for themes, list(); see skins.lua
M.theme = Theme -- the Halloween theme; Theme.status() says what it's doing
-- Play a skit now (the theme must be on): ClaudeBuddy.skit("hat-perch")
M.skit = function(id) return Theme.skit(id) end
-- Turn the Halloween theme on or off for this session (nil goes back to the dates); not saved.
M.halloween = function(on) Theme.set(on) end
-- A money comparison from the brain for the card's API value row; false when there's no brain or it can't ask.
function M.compare(ctx, done) return Brain ~= nil and Brain.compare(ctx, done) or false end
M.peek = function() return peek("screen", true) end
M.chat = function() openChat() end
-- Wipe the chat transcript, what the brain remembers about you, and the habits and
-- facts every feature keeps (FORGET_STORES).
M.forget = function()
  Privacy.forget({ brain = Brain, chat = Chat, stores = FORGET_STORES })
end
M.joke = tellJoke
M.newSession = newSession
M.tasks = TK -- hs -c 'return ClaudeBuddy.tasks.lib.listText()'
M.telegramStatus = function() return Telegram and Telegram.status() or "Telegram: off" end
return M
