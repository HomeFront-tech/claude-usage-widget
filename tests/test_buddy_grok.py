"""bin/buddy_grok.py: the bridge to the running buddy, the daily Opus cap and the run log.

Run: /usr/bin/python3 -m unittest tests.test_buddy_grok -v
"""
import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAKE_HS = str(ROOT / "tests" / "fakes" / "hs")
sys.path.insert(0, str(ROOT / "bin"))


class BuddyGrokTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state"
        self.log = Path(self.tmp.name) / "hs.log"
        self.env = {"BUDDY_STATE_DIR": str(self.state), "BUDDY_HS": FAKE_HS,
                    "FAKE_HS_LOG": str(self.log), "FAKE_HS_REPLY": ""}
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        import buddy_grok
        self.bg = importlib.reload(buddy_grok)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def test_config_none_when_buddy_offline(self):
        os.environ["BUDDY_HS"] = "/nonexistent/hs"
        bg = importlib.reload(self.bg)
        self.assertIsNone(bg.buddy_config())

    def test_config_parsed(self):
        os.environ["FAKE_HS_REPLY"] = json.dumps(
            {"enabled": True, "cap": 10, "approve_timeout": 600, "owner": "Sam", "deny_read": []})
        self.assertEqual(self.bg.buddy_config()["cap"], 10)

    def test_config_none_when_feature_off(self):
        os.environ["FAKE_HS_REPLY"] = ""
        self.assertIsNone(self.bg.buddy_config())

    def test_claim_until_cap(self):
        first, second, third = (self.bg.claim_run(2) for _ in range(3))
        self.assertTrue(first and second)
        self.assertNotEqual(first, second)
        self.assertIsNone(third)
        self.assertEqual(self.bg.runs_today(), 2)

    def test_runs_from_yesterday_not_counted(self):
        self.state.mkdir(parents=True)
        yesterday = (datetime.now() - timedelta(days=1)).isoformat(timespec="seconds")
        (self.state / "opus-runs.jsonl").write_text(
            json.dumps({"id": "old", "at": yesterday, "event": "claimed"}) + "\n")
        self.assertEqual(self.bg.runs_today(), 0)
        self.assertIsNotNone(self.bg.claim_run(1))

    def test_cap_is_atomic_under_concurrency(self):
        code = "import buddy_grok, sys; r = buddy_grok.claim_run(1); print(r or '')"
        env = dict(os.environ, PYTHONPATH=str(ROOT / "bin"))
        procs = [subprocess.Popen([sys.executable, "-c", code], env=env, stdout=subprocess.PIPE, text=True)
                 for _ in range(8)]
        ids = [p.communicate()[0].strip() for p in procs]
        self.assertEqual(len([i for i in ids if i]), 1)
        self.assertEqual(self.bg.runs_today(), 1)

    def test_notify_encodes_quotes(self):
        self.bg.notify("start", 'say "hi"\nthere\x01')
        logged = self.log.read_text().strip()
        self.assertEqual(logged, 'ClaudeBuddy.grokOpus("start", "say \\"hi\\"\\nthere\\001")')

    def test_log_run_appends_finished_line(self):
        run = self.bg.claim_run(5)
        self.bg.log_run(run, outcome="answered", seconds=3)
        lines = [json.loads(x) for x in (self.state / "opus-runs.jsonl").read_text().splitlines()]
        self.assertEqual(lines[-1]["event"], "finished")
        self.assertEqual(lines[-1]["outcome"], "answered")
        self.assertEqual(self.bg.runs_today(), 1)


if __name__ == "__main__":
    unittest.main()
