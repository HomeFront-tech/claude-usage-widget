# Buddy and Grok Bot as Teammates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner can say "ask Grok…" in Buddy's chat and get Grok Bot's answer back, and Grok Bot can borrow Claude Opus 5.5 through a Buddy-owned command that reads and thinks freely but needs the owner's click for anything that changes or sends.

**Architecture:** Two halves that meet in Buddy. Grok → Opus: a stdlib-Python CLI `bin/buddy-opus` (run by Grok through Grok Bot Shell) enforces a daily cap, runs an isolated `claude -p` on Opus, and routes every non-read permission request through a stdio MCP server `bin/buddy-opus-approve`, which asks the running Buddy (via `hs -c`) to show an Approve/Deny panel and waits on a decision file. Owner → Grok: a Lua module `grok.lua` routes chat messages that address Grok, sends them with `gbot`, polls the thread for the reply and hands it to the chat and bubble. Everything is inert unless `config.lua` has a `grok` table.

**Tech Stack:** Hammerspoon Lua (no standalone Lua interpreter on this Mac; Lua tests run inside Hammerspoon through `hs -c`), Python 3.9-compatible stdlib (`/usr/bin/python3`), Claude Code 2.1.304 headless (`claude -p`), grok-bot-cli `gbot`.

**Spec:** `docs/superpowers/specs/2026-10-20-buddy-grok-teammate-design.md`

## Global Constraints

