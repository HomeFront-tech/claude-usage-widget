"""Shared helpers for buddy-opus and buddy-opus-approve: talking to the running buddy
through Hammerspoon's hs CLI, the daily cap on Opus runs Grok asks for, and the run log.

State lives in ~/Library/Application Support/claude-usage-widget/grok (BUDDY_STATE_DIR
overrides it); the hs CLI is /opt/homebrew/bin/hs (BUDDY_HS overrides it). Runs on the
stock macOS python3 (3.9), standard library only.
"""
import fcntl
import json
import os
import secrets
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

STATE = Path(os.environ.get("BUDDY_STATE_DIR")
             or "~/Library/Application Support/claude-usage-widget/grok").expanduser()
HS = os.environ.get("BUDDY_HS") or "/opt/homebrew/bin/hs"
RUNS = STATE / "opus-runs.jsonl"


def hs_call(lua: str, timeout: float = 10) -> Optional[str]:
    """Run Lua in the running Hammerspoon. None if it isn't running or the code failed.

    stdin is /dev/null: hs reads stdin when it isn't a terminal, and in the approval MCP
    server stdin is Claude Code's open pipe, so hs would wait forever. hs also prints
    "-- Loading extension: …" the first time code touches an extension; those lines go."""
    try:
        p = subprocess.run([HS, "-c", lua], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    lines = [x for x in p.stdout.splitlines() if not x.startswith("-- Loading extension:")]
    return "\n".join(lines).strip()


def buddy_config() -> Optional[dict]:
    """The buddy's grok settings, or None when the buddy is offline or the feature is off."""
    out = hs_call("return ClaudeBuddy.grokConfig()")
    if not out:
        return None
    try:
        cfg = json.loads(out)
    except ValueError:
        return None
    return cfg if isinstance(cfg, dict) and cfg.get("enabled") else None


def lua_str(s: str) -> str:
    """A Lua string literal for any text (JSON's \\uXXXX escapes aren't valid Lua)."""
    out = []
    for ch in s:
        if ch in '"\\':
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def notify(kind: str, text: str) -> None:
    """Tell the buddy what's happening with an Opus run (start, done, failed, capped)."""
    hs_call("ClaudeBuddy.grokOpus(%s, %s)" % (lua_str(kind), lua_str(text)))


def _now(now: Optional[datetime]) -> datetime:
    return now or datetime.now()


def _claimed_today(now: datetime) -> int:
    if not RUNS.exists():
        return 0
    day, n = now.date().isoformat(), 0
    for line in RUNS.read_text().splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("event") == "claimed" and str(rec.get("at", "")).startswith(day):
            n += 1
    return n


def _append(rec: dict) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with RUNS.open("a") as f:
        f.write(json.dumps(rec) + "\n")


def runs_today(now: Optional[datetime] = None) -> int:
    """Opus runs Grok has used today (local date)."""
    return _claimed_today(_now(now))


def claim_run(cap: int, now: Optional[datetime] = None) -> Optional[str]:
    """Take one of today's runs. Returns a run id, or None when the cap is used up."""
    now = _now(now)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "opus-runs.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if _claimed_today(now) >= cap:
            return None
        run_id = now.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)
        _append({"id": run_id, "at": now.isoformat(timespec="seconds"), "event": "claimed"})
        return run_id


def log_run(run_id: str, **fields) -> None:
    """Record how a run ended: outcome, seconds, approvals and so on."""
    rec = {"id": run_id, "at": datetime.now().isoformat(timespec="seconds"), "event": "finished"}
    rec.update(fields)
    _append(rec)
