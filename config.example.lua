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

  -- Minutes without keyboard or mouse before it naps (0 = never).
  sleep_after = 10,

  -- A brain: a small vision model on this Mac through Ollama (ollama pull gemma3:4b).
  -- It jokes about windows it doesn't know and chats when you click it. Leave it out
  -- for plain rules. Screenshots go only to `url` and are never saved.
  ai = {
    model = "gemma3:4b",               -- any Ollama model that takes images
    -- url = "http://localhost:11434", -- where Ollama runs
    peek_every = 0,                    -- seconds between unprompted looks at the screen; 0 = only unknown windows
    -- unknown = false,                -- don't look at windows it doesn't know
    -- private = { "payroll" },        -- extra words in an app or title it never takes a picture of
  },

  -- Cmd-click opens a new Claude Code session here: "Terminal" or "iTerm".
  terminal = "Terminal",
  -- Folders for the menu's "New Claude Code session". Default: your most recently
  -- changed folders in ~/dev, ~/Projects, ~/code or ~/src.
  -- projects = { "~/dev/my-app", "~/work/site" },

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
  -- Which GitHub repo to check for releases; change it if you run your own fork.
  -- update_repo = "HomeFront-tech/claude-usage-widget",

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
-- money, call.