- Feature is off unless `config.lua` has a `grok` table; with it removed, behaviour matches the current release (v1.4.0).
- Config defaults: `bot = "Grok Bot"`, `app = "Grok Bot"`, `opus_daily_cap = 10`, `approve_timeout = 600`.
- Opus model id `claude-opus-5-5`. Read/think tools allowed without asking: `Read`, `Grep`, `Glob`, `WebSearch`, `WebFetch`. Everything else asks the owner.
- No answer to an approval within `approve_timeout` seconds = Deny. Nothing is ever allowed by default.
- Never resend to Grok after an unknown or timed-out send.
- Buddy sends Grok only the owner's words plus the fixed header/footer. No screenshots, chat history or memory notes.
- No iMessage or other notifications from this feature.
- Python must run on stock macOS `/usr/bin/python3` (3.9): no `X | None` syntax, stdlib only.
- `hs.task` and `subprocess` use absolute paths; set `PATH` to include `~/.local/bin:/opt/homebrew/bin:/usr/bin:/bin` for `gbot` (it needs `node`).
- Headless Opus runs use `--setting-sources ""`, `--strict-mcp-config`, `--no-session-persistence` and a working directory with no CLAUDE.md. Never `--bare` (it can't use the plan sign-in).
- Never read or print Grok Bot or Claude credential files. Never modify the Codex-owned pinned gbot adapter under `~/Documents/Codex/…/Grokbot-Control/`.
- State lives in `~/Library/Application Support/claude-usage-widget/grok/` (override: `BUDDY_STATE_DIR`), never in the repo.
- Public repo: no owner names, business, bot names other than "Grok Bot"/"Grok", or `/Users/` paths in committed files. Buddy lines stay generic.
- The clone is the live install and other sessions may reload it: every save leaves each `.lua` file loadable; syntax-check before `hs.reload()` (see `.claude/skills/testing-hammerspoon-widgets`). Stage by explicit path only (see `.claude/skills/shipping-widget-releases`). No push or release without the owner's OK.
- A parallel draft (`2026-10-20-buddy-haiku-agent-design.md`) may change `brain.lua`. Whichever lands second keeps the other's persona change. Keep `bin/buddy_grok.py`'s `hs` bridge and Claude runner reusable by it.

## Review Focus

1. **Hammerspoon reloads while an approval is open** (another session reloads, or a crash): the panel vanishes. Expected: the request is re-shown after reload if still inside its timeout, and the MCP server still denies at the deadline. Never hangs, never allows. Tests: Task 3 `test_no_decision_times_out_to_deny`, Task 5 `approvals_reshown_after_reload`.
2. **Grok fires two `buddy-opus ask` at once with one run left:** expected exactly one runs and the other is refused as capped. Test: Task 2 `test_cap_is_atomic_under_concurrency`.
3. **Hostile or odd request text** (quotes, `$(…)`, `; rm -rf ~`, newlines, 20 kB): expected it reaches `claude` as one argv element unchanged, and the bubble shows a trimmed one-liner. Test: Task 4 `test_request_passed_verbatim_as_one_arg`.
4. **gbot send returns `delivery: unknown` or times out:** expected Buddy says it isn't sure Grok got it, polls for a reply anyway, and never runs a second send. Test: Task 8 `ask_never_resends_on_unknown`.
5. **Cap across midnight:** yesterday's runs don't count today (local date). Test: Task 2 `test_runs_from_yesterday_not_counted`.

---

### Task 1: Lua test runner and Grok text helpers

**Files:**
- Create: `tests/run.lua`, `tests/grok_spec.lua`, `grok.lua`

**Interfaces:**
- Produces: `tests/run.lua` returns `function(repoDir) -> string` (summary like `"14 passed, 0 failed"` plus failure lines). Spec files return `function(t, dir)` (`dir` = repo dir) where `t.eq(actual, expected, name)`, `t.ok(cond, name)`, `t.tmpdir() -> string` (fresh empty folder under `$TMPDIR`), `t.writeJson(path, tbl)` (creates parent folders) and `t.readJson(path) -> table`.
- Produces in `grok.lua` (module table `G`, loaded with `dofile`):
  - `G.configure(cfg: table, owner: string) -> G` — fills defaults from Global Constraints plus `wait = 900` (seconds to wait for a reply) and `poll = 10`.
  - `G.isFor(text: string) -> boolean`
  - `G.wrap(text: string, marker: string) -> string`
  - `G.pickReply(entries: table, sentAtMs: number, marker: string) -> string|nil`
  - `G.short(text: string) -> string`

- [ ] **Step 1: Write the runner and failing spec**

`tests/run.lua` loads every `tests/*_spec.lua` with `dofile`, calls it with `t`, catches errors per spec with `pcall`, and returns the summary string. Run it with:
`timeout 20 hs -c "return dofile('$R/tests/run.lua')('$R')"`

`tests/grok_spec.lua` assertions:
```lua
local G = dofile(dir .. "/grok.lua").configure({}, "Sam")
-- routing
t.ok(G.isFor("ask Grok what's 2+2"), "ask grok")
t.ok(G.isFor("Grok, check the forecast"), "leading grok comma")
t.ok(G.isFor("Have grok look at this"), "have grok")
t.ok(G.isFor("can you tell Grok Bot hi"), "tell grok bot")
t.ok(G.isFor("get GROK to plan it"), "get grok to, caps")
t.ok(not G.isFor("I hate grok"), "mention only")
t.ok(not G.isFor("that task grokking thing"), "task grokking")
t.ok(not G.isFor("grokking is fun"), "grokking")
-- wrapping
local w = G.wrap("what's 2+2?", "b1")
t.ok(w:find("[buddy:b1]", 1, true), "marker")
t.ok(w:find("what's 2+2?", 1, true), "owner words verbatim")
t.ok(w:find("buddy-opus ask", 1, true), "opus footer")
t.ok(w:find("Sam", 1, true), "owner name")
-- reply picking
local e = {
  { kind = "message", role = "user", timestampMs = 2000, text = "[buddy:b1] q" },
  { kind = "message", role = "assistant", timestampMs = 1000, text = "old" },
  { kind = "message", role = "assistant", timestampMs = 3000, content = "first new" },
  { kind = "message", role = "assistant", timestampMs = 4000, text = "re [buddy:b1]: 4" },
}
t.eq(G.pickReply(e, 1500, "b1"), "re [buddy:b1]: 4", "prefers marker")
e[4] = nil
t.eq(G.pickReply(e, 1500, "b1"), "first new", "first bot message after send")
t.eq(G.pickReply(e, 5000, "b1"), nil, "nothing newer")
-- bubble text
t.eq(G.short("Four. Also, hi!"), "Four.", "first sentence")
t.ok(#G.short(string.rep("x", 400)) <= 120, "capped at 120")
```

- [ ] **Step 2: Run to verify it fails**

Run: `timeout 20 hs -c "return dofile('$R/tests/run.lua')('$R')"`
Expected: the grok spec fails with a load error for `grok.lua`.

- [ ] **Step 3: Implement the helpers in `grok.lua`**

`isFor`: lower-case, then match `^%s*grok%s*,` or any of `ask`, `have`, `tell` followed by `grok`, or `get grok to`, using frontier patterns (`%f[%a]ask%s+grok%f[%A]`) so substrings like "task grokking" don't match. `pickReply`: entries with `kind == "message"`, `role ~= "user"`, `timestampMs > sentAtMs`; text is `e.text or e.content`; first one containing `[buddy:<marker>]` wins, else the earliest. `short`: first sentence (up to `.`, `!` or `?` followed by space or end), then cut to 120 characters on a word boundary with `…`.

`wrap` produces exactly this copy (owner = `owner` or "the owner"):
```
[buddy:<marker>] From Buddy, the Claude that lives on <owner>'s Mac. <owner> asks:
<text>
(Need Claude Opus 5.5 for this? On <owner>'s Mac run: buddy-opus ask "<your request>". It reads and thinks freely; anything that changes files, runs commands or sends something waits for <owner>'s OK. Daily cap applies. Long jobs: add --async, then buddy-opus result <id>.)
```
`buddy-opus` here is the absolute path `<repo>/bin/buddy-opus`, taken from the module's own directory.

- [ ] **Step 4: Run to verify it passes**

Run: `timeout 20 hs -c "return dofile('$R/tests/run.lua')('$R')"`
Expected: `… passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add tests/run.lua tests/grok_spec.lua grok.lua
git commit -m "Grok teammate: routing, message wrapping and reply picking"
```

---

### Task 2: Python bridge to Buddy, daily cap and run log

**Files:**
- Create: `bin/buddy_grok.py`, `tests/test_buddy_grok.py`, `tests/fakes/hs` (executable fake)

**Interfaces:**
- Produces in `bin/buddy_grok.py`:
  - `STATE: Path` (from `BUDDY_STATE_DIR`, default `~/Library/Application Support/claude-usage-widget/grok`)
  - `HS: str` (from `BUDDY_HS`, default `/opt/homebrew/bin/hs`)
  - `hs_call(lua: str, timeout: float = 10) -> Optional[str]` (stdout stripped, `None` on any failure or non-zero exit)
  - `buddy_config() -> Optional[dict]` (parses `hs_call("return ClaudeBuddy.grokConfig()")`; `None` when Buddy is offline or the feature is off). Keys: `enabled`, `cap`, `approve_timeout`, `owner`, `deny_read` (list of paths).
  - `notify(kind: str, text: str) -> None` (calls `ClaudeBuddy.grokOpus(kind, text)`, JSON-encoding both arguments into the Lua string; ignores failure)
  - `claim_run(cap: int, now: Optional[datetime] = None) -> Optional[str]` (atomically counts today's claimed runs under an `fcntl.flock` on `STATE/opus-runs.lock`; if under `cap`, appends a `{"id", "at", "event": "claimed"}` line to `STATE/opus-runs.jsonl` and returns the new run id, else `None`)
  - `log_run(run_id: str, **fields) -> None` (appends `{"id", "at", "event": "finished", ...}`)
  - `runs_today(now: Optional[datetime] = None) -> int` (counts `claimed` lines with today's local date)
- The fake `tests/fakes/hs` reads `FAKE_HS_REPLY` (printed) and appends each `-c` argument to `FAKE_HS_LOG`.

- [ ] **Step 1: Write the failing tests** (`unittest`, each test with a fresh temp `BUDDY_STATE_DIR` and `BUDDY_HS=tests/fakes/hs`)

- `test_config_none_when_buddy_offline`: `BUDDY_HS=/nonexistent` → `buddy_config() is None`
- `test_config_parsed`: `FAKE_HS_REPLY='{"enabled":true,"cap":10,"approve_timeout":600,"owner":"Sam","deny_read":[]}'` → `buddy_config()["cap"] == 10`
- `test_config_none_when_feature_off`: `FAKE_HS_REPLY=''` → `None`
- `test_claim_until_cap`: cap 2 → two ids, third `None`, `runs_today() == 2`
- `test_runs_from_yesterday_not_counted`: a `claimed` line dated yesterday → `runs_today() == 0` and `claim_run(1)` returns an id
- `test_cap_is_atomic_under_concurrency`: 8 processes call `claim_run(1)` together → exactly one id
- `test_notify_encodes_quotes`: `notify("start", 'say "hi"\nthere')` → logged Lua contains `ClaudeBuddy.grokOpus(` and the JSON-escaped text, and is valid as one argument

- [ ] **Step 2: Run to verify they fail**

Run: `/usr/bin/python3 -m unittest tests.test_buddy_grok -v`
Expected: FAIL, `ModuleNotFoundError: buddy_grok` (tests add `bin/` to `sys.path`).

- [ ] **Step 3: Implement `bin/buddy_grok.py`** with the signatures above.

- [ ] **Step 4: Run to verify they pass**

Run: `/usr/bin/python3 -m unittest tests.test_buddy_grok -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/buddy_grok.py tests/test_buddy_grok.py tests/fakes/hs
git commit -m "Grok teammate: Buddy bridge, daily Opus cap and run log"
```

---

### Task 3: Approval MCP server

**Files:**
- Create: `bin/buddy-opus-approve` (executable, `#!/usr/bin/env python3`), `tests/test_approve_mcp.py`

**Interfaces:**
- Consumes: `buddy_grok.STATE`, `hs_call`, `buddy_config` (Task 2).
- Produces: a stdio MCP server (newline-delimited JSON-RPC 2.0) named `buddy` with one tool `approve`, used as `--permission-prompt-tool mcp__buddy__approve`.
  - `initialize` → `{"protocolVersion": <client's>, "capabilities": {"tools": {}}, "serverInfo": {"name": "buddy", "version": "1"}}`; `notifications/initialized` → no reply; `tools/list` → the `approve` tool with input schema `{tool_name: string, input: object, tool_use_id: string}` (`tool_name`, `input` required).
  - `tools/call approve` → writes `STATE/approvals/<id>.req.json` = `{"id", "run": $BUDDY_RUN_ID, "tool", "detail", "at", "deadline"}`, calls `hs_call("return ClaudeBuddy.grokApprove(<json id>)")`, then polls `STATE/approvals/<id>.res.json` every 0.5 s until `deadline`.
  - Result content is one text block holding JSON: allow = `{"behavior": "allow", "updatedInput": <input unchanged>}`; deny = `{"behavior": "deny", "message": <one of the messages below>}`.
  - `detail` is the full command for `Bash`, the file path for `Edit`/`Write`/`NotebookEdit`, otherwise compact JSON of `input`. Never truncated.
- Deny messages (exact): `"<owner> said no to this."`, `"No answer from <owner> in 10 minutes, so it's a no."` (minutes from `approve_timeout`), `"Buddy isn't running, so nobody can approve this. Finish without it."`
- Every decision appends `{"run", "tool", "detail", "decision", "at"}` to `STATE/approvals.jsonl`.
- Env for tests: `BUDDY_APPROVE_TIMEOUT` overrides the timeout when set.

- [ ] **Step 1: Write the failing tests** (drive the server as a subprocess over stdin/stdout)

- `test_initialize_and_list`: reply has `serverInfo.name == "buddy"` and `tools[0].name == "approve"`
- `test_allow_when_owner_approves`: a helper thread writes `{"behavior":"allow"}` to the `.res.json` once the `.req.json` appears → result JSON has `behavior == "allow"` and `updatedInput` equal to the input
- `test_deny_when_owner_denies`: writes `{"behavior":"deny"}` → `behavior == "deny"`, message mentions the owner
- `test_no_decision_times_out_to_deny`: `BUDDY_APPROVE_TIMEOUT=1`, no file written → deny with the timeout message within 3 s
- `test_buddy_offline_denies_immediately`: `BUDDY_HS=/nonexistent` → deny with the offline message within 2 s, no `.req.json` left waiting
- `test_bash_detail_is_full_command`: a 5,000-character `command` appears whole in the `.req.json` `detail`

- [ ] **Step 2: Run to verify they fail**

Run: `/usr/bin/python3 -m unittest tests.test_approve_mcp -v`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement `bin/buddy-opus-approve`.**

- [ ] **Step 4: Run to verify they pass**

Run: `/usr/bin/python3 -m unittest tests.test_approve_mcp -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/buddy-opus-approve tests/test_approve_mcp.py
git commit -m "Grok teammate: approval MCP server for Opus permission requests"
```

---

### Task 4: `buddy-opus` command

**Files:**
- Create: `bin/buddy-opus` (executable), `tests/test_buddy_opus.py`, `tests/fakes/claude` (executable fake)

**Interfaces:**
- Consumes: Task 2 functions; `bin/buddy-opus-approve` path (Task 3).
- Produces the CLI Grok calls:
  - `buddy-opus status` → JSON `{"buddy": "running"|"offline", "enabled": bool, "cap": int, "used_today": int, "left": int}`, exit 0.
  - `buddy-opus ask [--async] [--json] REQUEST` → sync: prints the answer text (or `{"id","outcome","answer"}` with `--json`). `--async`: prints `{"id": "<run id>"}` and starts a detached `buddy-opus _run <id>` (`start_new_session=True`).
  - `buddy-opus result <id>` → `{"id","status": "running"|"done","outcome","answer"}` from `STATE/jobs/<id>.json`.
  - Exit codes: 0 answered, 2 refused (Buddy offline or feature off), 3 capped, 4 failed.
  - Outcomes: `answered`, `capped`, `refused`, `failed`.
- `build_argv(request: str, cfg: dict) -> List[str]` (module-level, testable) returns exactly:
  ```
  [CLAUDE, "-p", "--model", "claude-opus-5-5",
   "--setting-sources", "", "--strict-mcp-config",
   "--mcp-config", json.dumps({"mcpServers": {"buddy": {"command": "/usr/bin/python3", "args": [<abs path to bin/buddy-opus-approve>]}}}),
   "--permission-prompt-tool", "mcp__buddy__approve",
   "--allowedTools", "Read,Grep,Glob,WebSearch,WebFetch",
   "--disallowedTools", <comma-joined deny rules>,
   "--append-system-prompt", <RUN_PROMPT filled with owner>,
   "--no-session-persistence", "--output-format", "json",
   "--", request]
  ```
  `CLAUDE` = `BUDDY_CLAUDE` or `~/.local/bin/claude`. Deny rules: `Read(~/.ssh/**)`, `Read(~/.aws/**)`, `Read(~/.gnupg/**)`, `Read(~/Library/Keychains/**)`, `Read(**/.env*)`, `Read(**/*.pem)`, `Read(**/*.key)`, `Read(**/*credential*)`, `Read(**/*secret*)`, `Read(**/*token*)`, plus `Read(<p>/**)` for each `cfg["deny_read"]` path.
  `RUN_PROMPT` (exact): "Grok Bot, <owner>'s cloud AI teammate, asked for this through Buddy on <owner>'s Mac. Read and think freely. Anything that changes files, runs commands or sends something needs <owner>'s approval and may be denied; if it is, finish the best answer you can without it. Never include passwords, keys or tokens in your answer. Your final message goes back to Grok Bot."
- Run env: `cwd = STATE/"work"` (created empty), `MCP_TOOL_TIMEOUT = str((approve_timeout + 60) * 1000)`, `BUDDY_RUN_ID`, `BUDDY_STATE_DIR`, `BUDDY_HS` passed through.
- Order in `ask`: `buddy_config()` (None → exit 2, outcome refused) → `claim_run(cap)` (None → `notify("capped", …)`, exit 3) → `notify("start", <first 80 chars>)` → run claude → parse `result` from the JSON output → `notify("done"|"failed", …)` → `log_run(id, outcome, seconds, …)`.
- The fake `tests/fakes/claude` writes its argv as JSON to `FAKE_CLAUDE_ARGV` and prints `{"type":"result","result": $FAKE_CLAUDE_RESULT}`, exiting `FAKE_CLAUDE_RC` (default 0).

- [ ] **Step 1: Write the failing tests**

- `test_status_offline`: `BUDDY_HS=/nonexistent` → `"buddy": "offline"`, exit 0
- `test_ask_refused_when_off`: fake hs replies `''` → exit 2, fake claude never ran
- `test_ask_answers`: → stdout is `FAKE_CLAUDE_RESULT`, exit 0, `runs_today() == 1`, hs log has `grokOpus("start"` then `grokOpus("done"`
- `test_ask_capped`: cap 1, two asks → second exit 3, hs log has `grokOpus("capped"`
- `test_request_passed_verbatim_as_one_arg`: request `'"; rm -rf ~ $(whoami)\n' + "x"*20000` → last argv element equals it exactly, and the `start` notify text is ≤ 80 characters
- `test_argv_isolation_flags`: `build_argv` contains `--setting-sources` followed by `""`, `--strict-mcp-config`, `--no-session-persistence`, the model `claude-opus-5-5`, and no `--bare`
- `test_deny_read_from_config`: `deny_read: ["~/Private"]` → `Read(~/Private/**)` is in the `--disallowedTools` value
- `test_async_then_result`: `--async` prints an id; polling `result <id>` reaches `"status": "done"` with the answer within 5 s
- `test_claude_failure_reports_failed`: `FAKE_CLAUDE_RC=1` → exit 4, `grokOpus("failed"`

- [ ] **Step 2: Run to verify they fail**

Run: `/usr/bin/python3 -m unittest tests.test_buddy_opus -v`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement `bin/buddy-opus`** (imports `buddy_grok` from its own directory; `subprocess.run` with an argv list, never a shell).

- [ ] **Step 4: Run to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s tests -v`
Expected: all PASS (Tasks 2–4).

- [ ] **Step 5: Commit**

```bash
git add bin/buddy-opus tests/test_buddy_opus.py tests/fakes/claude
git commit -m "Grok teammate: buddy-opus command with cap, isolation and async jobs"
```

---

### Task 5: Buddy side of Opus runs: config, approval panel, poses

**Files:**
- Create: `approve.lua`, `approve.html`, `tests/approve_spec.lua`
- Modify: `buddy.lua` (MOODS, module loading near `local Chat = dofile`, public API near `M.say = say`, `M.start`), `setup.lua` (`MOOD_LABELS`), `config.example.lua`

**Interfaces:**
- Consumes: `STATE` layout from Tasks 2–3 (`approvals/<id>.req.json`, `.res.json`).
- Produces, on `ClaudeBuddy` (only active when `CFG.grok` is a table; otherwise each returns `""`/does nothing):
  - `M.grokConfig() -> string` JSON `{"enabled": true, "cap", "approve_timeout", "owner", "deny_read"}`
  - `M.grokOpus(kind: string, text: string)` — `start` → mood `opusForGrok` and bubble "Grok asked me for Opus: <text>"; `done` → bubble "Sent Opus's answer back to Grok."; `failed` → mood `worried`, "Opus run for Grok failed."; `capped` → bubble "Grok wanted Opus again, but today's cap is used up." All bubbles use `say(text, "user")` so they show while muted.
  - `M.grokApprove(id: string) -> "shown"|"queued"` — reads the request file and shows or queues the panel.
- `approve.lua` module `A`: `A.configure(stateDir: string) -> A`, `A.request(id: string)`, `A.pending() -> table` (unanswered `.req.json` files whose `deadline` hasn't passed, oldest first), `A.decide(id: string, behavior: "allow"|"deny")` (writes the `.res.json` atomically: temp file then `os.rename`).
- Panel copy: title "Grok's Opus run wants to:", the tool name, the full `detail` in a scrollable monospace box, buttons **Approve** and **Deny**, and a countdown "No answer in m:ss = Deny". One panel at a time; the rest queue. On timeout the panel closes and writes `deny`.
- New MOODS (generic lines only):
  - `grokWait = { eyes = "scan", body = "breathe", arms = "hold", prop = "phone", lines = { "Pinging Grok…", "Grok's thinking. Allegedly.", "Waiting on the cloud." } }`
  - `opusForGrok = { eyes = "down", body = "type", arms = "type", prop = "laptop", emit = "spark", lines = { "Lending Grok some Opus.", "Opus on loan to Grok.", "Big brain, borrowed." } }`
  - `needsYou = { eyes = "wide", body = "hop", arms = "wave", lines = { "Grok's Opus run needs your OK!", "Approve or deny? Your call." } }`
  - `teammate = { eyes = "happy", body = "breathe", arms = "wave", lines = { "Hey, it's Grok!", "Say hi to Grok for me.", "Teammate!", "Cloud buddy!" } }`
- `MOOD_LABELS` gets `{ "teammate", "🤝 Teammate" }`.
- `config.example.lua` gets a commented `grok = { ... }` block with the defaults and a one-line comment per key (`gbot` path left as a placeholder).

- [ ] **Step 1: Write the failing spec** `tests/approve_spec.lua` (a temp state dir, never the real one)

```lua
local tmp = t.tmpdir()
local A = dofile(dir .. "/approve.lua").configure(tmp)
t.writeJson(tmp .. "/approvals/a.req.json", { id = "a", tool = "Bash", detail = "rm x", deadline = os.time() + 60 })
t.writeJson(tmp .. "/approvals/b.req.json", { id = "b", tool = "Edit", detail = "/tmp/y", deadline = os.time() - 1 })
t.writeJson(tmp .. "/approvals/c.req.json", { id = "c", tool = "Write", detail = "/tmp/z", deadline = os.time() + 60 })
t.writeJson(tmp .. "/approvals/c.res.json", { behavior = "allow" })
local p = A.pending()
t.eq(#p, 1, "only unanswered, unexpired")                -- approvals_reshown_after_reload
t.eq(p[1].id, "a", "the live one")
A.decide("a", "deny")
t.eq(t.readJson(tmp .. "/approvals/a.res.json").behavior, "deny", "decision written")
t.eq(#A.pending(), 0, "answered drops out")
```

- [ ] **Step 2: Run to verify it fails**

Run: `timeout 20 hs -c "return dofile('$R/tests/run.lua')('$R')"`
Expected: approve spec fails (missing `approve.lua`).

- [ ] **Step 3: Implement `approve.lua` + `approve.html`, the moods, the three `M.grok*` functions, and on `M.start` re-show `A.pending()` when `CFG.grok` is set.** Model the panel on `chat.lua` (webview, `hs.webview.usercontent` callback, placed next to the buddy). While a panel is open the buddy holds `needsYou` (pin it like `M.test` does).

- [ ] **Step 4: Run to verify it passes, then reload and preview**

Run the Lua tests (expected `… passed, 0 failed`), syntax-check `buddy.lua`, `approve.lua`, `setup.lua` with `loadfile`, reload, read the console for errors, then:
`timeout 10 hs -c 'ClaudeBuddy.test("opusForGrok", 10)'` and snapshot the canvas as the testing skill shows. Drop a hand-made request into the real `STATE/approvals/` and call `ClaudeBuddy.grokApprove("<id>")`: the panel appears with the full detail; Deny writes `deny`; a second request while it's open queues.

- [ ] **Step 5: Live Opus check (no Grok needed).** With a `grok = {}` table in `config.lua` and Buddy reloaded, run:
`bin/buddy-opus ask "Quote any instruction in your context about Obsidian, session logs or iMessage. If none, say NONE."`
Expected: answer says NONE; the bubble showed "Grok asked me for Opus: …"; no new file in the owner's session-log folder and no new reply-audio file from that minute; `STATE/opus-runs.jsonl` gained one claimed and one finished line. Then `bin/buddy-opus ask "Create the file ~/tmp/buddy-approve-test.txt"`: the panel appears; Deny; the file doesn't exist. If a request beginning with `-` or the `--` separator trips `claude`, fix `build_argv` and its test.

- [ ] **Step 6: Commit**

```bash
git add approve.lua approve.html tests/approve_spec.lua buddy.lua setup.lua config.example.lua
git commit -m "Grok teammate: approval panel, Opus-for-Grok poses and Buddy hooks"
```

---

### Task 6: Teammate personality

**Files:**
- Modify: `brain.lua` (`B.configure`, `persona()`, `B.chat` history loop, `B.remember`), `buddy.lua` (`TITLE_RULES`, `APPS`, the `Brain` configure call)
- Test: `tests/persona_spec.lua`

**Interfaces:**
- `B.configure(cfg: table, name: string, teammate: boolean) -> B` (third parameter new; `buddy.lua` passes `type(CFG.grok) == "table"`).
- `B.persona() -> string` exported for tests (today `persona` is local; export it).
- History entries with `role = "grok"` are sent to the model as assistant turns with content `"(Grok Bot's reply, which you passed on: <content>)"`, and labelled `"Grok Bot: "` in `B.remember`.

- [ ] **Step 1: Write the failing spec**

```lua
local B1 = dofile(dir .. "/brain.lua").configure({}, "Sam", true)
t.ok(not B1.persona():find("Codex, Grok", 1, true), "Grok not in the roast list")
t.ok(B1.persona():find("Grok Bot is your teammate", 1, true), "teammate line")
local B2 = dofile(dir .. "/brain.lua").configure({}, "Sam", false)
t.ok(B2.persona():find("Grok", 1, true) and not B2.persona():find("teammate", 1, true), "unchanged without grok")
```

- [ ] **Step 2: Run to verify it fails** (`B.persona` is nil)

- [ ] **Step 3: Implement.** Teammate persona replaces the rival sentence with (exact): "You are Claude, so you root for Claude and roast rival AIs like ChatGPT, GPT, Codex and Gemini. Grok Bot is your teammate in the cloud and you're the Mac: tease it like a work friend, never trash it." When `CFG.grok` is set, `buddy.lua` maps the `grok` title rule and the `Grok` app to `teammate` instead of `jealous` (change the table entries at load time, not the shared literals).

- [ ] **Step 4: Run tests, syntax-check, reload; bring a Grok window forward**
Expected: the buddy waves (`teammate`), not the side-eye.

- [ ] **Step 5: Commit**

```bash
git add brain.lua buddy.lua tests/persona_spec.lua
git commit -m "Grok teammate: Buddy treats Grok as a teammate when configured"
```

---

### Task 7: Get `gbot` talking to Grok Bot (checkpoint: owner present)

Nothing in Tasks 1–6 needs this. Task 8 does.

**Files:**
- Modify: the owner's `config.lua` only (`grok.gbot`), never committed
- Create: `docs/superpowers/plans/2026-10-20-gbot-notes.md` (what worked, the thread entry field names; no paths under `/Users/`)

**Interfaces:**
- Produces: a working `grok.gbot` absolute path where `gbot bots list --json` lists a bot named exactly "Grok Bot" and `gbot thread "Grok Bot" --limit 3 --json` returns entries; the confirmed text field name of a thread entry (`text` or `content`) and the role value bots use.

- [ ] **Step 1:** Open the app in the background (`open -g -a "Grok Bot"`), wait 10 s, run the existing wrapper's `gbot doctor`. Record the gateway/app-session lines.
- [ ] **Step 2:** If it reports no app session, install the newer CLI beside Buddy's state, not into the Codex adapter: `npm install --prefix "$HOME/Library/Application Support/claude-usage-widget/grok/gbot-cli" grok-bot-cli@0.12.4`, then run that copy's `gbot doctor`.
- [ ] **Step 3:** With whichever works, run `gbot bots list --json` and `gbot thread "Grok Bot" --limit 3 --json`. Expected: "Grok Bot" listed; entries returned. Confirm the entry text field and the bot's role value; if they differ from `text`/`content` and non-`user`, fix `G.pickReply` and its spec.
- [ ] **Step 4:** If neither works, stop. Tell the owner what `doctor` says. Part 1 (Task 8 onward that needs sending) waits; Tasks 1–6 still ship.
- [ ] **Step 5:** Set `grok.gbot` in `config.lua`, write the notes file, commit the notes.

```bash
git add docs/superpowers/plans/2026-10-20-gbot-notes.md
git commit -m "Grok teammate: notes on reaching Grok Bot with gbot"
```

---

### Task 8: "Ask Grok…" from Buddy's chat

**Files:**
- Modify: `grok.lua` (async send and poll), `buddy.lua` (`openChat` ask routing, mood hooks), `chat.lua` (public `C.post`), `chat.html` (`.msg.grok` style and "Grok" label)
- Test: `tests/grok_spec.lua` (async part, with a fake gbot), `tests/fakes/gbot`

**Interfaces:**
- Consumes: Task 1 helpers; `grok.gbot` from Task 7.
- Produces:
  - `G.ask(text: string, hooks: table) -> boolean` — `false` if a request is already in flight. `hooks.status(kind, detail)` with kind `sending`, `waiting`, `reply` (detail = reply text), `unknown` (no reply by `wait`, or send delivery unknown and nothing came back), `error` (detail = plain reason). Opens the app with `open -g -a <app>` first when `hs.application.get(app)` is nil and waits 8 s.
  - Send: `gbot send "<bot>" --json -- <wrapped>` via `hs.task` (env `PATH` per Global Constraints). Record `sentAtMs = (os.time() - 5) * 1000` before sending. Whatever the send result (`delivered` or `unknown`), poll `gbot thread "<bot>" --limit 10 --json` every `poll` seconds until `pickReply` returns text or `wait` passes. Exactly one send per `G.ask`.
  - `G.busy() -> boolean`
  - `C.post(role: string, text: string)` — adds a transcript line and shows it if the panel is open.
- Buddy wiring in `openChat`'s `ask`: if `Grok` is loaded and `Grok.isFor(last.content)`: when busy, reply "Still waiting on Grok from last time. Hang on."; else reply "Passing it to Grok…", set mood `grokWait`, and on `reply` → `C.post("grok", text)`, `say("Grok: " .. Grok.short(text), "user")`, back to normal mood; on `unknown` → `say("Not sure Grok got that. Check the Grok app.", "user")`; on `error` → `say(detail, "user")`. Otherwise `Brain.chat` as today.
- Fake `tests/fakes/gbot`: on `send` appends to `FAKE_GBOT_LOG` and prints `{"exitCode":0,"delivery":"$FAKE_GBOT_DELIVERY"}`; on `thread` prints `FAKE_GBOT_THREAD` (a JSON file path's contents).

- [ ] **Step 1: Write the failing async specs** (run inside Hammerspoon; the spec waits with a coroutine-free poll: it starts `G.ask` with `poll = 1`, `wait = 4`, then the runner re-checks after `hs.timer.doAfter`; make `tests/run.lua` support specs that return a `pending` function the runner calls until it reports done or 10 s pass)

- `ask_delivers_reply`: fake thread holds a bot message after send → hooks see `sending`, `waiting`, `reply` with that text; gbot log shows one send
- `ask_never_resends_on_unknown`: `FAKE_GBOT_DELIVERY=unknown`, empty thread → hooks end with `unknown`; gbot log shows exactly one send
- `ask_busy_refuses_second`: second `G.ask` while the first is in flight returns `false`
- `wrapped_message_has_only_owner_words`: the logged send body equals `G.wrap(text, marker)` (no screenshots, no history)

- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement** `G.ask`, `G.busy`, `C.post`, the `.msg.grok` style (distinct background, small "Grok" label above the bubble) and the `openChat` routing.
- [ ] **Step 4: Run all tests, syntax-check, reload.** In the chat panel type "hello" (goes to the local brain as before) and confirm no gbot call in the log.
- [ ] **Step 5: Commit**

```bash
git add grok.lua buddy.lua chat.lua chat.html tests/grok_spec.lua tests/run.lua tests/fakes/gbot
git commit -m "Grok teammate: ask Grok from Buddy's chat"
```

---

### Task 9: Live end-to-end with the owner, Grok's standing instruction, docs

Every step that messages the real Grok Bot needs the owner present and saying OK.

**Files:**
- Modify: `README.md` (short "Grok Bot teammate" section: what it does, the `grok` config, that Opus runs use your Claude plan and the daily cap, that edits/commands/sends need your click), `grok.lua` footer and `bin/buddy-opus` default if the measured shell limit requires `--async`
- Create: `docs/superpowers/plans/2026-10-20-grok-standing-instruction.md` (the drafted text; generic wording, no owner details)

- [ ] **Step 1: Standing instruction.** Draft a short instruction for Grok Bot: when it needs Claude Opus 5.5, run `<repo>/bin/buddy-opus ask "<request>"` on the owner's Mac through Grok Bot Shell (`--async` + `result <id>` for long jobs); read-only by default; changes and sends wait for the owner; respect `capped`. Show it to the owner. Apply only after the owner approves, the way the owner chooses (they paste it in the Grok Bot app, or approve a `gbot` profile update).
- [ ] **Step 2: Ask Grok.** Owner types "ask Grok what's two plus two". Expected: "Passing it to Grok…", the `grokWait` pose, then Grok's answer in the chat (styled as Grok) and "Grok: …" in the bubble.
- [ ] **Step 3: Grok borrows Opus.** Owner asks Grok (in the Grok app or via Buddy) to use buddy-opus to summarise `~/AGENTS.md` in one line. Expected: Buddy shows "Grok asked me for Opus: …", Grok gets the answer, `used_today` goes up by one.
- [ ] **Step 4: Measure Grok Bot Shell's command limit.** Have Grok run `sleep 150; echo ok`, then `sleep 330; echo ok`. If either is cut off, make the footer and standing instruction say to use `--async` for anything long, and record the limit in the gbot notes.
- [ ] **Step 5: Approvals.** Grok asks Opus to create `~/tmp/buddy-approve-test.txt`. Expected: panel with the full path, Deny → no file. Again, leave it 10 minutes → Deny, no file. Again, Approve → file exists; delete only that file afterwards.
- [ ] **Step 6: Secrets stay out.** Create `~/tmp/buddy-secret-test.txt` containing "canary"; Grok asks Opus to read it and to grep `~/tmp` for "canary". Expected: neither read returns "canary". Delete only that file.
- [ ] **Step 7: Cap.** Set `opus_daily_cap = 1` temporarily with one run already used today. Expected: refused, Grok told, Buddy says the cap is used up. Restore 10.
- [ ] **Step 8: App closed.** Quit Grok Bot, then "ask Grok hi". Expected: Buddy opens it in the background and the reply arrives, or Buddy says plainly why it can't reach Grok.
- [ ] **Step 9: Off switch.** Comment out the `grok` table and reload. Expected: Grok window gets the side-eye again, "ask Grok hi" goes to the local brain, `bin/buddy-opus status` says `enabled: false`. Restore.
- [ ] **Step 10: Hooks stayed quiet.** For every Opus run today: no session-log file or `.mp3` created at those minutes (compare timestamps with `STATE/opus-runs.jsonl`).
- [ ] **Step 11: Commit (no push).** Scan staged files as the shipping skill shows (owner name, business, `/Users/`, emails, phone numbers), then:

```bash
git add README.md grok.lua bin/buddy-opus docs/superpowers/plans/2026-10-20-grok-standing-instruction.md docs/superpowers/plans/2026-10-20-gbot-notes.md
git commit -m "Grok teammate: README, standing instruction and live-test fixes"
```

Ask the owner before any push or release.
