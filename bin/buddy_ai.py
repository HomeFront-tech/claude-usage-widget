"""Which AI tools are on this Mac and whether they are busy, read-only.

One entry in PROVIDERS per tool. detect() looks for the app or command-line tool and whether it
is running; status() adds how recently it was used, from file dates and names only. Nothing here
opens a chat, a title, a login, a token or a keychain: the blocklist below is checked before any
folder is looked at, and the tests keep it that way. Asking a tool a question is a later step.
"""
import os
import subprocess
import time
from pathlib import Path

HOME = Path(os.path.expanduser(os.environ.get("BUDDY_AI_HOME") or "~"))
APP_DIRS = [Path("/Applications"), HOME / "Applications"]
BIN_DIRS = [HOME / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"),
            HOME / ".kimi-code/bin", HOME / ".opencode/bin", HOME / ".cargo/bin"]
RECENT = 3600       # used within this many seconds counts as "active now"
DAY = 86400

# Names that hold logins or keys. Never listed, never opened.
SECRET_WORDS = ("auth", "credential", "token", "secret", "keychain", "cookie", ".key", ".pem", "password", "login")

# name, apps, commands, process names, folder holding its session files (dates read only)
PROVIDERS = [
    {"id": "claude-code", "name": "Claude Code", "apps": ["Claude.app"], "cmds": ["claude"],
     "procs": ["claude"], "activity": ".claude/projects", "live": ".claude/sessions"},
    {"id": "codex", "name": "Codex", "apps": ["Codex.app"], "cmds": ["codex"],
     "procs": ["codex"], "activity": ".codex/sessions"},
    {"id": "cursor", "name": "Cursor", "apps": ["Cursor.app"], "cmds": ["cursor", "cursor-agent"],
     "procs": ["Cursor", "cursor-agent"], "activity": ".cursor/projects"},
    {"id": "grok", "name": "Grok", "apps": ["Grok Bot.app"], "cmds": ["gbot", "grok"],
     "procs": ["Grok Bot"], "activity": None},
    {"id": "chatgpt", "name": "ChatGPT", "apps": ["ChatGPT.app", "ChatGPT Classic.app"], "cmds": [],
     "procs": ["ChatGPT"], "activity": None},
    {"id": "kimi", "name": "Kimi", "apps": ["Kimi.app"], "cmds": ["kimi"], "procs": ["kimi"], "activity": None},
    {"id": "gemini", "name": "Gemini", "apps": [], "cmds": ["gemini"], "procs": ["gemini"], "activity": None},
    {"id": "opencode", "name": "OpenCode", "apps": [], "cmds": ["opencode"], "procs": ["opencode"], "activity": None},
    {"id": "hermes", "name": "Hermes", "apps": [], "cmds": ["hermes"], "procs": ["hermes"], "activity": None},
    {"id": "ollama", "name": "Ollama", "apps": ["Ollama.app"], "cmds": ["ollama"], "procs": ["ollama"], "activity": None},
    {"id": "copilot", "name": "GitHub Copilot", "apps": [], "cmds": ["copilot"], "procs": ["copilot"], "activity": None},
    {"id": "aider", "name": "Aider", "apps": [], "cmds": ["aider"], "procs": ["aider"], "activity": None},
]


def is_secret(name):
    low = str(name).lower()
    return any(word in low for word in SECRET_WORDS)


def _running():
    """Names of running programs, one ps call."""
    try:
        out = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return {os.path.basename(line.strip()) for line in out.splitlines() if line.strip()}


def _find_app(names):
    for folder in APP_DIRS:
        for name in names:
            if (folder / name).is_dir():
                return name
    return None


def _find_cmd(names):
    for folder in BIN_DIRS:
        for name in names:
            path = folder / name
            if path.is_file() and os.access(path, os.X_OK):
                return name
    return None


def _newest(folder, deep=3):
    """(newest file date, files touched in the last day). File dates only; never file contents."""
    root = HOME / folder
    newest, today, now = 0.0, 0, time.time()
    if not root.is_dir():
        return None, 0
    stack = [(root, 0)]
    while stack:
        here, depth = stack.pop()
        try:
            entries = list(os.scandir(here))
        except OSError:
            continue
        for entry in entries:
            if is_secret(entry.name):
                continue
            try:
                if entry.is_dir(follow_symlinks=False):
                    if depth < deep:
                        stack.append((Path(entry.path), depth + 1))
                    continue
                mtime = entry.stat().st_mtime
            except OSError:
                continue
            newest = max(newest, mtime)
            today += now - mtime < DAY
    return (newest or None), today


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError):
        return False


def _live_sessions(folder):
    """How many session files point at a program that is still running (Claude Code writes one per pid)."""
    root = HOME / folder
    if not root.is_dir():
        return 0
    count = 0
    for path in root.glob("*.json"):
        if path.stem.isdigit() and _pid_alive(int(path.stem)):
            count += 1
    return count


def detect(running=None):
    """One dict per tool that is installed or running; missing tools are left out."""
    running = _running() if running is None else running
    found = []
    for p in PROVIDERS:
        app, cmd = _find_app(p["apps"]), _find_cmd(p["cmds"])
        up = any(name in running for name in p["procs"])
        if app or cmd or up:
            found.append({"id": p["id"], "name": p["name"], "app": app, "command": cmd, "running": up})
    return found


def status(running=None):
    """detect() plus how recently each tool was used, in plain words."""
    now = time.time()
    by_id = {p["id"]: p for p in PROVIDERS}
    out = []
    for item in detect(running):
        p = by_id[item["id"]]
        newest, today = _newest(p["activity"]) if p.get("activity") else (None, 0)
        item["last_used"] = None if newest is None else int(now - newest)
        item["files_today"] = today
        item["active_now"] = bool(item["running"] and newest and now - newest < RECENT)
        if p.get("live"):
            item["live_sessions"] = _live_sessions(p["live"])
        out.append(item)
    return out


def _ago(seconds):
    if seconds is None:
        return "no activity found"
    if seconds < 90:
        return "just now"
    if seconds < 5400:
        return "%d minutes ago" % round(seconds / 60)
    if seconds < 2 * DAY:
        return "%d hours ago" % round(seconds / 3600)
    return "%d days ago" % round(seconds / DAY)


def describe(items):
    """The list as plain lines for the chat."""
    if not items:
        return "No AI tools found on this Mac."
    lines = []
    for it in items:
        how = "app" if it["app"] else "command-line tool"
        if it["app"] and it["command"]:
            how = "app and command-line tool"
        state = "open now" if it["running"] else "not running"
        extra = ""
        if it.get("live_sessions"):
            extra = ", %d session%s running" % (it["live_sessions"], "" if it["live_sessions"] == 1 else "s")
        if "last_used" in it and it["last_used"] is not None:
            extra += ", last activity " + _ago(it["last_used"])
        if it.get("active_now"):
            extra += " (busy right now)"
        lines.append("%s: %s, %s%s" % (it["name"], how, state, extra))
    return "\n".join(lines)
