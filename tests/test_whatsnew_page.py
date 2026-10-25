"""whatsnew.html and buddy_draw.js: the placeholders whatsnew.lua fills, the messages the
page sends, nothing loaded from outside, and scripts that parse.

Run: /usr/bin/python3 -m unittest tests.test_whatsnew_page -v
"""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = (ROOT / "whatsnew.html").read_text(encoding="utf-8")
DRAW = (ROOT / "buddy_draw.js").read_text(encoding="utf-8")


class Page(unittest.TestCase):
    def test_placeholders_present(self):
        self.assertEqual(PAGE.count("/*__INIT__*/null"), 1)
        self.assertEqual(PAGE.count("/*__BUDDY_DRAW__*/"), 1)

    def test_message_types(self):
        sent = set(re.findall(r'post\("([a-z]+)"', PAGE))
        self.assertEqual(sent, {"wear", "rate", "send", "copy", "share", "open", "close"})

    def test_no_outside_resources(self):
        self.assertNotRegex(PAGE, r'<(script|link|img)[^>]+(src|href)=["\']?https?:')
        self.assertNotIn("fetch(", PAGE)
        self.assertNotIn("XMLHttpRequest", PAGE)

    def test_page_text_is_never_html(self):
        # every bit of release text goes in through textContent
        self.assertNotIn("innerHTML", PAGE)
        self.assertNotIn("innerHTML", DRAW)

    @unittest.skipUnless(shutil.which("node"), "node isn't installed")
    def test_scripts_parse(self):
        init = json.dumps({"releases": [], "skins": {}, "images": {}, "wearable": {}, "mode": "email",
                           "repoURL": "https://github.com/x/y", "version": "1.7.0"})
        script = PAGE.split("<script>/*__BUDDY_DRAW__*/</script>")[1]
        script = script.split("<script>", 1)[1].rsplit("</script>", 1)[0].replace("/*__INIT__*/null", init)
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in (("draw.js", DRAW), ("page.js", script)):
                path = Path(tmp) / name
                path.write_text(text, encoding="utf-8")
                out = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
                self.assertEqual(out.returncode, 0, name + ": " + out.stderr)


if __name__ == "__main__":
    unittest.main()
