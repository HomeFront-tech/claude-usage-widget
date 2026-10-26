# Buddy: ideas borrowed from Hermes Agent

Date: 2026-10-25. Status: approved by the owner, building.

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research, MIT) is a
personal agent with a Telegram gateway, a memory loop and scheduled jobs. Buddy borrows
its patterns, not its code or runtime: Buddy stays a small Hammerspoon module with one
long poll. Where a pattern came from Hermes, the code comment can say so in one line.
A local copy of the Hermes source, useful as a reference for Telegram Bot API calls, may
be at `~/.hermes/hermes-agent/plugins/platforms/telegram/adapter.py`.

Every new key is optional, read with a default, and documented in `config.example.lua`
with neutral examples. Old `config.lua` files keep working. Nothing personal goes in the
repo.

## 1. Telegram transport (telegram.lua, buddy.lua's Telegram section)

### 1a. Send queue and flood control
- One queue per chat: a second `T.send` waits until the first one's pieces are all out,
  so two replies never interleave.
- On HTTP 429, read `parameters.retry_after` from the Bot API reply, wait that long and
  retry the same piece (at most 3 times). Never resend pieces already delivered. A
  network error retries the piece twice with a short backoff.
- `call` hands `retry_after` to its callback.

### 1b. Buttons (inline keyboards)
- `allowed_updates` adds `"callback_query"`.
- `T.parse` returns `{ callback = data, query = id, message_id = n }` for a callback
  query, only when `query.from.id` is the paired chat id and the query's message is in
  the paired private chat. Everything else stays ignored.
- `T.send(text, done, opts)`: `opts.buttons` is rows of `{ text = ..., data = ... }`
  (`data` at most 64 bytes); `opts.thread` is a `message_thread_id` (see 4b);
  `opts.reply_to` a message id.
- `T.answer(queryId, text)` (`answerCallbackQuery`), `T.edit(messageId, text, buttons)`
  (`editMessageText`; `buttons = false` removes the keyboard).
- buddy.lua routes callbacks by prefix: `t:` task proposals (1c), `p:` permission
  answers (section 4). Unknown or stale data gets `T.answer(id, "That one's done.")`.

### 1c. Task proposals get buttons
When Buddy asks whether to start a task session (or to send text into one) on Telegram,
the question carries `[▶️ Start] [✖️ No]` (`t:<id>:y|n`). A tap does exactly what typing
yes or no does, then edits the question to show the answer and drops the keyboard.
Typing yes or no keeps working.

