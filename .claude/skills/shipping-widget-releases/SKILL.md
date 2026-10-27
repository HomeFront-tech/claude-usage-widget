---
name: shipping-widget-releases
description: Use when committing to, pushing or releasing this public repo, especially when other sessions have uncommitted work in the same folder, when tools/release refuses because of uncommitted changes, or before adding screenshots or text that could contain personal data.
---

# Shipping widget releases

## Overview
The repo is public, and installed copies update themselves from its GitHub releases.
Three things can't be undone: publishing personal data, publishing someone else's
unfinished work, and rewriting history after a release.

## What reaches users
- A push to `main` notifies nobody. Work in progress is fine there.
- `tools/release X.Y.Z "notes"` bumps `VERSION`, tags, pushes and creates the GitHub
  release. Every install shows "vX.Y.Z is out" within 6 hours and fast-forwards to the
  tag when the user clicks. **Ask the owner before every release.** Bump the minor
  version for features and the patch version for fixes. The notes are what users read
  in the update dialog: plain sentences, one per change.

## Commit only your own work
1. Run `git status --short` and, in a main session, `ListAgents` (a sub-agent asks
   whoever started it instead). Files you didn't change belong to someone else, even if
   they look abandoned.
2. Stage by explicit path: `git add buddy.lua events.lua`. Never use `git add -A`,
   `git stash`, `git checkout -- <file>` or `git reset --hard` on another session's
   files: the live buddy reloads them and their work is lost.
3. For a file you both changed (often README.md), stage only your hunks. Write your
   edits as a small script of exact-string replacements and run it on both the working
   file and a copy of the committed version. That works even when your changes sit
   between someone else's in the same file (`git add -p` needs a terminal):
   ```sh
   git show HEAD:README.md > "$OUT/README.mine"   # apply ONLY your edits to this copy
   blob=$(git hash-object -w "$OUT/README.mine")
   git update-index --cacheinfo "100644,$blob,README.md"
   git diff --cached README.md                     # must show only your change
   ```
4. `tools/release` refuses while any tracked file is modified. Don't stash the other
   session's changes to get past it. Message them and release together, or wait.

## Before anything public
- Scan what's staged, not the working tree, and read every hit:
  ```sh
  for f in $(git diff --cached --name-only | grep -v '\.png$'); do git show ":$f"; done \
    | grep -niE 'OWNER_NAME|COMPANY|/Users/|[a-z0-9._-]+@[a-z0-9-]+\.[a-z]{2,}|[0-9]{3}[- .][0-9]{3}[- .][0-9]{4}|sk-ant|ghp_'
  ```
  Fill in OWNER_NAME and COMPANY first: the `name` in config.lua, the GitHub owner in
  `git remote get-url origin`, and anything else private you know about the owner (their
  business, town, clients). If you don't know, ask the owner.
- Screenshots use demo data only (`ClaudeUsage.chart(true)`, `ClaudeBuddy.test(...)`):
  no real usage numbers, names, window titles or desktop around them. Open every PNG
  before adding it.
- `config.lua` is personal and gitignored. New options go in config.example.lua with
  neutral examples.
- A force-push doesn't take anything off GitHub: a replaced commit is still served by
  its SHA (`gh api repos/OWNER/REPO/commits/SHA`). Catch personal data before the first
  push; `git reflog show origin/main` lists commits that were pushed and replaced.

## Several sessions, one release
When parallel sessions each build a feature on their own worktree branch (see
testing-hammerspoon-widgets), ship them together: merge each branch into `main`
(one squash commit per feature, or `git merge --no-ff <branch>`; resolve `buddy.lua` and
README.md conflicts by keeping both sides), run `tests/lua-tests` and the Python tests on the merged `main`, reload and
click through every feature, then ask the owner and make one release whose notes cover
them all. Remove each worktree after merging (`git worktree remove .claude/worktrees/<name>`).

## Batch night with an orchestrator
When the orchestrator ledger for today (a session note named `<date>-buddy-release-orchestrator.md`) exists, one session owns
the day's release and the others only hand off (user skill coordinating-buddy-releases:
each stream ends with a `## Release handoff` block in its own session log). The
orchestrator: freeze (every stream committed on its branch), merge in a fixed order
(live-main fixes first, then feature branches, oldest first; `buddy.lua`, `brain.lua`,
`chat.html` and README.md are the usual conflicts), run `tests/lua-tests` and the Python
tests on merged `main`, review the whole diff against the last tag, scan it for personal
data, write one `"version": "next"` entry in `whatsnew/releases.json` with a slide per
feature (`tools/whatsnew check`, preview `hs -c 'ClaudeBuddy.whatsNew("next")'`), then
one `tools/release` with one note line per stream, reload, and bump the version in the
`~/AGENTS.md` widget line. Heavy merge, test and review passes go to sub-agents; the
push and release stay with the orchestrator. Once the owner has said ship, the orchestrator
may commit an idle owner's finished live-main files itself, by explicit path, after reading
the diff. Commit `whatsnew/releases.json` with the `"next"` entry before `tools/release`
(it refuses a dirty tree and stamps the entry itself), reload merged `main` and read the
console before releasing, and expect sub-agents to sign commits with their own model.
The orchestrator's runbook and scripts live in the user skill coordinating-buddy-releases.

## Releasing
```sh
gh auth status && git status --short     # no modified tracked files
tools/release 1.3.0 "The buddy holds a paint palette in Figma
New .fig downloads get a comment"
gh release view v1.3.0 --json isDraft,tagName && git show v1.3.0:VERSION
timeout 10 hs -c 'hs.reload()'           # this Mac now runs the new VERSION and won't offer itself the update
```
Never force-push or rebase `main` after a release: installs fast-forward to tags, and
rewritten history breaks their updates. If something bad shipped, release a fix on top.

## Compatibility
People keep old `config.lua` files indefinitely. Read new keys with defaults, keep
accepting old shapes (apps keyed by name or by bundle id), and never rename a key
without still reading the old name.
