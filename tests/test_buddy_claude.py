"""Shared isolation for Buddy's Claude CLI runs.

Run: /usr/bin/python3 -m unittest tests.test_buddy_claude -v
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / "bin" / "buddy-opus")
sys.path.insert(0, str(ROOT / "bin"))
import buddy_claude  # noqa: E402


def load_cli():
    loader = importlib.machinery.SourceFileLoader("buddy_opus", CLI)
    spec = importlib.util.spec_from_loader("buddy_opus", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class BuddyClaudeTest(unittest.TestCase):
    def test_base_argv_isolation(self):
        argv = buddy_claude.base_argv("example-model")
        self.assertEqual(argv[3], "example-model")
        self.assertEqual(argv[argv.index("--setting-sources") + 1], "")
        self.assertIn("--strict-mcp-config", argv)
        self.assertIn("--no-session-persistence", argv)
        self.assertNotIn("--bare", argv)

    def test_work_dir_is_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / "work"
            work.mkdir()
            (work / "CLAUDE.md").write_text("project instructions")
            (work / ".claude").mkdir()
            (work / ".claude" / "settings.json").write_text("{}")
            self.assertEqual(buddy_claude.work_dir(root), work)
            self.assertFalse((work / "CLAUDE.md").exists())
            self.assertFalse((work / ".claude").exists())

    def test_buddy_opus_uses_base_argv(self):
        argv = load_cli().build_argv("x", {})
        self.assertEqual(argv[:8], buddy_claude.base_argv("claude-opus-5-5"))

    def test_fake_claude_saves_stdin_when_requested(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved = Path(tmp) / "stdin.txt"
            env = dict(os.environ, FAKE_CLAUDE_STDIN=str(saved))
            result = subprocess.run([sys.executable, str(ROOT / "tests" / "fakes" / "claude")],
                                    input="request body\n", text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(saved.read_text(), "request body\n")


if __name__ == "__main__":
    unittest.main()
