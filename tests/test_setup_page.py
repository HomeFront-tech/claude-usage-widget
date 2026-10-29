"""setup.html: steps found by name, the AI steps' messages, no keys in what the page saves,
and a script that parses.

Run: /usr/bin/python3 -m unittest tests.test_setup_page -v
"""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = (ROOT / "setup.html").read_text(encoding="utf-8")
SCRIPT = PAGE.rsplit("<script>", 1)[1].rsplit("</script>", 1)[0]


def body(name):
    """The source of a top-level `function name(...) { ... }` in the page script."""
    start = SCRIPT.index("function " + name + "(")
    depth, i = 0, SCRIPT.index("{", start)
    while True:
        depth += {"{": 1, "}": -1}.get(SCRIPT[i], 0)
        if depth == 0:
            return SCRIPT[start:i + 1]
        i += 1


class Page(unittest.TestCase):
    def test_steps_found_by_name(self):
        for name in ("checks", "ais", "card"):
            self.assertIn('data-step="%s"' % name, PAGE)
        self.assertNotIn("step === 1", PAGE)

    def test_message_types(self):
        sent = set(re.findall(r'post\(\{ type: "([A-Za-z]+)"', PAGE))
        self.assertTrue({"providerCheck", "keyRemove", "keyStatus"} <= sent, sent)

    def test_no_innerHTML(self):
        self.assertNotIn("innerHTML", PAGE)

    def test_collect_sends_every_voice_switch(self):
        """The wizard saves the bubble-lines switch too (v1.13.0: a missing key reset it from the slider)."""
        block = PAGE[PAGE.index("voice: { listen: state.voice.listen"):]
        block = block[:block.index("phrase:")]
        for key in ("listen", "answers", "bubbles", "outLoud"):
            self.assertIn("%s: state.voice.%s" % (key, key), block)
        self.assertIn("state.voice.voice", block)

    def test_keys_not_in_collect(self):
        for name in ("collect", "collectUsage"):
            self.assertNotRegex(body(name), r"\bkey\b", name)

    @unittest.skipUnless(shutil.which("node"), "node isn't installed")
    def test_script_parses(self):
        init = json.dumps({"firstRun": False, "name": "", "usage": {
            "order": ["claude", "codex"], "warn_at": 70, "hot_at": 90, "alert_red": False,
            "providers": {"claude": {"refresh": 300, "hide": []}},
            "known": [{"id": "claude", "name": "Claude", "kind": "login", "refresh": 300,
                       "min_refresh": 300, "choices": [300, 600], "fields": []}]}})
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "page.js"
            path.write_text(SCRIPT.replace("/*__INIT__*/null", init), encoding="utf-8")
            out = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)


if __name__ == "__main__":
    unittest.main()
