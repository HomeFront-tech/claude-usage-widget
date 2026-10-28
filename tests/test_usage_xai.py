"""Tests for xAI Management API credits."""
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
import usage_xai
from usage_common import Fail


def load_cli():
    loader = importlib.machinery.SourceFileLoader("ai_usage_xai", str(BIN / "ai-usage"))
    spec = importlib.util.spec_from_loader("ai_usage_xai", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(json.dumps(data).encode())


class XaiTest(unittest.TestCase):
    def setUp(self):
        self.balance = {"total": {"val": "-12345"}}
        self.invoice = {"coreInvoice": {"amountAfterVat": {"val": "4000"}}}
        self.limits = {"spendingLimits": {"effectiveSl": {"val": "10000"}}}
        self.errors = {}
        self.requests = []
        self.old_urlopen = usage_common.URLOPEN
        usage_common.URLOPEN = self.urlopen
        self.addCleanup(self.restore)

    def restore(self):
        usage_common.URLOPEN = self.old_urlopen

    def urlopen(self, request, timeout=None):
        self.assertEqual(timeout, 15)
        self.requests.append(request)
        for suffix, data in (("prepaid/balance", self.balance),
                             ("postpaid/invoice/preview", self.invoice),
                             ("postpaid/spending-limits", self.limits)):
            if request.full_url.endswith(suffix):
                if suffix in self.errors:
                    raise urllib.error.HTTPError(request.full_url,
                                                 self.errors[suffix], "error", {}, None)
                return Response(data)
        self.fail("unexpected URL")

    def fetch(self, **opts):
        options = {"team_id": "team-test"}
        options.update(opts)
        return usage_xai.fetch("xai-testkey123", options)

    def test_balance_sign(self):
        self.assertEqual(self.fetch()["facts"][0], "$123.45 credits left")

    def test_spend_against_effective_limit(self):
        self.assertEqual(self.fetch()["credits"], [
            {"label": "This month", "used": 40.0, "limit": 100.0,
             "pct": 40.0, "resets_at": None}])

    def test_before_vat_fallback(self):
        self.invoice = {"coreInvoice": {"amountBeforeVat": {"val": "3500"}}}
        self.assertEqual(self.fetch()["credits"][0]["used"], 35.0)

    def test_budget_when_no_limit(self):
        self.limits = {"spendingLimits": {}}
        self.assertEqual(self.fetch(budget=80)["credits"][0]["limit"], 80)

    def test_spend_fact_without_any_cap(self):
        self.limits = {"spendingLimits": {}}
        got = self.fetch()
        self.assertIn("This month $40.00", got["facts"])
        self.assertEqual(got["credits"], [])

    def test_optional_endpoints_may_fail(self):
        self.errors["postpaid/invoice/preview"] = 404
        got = self.fetch()
        self.assertTrue(got["ok"])
        self.assertEqual(got["facts"], ["$123.45 credits left"])

    def test_auth_errors(self):
        for code in (401, 403):
            with self.subTest(code=code):
                self.errors["prepaid/balance"] = code
                with self.assertRaises(Fail) as raised:
                    self.fetch()
                self.assertEqual(raised.exception.error,
                                 "Needs a Management key, not an API key")

    def test_team_id_required(self):
        for team in (None, "bad id!"):
            with self.subTest(team=team):
                with self.assertRaises(Fail) as raised:
                    self.fetch(team_id=team)
                self.assertEqual(raised.exception.error, "Add your team ID")
        self.assertEqual(self.requests, [])

    def test_cents_shapes(self):
        for value in ({"val": "250"}, "250", 250):
            self.assertEqual(usage_xai.cents(value), 2.5)
        for value in ({}, "x"):
            self.assertIsNone(usage_xai.cents(value))

    def test_through_dispatcher(self):
        output = io.StringIO()
        cli = load_cli()
        with mock.patch.dict(os.environ, {"FAKE_KEYCHAIN": "[]"}), redirect_stdout(output):
            with self.assertRaises(SystemExit) as raised:
                cli.main(["xai", "--team-id", "team-test", "--key-stdin"],
                         io.StringIO("xai-testkey123\n"))
        self.assertEqual(raised.exception.code, 0)
        line = output.getvalue().strip()
        self.assertEqual(json.loads(line)["provider"], "xai")
        self.assertNotIn("xai-testkey123", line)


if __name__ == "__main__":
    unittest.main()