### 1d. Photos
- `T.parse` also returns `{ photo = file_id, caption = ..., message_id = ... }` for
  `message.photo` (largest size not over 1600 px on its longest side, or the largest
  when all are bigger) and for an image `message.document` (`mime_type` image/*).
- buddy.lua downloads it (10 MB cap, temp file, deleted after), and hands it to the
  brain as an image on the newest user turn, with the caption (or "(a photo)") as the
  text. The brain already takes images for screenshots; use the same path and format.
- Plain-rules Buddy (no brain) says it needs a brain to look at photos.
- README privacy line: photos go to the brain you picked (Anthropic with Claude,
  nowhere with Ollama), like screenshots, and aren't saved.

### 1e. Command menu
On start, `setMyCommands` registers the commands that are on: help, usage, sessions,
task, tasks, stop (tasks on), notes, forget (section 2b), watch, watches, unwatch
(section 3). Only when the list changed since last time (keep a hash in hs.settings).

### 1f. Awake/asleep status
`telegram.status` (default true): the bot's short description
(`setMyShortDescription`) says `🟢 The Mac is awake. Text me!` on start and wake, and
`💤 The Mac is asleep. I'll answer when it wakes.` on `systemWillSleep` and from
`hs.shutdownCallback`. Only call when the state changes. Failures are ignored.

### 1g. Reactions
`telegram.reactions` (default true): `setMessageReaction` puts 👀 on each message Buddy
takes in, then 👍 once the answer is out or 👎 if the answer failed. Needs `message_id`
in `T.parse`'s result for every kind.

### 1h. Voice replies
`telegram.voice_replies` = `"voice"` (default: answer a voice note with a voice note as
well as text), `"always"`, or `false`.
- Text to speech: `telegram.tts` is an optional command `{ "/path/cmd", "{in}", "{out}" }`
  where `{in}` is a UTF-8 text file and `{out}` an audio file path the command writes
  (any format ffmpeg reads). Without it, `/usr/bin/say -f {in} -o {out}.aiff`.
- `ffmpeg` (already needed for dictation; absolute path from /opt/homebrew/bin or
  /usr/local/bin) converts to OGG/Opus: `-c:a libopus -b:a 32k -ac 1`.
- Upload with `/usr/bin/curl -sS -K -`, the URL given on stdin as a curl config line, so
  the bot token never appears in the process list. `sendVoice` with `chat_id` and
  `voice=@file` (plus `message_thread_id` when set).
- Speak at most the first ~1,200 characters (cut at a sentence end). Strip markdown and
  URLs from the spoken text. Temp files deleted after. Any failure: the text reply
  already went out; print one console line.

### 1i. Affection
A token-free word list (no model call), matched on short user messages (under ~60
characters) or ones that name Buddy: "good bot", "good buddy", "thank you", "thanks",
"ty", "ily", "love you", "<3", ❤️ 🥰 😍 💕 💖. On the desktop the buddy shows its heart
eyes / hearts for a few seconds (reuse the existing heart look). On Telegram the
reaction is ❤ instead of 👍. It still answers normally.

## 2. Brain and memory (brain.lua, chat.lua, bin/buddy-tools)

### 2a. Searchable chat archive
- Every line chat.lua adds (role, content, via, name, at) is also appended to
  `chat-archive.jsonl` in Buddy's data folder (`~/Library/Application Support/claude-usage-widget/`).
  No images. When it passes 5 MB, keep the newest half.
- **Forget** (the menu item and `ClaudeBuddy.forget()`) deletes the archive too.
- `bin/buddy-tools` gets `chat_search(query, limit = 10)`: case-insensitive word match,
  ranked by hits then recency, each result with its date, who said it, the channel, and
  the line before and after. Available in chat mode and job mode. Read-only.
- The Claude brain's system prompt says, once: older conversations can be looked up with
  chat_search; use it when they refer to something from before.

### 2b. Notes you can see and edit
- Notes become a list: `{ entries = { { text, at }, ... }, at = n }` in the same
  hs.settings key. An old `{ text = "...", at = n }` is read as one entry per line
  (leading `- ` dropped) and saved in the new shape on the next write.
- Limit `ai.notes_limit` characters in total (default 1400). The prompt shows them as a
  list with how full they are ("6 notes, 71% full").
- `B.remember` asks the note model for JSON edits instead of a full rewrite:
  `{"add": ["..."], "replace": [{"old": "<substring>", "new": "..."}], "remove": ["<substring>"]}`.
  Apply them in order. An add that would pass the limit is dropped. A parse failure
  changes nothing (today's code would rewrite everything).
- After edits apply, Buddy posts one quiet line in the chat panel: `📝 Noted: <added or
  changed text>` (or `📝 Forgot: …`). The chat shows it in a small grey style. B.turns
  never sends these lines to the brain. On Telegram the same line goes out only when the
  conversation that led to it came from Telegram.
- Commands (chat panel and Telegram): `/notes` lists them numbered; `/forget 3` removes
  one; `/forget` alone explains. The right-click menu gets **What I remember about
  you…**, which opens the chat showing the list.

### 2c. Prompt-cache-friendly prompts
The Claude brain runs `claude -p --system-prompt <sys>`, so the system prompt is the
start of every request and anything that changes in it makes the whole request miss the
prompt cache.
- The system prompt holds only what is stable: the persona or assistant text, the notes,
  fixed instructions (including the two fixed variants for "chat panel" and "Telegram").
- Everything that changes each call moves to a short bracketed context block at the start
  of the newest user turn: the day and time, how long it was quiet, the window/app and
  title, the Mac status (sessions and usage), the task list, the health summary.
- History: today B.turns takes the last 20 entries, so the start of the conversation
  shifts every turn. Give each chat entry a monotonic sequence number and start the
  window on a multiple of 10, so the window is 20 to 29 entries and its start moves once
  every 10 lines.
- Check the other dispatch kinds (quips, learn, compare) for the same issue.
- Log `cache_read_input_tokens` and `cache_creation_input_tokens` from the stream-json
  result in Buddy's usage ledger when present, so the effect can be measured.
- Ollama gets the same message layout.

## 3. Standing jobs (automations.lua, bin/buddy-tools, buddy.lua's jobs section)

### 3a. Results to the phone
When a standing job's result is ready, Telegram is paired, `telegram.jobs` is not false,
and the owner is away (the same idle rule task updates use), send it to Telegram
(`🗓 <job name>:` then the text) and count it as delivered, so it doesn't pop up again
in the chat panel later (it is still in the chat history).

### 3b. Watches
- A new job trigger `{ type = "every", minutes = n, ["until"] = unix_time }`. `minutes`
  is at least `ai.watch_min` (default 15). `until` defaults to the end of today and is
  at most 7 days ahead; the job is removed after it.
- Each run's prompt includes the previous result and says: if nothing worth telling has
  changed, reply exactly `NOTHING NEW`. Buddy says nothing for those runs.
- Delivery: like other jobs (chat panel and bubble when present, Telegram when away),
  and always Telegram when the watch was made from Telegram.
- At most `ai.watch_runs` runs per day across all watches (default 40). Runs count in
  Buddy's usage like other jobs.
- `/watch 30m <what to check>` (Telegram and chat panel; units m or h) makes one
  without a brain round trip; `/watches` lists them with time left; `/unwatch 2` removes
  one. The brain's automation tool can also make `every` jobs.
- Needs the Claude brain (jobs do). Without it, `/watch` says so.

## 4. Task sessions from the phone (bin/buddy_tasks.py, tasks.lua, buddy.lua TK)

### 4a. Allow / Deny buttons for permission questions
Verified on Claude Code 2.1.310: a `PermissionRequest` command hook runs while the
permission prompt is on screen (Terminal and the Claude app still work), and a decision
from the hook closes that prompt. A hook that exits without a decision leaves the prompt
as it is.
- `telegram.approvals` (default true, only matters when Telegram is paired). The
  session's settings get a `PermissionRequest` hook (matcher `*`, timeout 600) running
  `buddy-task permit <task id>`.
- `permit` reads the payload, writes `tasks/<id>/permits/<rid>.json` (`rid` = 12 random
  hex chars; tool name, a one-line summary, time), emits a `permit` event, then waits up
  to 570 s for `<rid>.decision` (`allow` or `deny`), checking every half second.
  - allow → prints `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  - deny → `"behavior":"deny"` with `"message"` saying the owner said no from Buddy.
  - Answered elsewhere or timed out → exits 0 with no output, and emits `permit_closed`.
  "Answered elsewhere": any later hook event for the same task (PostToolUse,
  PostToolUseFailure, UserPromptSubmit, Stop, SessionEnd) marks that task's open permits
  closed.
- Never "always allow" and never `updatedPermissions`: one tap allows one call.
- Summary line: Bash → the command; Edit/Write/MultiEdit/NotebookEdit → the file path;
  WebFetch → the URL; MCP tools → server and tool; anything else → the tool name and its
  first short field. At most 300 characters.
- Buddy relays a `permit` event like task updates (Telegram when the task came from
  there or the owner is away): `🔐 <name> wants to run: <summary>` with
  `[✅ Allow once] [❌ Deny]` (`p:<rid>:a|d`). The bubble and chat panel say it needs an
  OK, as today.
- A tap writes the decision through a new `buddy-task answer <task id> <rid> allow|deny`
  (refuses when the permit is closed), answers the callback ("Allowed" / "Denied" /
  "Already answered"), and edits the message to show the outcome without buttons. On
  `permit_closed`, Buddy edits an unanswered message to "Answered on the Mac" (or "Timed
  out").
- While a permit message is out for that task, the older `Notification`
  (`permission_prompt`) "needs your OK" message is not sent again.
- `telegram.approvals = false` keeps today's behaviour exactly (no hook registered).

### 4b. A topic per task session
Telegram private chats can have topics (forum threads) when the owner turns Topics on
for the chat (Bot API 9.4; the bot can't turn it on).
- `telegram.topics` (default true). When a task session starts and Telegram is paired,
  try `createForumTopic` in the paired chat with the task's name. On success, store the
  `message_thread_id` with the task and send all its updates, permits and task-started
  links there. On failure, remember "no topics" for a day and fall back to today's
  reply-to threading.
- A message in a task's topic goes to that task (as a reply to its update does now). A
  message in any other topic or the main chat goes to Buddy's chat; Buddy answers in the
  same thread it came from.
- When the task ends, post the ended line in its topic and rename the topic with a ✔
  prefix (`editForumTopic`); don't delete it.

## 5. Streaming replies (brain dispatch, telegram.lua)
`telegram.streaming` (default true; Claude brain only).
- Run the chat call with `--include-partial-messages` and read text deltas from the
  stream-json output as they arrive (hs.task streaming callback).
- On Telegram: once there are 40+ characters or 1.5 s passed, send the text so far, then
  `editMessageText` it at most every 1.5 s. At the end, edit it to the final cleaned
  text; overflow past 4096 goes out as further pieces. If an edit fails, stop editing and
  send the final text as usual. The typing dots stop at the first piece.
- `streaming = "draft"` uses `sendMessageDraft` (Bot API 9.5, private chats) instead of
  edits, falling back to edits if a draft call fails.

## Testing
Lua specs for each part in `tests/` (fakes in `tests/fakes/`, temp folders, never live
state): telegram_spec.lua (queue, 429, callbacks, photos, reactions, voice command
lines, status changes), notes and prompt layout specs, automations specs for `every`,
tasks specs for permits and topics. Python unittest for `buddy-tools` chat_search and
for `buddy_tasks.py` permit/answer (including timeout and closed paths). Run:
`/usr/bin/lockf -k /tmp/buddy-hs.lock tests/lua-tests` and
`/usr/bin/python3 -m unittest discover -s tests -v`.

## Out of scope
Hermes's multi-platform gateway, kanban, profiles, self-written skills and their curator,
remote terminals, and running Buddy on Hermes.
