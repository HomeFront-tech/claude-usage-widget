"""bin/buddy-opus: the command Grok runs to borrow Claude Opus through the buddy.

Run: /usr/bin/python3 -m unittest tests.test_buddy_opus -v
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / "bin" / "buddy-opus")
FAKES = ROOT / "tests" / "fakes"
sys.path.insert(0, str(ROOT / "bin"))
import buddy_grok  # noqa: E402


def load_cli():
    loader = importlib.machinery.SourceFileLoader("buddy_opus", CLI)
    spec = importlib.util.spec_from_loader("buddy_opus", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class BuddyOpusTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.state, self.hslog, self.argv = t / "state", t / "hs.log", t / "argv.json"
        self.cfg = {"enabled": True, "cap": 10, "approve_timeout": 600, "owner": "Sam", "deny_read": []}
        self.env = dict(os.environ, BUDDY_STATE_DIR=str(self.state), BUDDY_HS=str(FAKES / "hs"),
                        BUDDY_CLAUDE=str(FAKES / "claude"), FAKE_HS_LOG=str(self.hslog),
                        FAKE_CLAUDE_ARGV=str(self.argv), FAKE_CLAUDE_RESULT="Four.")
        self.set_cfg()

    def tearDown(self):
        self.tmp.cleanup()

    def set_cfg(self, **changes):
        self.cfg.update(changes)
        self.env["FAKE_HS_REPLY"] = json.dumps(self.cfg)

    def run_cli(self, *args):
        return subprocess.run([sys.executable, CLI] + list(args), env=self.env,
                              capture_output=True, text=True, timeout=30)

    def hs_calls(self):
        return self.hslog.read_text().splitlines() if self.hslog.exists() else []

    def claimed(self):
        f = self.state / "opus-runs.jsonl"
        lines = [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []
        return [x for x in lines if x["event"] == "claimed"]

    def test_status_offline(self):
        self.env["BUDDY_HS"] = "/nonexistent/hs"
        p = self.run_cli("status")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(json.loads(p.stdout)["buddy"], "offline")

    def test_status_running(self):
        out = json.loads(self.run_cli("status").stdout)
        self.assertEqual((out["buddy"], out["enabled"], out["cap"], out["left"]), ("running", True, 10, 10))

    def test_ask_refused_when_off(self):
        self.env["FAKE_HS_REPLY"] = ""
        p = self.run_cli("ask", "hello")
        self.assertEqual(p.returncode, 2)
        self.assertIn("Buddy", p.stdout)
        self.assertFalse(self.argv.exists())

    def test_ask_answers(self):
        p = self.run_cli("ask", "what's two plus two?")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "Four.")
        self.assertEqual(len(self.claimed()), 1)
        calls = [c for c in self.hs_calls() if "grokOpus" in c]
        self.assertTrue(calls[0].startswith('ClaudeBuddy.grokOpus("start"'))
        self.assertTrue(calls[-1].startswith('ClaudeBuddy.grokOpus("done"'))

    def test_ask_json(self):
        out = json.loads(self.run_cli("ask", "--json", "hi").stdout)
        self.assertEqual((out["outcome"], out["answer"]), ("answered", "Four."))

    def test_ask_capped(self):
        self.set_cfg(cap=1)
        self.assertEqual(self.run_cli("ask", "one").returncode, 0)
        p = self.run_cli("ask", "two")
        self.assertEqual(p.returncode, 3)
        self.assertIn("cap", p.stdout)
        self.assertTrue(any(c.startswith('ClaudeBuddy.grokOpus("capped"') for c in self.hs_calls()))

    def test_request_passed_verbatim_as_one_arg(self):
        request = '"; rm -rf ~ $(whoami)\n' + "x" * 20000
        self.assertEqual(self.run_cli("ask", request).returncode, 0)
        self.assertEqual(json.loads(self.argv.read_text())[-1], request)
        shown = " ".join(request.split())[:80]
        expected = 'ClaudeBuddy.grokOpus("start", %s)' % buddy_grok.lua_str(shown)
        self.assertIn(expected, self.hs_calls())

    def test_argv_isolation_flags(self):
        argv = load_cli().build_argv("hi", self.cfg)
        i = argv.index("--setting-sources")
        self.assertEqual(argv[i + 1], "")
        for flag in ("--strict-mcp-config", "--no-session-persistence", "-p"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--model") + 1], "claude-opus-5-5")
        self.assertEqual(argv[argv.index("--permission-prompt-tool") + 1], "mcp__buddy__approve")
        self.assertEqual(argv[argv.index("--allowedTools") + 1], "Read,Grep,Glob,WebSearch,WebFetch")
        self.assertNotIn("--bare", argv)
        self.assertEqual(argv[-2:], ["--", "hi"])

    def test_deny_read_from_config(self):
        argv = load_cli().build_argv("hi", dict(self.cfg, deny_read=["~/Private"]))
        rules = argv[argv.index("--disallowedTools") + 1].split(",")
        self.assertIn("Read(~/Private/**)", rules)
        self.assertIn("Read(~/.ssh/**)", rules)
        # name patterns must be absolute ("//"), or they only cover the working folder
        self.assertIn("Read(//**/*secret*)", rules)
        self.assertIn("Read(//**/.env*)", rules)

    def test_async_then_result(self):
        p = self.run_cli("ask", "--async", "long job")
        self.assertEqual(p.returncode, 0)
        run_id = json.loads(p.stdout)["id"]
        deadline = time.time() + 5
        while time.time() < deadline:
            out = json.loads(self.run_cli("result", run_id).stdout)
            if out["status"] == "done":
                break
            time.sleep(0.2)
        self.assertEqual((out["status"], out["answer"]), ("done", "Four."))

    def test_claude_failure_reports_failed(self):
        self.env["FAKE_CLAUDE_RC"] = "1"
        p = self.run_cli("ask", "hi")
        self.assertEqual(p.returncode, 4)
        self.assertTrue(any(c.startswith('ClaudeBuddy.grokOpus("failed"') for c in self.hs_calls()))


if __name__ == "__main__":
    unittest.main()
