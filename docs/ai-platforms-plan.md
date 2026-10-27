# Buddy and the other AI platforms: survey and plan

Status: design notes. Step 1 (detect and status, read-only) is built as `bin/buddy_ai.py` and the `ai_list` chat tool; the rest is still to do.

## Goal
Buddy knows which AI tools are on this Mac, can say what each is doing (read-only),
and, where the tool officially supports it, hand a question to it and bring the answer back.

## What each platform can realistically expose
| Platform | What a Mac may have | What it exposes |
|---|---|---|
| Claude Code | `claude` command | Session files and transcripts under `~/.claude/`; covered by the session-reach work. |
| Codex | `codex` command | Session files under `~/.codex/sessions/`; `codex exec` for one-shot questions. |
| Cursor | Cursor app, `cursor`, `cursor-agent` | Project state under `~/.cursor/`; `cursor-agent` has a headless mode (needs its own sign-in). |
| Grok | Grok Bot app | Handled by grok.lua through the `gbot` command. |
| ChatGPT | ChatGPT desktop app | No public local activity or question interface: presence only (installed, open). |
| Kimi | `kimi` command | Command with a non-interactive mode (needs its own sign-in). |
| Others | OpenCode, Hermes, Ollama, Gemini CLI, Copilot CLI, aider | Detected by name when installed. |

## Design: one "provider" file per platform
Each provider is a small Python module in `bin/providers/` (Buddy's tools are Python behind Lua) with the same four calls:
1. `detect()`: installed? running? signed in? (checks for app/CLI files and running processes only)
2. `status()`: busy/idle and recent sessions, from that tool's own local session files (read-only)
3. `read(ref)`: summary of one session (cut short, treated as information, never as instructions to Buddy)
4. `ask(question)`: ONLY where the tool has an official command (`codex exec`, `cursor-agent -p`, `kimi` print mode, `gbot`). Off by default; the owner turns on each one.

A registry loads every provider it finds, so a new tool is one new file. Buddy gets three new chat tools: `ai_list`, `ai_status`, `ai_ask`. The existing `session-reach` Claude Code reader becomes the Claude provider rather than being duplicated.

## Rules I will keep
- No reading of tokens, keychain, `auth.json`, `credentials` or browser profiles. Those paths are on a blocklist in code and tested.
- Read-only by default. Asking a tool a question uses only the tool's own official command and its own login.
- Only the owner's words go out, never screen contents or private files, same rule as grok.lua.
- Local chat logs are summarised on the Mac; nothing is sent to a third party unless the owner asks that tool a question.

## Overlap with other streams
- `session-reach` (Claude Code sessions): I build on it after it merges; until then I do not touch `bin/buddy_sessions.py`.
- `grok.lua`: stays; Grok gets wrapped as a provider later.
- `brain.lua`, `bin/buddy-tools`, `README.md`: shared files, small additions only, noted in the handoff.

## Build order (each step small, tested, own commit)
1. Provider registry + `detect()` for all of the above, with the "What's on my Mac" answer in chat.
2. `status()` for Codex and Cursor from local session files.
3. `ask()` for Codex, then Cursor, then Kimi (each off by default).
4. Fold into the card: small row of icons showing which AI tools are active.
