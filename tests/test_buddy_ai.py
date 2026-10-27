"""buddy_ai: finds AI tools by app/command names and file dates only."""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bin"))
import buddy_ai as ai


class BuddyAiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.saved = (ai.HOME, ai.APP_DIRS, ai.BIN_DIRS)
        ai.HOME, ai.APP_DIRS, ai.BIN_DIRS = self.home, [self.home / "Applications"], [self.home / ".local/bin"]
        self.addCleanup(lambda: setattr(ai, "HOME", self.saved[0]))
        self.addCleanup(lambda: setattr(ai, "APP_DIRS", self.saved[1]))
        self.addCleanup(lambda: setattr(ai, "BIN_DIRS", self.saved[2]))
        self.addCleanup(self.tmp.cleanup)

    def test_nothing_installed(self):
        self.assertEqual(ai.detect(running=set()), [])
        self.assertEqual(ai.describe([]), "No AI tools found on this Mac.")

    def test_finds_app_command_and_running(self):
        (self.home / "Applications/Cursor.app").mkdir(parents=True)
        cmd = self.home / ".local/bin/codex"
        cmd.parent.mkdir(parents=True)
        cmd.write_text("#!/bin/sh\n")
        cmd.chmod(0o755)
        found = {i["id"]: i for i in ai.detect(running={"Cursor"})}
        self.assertTrue(found["cursor"]["running"])
        self.assertEqual(found["cursor"]["app"], "Cursor.app")
        self.assertEqual(found["codex"]["command"], "codex")
        self.assertFalse(found["codex"]["running"])

    def test_running_without_install_still_listed(self):
        self.assertEqual([i["id"] for i in ai.detect(running={"ollama"})], ["ollama"])

    def test_activity_uses_dates_not_contents_and_skips_secrets(self):
        sessions = self.home / ".codex/sessions/2026/10"
        sessions.mkdir(parents=True)
        (sessions / "rollout-a.jsonl").write_text("SECRET CHAT TEXT")
        old = self.home / ".codex/sessions/auth.json"
        old.write_text("token")
        os.utime(old, (time.time() + 500, time.time() + 500))  # newer, but must be ignored
        newest, today = ai._newest(".codex/sessions")
        self.assertEqual(today, 1)
        self.assertLess(abs(newest - time.time()), 10)

    def test_never_reads_file_contents(self):
        sessions = self.home / ".cursor/projects"
        sessions.mkdir(parents=True)
        (sessions / "chat.txt").write_text("private")
        real_open = open
        def guard(*a, **k):
            raise AssertionError("opened a file")
        import builtins
        builtins.open = guard
        try:
            ai._newest(".cursor/projects")
        finally:
            builtins.open = real_open

    def test_secret_words(self):
        for name in ("auth.json", "credentials", "api_token", "cookies.sqlite", "id.pem", "keychain-db"):
            self.assertTrue(ai.is_secret(name), name)
        self.assertFalse(ai.is_secret("rollout-2026.jsonl"))

    def test_describe_wording(self):
        text = ai.describe([{"name": "Codex", "app": None, "command": "codex", "running": True,
                             "last_used": 120, "active_now": True}])
        self.assertIn("Codex: command-line tool, open now", text)
        self.assertIn("2 minutes ago", text)
        self.assertIn("busy right now", text)


if __name__ == "__main__":
    unittest.main()
