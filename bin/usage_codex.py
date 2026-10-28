"""Read Codex rate limits from its app-server."""
import json
import os
import re
import selectors
import subprocess
import time
from decimal import Decimal, InvalidOperation
from typing import Optional

from usage_common import Fail

CODEX_DIRS = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
              "/usr/bin", "/bin"]


def find_codex() -> Optional[str]:
    for directory in CODEX_DIRS:
        path = os.path.join(os.path.expanduser(directory), "codex")
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def ask(codex: str, timeout: float = 20) -> dict:
    env = os.environ.copy()
    env["PATH"] = ":".join(os.path.expanduser(directory) for directory in CODEX_DIRS)
    process = None
    try:
        process = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   env=env)
        requests = [
            {"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "claude-buddy", "version": "1"}}},
            {"method": "initialized"},
            {"id": 2, "method": "account/rateLimits/read"},
        ]
        for request in requests:
            process.stdin.write((json.dumps(request) + "\n").encode())
        process.stdin.flush()
        deadline = time.monotonic() + timeout
        pending = b""
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                ready = selector.select(max(0, deadline - time.monotonic()))
                if not ready:
                    break
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    try:
                        reply = json.loads(line)
                    except (ValueError, UnicodeError):
                        continue
                    if not isinstance(reply, dict) or reply.get("id") != 2:
                        continue
                    if reply.get("error"):
                        message = str(reply["error"].get("message") or "")
                        if re.search(r"auth|log(?:ged)? ?in|sign|token|unauthori", message,
                                     re.IGNORECASE):
                            raise Fail("Signed out · open Codex")
                        raise Fail("Codex didn't answer")
                    if isinstance(reply.get("result"), dict):
                        return reply["result"]
                    raise Fail("Codex didn't answer")
    except Fail:
        raise
    except (OSError, ValueError, BrokenPipeError):
        raise Fail("Codex didn't answer")
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            if process.stdin:
                process.stdin.close()
            if process.stdout:
                process.stdout.close()
    raise Fail("Codex didn't answer")


def label_for(mins: Optional[int], name: Optional[str]) -> str:
    if mins == 10080:
        window = "Week"
    elif mins is None:
        window = "Limit"
    elif mins >= 1440 and mins % 1440 == 0:
        window = "%d-day" % (mins // 1440)
    elif mins >= 60 and mins % 60 == 0:
        window = "%d-hour" % (mins // 60)
    else:
        window = "%d-min" % mins
    return name + " · " + window if name and name.lower() != "codex" else window


def normalize(rate: dict) -> dict:
    snapshot = rate.get("rateLimits") or {}
    by_id = rate.get("rateLimitsByLimitId") or snapshot.get("rateLimitsByLimitId")
    sources = list(by_id.values()) if isinstance(by_id, dict) and by_id else [snapshot]
    limits = []
    for source in sources:
        if not isinstance(source, dict):
            continue
        windows = []
        for key in ("primary", "secondary"):
            window = source.get(key)
            if not isinstance(window, dict) or window.get("usedPercent") is None:
                continue
            try:
                pct = max(0.0, min(100.0, float(window["usedPercent"])))
            except (TypeError, ValueError):
                continue
            windows.append({"label": label_for(window.get("windowDurationMins"),
                                                source.get("limitName")),
                            "pct": pct, "resets_at": window.get("resetsAt"),
                            "severity": "normal"})
        # a limit reached in this bucket marks this bucket's fullest window, no other's
        reached = source.get("rateLimitReachedType") or source.get("spendControlReached")
        if source is snapshot:
            reached = reached or rate.get("rateLimitReachedType") or rate.get("spendControlReached")
        if reached and windows:
            max(windows, key=lambda item: item["pct"])["severity"] = "critical"
        limits.extend(windows)
    facts = []
    credits = snapshot.get("credits") or rate.get("credits") or {}
    if credits.get("unlimited"):
        facts.append("Unlimited credits")
    elif credits.get("balance") is not None:
        try:
            balance = Decimal(str(credits["balance"]))
            if balance == balance.to_integral_value():
                formatted = "{:,}".format(int(balance))
            else:
                formatted = "{:,.2f}".format(balance)
            facts.append(formatted + " credits left")
        except (InvalidOperation, ValueError):
            pass
    result = {"ok": True, "plan": snapshot.get("planType") or rate.get("planType"),
              "limits": limits, "credits": [], "facts": facts}
    if rate.get("ordinaryUsageAllowed") is not None:
        result["blocked"] = not bool(rate["ordinaryUsageAllowed"])
    return result


def fetch(key: Optional[str], opts: dict) -> dict:
    codex = find_codex()
    if not codex:
        raise Fail("Codex isn't installed")
    return normalize(ask(codex))
