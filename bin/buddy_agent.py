"""Shared state and path rules for Buddy's agent processes."""
import fcntl
import fnmatch
import json
import os
import secrets
import sys
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


def mutate_jobs(request: dict) -> dict:
    """Apply a desktop watch edit under the same lock as the brain tools."""
    action = request.get("action")
    with edit_jobs() as jobs:
        if action == "add_watch":
            job = dict(request["job"])
            if any(item.get("id") == job.get("id") for item in jobs):
                job["id"] += "-" + secrets.token_hex(2)
            jobs.append(job)
            return {"added": True}
        if action == "remove_watch":
            for index, job in enumerate(jobs):
                if job.get("id") == request.get("id") and (job.get("trigger") or {}).get("type") == "every":
                    jobs.pop(index)
                    return {"removed": True, "name": job.get("name") or job.get("instructions") or "watch"}
            return {"removed": False}
        if action == "expire":
            now = request["now"]
            before = len(jobs)
            jobs[:] = [job for job in jobs if not (
                (job.get("trigger") or {}).get("type") == "every" and
                isinstance((job.get("trigger") or {}).get("until"), (int, float)) and
                now >= job["trigger"]["until"])]
            return {"removed": before - len(jobs)}
        raise ValueError("Unknown job edit.")


def load_runs() -> dict:
    value = _load("runs.json", {})
    return value if isinstance(value, dict) else {}


def log(record: dict) -> None:
    AGENT.mkdir(parents=True, exist_ok=True)
    entry = dict(record, at=datetime.now().isoformat(timespec="seconds"))
    with (AGENT / "usage.jsonl").open("a") as out:
        out.write(json.dumps(entry, ensure_ascii=False) + "\n")


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "edit-jobs":
    try:
        request_path = Path(sys.argv[2]).resolve()
        if request_path.parent != AGENT.resolve():
            raise ValueError("Job edit must be in the agent folder.")
        result = mutate_jobs(json.loads(request_path.read_text()))
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError):
        raise SystemExit(1)
