# Task sessions: hand Buddy a bigger job

## Why
The owner asked Buddy's chat for "a separate Claude Code session dedicated to building a
feature" and it said it couldn't. Buddy should be able to open a Claude Code session for a
job given in the chat panel or over Telegram, with Remote Control on so the owner can drive
it from the Claude app on their phone, and pass its updates and the owner's follow-ups
back and forth through the chat or Telegram.

## What the owner decided
- Every session Buddy opens has Remote Control on, and Buddy sends its link at once.
- Updates and follow-up prompts go through Telegram or the chat, as well as the Claude app.

## Approved guesses
- Buddy confirms in one line (yes or no) before it opens anything.
- Updates are the moments that matter: it started, it needs an answer or approval, it
  finished a turn. Not every step.
- A reply to an update reaches the right session even with several running.
- The session opens in a Terminal window on the Mac, like Cmd-click.

## How it works
- `bin/buddy-task` (`bin/buddy_tasks.py`) opens, types into, stops and lists sessions. A
  session is `claude --remote-control <name> -n <name> --settings <hooks> "<task>"`, run by
  a launch script that notes its PID (the link is `bridgeSessionId` in
  `~/.claude/sessions/<pid>.json`). It runs in Buddy's own tmux server
  (`tmux -L claude-buddy -f bin/buddy-tmux.conf`) inside a new Terminal window opened from a
  throwaway `.command` file (no Automation permission). Without tmux it runs in Terminal
  directly and only the Claude app can answer it.
- The session's hooks (UserPromptSubmit, PostToolUse, Notification, Stop, SessionEnd) call
  `buddy-task hook <id>`, which keeps `task.json` state (working, asking, waiting, ended) and
  appends `done` (with `last_assistant_message`), `asking` and `ended` events to
  `events.jsonl`. The hook prints nothing, since UserPromptSubmit output joins the prompt.
- `tasks.lua` reads the events every 2 s (whole lines only, offsets kept across reloads),
  holds the yes-or-no question, maps Telegram message ids to sessions, and runs
  `bin/buddy-task`. `buddy.lua` relays: the chat transcript (a `task` line labelled with
  the session's name) and the bubble always, Telegram when the job came from there or the
  owner has been idle a minute.
- Follow-ups are pasted with `tmux load-buffer` + `paste-buffer -p` (bracketed paste, so
  several lines stay one message) and Enter. Not while a permission question is open.

## Safety
The chat brain reads files, mail and web pages, so it must not be able to open or drive a
full Claude Code session by itself. Its `task_start` and `task_send` tools only write
`pending.json`; Buddy (Lua, not the model) asks the owner and acts on a literal yes. A send
whose text is the owner's own words from their latest message skips the question, as does
a Telegram swipe-reply to a session's update. The `task_*` tools exist only in chat mode,
never in automations, and only when `tasks` is on.

## Calls made by the builder
- tmux for follow-ups and for keeping a job alive when its window closes, rather than
  Claude Code's internal session socket, which isn't a public interface.
- `/task`, `/tasks` and `/stop` work in the chat and on Telegram for every brain, including
  a local model with no tools.
- Sessions use the owner's normal Claude Code settings and permission mode; `tasks.model`
  and `tasks.effort` in config.lua are optional.
