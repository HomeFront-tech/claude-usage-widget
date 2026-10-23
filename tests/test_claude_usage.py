"""bin/claude-usage: finding Claude Code's login in the Keychain.

Run: /usr/bin/python3 -m unittest tests.test_claude_usage -v
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import pwd
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / "bin" / "claude-usage")
FAKES = ROOT / "tests" / "fakes"
SERVICE = "Claude Code-credentials"
# What turned up on a real Mac: a second item with Claude Code's service name, filed
# under account "unknown", listed ahead of Claude Code's own and holding no login.
STRAY = {"acct": "unknown", "svce": SERVICE, "secret": json.dumps({"mcpOAuth": {}})}


def login(acct, tok):
    secret = json.dumps({"claudeAiOauth": {"accessToken": tok, "subscriptionType": "max"}})
    return {"acct": acct, "svce": SERVICE, "secret": secret}


def load_cli():
    loader = importlib.machinery.SourceFileLoader("claude_usage", CLI)
    spec = importlib.util.spec_from_loader("claude_usage", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TokenTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()  # HOME without a credentials file
        self.cli = load_cli()
        self.cli.SECURITY = str(FAKES / "security")

    def tearDown(self):
        self.tmp.cleanup()

    def token(self, keychain, call="token", **env):
        env = dict(env, HOME=self.tmp.name, FAKE_KEYCHAIN=json.dumps(keychain))
        clear = "USER" not in env
        with mock.patch.dict(os.environ, env, clear=False):
            if clear:
                os.environ.pop("USER", None)
            buf = io.StringIO()
            try:
                with redirect_stdout(buf):
                    return getattr(self.cli, call)()
            except SystemExit:
                return json.loads(buf.getvalue())

    def test_reads_claude_codes_own_item_past_a_stray_one(self):
        got = self.token([STRAY, login("sam", "tok-sam")], USER="sam")
        self.assertEqual(got, ("tok-sam", "max"))

    def test_without_USER_uses_the_login_name(self):
        me = pwd.getpwuid(os.getuid()).pw_name
        self.assertEqual(self.token([STRAY, login(me, "tok-me")]), ("tok-me", "max"))

    def test_unusual_USER_uses_claude_codes_fallback_account(self):
        got = self.token([STRAY, login("claude-code-user", "tok-cc")], USER="sam smith")
        self.assertEqual(got, ("tok-cc", "max"))

    def test_falls_back_to_any_item_for_the_service(self):
        got = self.token([login("someone-else", "tok-other")], USER="sam")
        self.assertEqual(got, ("tok-other", "max"))

    def test_no_login_anywhere(self):  # main() stops before the network when there's no token
        got = self.token([STRAY], call="main", USER="sam")
        self.assertEqual((got["ok"], got["error"]), (False, "No Claude Code login found"))


if __name__ == "__main__":
    unittest.main()
