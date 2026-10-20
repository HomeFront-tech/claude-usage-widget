"""Shared isolation settings for Buddy's Claude CLI runs."""
import os
import shutil
from pathlib import Path
from typing import List

CLAUDE: str = os.path.expanduser(os.environ.get("BUDDY_CLAUDE") or "~/.local/bin/claude")
CHILD_PATH: str = os.path.expanduser("~/.local/bin") + ":/opt/homebrew/bin:/usr/bin:/bin"


def base_argv(model: str) -> List[str]:
    return [CLAUDE, "-p", "--model", model, "--setting-sources", "",
            "--strict-mcp-config", "--no-session-persistence"]


def work_dir(root: Path) -> Path:
    work = root / "work"
    work.mkdir(parents=True, exist_ok=True)
    for name in ("CLAUDE.md", ".claude"):
        path = work / name
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()
    return work
