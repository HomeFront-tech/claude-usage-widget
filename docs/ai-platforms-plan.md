# Buddy and the other AI platforms: survey and plan

Status: PLAN ONLY. Nothing built. Branch `ai-platforms`.

## Goal
Buddy knows which AI tools are on this Mac, can say what each is doing (read-only),
and, where the tool officially supports it, hand a question to it and bring the answer back.

## What is on this Mac today (surveyed 2026-10-26, nothing opened except folder listings)
| Platform | Found | What it realistically exposes |
|---|---|---|
| Claude Code | `claude` CLI | `~/.claude/sessions/<pid>.json` + transcripts. Already covered by branch `session-reach` (bin/buddy_sessions.py). |
| Codex | `codex` CLI, ChatGPT-adjacent `com.openai.codex` | Session files under `~/.codex/sessions/<year>/<month>/`, `session_index.jsonl`; CLI `codex exec` for one-shot questions. |
| Cursor | Cursor.app, `cursor`, `cursor-agent` | `~/.cursor/` project and chat state; `cursor-agent` CLI headless mode (needs its own login, currently logged out). |
| Grok | Grok Bot.app, `~/.grokbot` | Already handled by grok.lua through the `gbot` CLI. No `grok` CLI. |
| ChatGPT | ChatGPT.app, ChatGPT Classic.app | No public local activity or question interface. Presence only (installed, running, in front). |
| Kimi | `kimi` CLI 2.3.2 | CLI with a non-interactive mode; needs Rennie's login (not done yet). |
| Others | opencode, hermes, ollama | CLIs; Ollama already used for the local brain. |
| Not installed | Gemini CLI, Copilot CLI, aider | Detect automatically if they appear later. |

## Design: one "provider" file per platform
Each provider is a small Python module in `bin/providers/` (Buddy's tools are Python behind Lua) with the same four calls:
1. `detect()`: installed? running? signed in? (checks for app/CLI files and running processes only)
2. `status()`: busy/idle and recent sessions, from that tool's own local session files (read-only)
3. `read(ref)`: summary of one session (cut short, treated as information, never as instructions to Buddy)
4. `ask(question)`: ONLY where the tool has an official command (`codex exec`, `cursor-agent -p`, `kimi` print mode, `gbot`). Off by default; Rennie turns on each one.

A registry loads every provider it finds, so a new tool is one new file. Buddy gets three new chat tools: `ai_list`, `ai_status`, `ai_ask`. The existing `session-reach` Claude Code reader becomes the Claude provider rather than being duplicated.

## Rules I will keep
- No reading of tokens, keychain, `auth.json`, `credentials` or browser profiles. Those paths are on a blocklist in code and tested.
- Read-only by default. Asking a tool a question uses only the tool's own official command and its own login.
- Only Rennie's words go out, never screen contents or private files, same rule as grok.lua.
- Local chat logs are summarised on the Mac; nothing is sent to a third party unless Rennie asks that tool a question.

## Overlap with other streams
- `session-reach` (Claude Code sessions): I build on it after it merges; until then I do not touch `bin/buddy_sessions.py`.
- `grok.lua`: stays; Grok gets wrapped as a provider later.
- `brain.lua`, `bin/buddy-tools`, `README.md`: shared files, small additions only, noted in the handoff.

## Build order (each step small, tested, own commit)
1. Provider registry + `detect()` for all of the above, with the "What's on my Mac" answer in chat.
2. `status()` for Codex and Cursor from local session files.
3. `ask()` for Codex, then Cursor, then Kimi (each off by default).
4. Fold into the card: small row of icons showing which AI tools are active.

## Questions for Rennie
- "Fold the features in": does he mean Buddy can use those tools' abilities (ask them things), or show their usage like the Claude plan card? (Plan covers both; step 4 is the usage side.)
- OK to build steps 1 and 2 (read-only) now?
