# Reaching Grok Bot with gbot: notes (2026-10-20)

Task 7 of `2026-10-20-buddy-grok-teammate.md`. Status: **blocked, waiting on the owner.**

## What was checked

- Grok Bot desktop app 0.72.0 (bundle `com.anysphere.sand`) running and signed in.
- `gbot doctor` with the pinned 0.12.2 CLI and with grok-bot-cli 0.12.4 (installed separately
  under the buddy's state folder, `grok/gbot-cli/`, leaving any other install untouched).
  Both report:
  ```
  resolved: (none)
  gateway auth: no
  Grok Bot app session: not found
  ```
- gbot finds the desktop app's session through `~/Library/Application Support/Grok Bot/gateway-descriptor.json`.
  App 0.72.0 doesn't write that file, so the app-session route is closed.
- gbot's other routes are environment variables: `CURSOR_ACCESS_TOKEN`, or
  `GROK_BOT_GATEWAY_URL` + `GROK_BOT_GATEWAY_TOKEN`. Getting either means handling a login
  credential, which is the owner's call. Nothing was read from credential files.

## Options for the owner

1. Wait for a Grok Bot app or gbot release that restores the gateway descriptor, then
   set `grok.gbot` to the working CLI.
2. Give the buddy a gateway URL and token through the environment Hammerspoon launches
   with (never in `config.lua` or the repo).
3. A different path Grok Bot offers for desktop messaging, if one exists.

## Thread format (from an earlier successful probe)

Thread entries look like `{ kind = "message", id, role, timestampMs, seq, requestId, ... }`, and
the owner's sends have `role = "user"`. The text field name and the bot's role value still need
confirming against a live `gbot thread "Grok Bot" --limit 3 --json`. `grok.lua`'s `pickReply`
accepts `text` or `content` and treats any role other than `user` as the bot.

## Not affected

Grok borrowing Opus (`bin/buddy-opus`) doesn't use gbot. Grok runs it through Grok Bot Shell,
so that half works without this.
