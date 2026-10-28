"""Shared helpers for AI usage fetchers."""
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from typing import Dict, Optional

SECURITY = "/usr/bin/security"
URLOPEN = urllib.request.urlopen


class Fail(Exception):
    def __init__(self, error: str, retry_after: Optional[int] = None):
        super().__init__(error)
        self.error = error
        self.retry_after = retry_after


def account() -> str:
    """The Keychain account, worked out the way telegram.lua does it."""
    name = os.environ.get("USER") or ""
    return name if re.fullmatch(r"[A-Za-z0-9._-]+", name) else "buddy"


def keychain_key(provider: str) -> Optional[str]:
    try:
        result = subprocess.run(
            [SECURITY, "find-generic-password", "-s", "claude-buddy-" + provider,
             "-a", account(), "-w"], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return result.stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def get_json(url: str, headers: dict, errors: Dict[int, str]) -> dict:
    request = urllib.request.Request(url, headers=headers)
    try:
        with URLOPEN(request, timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            try:
                wait = int(exc.headers.get("Retry-After") or 600)
            except (ValueError, TypeError):
                wait = 600
            raise Fail("Busy · showing last numbers", retry_after=wait)
        raise Fail(errors.get(exc.code, "HTTP %d" % exc.code))
    except (urllib.error.URLError, TimeoutError, OSError):
        raise Fail("Offline")
    except (ValueError, UnicodeError):
        raise Fail("Unexpected answer")


def money(x) -> str:
    return "${:,.2f}".format(x)
