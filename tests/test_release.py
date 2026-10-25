"""tools/release: the What's New draft is stamped inside the release commit.

Runs the real tools/release in a throwaway clone with a bare origin and a fake gh, so
nothing leaves the machine. Run: /usr/bin/python3 -m unittest tests.test_release -v
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def entry(version, title="A test release"):
    return {
        "version": version, "title": title, "summary": "Short.",
        "hero": {"skin": "classic", "wave": True, "lines": ["Hi!"]},
        "slides": [], "notes": {"new": ["A thing."], "better": [], "fixed": []},
    }


class Release(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.origin, self.work, fake = base / "origin.git", base / "work", base / "bin"
        self.gh_log = base / "gh.log"
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
                        PATH=f"{fake}:{os.environ['PATH']}")
        fake.mkdir()
        gh = fake / "gh"
        gh.write_text(f'#!/bin/sh\necho "$@" >> "{self.gh_log}"\n')
        gh.chmod(0o755)
        self.git("init", "-q", "--bare", str(self.origin), cwd=base)
        self.git("init", "-q", "-b", "main", str(self.work), cwd=base)
        for key, value in (("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false")):
            self.git("config", key, value)
        self.git("remote", "add", "origin", str(self.origin))
        (self.work / "tools").mkdir()
        for tool in ("release", "whatsnew"):
            shutil.copy2(ROOT / "tools" / tool, self.work / "tools" / tool)
        shutil.copytree(ROOT / "skins", self.work / "skins")
        (self.work / "VERSION").write_text("1.6.0\n")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.work, env=getattr(self, "env", None),
                              check=True, capture_output=True, text=True).stdout

    def commit_all(self, releases=None):
        if releases is not None:
            (self.work / "whatsnew").mkdir(exist_ok=True)
            (self.work / "whatsnew" / "releases.json").write_text(json.dumps({"releases": releases}, indent=2) + "\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "start")
        self.git("push", "-q", "origin", "main")
        return self.git("rev-parse", "HEAD").strip()

    def release(self, version, notes="Notes"):
        return subprocess.run(["tools/release", version, notes], cwd=self.work, env=self.env,
                              capture_output=True, text=True)

    def tags(self):
        return self.git("tag", cwd=self.origin).split()

    def test_release_stamps_next_in_release_commit(self):
        self.commit_all([entry("1.6.0"), entry("next")])
        out = self.release("1.7.0")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        shipped = json.loads(self.git("show", "HEAD:whatsnew/releases.json"))
        self.assertEqual([r["version"] for r in shipped["releases"]], ["1.6.0", "1.7.0"])
        self.assertEqual(self.git("show", "HEAD:VERSION").strip(), "1.7.0")
        self.assertEqual(self.git("log", "-1", "--format=%s"), "Release v1.7.0\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("v1.7.0", self.tags())
        self.assertIn("release create v1.7.0 --title v1.7.0 --notes Notes", self.gh_log.read_text())
        self.assertNotIn("no What's New entry", out.stdout)

    def test_fix_only_release_without_next(self):
        self.commit_all([entry("1.6.0")])
        before = (self.work / "whatsnew" / "releases.json").read_bytes()
        out = self.release("1.6.1", "A fix")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertEqual((self.work / "whatsnew" / "releases.json").read_bytes(), before)
        self.assertIn("no What's New entry for v1.6.1", out.stdout)
        self.assertEqual(self.git("show", "HEAD:VERSION").strip(), "1.6.1")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("v1.6.1", self.tags())

    def test_invalid_content_stops_before_writing(self):
        start = self.commit_all([entry("next", title="x" * 41)])
        out = self.release("1.7.0")
        self.assertNotEqual(out.returncode, 0)
        self.assertEqual((self.work / "VERSION").read_text(), "1.6.0\n")
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), start)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.tags(), [])
        self.assertFalse(self.gh_log.exists())

    def test_draft_and_same_version_conflict_stops(self):
        start = self.commit_all([entry("1.7.0"), entry("next")])
        out = self.release("1.7.0")
        self.assertNotEqual(out.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), start)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.tags(), [])

    def test_checkout_without_releases_file_still_releases(self):
        self.commit_all()
        out = self.release("1.6.1")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertEqual(self.git("show", "HEAD:VERSION").strip(), "1.6.1")
        self.assertIn("v1.6.1", self.tags())


if __name__ == "__main__":
    unittest.main()
