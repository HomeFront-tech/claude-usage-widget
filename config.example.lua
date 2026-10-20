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
-- chat, reading, curious, tinker, browsing, snow, proud, music, home, generic.
