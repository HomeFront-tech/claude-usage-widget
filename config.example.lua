-- Copy this file to config.lua (same folder) and edit it. config.lua is gitignored.
-- Reload Hammerspoon afterwards. Every setting is optional.
return {
  -- The buddy greets you by name ("Hi Sam!").
  name = "Sam",

  -- true floats the buddy above your windows instead of sitting on the desktop.
  buddy_on_top = false,

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
