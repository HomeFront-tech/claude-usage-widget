"""Tests for Codex usage through its app-server."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
sys.path.insert(0, str(BIN))
import usage_codex
from usage_common import Fail


def window(pct, mins, reset):
    return {"usedPercent": pct, "windowDurationMins": mins, "resetsAt": reset}


class CodexTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        target = Path(self.temp.name) / "codex"
        shutil.copy2(ROOT / "tests" / "fakes" / "codex", target)
        target.chmod(0o755)
        self.dirs = mock.patch.object(usage_codex, "CODEX_DIRS", [self.temp.name])
        self.dirs.start()
        self.addCleanup(self.dirs.stop)
        self.rate = {"rateLimits": {"planType": "pro",
                                    "primary": window(41, 10080, 1900000000),
                                    "secondary": window(12, 300, 1890000000),
                                    "credits": {"hasCredits": True,
                                                "unlimited": False,
                                                "balance": "12000"}}}

    def fake(self, **changes):
        config = {"rate": self.rate}
        config.update(changes)
        return mock.patch.dict(os.environ, {"FAKE_CODEX": json.dumps(config)})

    def test_primary_and_secondary_windows(self):
        with self.fake():
            got = usage_codex.fetch(None, {})
        self.assertEqual(got["plan"], "pro")
        self.assertEqual(got["limits"], [
            {"label": "Week", "pct": 41.0, "resets_at": 1900000000,
             "severity": "normal"},
            {"label": "5-hour", "pct": 12.0, "resets_at": 1890000000,
             "severity": "normal"}])
        self.assertEqual(got["facts"], ["12,000 credits left"])

    def test_null_windows_and_credits(self):
        self.rate = {"rateLimits": {"planType": "pro", "primary": None,
                                    "secondary": None, "credits": None}}
        with self.fake():
            got = usage_codex.fetch(None, {})
        self.assertTrue(got["ok"])
        self.assertEqual(got["limits"], [])
        self.assertEqual(got["facts"], [])

    def test_labels(self):
        cases = [(10080, None, "Week"), (300, None, "5-hour"),
                 (120, None, "2-hour"), (2880, None, "2-day"),
                 (30, None, "30-min"), (None, None, "Limit"),
                 (10080, "GPT-6 Sol", "GPT-6 Sol · Week"),
                 (10080, "codex", "Week")]
        for mins, name, label in cases:
            with self.subTest(mins=mins, name=name):
                self.assertEqual(usage_codex.label_for(mins, name), label)

    def test_by_limit_id_wins(self):
        self.rate["rateLimitsByLimitId"] = {
            "base": {"limitName": "codex", "primary": window(41, 10080, 1900000000)},
            "sol": {"limitName": "GPT-6 Sol", "primary": window(70, 300, 1890000000)}}
        got = usage_codex.normalize(self.rate)
        self.assertEqual([x["label"] for x in got["limits"]],
                         ["Week", "GPT-6 Sol · 5-hour"])
        self.assertEqual(len(got["limits"]), 2)

    def test_reached_marks_fullest_window_critical(self):
        self.rate["rateLimits"]["rateLimitReachedType"] = "rate_limit_reached"
        self.rate["rateLimits"]["primary"]["usedPercent"] = 100
        self.rate["rateLimits"]["secondary"]["usedPercent"] = 30
        got = usage_codex.normalize(self.rate)
        self.assertEqual([x["severity"] for x in got["limits"]],
                         ["critical", "normal"])
        self.rate["rateLimits"]["rateLimitReachedType"] = None
        self.rate["rateLimits"]["spendControlReached"] = True
        self.rate["rateLimits"]["primary"]["usedPercent"] = 60
        got = usage_codex.normalize(self.rate)
        self.assertEqual([x["severity"] for x in got["limits"]],
                         ["critical", "normal"])

    def test_reached_stays_in_its_own_bucket(self):
        # a limit reached in one bucket marks that bucket's window, not another bucket's fuller one
        self.rate["rateLimitsByLimitId"] = {
            "a": {"limitName": "A", "rateLimitReachedType": "rate_limit_reached",
                  "primary": window(60, 10080, 1900000000)},
            "b": {"limitName": "B", "primary": window(62, 10080, 1900000000)}}
        got = usage_codex.normalize(self.rate)
        self.assertEqual({x["label"]: x["severity"] for x in got["limits"]},
                         {"A · Week": "critical", "B · Week": "normal"})

    def test_blocked(self):
        self.rate["ordinaryUsageAllowed"] = False
        self.assertIs(usage_codex.normalize(self.rate)["blocked"], True)
        self.rate["ordinaryUsageAllowed"] = None
        self.assertNotIn("blocked", usage_codex.normalize(self.rate))
        del self.rate["ordinaryUsageAllowed"]
        self.assertNotIn("blocked", usage_codex.normalize(self.rate))

    def test_unlimited_credits(self):
        self.rate["rateLimits"]["credits"] = {"unlimited": True}
        self.assertEqual(usage_codex.normalize(self.rate)["facts"],
                         ["Unlimited credits"])

    def test_signed_out(self):
        with self.fake(error={"code": -32000, "message": "not logged in"}):
            with self.assertRaises(Fail) as raised:
                usage_codex.fetch(None, {})
        self.assertEqual(raised.exception.error, "Signed out · open Codex")
        with self.fake(error={"code": -32000, "message": "some other error"}):
            with self.assertRaises(Fail) as raised:
                usage_codex.fetch(None, {})
        self.assertEqual(raised.exception.error, "Codex didn't answer")

    def test_hang_times_out(self):
        start = time.monotonic()
        pid_file = Path(self.temp.name) / "pid"
        with self.fake(hang=True, pid_file=str(pid_file)):
            with self.assertRaises(Fail) as raised:
                usage_codex.ask(usage_codex.find_codex(), timeout=1)
        self.assertEqual(raised.exception.error, "Codex didn't answer")
        self.assertLess(time.monotonic() - start, 3)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)

    def test_skips_noise_and_notifications(self):
        with self.fake(noise=True):
            self.assertEqual(usage_codex.ask(usage_codex.find_codex()), self.rate)

    def test_finds_codex_without_PATH(self):
        with mock.patch.dict(os.environ, {"PATH": "/usr/bin:/bin"}):
            self.assertEqual(usage_codex.find_codex(),
                             str(Path(self.temp.name) / "codex"))
        with mock.patch.object(usage_codex, "CODEX_DIRS", []):
            with self.assertRaises(Fail) as raised:
                usage_codex.fetch(None, {})
        self.assertEqual(raised.exception.error, "Codex isn't installed")

    def test_runs_app_server(self):
        argv_file = str(Path(self.temp.name) / "argv")
        with self.fake(argv_file=argv_file):
            usage_codex.fetch(None, {})
        self.assertEqual(Path(argv_file).read_text(), "app-server")

    def test_never_reads_codex_auth(self):
        self.assertNotIn("auth.json", (BIN / "usage_codex.py").read_text())


if __name__ == "__main__":
    unittest.main()
