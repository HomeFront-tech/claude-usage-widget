"""Claude Code sessions Buddy starts for a task: their files, their tmux pane, their hooks.

Each task has a folder under TASKS with task.json (name, state, link), prompt.md (its
first message), settings.json (hooks that call `buddy-task hook <id>`), launch.sh and
events.jsonl, which the hooks append to and tasks.lua reads. The session runs in Buddy's
own tmux server (`tmux -L claude-buddy`) so Buddy can type follow-ups into it and closing
its Terminal window doesn't end it. Without tmux it runs straight in Terminal and only
the Claude app can talk to it.
"""
import fcntl
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

HERE = os.path.dirname(os.path.realpath(__file__))
TASKS = Path(os.path.expanduser(os.environ.get("BUDDY_TASKS_DIR") or
                                "~/Library/Application Support/claude-usage-widget/tasks"))
SESSIONS = Path(os.path.expanduser(os.environ.get("BUDDY_SESSIONS_DIR") or "~/.claude/sessions"))
SEARCH = os.path.expanduser("~/.local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
SOCKET = "claude-buddy"  # Buddy's own tmux server, apart from any the owner runs
CONF = os.path.join(HERE, "buddy-tmux.conf")
HOOK = os.path.join(HERE, "buddy-task")
HOOKED = ("UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
PENDING = "pending.json"  # a start or send the brain proposed, waiting for the owner's yes
KEEP_ENDED = 86400        # an ended task stays in the list this long
PID_WAIT, LINK_WAIT = 30, 45  # seconds start() waits for the session, then for its link
QUIET = ("idle_prompt", "auth_success")  # notifications that aren't a question for the owner


class TaskError(Exception):
    pass


def now() -> float:
    return time.time()


def tmux_path() -> Optional[str]:
    given = os.environ.get("BUDDY_TMUX")
    if given is not None:
        return given or None  # "": no tmux (the specs)
    return shutil.which("tmux", path=SEARCH)


def claude_path() -> str:
    found = os.environ.get("BUDDY_CLAUDE") or shutil.which("claude", path=SEARCH)
    return found or os.path.expanduser("~/.local/bin/claude")


def tmux(*args, input_text=None, timeout=10):
    argv = [tmux_path() or "tmux", "-L", SOCKET, "-f", CONF] + list(args)
    return subprocess.run(argv, input=input_text, capture_output=True, text=True, timeout=timeout)


def pane(task: dict) -> str:
    return "buddy-" + task["id"]


def slug(name: str) -> str:
    return (re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:30].strip("-") or "task")


def folder_of(task_id: str) -> Path:
    if not re.fullmatch(r"[a-z0-9-]{1,40}", task_id or ""):
        raise TaskError("Unknown task.")
    return TASKS / task_id


def write_json(path: Path, value) -> None:
    tmp = path.with_name(path.name + ".%d.tmp" % os.getpid())
    tmp.write_text(json.dumps(value, ensure_ascii=False) + "\n")
    os.replace(str(tmp), str(path))


def load(task_id: str) -> Optional[dict]:
    try:
        value = json.loads((folder_of(task_id) / "task.json").read_text())
    except (OSError, ValueError, TaskError):
        return None
    return value if isinstance(value, dict) else None


@contextmanager
def edit(task_id: str):
    """The task, locked for changes; written back when the block ends."""
    folder = folder_of(task_id)
    with (folder / "task.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            task = load(task_id)
            if task is None:
                raise TaskError("Unknown task.")
            yield task
            write_json(folder / "task.json", task)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def event(task_id: str, kind: str, text: str = "") -> None:
    line = json.dumps({"kind": kind, "text": text, "at": now()}, ensure_ascii=False)
    with (folder_of(task_id) / "events.jsonl").open("a") as out:
        out.write(line + "\n")


def end(task: dict) -> None:
    """Mark a task ended once (the caller holds edit())."""
    if task.get("state") != "ended":
        task["state"], task["ended"] = "ended", now()
        event(task["id"], "ended")


def pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except PermissionError:
        return True  # there, just not ours to signal
    except (OSError, ValueError, TypeError):
        return False
    return True


def alive(task: dict) -> bool:
    if task.get("state") == "ended":
        return False
    if not task.get("pid"):
        return now() - task.get("created", 0) < PID_WAIT + LINK_WAIT  # still starting
    if task.get("tmux") and tmux_path():
        try:
            return tmux("has-session", "-t", pane(task)).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return pid_alive(task["pid"])
    return pid_alive(task["pid"])


def all_tasks() -> list:
    out = []
    if TASKS.is_dir():
        for entry in TASKS.iterdir():
            task = load(entry.name) if entry.is_dir() else None
            if task:
                out.append(task)
    return sorted(out, key=lambda t: t.get("created", 0))


def sweep() -> list:
    """Mark tasks whose session is gone as ended; return the ones still worth listing."""
    shown = []
    for task in all_tasks():
        if task.get("state") != "ended" and not alive(task):
            with edit(task["id"]) as fresh:
                end(fresh)
            task = load(task["id"]) or task
        if task.get("state") != "ended" or now() - task.get("ended", 0) < KEEP_ENDED:
            shown.append(task)
    return shown


def link(bridge: Optional[str]) -> Optional[str]:
    return "https://claude.ai/code/" + bridge if bridge else None


def session_file(pid) -> dict:
    try:
        value = json.loads((SESSIONS / ("%s.json" % int(pid))).read_text())
    except (OSError, ValueError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def seed(task_text: str, owner: str, origin: str) -> str:
    who = owner or "the owner"
    where = "over Telegram from their phone" if origin == "telegram" else "in Buddy's chat on the Mac"
    return (task_text.strip() + "\n\n(Buddy, %s's desktop sidekick, started this session for that task after %s asked "
            "for it %s. %s can follow along and reply from the Claude app on their phone through Remote Control, "
            "and Buddy passes your last message of each turn on to them, so end each turn with a short, plain "
            "summary of where things stand or the question you need answered.)" % (who, who, where, who))


def hook_settings(task_id: str) -> dict:
    # the folder goes with the command: the session's environment is Terminal's, not Buddy's
    command = "BUDDY_TASKS_DIR=%s %s %s hook %s" % (shlex.quote(str(TASKS)), shlex.quote("/usr/bin/python3"),
                                                     shlex.quote(HOOK), task_id)
    entry = [{"hooks": [{"type": "command", "command": command, "timeout": 10}]}]
    hooks = {name: entry for name in HOOKED}
    hooks["PostToolUse"] = [dict(entry[0], matcher="*")]
    return {"hooks": hooks}


def launcher(task: dict, folder: Path, model: Optional[str], effort: Optional[str]) -> str:
    """launch.sh: note the PID (exec keeps it), then become Claude Code with the task as its first message."""
    q = shlex.quote
    argv = [claude_path(), "--remote-control", task["name"], "-n", task["name"],
            "--settings", str(folder / "settings.json")]
    if model:
        argv += ["--model", model]
    if effort:
        argv += ["--effort", effort]
    return ("#!/bin/bash\necho $$ > %s\ncd %s || exit 1\nexec %s \"$(cat %s)\"\n" %
            (q(str(folder / "pid")), q(task["folder"]), " ".join(q(a) for a in argv), q(str(folder / "prompt.md"))))


def open_terminal(script: str, terminal: str) -> None:
    """A throwaway .command file in a new Terminal window; it needs no Automation permission."""
    fd, path = tempfile.mkstemp(prefix="claude-buddy-task-", suffix=".command")
    with os.fdopen(fd, "w") as out:
        out.write("#!/bin/zsh\nrm -f %s\n%s\n" % (shlex.quote(path), script))
    os.chmod(path, 0o755)
    opener = os.environ.get("BUDDY_OPEN", "/usr/bin/open")
    proc = subprocess.run([opener, "-a", terminal or "Terminal", path], capture_output=True, text=True, timeout=15)
    if proc.returncode:
        os.unlink(path)
        raise TaskError("Couldn't open %s." % (terminal or "Terminal"))


def attach_script(task: dict, folder: Path, new: bool) -> str:
    q = shlex.quote
    base = " ".join(q(a) for a in [tmux_path() or "tmux", "-L", SOCKET, "-f", CONF])
    if not new:
        return "exec %s attach -t %s" % (base, q(pane(task)))
    return "exec %s new-session -A -s %s -c %s %s" % (
        base, q(pane(task)), q(task["folder"]), q("/bin/bash " + q(str(folder / "launch.sh"))))


def start(req: dict) -> dict:
    task_text = str(req.get("task") or "").strip()
    if not task_text:
        raise TaskError("What should the session work on?")
    name = " ".join(str(req.get("name") or task_text).split())[:40].strip() or "Buddy task"
    where = os.path.realpath(os.path.expanduser(str(req.get("folder") or "~")))
    if not os.path.isdir(where):
        raise TaskError("That folder doesn't exist: %s" % where)
    model = req.get("model") if isinstance(req.get("model"), str) and re.fullmatch(r"[\w.\-\[\]]+", req["model"]) else None
    effort = req.get("effort") if req.get("effort") in EFFORTS else None
    origin = "telegram" if req.get("origin") == "telegram" else "chat"
    has_tmux = tmux_path() is not None
    TASKS.mkdir(parents=True, exist_ok=True)
    task_id = slug(name) + "-" + secrets.token_hex(2)
    folder = TASKS / task_id
    folder.mkdir()
    task = {"id": task_id, "name": name, "task": task_text[:4000], "folder": where, "origin": origin,
            "state": "starting", "created": now(), "tmux": has_tmux, "pid": None, "url": None, "last": ""}
    write_json(folder / "task.json", task)
    (folder / "events.jsonl").touch()
    (folder / "prompt.md").write_text(seed(task_text, str(req.get("owner") or ""), origin))
    write_json(folder / "settings.json", hook_settings(task_id))
    (folder / "launch.sh").write_text(launcher(task, folder, model, effort))
    os.chmod(folder / "launch.sh", 0o755)
    try:
        open_terminal(attach_script(task, folder, True) if has_tmux
                      else "exec /bin/bash %s" % shlex.quote(str(folder / "launch.sh")), req.get("terminal"))
    except (OSError, subprocess.SubprocessError, TaskError) as exc:
        with edit(task_id) as fresh:
            end(fresh)
        raise TaskError(str(exc) if isinstance(exc, TaskError) else "Couldn't open a Terminal window.")
    pid = wait_for(lambda: (folder / "pid").read_text().strip() or None, PID_WAIT)
    if not pid:
        stop(task_id)
        raise TaskError("Claude Code didn't start in the new Terminal window.")
    info = wait_for(lambda: session_file(pid) if session_file(pid).get("bridgeSessionId") else None, LINK_WAIT) or session_file(pid)
    with edit(task_id) as fresh:
        fresh["pid"] = int(pid)
        fresh["session_id"] = info.get("sessionId")
        fresh["url"] = link(info.get("bridgeSessionId"))
        if fresh["state"] == "starting":
            fresh["state"] = "working"
        task = dict(fresh)
    return task


def wait_for(probe, seconds: float):
    deadline = now() + seconds
    while True:
        try:
            value = probe()
        except (OSError, ValueError):
            value = None
        if value or now() >= deadline:
            return value
        time.sleep(0.5)


def send(task_id: str, text: str) -> dict:
    text = text.strip()
    task = load(task_id)
    if not task or not alive(task):
        raise TaskError("That session has ended.")
    if not text:
        raise TaskError("Nothing to send.")
    if not task.get("tmux") or not tmux_path():
        raise TaskError("I can only type into sessions running in tmux (brew install tmux). Use the Claude app instead.")
    if task.get("state") == "asking":
        raise TaskError("It's waiting on a permission question. Answer that first, in the Claude app or its window.")
    buffer = "buddy-send-" + task_id
    steps = [(("load-buffer", "-b", buffer, "-"), text),
             (("paste-buffer", "-p", "-d", "-b", buffer, "-t", pane(task)), None)]
    for args, given in steps:
        if tmux(*args, input_text=given).returncode:
            raise TaskError("Couldn't type into that session.")
    time.sleep(0.3)  # let the paste land before Enter sends it
    if tmux("send-keys", "-t", pane(task), "Enter").returncode:
        raise TaskError("Couldn't type into that session.")
    return task


def stop(task_id: str) -> dict:
    task = load(task_id)
    if not task:
        raise TaskError("Unknown task.")
    if task.get("tmux") and tmux_path():
        tmux("kill-session", "-t", pane(task))
    elif task.get("pid") and pid_alive(task["pid"]):
        os.kill(int(task["pid"]), signal.SIGTERM)
    with edit(task_id) as fresh:
        end(fresh)
        return dict(fresh)


def reopen(task_id: str, terminal: Optional[str]) -> dict:
    task = load(task_id)
    if not task or not alive(task):
        raise TaskError("That session has ended.")
    if not task.get("tmux"):
        raise TaskError("It's still in its first Terminal window.")
    open_terminal(attach_script(task, folder_of(task_id), False), terminal)
    return task


def last_text(transcript: str) -> str:
    """The last thing Claude said in a transcript, for Claude Code versions whose Stop hook doesn't say it."""
    said = ""
    try:
        with open(os.path.expanduser(transcript)) as lines:
            for line in lines:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                message = item.get("message") if isinstance(item, dict) and item.get("type") == "assistant" else None
                parts = [b.get("text", "") for b in (message or {}).get("content") or []
                         if isinstance(b, dict) and b.get("type") == "text"]
                if any(p.strip() for p in parts):
                    said = "\n".join(p for p in parts if p.strip())
    except (OSError, TypeError, AttributeError):
        pass
    return said


def hook(task_id: str, payload: dict) -> None:
    """What a session's hook reports: its state, and an event for anything the owner should hear."""
    name = payload.get("hook_event_name")
    if name == "PostToolUse" and (load(task_id) or {}).get("state") != "asking":
        return  # the common case, every tool call: nothing changes, so no lock and no write
    with edit(task_id) as task:
        if task.get("state") == "ended":
            return
        if payload.get("session_id"):
            task["session_id"] = payload["session_id"]
        if name == "UserPromptSubmit":
            task["state"] = "working"
        elif name == "PostToolUse":
            if task.get("state") == "asking":
                task["state"] = "working"
        elif name == "Notification":
            if payload.get("notification_type") in QUIET:
                return
            task["state"] = "asking"
            event(task_id, "asking", str(payload.get("message") or "It needs your answer."))
        elif name == "Stop":
            said = payload.get("last_assistant_message")
            if not isinstance(said, str) or not said.strip():
                said = last_text(payload.get("transcript_path") or "")
            task["state"], task["last"] = "waiting", said[:500]
            event(task_id, "done", said)
        elif name == "SessionEnd":
            end(task)


def propose(fields: dict) -> None:
    """Hold a start or a send for the owner's yes (tasks.lua asks, then runs it)."""
    TASKS.mkdir(parents=True, exist_ok=True)
    write_json(TASKS / PENDING, dict(fields, at=now()))


def folders(cfg: dict) -> list:
    """Project folders the brain can pick from: config.lua projects, else the newest in ~/dev and friends."""
    listed = [os.path.expanduser(p) for p in cfg.get("projects") or [] if isinstance(p, str)]
    if listed:
        return [p for p in listed if os.path.isdir(p)][:10]
    found = []
    for root in ("~/dev", "~/Projects", "~/code", "~/src"):
        root = os.path.expanduser(root)
        if os.path.isdir(root):
            for entry in os.scandir(root):
                if entry.is_dir() and not entry.name.startswith("."):
                    found.append((entry.stat().st_mtime, entry.path))
    return [p for _, p in sorted(found, reverse=True)[:10]]


def describe(task: dict) -> dict:
    keys = ("id", "name", "state", "folder", "origin", "url", "created", "last", "tmux")
    return {k: task.get(k) for k in keys}
