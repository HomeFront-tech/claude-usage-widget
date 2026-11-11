"""Claude Code sessions Buddy starts for a task: their files, their tmux pane, their hooks.

Each task has a folder under TASKS with task.json (name, state, link), prompt.md (its
first message), settings.json (hooks that call `buddy-task hook <id>`), launch.sh and
events.jsonl, which the hooks append to and tasks.lua reads. The session runs in Buddy's
own tmux server (`tmux -L claude-buddy`) so Buddy can type follow-ups into it and closing
its Terminal window doesn't end it. Without tmux it runs straight in Terminal and only
the Claude app can talk to it.
"""
import fcntl
import hashlib
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
import unicodedata
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

import buddy_agent as agent

HERE = os.path.dirname(os.path.realpath(__file__))
TASKS = Path(os.path.expanduser(os.environ.get("BUDDY_TASKS_DIR") or
                                "~/Library/Application Support/claude-usage-widget/tasks"))
SESSIONS = Path(os.path.expanduser(os.environ.get("BUDDY_SESSIONS_DIR") or "~/.claude/sessions"))
SEARCH = os.path.expanduser("~/.local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
SOCKET = "claude-buddy"  # Buddy's own tmux server, apart from any the owner runs
CONF = os.path.join(HERE, "buddy-tmux.conf")
HOOK = os.path.join(HERE, "buddy-task")
HOOKED = ("UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd")
EFFORTS = ("low", "medium", "high", "xhigh", "max")  # Claude Code's --effort levels
# What they might call each effort level ("x-high" and "extra high" read as "x high").
EFFORT_WORDS = {"low": "low", "lo": "low", "minimal": "low", "lowest": "low", "medium": "medium", "med": "medium",
                "mid": "medium", "moderate": "medium", "normal": "medium", "high": "high", "hi": "high",
                "xhigh": "xhigh", "x high": "xhigh", "extra high": "xhigh", "very high": "xhigh", "max": "max",
                "maximum": "max", "highest": "max"}
# The newest Claude model of each family, which a family name alone means, as Claude Code calls it.
MODELS = {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5",
          "fable": "claude-fable-5-2"}
# Every model a session can be asked for by name and version, and how each one reads (bin/claude-tokens
# PRICES has the same list). The bare aliases only read right for tasks that were started with one.
MODEL_NAMES = {"claude-fable-5-2": "Fable 5.2", "claude-fable-5-1": "Fable 5.1", "claude-fable-5": "Fable 5",
               "claude-opus-5-5": "Opus 5.5", "claude-opus-5": "Opus 5", "claude-opus-4-8": "Opus 4.8",
               "claude-opus-4-7": "Opus 4.7", "claude-opus-4-6": "Opus 4.6", "claude-opus-4-5": "Opus 4.5",
               "claude-sonnet-5-5": "Sonnet 5.5", "claude-sonnet-5": "Sonnet 5", "claude-sonnet-4-6": "Sonnet 4.6",
               "claude-sonnet-4-5": "Sonnet 4.5", "claude-haiku-5-5": "Haiku 5.5", "claude-haiku-4-5": "Haiku 4.5",
               "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "fable": "Fable"}
# Words that can follow a model's name without making it another model: "Opus 4.7 please", "Sonnet at medium".
MODEL_FILLER = {"please", "model", "latest", "newest", "at", "with", "on", "effort", "thinking", "level",
                "low", "medium", "med", "high", "xhigh", "x", "extra", "very", "max", "maximum"}
NUMBER_WORDS = {"zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                "seven": "7", "eight": "8", "nine": "9"}
PENDING = "pending.json"  # a start or send the brain proposed, waiting for the owner's yes
KEEP_ENDED = 86400        # an ended task stays in the list this long
PID_WAIT, LINK_WAIT = 30, 45  # seconds start() waits for the session, then for its link
PERMIT_WAIT = 570
PERMIT_MARGIN = 15  # stop taking taps before the hook's own deadline
PERMIT_CHARS = 3500
CLOSE_PERMITS = ("PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "SessionEnd")
QUIET = ("idle_prompt", "auth_success")  # notifications that aren't a question for the owner
# Every Buddy task session gets these denies, merged by Claude Code with all settings sources.
# File rules match built-in tools; Bash commands such as cat are not covered.
TASK_DENY_BASH = (
    "Bash(security find-generic-password *)", "Bash(security find-internet-password *)",
    "Bash(security dump-keychain*)", "Bash(security export *)", "Bash(gh auth token*)",
    "Bash(gh ssh-key add *)", "Bash(git push --force*)", "Bash(git push -f*)",
    "Bash(git push * --force*)", "Bash(git push * -f)", "Bash(git push * -f *)",
    "Bash(git push --delete *)", "Bash(git push * --delete *)", "Bash(git push --mirror*)",
    "Bash(git push * --mirror*)", "Bash(git push -d *)", "Bash(git push * -d *)", "Bash(git push * +*)",
    "Bash(git -C * push --force*)", "Bash(git -C * push -f*)", "Bash(security -q find-*)",
    "Bash(security -i*)", "Bash(gh auth status -t*)", "Bash(gh auth status --show-token*)",
)
TASK_DENY_PATHS = ("~/.ssh/**", "~/.aws/**", "~/.gnupg/**", "~/Library/Keychains/**",
                   "~/.codex/auth.json", "~/.claude/.credentials.json", "~/.config/gh/hosts.yml",
                   "~/.netrc", "~/.npmrc", "~/.pypirc", "~/.git-credentials", "~/.docker/config.json",
                   "~/.kube/config", "~/.local/share/opencode/auth.json", "~/.config/github-copilot/**",
                   "~/.claude.json")


class TaskError(Exception):
    pass


def now() -> float:
    return time.time()


def from_tag() -> str:
    """The line every message Buddy types into a session starts with: who relayed it, and that the owner didn't
    type it. The owner's name is config.lua's name (in the agent config.json); without one, "the owner"."""
    owner = re.sub(r"[^\w .-]", "", str(agent.load_config().get("owner") or "")).strip()[:40] or "the owner"
    possessive = owner if owner == "the owner" else owner + "'s"
    return "[Relayed by Buddy, %s desktop sidekick, at %s request; not typed by %s]" % (
        "the owner's" if owner == "the owner" else possessive, "the owner's" if owner == "the owner" else possessive, owner)


def pick_model(said) -> Optional[str]:
    """The model they asked for as its Claude Code id: a family alone ("Sonnet") is its newest model, a version
    ("Opus 4.7", "fable five point two", "claude-haiku-5-5", "claude-haiku-4-5-20251001") that exact one. None
    when it isn't a Claude family or that version isn't in MODEL_NAMES ("Opus 4.1", "Sonnet 5.5.5", "gpt-5")."""
    words = [NUMBER_WORDS.get(w, w) for w in re.findall(r"[a-z]+|[0-9]+", str(said or "").lower())
             if w not in ("claude", "point", "dot")]
    if not words or words[0] not in MODELS:
        return None
    version = []
    for at, w in enumerate(words[1:]):
        if not w.isdigit():
            if any(rest not in MODEL_FILLER for rest in words[1 + at:]):
                return None  # "sonnet; rm -rf /" isn't a model they asked for
            break
        version.append(w)
    if version and len(version[-1]) == 8:  # a dated id: claude-haiku-4-5-20251001 is Haiku 4.5
        version.pop()
    if not version:
        return MODELS[words[0]]
    model = "claude-%s-%s" % (words[0], "-".join(str(int(v)) for v in version))
    return model if model in MODEL_NAMES else None


def pick_effort(said) -> Optional[str]:
    """The effort level they asked for ("medium", "Extra high effort", "x-high", "max"), or None."""
    words = [w for w in re.findall(r"[a-z]+", str(said or "").lower())
             if w not in ("effort", "thinking", "reasoning", "level", "at", "on", "a", "the")]
    return EFFORT_WORDS.get(" ".join(words))


def model_name(model) -> str:
    """How a session's model reads in a list: "Opus 5.5", or Claude Code's own default when none was set."""
    return MODEL_NAMES.get(model, model) if model else "Claude Code default"


def effort_name(effort) -> str:
    """How a session's effort reads in a list: "medium", or Claude Code's own default when none was set."""
    return effort if effort in EFFORTS else "Claude Code default"


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


def reply_pane(task: dict) -> str:
    target = task.get("pane")
    if target is None:
        # Older tasks did not save their pane; use the first, never the selected pane.
        got = tmux("list-panes", "-s", "-t", pane(task), "-F", "#{pane_id}")
        target = got.stdout.splitlines()[0] if got.returncode == 0 and got.stdout.splitlines() else ""
    if not isinstance(target, str) or not re.fullmatch(r"%\d+", target):
        raise TaskError("I can't find that session's Claude pane. Not typing into it.")
    return target


def check_foreground(task: dict, target: str) -> None:
    got = tmux("display", "-p", "-t", target, "#{session_name} #{pane_current_command} #{pane_in_mode} #{pane_pid}")
    fields = got.stdout.split()
    if (got.returncode or len(fields) != 4 or fields[0] != pane(task) or fields[2] != "0"
            or not (fields[1] in ("claude", "node") or re.fullmatch(r"\d+(\.\d+)+", fields[1]))
            or (task.get("pid") is not None and fields[3] != str(task["pid"]))):
        raise TaskError("Claude isn't in front in that session's pane (or the pane is in copy mode). Not typing into it.")


def slug(name: str) -> str:
    return (re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:30].strip("-") or "task")


def folder_of(task_id: str) -> Path:
    if not re.fullmatch(r"[a-z0-9-]{1,40}", task_id or ""):
        raise TaskError("Unknown task.")
    return TASKS / task_id


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".%d.tmp" % os.getpid())
    tmp.write_text(text)
    os.replace(str(tmp), str(path))


def write_json(path: Path, value) -> None:
    write_atomic(path, json.dumps(value, ensure_ascii=False) + "\n")


def load(task_id: str) -> Optional[dict]:
    try:
        value = json.loads((folder_of(task_id) / "task.json").read_text())
    except (OSError, ValueError, TaskError):
        return None
    return value if isinstance(value, dict) else None


@contextmanager
def edit(task_id: str, deadline=None):
    """The task, locked for changes; written back when the block ends."""
    folder = folder_of(task_id)
    with (folder / "task.lock").open("a+") as lock:
        if deadline is None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        else:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TaskError("Task is busy.")
                    time.sleep(0.05)
        try:
            task = load(task_id)
            if task is None:
                raise TaskError("Unknown task.")
            yield task
            write_json(folder / "task.json", task)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def event(task_id: str, kind: str, text: str = "", **fields) -> None:
    line = json.dumps(dict(fields, kind=kind, text=text, at=now()), ensure_ascii=False)
    with (folder_of(task_id) / "events.jsonl").open("a") as out:
        out.write(line + "\n")


def end(task: dict) -> None:
    """Mark a task ended once (the caller holds edit())."""
    if task.get("state") != "ended":
        close_permits(task, "Answered on the Mac")
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
        if task.get("state") != "ended" and task.get("pid"):
            info = session_file(task["pid"])
            session_id, url = info.get("sessionId"), link(info.get("bridgeSessionId"))
            if session_id and (task.get("link_session_id") != session_id or (url and task.get("url") != url)):
                with edit(task["id"]) as fresh:
                    if fresh.get("state") != "ended":
                        previous_url = fresh.get("url")
                        fresh["session_id"], fresh["link_session_id"] = session_id, session_id
                        if url:
                            fresh["url"] = url
                        note_session(fresh, session_id)
                        if url and url != previous_url:
                            event(task["id"], "link_ready", "The phone link is ready.", url=url)
                    task = dict(fresh)
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


def hook_settings(task_id: str, approvals: bool = False) -> dict:
    # the folder goes with the command: the session's environment is Terminal's, not Buddy's
    command = "BUDDY_TASKS_DIR=%s %s %s hook %s" % (shlex.quote(str(TASKS)), shlex.quote("/usr/bin/python3"),
                                                     shlex.quote(HOOK), task_id)
    entry = [{"hooks": [{"type": "command", "command": command, "timeout": 10}]}]
    hooks = {name: entry for name in HOOKED}
    hooks["PostToolUse"] = [dict(entry[0], matcher="*")]
    if approvals:
        hooks["PostToolUseFailure"] = [dict(entry[0], matcher="*")]
        hooks["PermissionRequest"] = [{"matcher": "*", "hooks": [{"type": "command",
            "command": command.rsplit(" hook ", 1)[0] + " permit " + task_id, "timeout": 600}]}]
    paths = list(TASK_DENY_PATHS)
    for value in agent.load_config().get("private_paths") or []:
        if not isinstance(value, str) or not value:
            continue
        path = os.path.expanduser(value)
        if re.search(r"[*?\[\]]", value):
            paths.append(("/" if os.path.isabs(path) else "") + path)
        else:
            path = "/" + re.sub(r"([\\*?\[\]])", r"\\\1", os.path.realpath(path))
            paths.extend((path, path.rstrip("/") + "/**"))
    if approvals:
        # // anchors an absolute path.
        path = "/" + re.sub(r"([\\*?\[\]])", r"\\\1", str(TASKS.resolve())) + "/**"
        paths.append(path)
    # No Write rules: Edit rules cover every file-editing tool, and Claude Code warns at start
    # that a Write(path) rule is never checked.
    deny = list(TASK_DENY_BASH) + [tool + "(" + path + ")" for path in paths for tool in ("Read", "Edit")]
    return {"hooks": hooks, "permissions": {"deny": deny}}


def launcher(task: dict, folder: Path, model: Optional[str], effort: Optional[str]) -> str:
    """launch.sh: note the PID (exec keeps it), then become Claude Code with the task as its first message."""
    q = shlex.quote
    argv = [claude_path(), "--remote-control", task["name"], "-n", task["name"],
            "--settings", str(folder / "settings.json")]
    if model:
        argv += ["--model", model]
    if effort:
        argv += ["--effort", effort]
    return ("#!/bin/bash\nprintf '%%s\\n' \"${TMUX_PANE:-}\" > %s\necho $$ > %s\ncd %s || exit 1\nexec %s \"$(cat %s)\"\n" %
            (q(str(folder / "pane")), q(str(folder / "pid")), q(task["folder"]), " ".join(q(a) for a in argv), q(str(folder / "prompt.md"))))


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
            "state": "starting", "created": now(), "tmux": has_tmux, "pid": None, "url": None, "last": "",
            "model": model, "effort": effort}
    if type(req.get("thread")) is int and req["thread"] > 0 \
            and isinstance(req.get("thread_bot"), str) and re.fullmatch(r"[0-9]+", req["thread_bot"]):
        task["thread"] = req["thread"]
        task["thread_bot"] = req["thread_bot"]
    write_json(folder / "task.json", task)
    (folder / "events.jsonl").touch()
    (folder / "prompt.md").write_text(seed(task_text, str(req.get("owner") or ""), origin))
    write_json(folder / "settings.json", hook_settings(task_id, req.get("approvals") is True))
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
        if has_tmux:
            target = (folder / "pane").read_text().strip()
            if re.fullmatch(r"%\d+", target):
                fresh["pane"] = target
        fresh["link_session_id"] = info.get("sessionId")
        fresh["session_id"] = info.get("sessionId")
        note_session(fresh, info.get("sessionId"))
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
    if text:
        text = from_tag() + " " + text
    task = load(task_id)
    if not task or not alive(task):
        raise TaskError("That session has ended.")
    if not text:
        raise TaskError("Nothing to send.")
    if not task.get("tmux") or not tmux_path():
        raise TaskError("I can only type into sessions running in tmux (brew install tmux). Use the Claude app instead.")
    def check_prompt():
        fresh = load(task_id)
        if not fresh or fresh.get("state") == "ended":
            raise TaskError("That session has ended.")
        if fresh.get("state") == "asking" or fresh.get("open_permits"):
            raise TaskError("It's waiting on a permission question. Answer that first, in the Claude app or its window.")
    check_prompt()
    target = reply_pane(task)
    buffer = "buddy-send-" + task_id
    steps = [(("load-buffer", "-b", buffer, "-"), text),
             (("paste-buffer", "-p", "-d", "-b", buffer, "-t", target), None)]
    for args, given in steps:
        check_prompt()
        check_foreground(task, target)
        if tmux(*args, input_text=given).returncode:
            raise TaskError("Couldn't type into that session.")
    time.sleep(0.3)  # let the paste land before Enter sends it
    check_prompt()  # a permission question may have arrived while the paste landed
    check_foreground(task, target)
    if tmux("send-keys", "-t", target, "Enter").returncode:
        raise TaskError("Couldn't type into that session.")
    return task


def clear_thread(task_id: str, thread: int, bot: str) -> dict:
    # A delayed failure from an old bot must not clear a newer topic assignment.
    with edit(task_id, time.monotonic() + 2) as task:
        if task.get("thread") == thread and task.get("thread_bot") == bot:
            task.pop("thread", None)
            task.pop("thread_bot", None)
        return dict(task)


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


def note_session(task: dict, session_id) -> None:
    """Every id the session has had (/clear starts a new one), so all its use can be found."""
    known = task.setdefault("session_ids", [])
    if session_id and session_id not in known:
        known.append(session_id)


def hook(task_id: str, payload: dict) -> None:
    """What a session's hook reports: its state, and an event for anything the owner should hear."""
    name = payload.get("hook_event_name")
    if name == "PostToolUse" and (load(task_id) or {}).get("state") != "asking" \
            and not (load(task_id) or {}).get("open_permits"):
        return  # the common case, every tool call: nothing changes, so no lock and no write
    with edit(task_id) as task:
        if task.get("state") == "ended":
            return
        if name in CLOSE_PERMITS:
            fingerprint = permit_fingerprint(payload) if name in ("PostToolUse", "PostToolUseFailure") else None
            close_permits(task, "Answered on the Mac", fingerprint)
        if payload.get("session_id"):
            task["session_id"] = payload["session_id"]
            note_session(task, payload["session_id"])
        if name == "UserPromptSubmit":
            task["state"] = "working"
        elif name in ("PostToolUse", "PostToolUseFailure"):
            if task.get("state") == "asking":
                task["state"] = "working"
        elif name == "Notification":
            if payload.get("notification_type") in QUIET:
                return
            task["state"] = "asking"
            if payload.get("notification_type") != "permission_prompt" or not task.get("open_permits"):
                event(task_id, "asking", str(payload.get("message") or "It needs your answer."))
        elif name == "Stop":
            said = payload.get("last_assistant_message")
            if not isinstance(said, str) or not said.strip():
                said = last_text(payload.get("transcript_path") or "")
            task["state"], task["last"] = "waiting", said[:500]
            event(task_id, "done", said)
        elif name == "SessionEnd":
            end(task)
        if task.get("open_permits") and task.get("state") != "ended":
            task["state"] = "asking"


def permit_fingerprint(payload: dict) -> str:
    args = json.dumps(payload.get("tool_input") or {}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256((str(payload.get("tool_name") or "Tool") + args).encode("utf-8")).hexdigest()


def permit_clean(value):
    # Invisible formatting must not disguise the command or its argument names.
    if isinstance(value, str):
        return "".join(c for c in value if c in "\n\t" or unicodedata.category(c) not in ("Cc", "Cf"))
    return value


def permit_json(value) -> str:
    # Clean each displayed pair separately: two keys can become identical after
    # stripping hidden characters, but both arguments must remain visible.
    if isinstance(value, dict):
        return "{" + ",".join(permit_json(k) + ":" + permit_json(v) for k, v in sorted(value.items())) + "}"
    if isinstance(value, list):
        return "[" + ",".join(permit_json(v) for v in value) + "]"
    return json.dumps(permit_clean(value), ensure_ascii=False, separators=(",", ":"))


def permit_detail(payload: dict) -> str:
    tool = str(payload.get("tool_name") or "Tool")
    args = payload.get("tool_input")
    args = args if isinstance(args, dict) else {}
    if tool == "Bash":
        detail = args.get("command") or tool
    elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        # Escape invisible characters too: they still change the file being approved.
        detail = tool + ": " + json.dumps(args, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        detail = "".join(json.dumps(c, ensure_ascii=True)[1:-1]
                         if unicodedata.category(c) in ("Cc", "Cf", "Zl", "Zp") else c for c in detail)
    elif tool == "WebFetch":
        detail = args.get("url") or tool
    elif tool.startswith("mcp__"):
        detail = tool[5:].replace("__", " / ", 1) + ": " + permit_json(args)
    else:
        field = next((str(v) for v in args.values() if isinstance(v, (str, int, float))), "")
        detail = tool + (": " + field if field else "")
    return permit_clean(str(detail))


def permit_summary(payload: dict) -> str:
    detail = permit_detail(payload)
    if len(detail) > PERMIT_CHARS:
        return detail[:PERMIT_CHARS] + "…(+%d more characters)" % (len(detail) - PERMIT_CHARS)
    return detail


def read_permit(task_id: str, rid: str) -> Optional[dict]:
    if not re.fullmatch(r"[0-9a-f]{12}", rid or ""):
        return None
    try:
        value = json.loads((folder_of(task_id) / "permits" / (rid + ".json")).read_text())
    except (OSError, ValueError, TaskError):
        return None
    return value if isinstance(value, dict) and value.get("task_id") == task_id and value.get("rid") == rid else None


def close_permit(task: dict, permit: dict, reason: str) -> None:
    # All permit changes share the task lock, including a tap racing a Mac answer.
    rid = permit["rid"]
    permit["state"], permit["reason"] = "closed", reason
    write_json(folder_of(task["id"]) / "permits" / (rid + ".json"), permit)
    task["open_permits"] = [r for r in task.get("open_permits", []) if r != rid]
    event(task["id"], "permit_closed", rid=rid, reason=reason)


def permit_decision(task_id: str, rid: str) -> Optional[str]:
    path = folder_of(task_id) / "permits" / (rid + ".decision")
    try:
        decision = path.read_text().strip()
    except FileNotFoundError:
        return None
    return decision if decision in ("allow", "deny") else None


def close_permits(task: dict, reason: str, fingerprint: Optional[str] = None) -> None:
    for rid in list(task.get("open_permits", [])):
        permit = read_permit(task["id"], rid)
        if permit and permit.get("state") == "open" \
                and (fingerprint is None or permit.get("fingerprint") == fingerprint) \
                and not permit_decision(task["id"], rid):
            # A written tap belongs to the listening hook, which acknowledges it.
            close_permit(task, permit, reason)
            if fingerprint is not None:
                break  # identical parallel calls still represent separate prompts


def answer(task_id: str, rid: str, decision: str) -> bool:
    if decision not in ("allow", "deny") or not read_permit(task_id, rid):
        return False
    with edit(task_id, time.monotonic() + 2) as task:
        permit = read_permit(task_id, rid)
        path = folder_of(task_id) / "permits" / (rid + ".decision")
        if not permit or permit.get("state") != "open" or task.get("state") == "ended" \
                or rid not in task.get("open_permits", []) or path.exists():
            return False
        if decision == "allow" and permit.get("truncated"):
            return False
        if permit.get("listener_pid") and not pid_alive(permit["listener_pid"]):
            close_permit(task, permit, "Answered on the Mac")
            return False
        if now() >= permit.get("expires", 0):
            close_permit(task, permit, "Timed out")
            return False
        write_atomic(path, decision + "\n")
        return True


def permit(task_id: str, payload: dict):
    """One tool call only. Errors and timeouts leave Claude Code's normal prompt alone."""
    rid, deadline = None, time.monotonic() + PERMIT_WAIT
    previous, reason = {}, "Timed out"
    def interrupted(*_):
        nonlocal reason
        reason = "Answered on the Mac"
        raise InterruptedError()
    try:
        if payload.get("hook_event_name") != "PermissionRequest" \
                or str(payload.get("tool_name") or "").startswith(("AskUser", "ExitPlan")):
            return None
        for sig in (signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        with edit(task_id, deadline) as task:
            if task.get("state") == "ended":
                return None
            rid = secrets.token_hex(6)
            base = folder_of(task_id) / "permits"
            base.mkdir(exist_ok=True)
            while (base / (rid + ".json")).exists():
                rid = secrets.token_hex(6)
            request = {"task_id": task_id, "rid": rid, "tool": str(payload.get("tool_name") or "Tool"),
                       "summary": permit_summary(payload), "truncated": len(permit_detail(payload)) > PERMIT_CHARS,
                       "fingerprint": permit_fingerprint(payload), "listener_pid": os.getpid(), "at": now(),
                       "expires": now() + deadline - time.monotonic() - PERMIT_MARGIN, "state": "open"}
            write_json(base / (rid + ".json"), request)
            task.setdefault("open_permits", []).append(rid)
            task["state"] = "asking"
            event(task_id, "permit", request["summary"], rid=rid)
        while time.monotonic() < deadline:
            with edit(task_id, deadline) as task:
                request = read_permit(task_id, rid)
                if not request or request.get("state") != "open":
                    return None
                decision = permit_decision(task_id, rid)
                if decision in ("allow", "deny") and not (decision == "allow" and request.get("truncated")):
                    close_permit(task, request, "Allowed" if decision == "allow" else "Denied")
                    result = {"behavior": decision}
                    if decision == "deny":
                        result["message"] = "The owner said no from Buddy."
                    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": result}}
                if task.get("state") == "ended":
                    return None
            time.sleep(0.5)
    except Exception:
        return None
    finally:
        if rid:
            try:
                with edit(task_id, time.monotonic() + 0.1) as task:
                    request = read_permit(task_id, rid)
                    if request and request.get("state") == "open":
                        close_permit(task, request, reason)
            except Exception:
                pass
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return None


@contextmanager
def proposals():
    # Producers and the one-at-a-time consumer share the same bounded lock.
    TASKS.mkdir(parents=True, exist_ok=True)
    with (TASKS / "pending.lock").open("a+") as lock, \
            agent.locked(lock, "Pending actions are busy; try again shortly."):
        try:
            pending = json.loads((TASKS / PENDING).read_text())
        except (OSError, ValueError):
            pending = []
        if isinstance(pending, dict):
            pending = [pending]  # proposals saved by older versions
        if not isinstance(pending, list):
            pending = []
        yield pending
        write_json(TASKS / PENDING, pending)


def propose(fields: dict) -> None:
    """Hold a start, send or open for the owner's yes (tasks.lua asks, then runs it)."""
    with proposals() as pending:
        pending.append(dict(fields, at=now()))


def take_proposal():
    with proposals() as pending:
        return pending.pop(0) if pending else None


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
    keys = ("id", "name", "state", "folder", "origin", "url", "created", "last", "tmux", "thread", "thread_bot", "model",
            "effort")
    return {k: task.get(k) for k in keys}
