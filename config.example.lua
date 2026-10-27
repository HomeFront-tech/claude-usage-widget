-- The setup wizard (Option-click the buddy) writes config.lua for you. To set things
-- by hand instead, copy this file to config.lua (same folder), edit it, and reload
-- Hammerspoon. config.lua is gitignored. Every setting is optional.
return {
  -- The buddy greets you by name ("Hi Sam!").
  name = "Sam",

  -- true floats the buddy above your windows instead of sitting on the desktop.
  buddy_on_top = false,

  -- How often it talks on its own: "chatty", "normal", "quiet" or "silent" (only when clicked).
  chatter = "normal",

  -- Personality dials, 0 to 100 like TARS. Leave one out for its default (humor 75, sarcasm 60,
  -- honesty 60, warmth 60, wordiness 30). They need a brain; plain rules don't change.
  -- personality = { humor = 90, sarcasm = 40, honesty = 90, warmth = 60, wordiness = 20 },

  -- Voice switches and the Talk out loud slider live in the setup wizard and right-click
  -- menu, saved in Hammerspoon's settings. These optional timings change listening:
  -- gap = seconds of quiet that end what you're saying; timeout = seconds Buddy waits
  -- after "okay Buddy" alone for you to continue.
  -- live = false: one question per "okay Buddy" (the default is a live chat that goes on until
  -- you say "we're done"); liveTimeout = seconds of quiet that end a live chat (default: never).
  -- voice = { gap = 1.0, timeout = 6, phrase = "okay Buddy", live = true, liveTimeout = 600 },

  -- The Halloween theme turns itself on October 24–31. true keeps it on all year, false keeps it off.
  -- halloween = true,

  -- Minutes without keyboard or mouse before it naps (0 = never).
  sleep_after = 10,

  -- Claude uses your Claude plan. Choose "auto" (Haiku for short work, Opus for
  -- chat and jobs, Sonnet helpers for research) or one alias for all work:
  -- "haiku", "sonnet", "opus", "fable". Leave `ai` out for plain rules, or remove
  -- `engine` and use model = "gemma3:4b" for local Ollama (ollama pull gemma3:4b).
  ai = {
    engine = "claude",
    model = "auto",
    daily_unprompted = 300,            -- daily cap on lines Buddy starts on its own
    watch_min = 15,                    -- shortest watch interval, in minutes
    watch_runs = 40,                   -- most watch runs in one day, across all watches
    web_search = true,                 -- allow web search in chat
    notes_limit = 1400,                -- total characters Buddy may keep in editable notes
    -- search = { "/usr/bin/mdfind", "-name" }, -- optional file search command
    -- private_paths = { "~/Private" }, -- extra folders Buddy may never read
    sources = {
      date = { cmd = { "/bin/date" }, about = "Current date and time" },
    },
    -- url = "http://localhost:11434", -- where Ollama runs, if using Ollama
    peek_every = 0,                    -- seconds between unprompted looks at the screen; 0 = only unknown windows
    -- unknown = false,                -- don't look at windows it doesn't know
    -- private = { "payroll" },        -- extra words in an app or title it never takes a picture of
    -- dictation = { model = "~/.cache/whisper.cpp/ggml-base.en.bin", language = "en" }, -- hold space to talk in the chat; false = off
  },

  -- The new wizard writes this switch. false stops screenshots and screen learning;
  -- the Watching menu can also pause temporarily. Older configs without this key
  -- keep their earlier behaviour until you save the new wizard.
  watch = true,
  -- With a brain, learn reactions for apps and sites. Needs watching on.
  auto_reactions = true,
  -- Bundle IDs of apps Buddy must never look at; also set per app in the wizard.
  never_look = { "com.example.private-app" },
  -- Health check-ins have their own switch and eight-per-day cap. Leave this out
  -- to keep them off. Defaults: move after 60 min; breakfast 8-10, lunch 12-14,
  -- dinner 17-19. Meal windows use local hours.
  -- health = { sit_minutes = 60, meals = {
  --   breakfast = { 8, 10 }, lunch = { 12, 14 }, dinner = { 17, 19 },
  -- }, daily_cap = 8 },

  -- Let other programs on this Mac hand Buddy a line to say, like a meal tracker's
  -- check-ins. They append a JSON line such as {"text": "Lunch time! What's on the plate?",
  -- "bubble": "Lunch time?", "mood": "food", "telegram": true, "at": <unix time>} to
  -- ~/Library/Application Support/claude-usage-widget/notices-new.jsonl. Buddy puts it in
  -- the chat, the speech bubble and on Telegram. Off unless set.
  -- notices = true,

  -- Ask Buddy in chat to make standing jobs. After four hours away, a sit-down job
  -- runs when you return after 5 AM; daily jobs run at their set time while you're here.
  -- /watch 30m <what to check> makes a temporary watch until tonight; /watches lists
  -- them and /unwatch 2 stops one. Watches that find nothing new stay quiet.

  -- Grok Bot as a teammate. Say "ask Grok …" in the chat and the buddy passes your words
  -- (only your words) to the bot through the gbot CLI and brings the answer back. Grok
  -- can borrow Claude Opus through bin/buddy-opus, which uses your Claude plan: it reads
  -- and thinks freely, but edits, commands and anything that sends wait for your Approve
  -- or Deny next to the buddy. Leave it out to turn all of this off.
  -- grok = {
  --   bot = "Grok Bot",            -- the bot's exact name
  --   gbot = "/path/to/gbot",      -- the gbot CLI on this Mac
  --   app = "Grok Bot",            -- opened in the background when it's closed
  --   opus_daily_cap = 10,         -- Opus runs Grok may ask for per day
  --   approve_timeout = 600,       -- seconds to answer Approve / Deny; no answer = Deny
  --   deny_read = { "~/Private" }, -- extra folders Opus may never read
  -- },

  -- Text the buddy from your phone. The setup wizard pairs a Telegram bot and writes this;
  -- the bot token goes in your Keychain, never here. Only this chat gets answers.
  -- telegram = {
  --   chat_id = 123456789,  -- your private chat with the bot (your Telegram account's id)
  --   bot = "MyBuddyBot",   -- the bot's username, shown in the wizard
  --   name = "Sam",         -- your first name on Telegram, shown in the wizard
  --   status = true,         -- show awake/asleep in the bot's short description
  --   reactions = true,      -- mark received messages and show when an answer is ready
  --   voice_replies = "voice", -- "voice" speaks replies to voice notes; "always" speaks every reply, including tasks; false = text only
  --   tts = { "/path/to/tts", "{in}", "{out}" }, -- optional speech command; defaults to macOS say
  --   approvals = true,     -- Allow once / Deny for task permission questions; the Mac prompt still works
  --   -- Long requests only offer Deny; questions and plan-mode changes stay on the Mac.
  --   -- A tap says Passing it on until the session confirms it; text waits for open approvals.
  --   topics = true,        -- put each task in its own topic when Topics is enabled for the chat
  --   -- Deleted topics fall back to the main chat; Buddy commands still work in a task topic.
  --   jobs = true,          -- send finished jobs when you're away; phone-made watches always send
  --   streaming = true,     -- preview Claude chat replies as they arrive; false waits for the full answer
  --   -- A failed preview still delivers the finished answer.
  --   -- streaming = "draft", -- use Telegram's private-chat draft preview; falls back to edits if unavailable
  -- },

  -- Cmd-click opens a new Claude Code session here: "Terminal" or "iTerm".
  terminal = "Terminal",
  -- Folders for the menu's "New Claude Code session". Default: your most recently
  -- changed folders in ~/dev, ~/Projects, ~/code or ~/src.
  -- projects = { "~/dev/my-app", "~/work/site" },

  -- Task sessions: hand the buddy a bigger job in the chat or over Telegram ("start a
  -- session to add a dark mode to my app", or /task and what it's for). After your yes it
  -- opens a Claude Code session for it in a new Terminal window, with Remote Control on, and
  -- passes its updates on. With tmux (brew install tmux) you can answer it through the
  -- buddy too. On by default; tasks = false turns it off. Optional: the sessions' model and
  -- effort (low, medium, high, xhigh or max); left out, your Claude Code defaults.
  -- tasks = { model = "opus", effort = "high" },

  -- false turns off the built-in Mac events (wake, USB, headphones, screenshots,
  -- downloads, crashes, internet down...).
  -- system_events = false,

  -- Your own events. `log`: a file it checks for new text matching `match` (a Lua
  -- pattern; captures become %1, %2 in the lines). `folder`: new files whose name
  -- matches `match` (%f is the file name). `mood` is any mood below, or an action:
  -- joy, startle, hop, wave, dance. `ai`: with a brain, it makes up a line about this
  -- description instead. `cooldown`: seconds before the same event can fire again (60).
  events = {
    { log = "~/logs/deploy.log", match = "deployed (%w+)", mood = "proud",
      lines = { "%1 is live!", "Shipped %1!" }, ai = "the app %1 was just deployed" },
    { folder = "~/Invoices", match = "%.pdf$", mood = "money", lines = { "New invoice: %f" } },
  },

  -- Notify me when a new version is released (checks GitHub every 6 hours).
  check_updates = true,

  -- Bring Claude Code's older history into the chart's History tab: its /stats daily
  -- totals and the time of each prompt you typed (numbers only, never the prompt).
  -- Claude Code deletes its logs after about 30 days; this keeps the numbers for good.
  import_history = true,
  -- Your Claude plan's monthly price in US dollars, for "× your plan" on the card's API
  -- value line. A billing.json with your receipts takes over where it has them.
  -- plan_price = 100,
  -- Which GitHub repo to check for releases; change it if you run your own fork.
  -- update_repo = "HomeFront-tech/claude-usage-widget",
  -- Where the What's New window sends ratings and ideas, if you run your own copy of
  -- worker/feedback. Without it, ideas open a GitHub issue for you to check and post.
  -- feedback_url = "https://buddy-feedback.example.workers.dev/feedback",

  -- Extra browser-tab rules, checked before the built-in ones.
  -- { "text in the tab title (lower case)", "mood" }
  title_rules = {
    { "my-company.com", "proud" },
    { "jira", "reading" },
  },

  -- Words in a Claude Code session's name -> lines the buddy says when you click into
  -- it (%t is the session's name). Checked before the built-in ones.
  session_topics = {
    { { "checkout", "payments" }, { "Money code! Careful now.", "%t: don't break checkout!" } },
  },

  -- Extra apps, by app name or bundle id -> mood.
  apps = {
    ["Figma"] = "curious",
    ["com.spotify.client"] = "music",
  },

  -- Replace what the buddy says in a mood. " {name}" becomes your name, "%s" the app name.
  lines = {
    proud = { "Hey, that's us!", "Ship it, team!" },
  },
}

-- Moods: idle, coding, claudeWork, claudeWait, love, jealous, watching, gaming, mail,
-- chat, reading, curious, tinker, browsing, snow, proud, music, home, generic, worried,
-- money, call, health, food.
