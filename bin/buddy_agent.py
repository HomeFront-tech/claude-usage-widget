"""Shared state and path rules for Buddy's agent processes."""
import fcntl
import fnmatch
import json
import os
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import List

AGENT = Path(os.path.expanduser(os.environ.get("BUDDY_AGENT_DIR") or
                                "~/Library/Application Support/claude-usage-widget/agent"))
BANNED_FOLDERS = (".ssh", ".aws", ".gnupg", "Library/Keychains")


def _load(name, fallback):
    try:
        return json.loads((AGENT / name).read_text())
    except (OSError, ValueError):
        return fallback


def load_config() -> dict:
    value = _load("config.json", {})
    return value if isinstance(value, dict) else {}


def denied(path: str, private: List[str]) -> bool:
    expanded = os.path.expanduser(path)
    real = os.path.realpath(expanded)
    home = os.path.realpath(os.path.expanduser("~"))
    ancestors = [str(parent) for value in (expanded, real)
                 for parent in (Path(value), *Path(value).parents)]
    identities = set()
    for ancestor in ancestors:
        try:
            stat = os.stat(ancestor)
            identities.add((stat.st_dev, stat.st_ino))
        except OSError:
            pass
    for part in BANNED_FOLDERS:
        try:
            stat = os.stat(os.path.join(home, part))
        except OSError:
            continue
        if (stat.st_dev, stat.st_ino) in identities:
            return True
    if any(real == os.path.realpath(os.path.join(home, part)) or
           real.startswith(os.path.realpath(os.path.join(home, part)) + os.sep)
           for part in BANNED_FOLDERS):
        return True
    for parent in [real] + list(Path(real).parents):
        name = Path(parent).name.lower()
        if (name.startswith(".env") or name.endswith((".pem", ".key")) or
                any(word in name for word in ("credential", "secret", "token"))):
            return True
    for pattern in private or []:
        expanded = os.path.expanduser(pattern)
        if not any(char in pattern for char in "*?["):
            protected = os.path.realpath(expanded)
            if real == protected or real.startswith(protected + os.sep):
                return True
            try:
                stat = os.stat(protected)
                if (stat.st_dev, stat.st_ino) in identities:
                    return True
            except OSError:
                pass
        else:
            patterns = (pattern, expanded)
            if expanded.startswith(os.sep):
                root = expanded[:next((i for i, c in enumerate(expanded) if c in "*?["), len(expanded))]
                real_root = os.path.realpath(root)
                if root.endswith(os.sep) and not real_root.endswith(os.sep):
                    real_root += os.sep
                patterns += (real_root + expanded[len(root):],)
            paths = [real]
            data_prefix = "/System/Volumes/Data"
            if real.startswith(data_prefix + os.sep):
                paths.append(real[len(data_prefix):])
            if any(fnmatch.fnmatch(parent, item) or
                   fnmatch.fnmatch(os.path.basename(parent), item)
                   for path in paths for parent in [path] + [str(p) for p in Path(path).parents]
                   for item in patterns):
                return True
    return False


def load_jobs() -> List[dict]:
    value = _load("automations.json", [])
    return value if isinstance(value, list) else []


def save_jobs(jobs) -> None:
    AGENT.mkdir(parents=True, exist_ok=True)
    with (AGENT / "automations.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        temp = AGENT / ("automations.%d.tmp" % os.getpid())
        try:
            temp.write_text(json.dumps(jobs, ensure_ascii=False) + "\n")
            os.replace(str(temp), str(AGENT / "automations.json"))
        finally:
            if temp.exists():
                temp.unlink()
            fcntl.flock(lock, fcntl.LOCK_UN)


@contextmanager
def edit_jobs():
    AGENT.mkdir(parents=True, exist_ok=True)
    with (AGENT / "automations.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            jobs = load_jobs()
            yield jobs
            temp = AGENT / ("automations.%d.tmp" % os.getpid())
            try:
                temp.write_text(json.dumps(jobs, ensure_ascii=False) + "\n")
                os.replace(str(temp), str(AGENT / "automations.json"))
            finally:
                if temp.exists():
                    temp.unlink()
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def load_runs() -> dict:
    value = _load("runs.json", {})
    return value if isinstance(value, dict) else {}


def log(record: dict) -> None:
    AGENT.mkdir(parents=True, exist_ok=True)
    entry = dict(record, at=datetime.now().isoformat(timespec="seconds"))
    with (AGENT / "usage.jsonl").open("a") as out:
        out.write(json.dumps(entry, ensure_ascii=False) + "\n")
