"""Tests for the AI usage dispatcher and OpenRouter fetcher."""
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
sys.path.insert(0, str(BIN))
import usage_common
import usage_openrouter


def load_cli():
    loader = importlib.machinery.SourceFileLoader("ai_usage", str(BIN / "ai-usage"))
    spec = importlib.util.spec_from_loader("ai_usage", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(json.dumps(data).encode())


class AiUsageTest(unittest.TestCase):
    def setUp(self):
        self.cli = load_cli()
        self.requests = []
        self.data = {"data": {"limit": 50, "limit_remaining": 31.6,
                              "limit_reset": "monthly", "usage_monthly": 18.4,
                              "usage_daily": 1.12}}
        self.failure = None
        self.old_security = usage_common.SECURITY
        self.old_urlopen = usage_common.URLOPEN
        usage_common.SECURITY = str(ROOT / "tests" / "fakes" / "security")
        usage_common.URLOPEN = self.urlopen
        self.addCleanup(self.restore)

    def restore(self):
        usage_common.SECURITY = self.old_security
        usage_common.URLOPEN = self.old_urlopen

    def urlopen(self, request, timeout=None):
        self.requests.append(request)
        self.assertEqual(timeout, 15)
        if self.failure:
            raise self.failure
        return Response(self.data)

    def run_cli(self, args=None, keychain=None, stdin="sk-or-v1-testkey123\n"):
        args = ["openrouter", "--key-stdin"] if args is None else args
        env = {"USER": "test-user", "FAKE_KEYCHAIN": json.dumps(keychain or [])}
        output = io.StringIO()
        with mock.patch.dict(os.environ, env), redirect_stdout(output):
            with self.assertRaises(SystemExit) as exited:
                self.cli.main(args, io.StringIO(stdin))
        self.assertEqual(exited.exception.code, 0)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        return json.loads(lines[0]), lines[0]

    def test_cap_bar_uses_limit_minus_remaining(self):
        got, _ = self.run_cli()
        self.assertTrue(got["ok"])
        self.assertEqual(got["provider"], "openrouter")
        self.assertEqual(got["limits"], [])
        self.assertEqual(got["facts"], [])
        self.assertEqual(len(got["credits"]), 1)
        credit = got["credits"][0]
        self.assertEqual({k: v for k, v in credit.items() if k != "pct"},
                         {"label": "This month", "used": 18.4, "limit": 50,
                          "resets_at": None})
        self.assertAlmostEqual(credit["pct"], 36.8)

    def test_cap_labels(self):
        for period, label in (("daily", "Today"), ("weekly", "This week"),
                              (None, "Spending cap")):
            with self.subTest(period=period):
                self.data["data"]["limit_reset"] = period
                got, _ = self.run_cli()
                self.assertEqual(got["credits"][0]["label"], label)

    def test_budget_without_cap(self):
        self.data = {"data": {"limit": None, "usage_monthly": 12.5}}
        got, _ = self.run_cli(["openrouter", "--key-stdin", "--budget", "50"])
        self.assertEqual(got["credits"], [{"label": "This month", "used": 12.5,
                                           "limit": 50, "pct": 25.0,
                                           "resets_at": None}])

    def test_facts_only_without_cap_or_budget(self):
        self.data["data"]["limit"] = None
        got, _ = self.run_cli()
        self.assertEqual(got["facts"], ["Today $1.12 · Month $18.40"])
        self.assertEqual(got["credits"], [])

    def test_free_tier_fact(self):
        self.data["data"]["is_free_tier"] = True
        got, _ = self.run_cli()
        self.assertEqual(got["facts"], ["Free tier"])

    def test_error_mapping(self):
        for code, expected in ((401, "Key not accepted"),
                               (402, "Out of credits or over the key's cap"),
                               (500, "HTTP 500"),
                               (429, "Busy · showing last numbers")):
            with self.subTest(code=code):
                self.failure = urllib.error.HTTPError(
                    usage_openrouter.URL, code, "error",
                    {"Retry-After": "120"} if code == 429 else {}, None)
                got, _ = self.run_cli()
                self.assertFalse(got["ok"])
                self.assertEqual(got["provider"], "openrouter")
                self.assertEqual(got["error"], expected)
                if code == 429:
                    self.assertEqual(got["retry_after"], 120)
        self.failure = urllib.error.URLError("offline")
        got, _ = self.run_cli()
        self.assertEqual(got["error"], "Offline")

    def test_key_from_stdin_is_trimmed(self):
        with mock.patch.object(self.cli, "keychain_key",
                               side_effect=AssertionError("keychain was called")):
            got, _ = self.run_cli(stdin="  sk-or-v1-testkey123\n")
        self.assertTrue(got["ok"])
        self.assertEqual(self.requests[0].get_header("Authorization"),
                         "Bearer sk-or-v1-testkey123")

    def test_key_from_keychain(self):
        entries = [{"acct": "test-user", "svce": "claude-buddy-openrouter",
                    "secret": "sk-or-v1-testkey123"}]
        got, _ = self.run_cli(["openrouter"], keychain=entries)
        self.assertTrue(got["ok"])
        self.assertEqual(self.requests[0].get_header("Authorization"),
                         "Bearer sk-or-v1-testkey123")

    def test_key_never_printed(self):
        for failure in (None, urllib.error.HTTPError(usage_openrouter.URL, 401,
                                                     "error", {}, None),
                        urllib.error.URLError("offline")):
            self.failure = failure
            _, line = self.run_cli()
            self.assertNotIn("sk-or-v1-testkey123", line)

    def test_no_key(self):
        got, _ = self.run_cli(["openrouter"])
        self.assertEqual({k: got[k] for k in ("ok", "error")},
                         {"ok": False, "error": "No key saved"})

    def test_account_matches_telegram(self):
        # telegram.lua files its token under $USER when it's plain, else "buddy"; keys match
        with mock.patch.dict(os.environ, {"USER": "sam"}):
            self.assertEqual(usage_common.account(), "sam")
        with mock.patch.dict(os.environ, {"USER": "sam smith"}):
            self.assertEqual(usage_common.account(), "buddy")
        with mock.patch.dict(os.environ, {}):
            os.environ.pop("USER", None)
            self.assertEqual(usage_common.account(), "buddy")

    def test_unknown_provider(self):
        got, _ = self.run_cli(["nope"])
        self.assertEqual(got["error"], "Unknown provider")


if __name__ == "__main__":
    unittest.main()
