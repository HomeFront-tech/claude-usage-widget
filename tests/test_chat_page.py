"""chat.html: a box that wraps and grows, Enter still sends, the messages the page sends,
nothing loaded from outside, and a script that parses.

Run: /usr/bin/python3 -m unittest tests.test_chat_page -v
"""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = (ROOT / "chat.html").read_text(encoding="utf-8")


class Page(unittest.TestCase):
    def test_placeholders_present(self):
        self.assertEqual(PAGE.count("/*__INIT__*/null"), 1)
        self.assertEqual(PAGE.count("/*__THEME__*/"), 1)

    def test_box_wraps(self):
        # a textarea wraps; the old one-line input didn't
        self.assertRegex(PAGE, r'<textarea id="text"[^>]*rows="1"')
        self.assertNotIn('<input id="text"', PAGE)
        self.assertIn("resize: none", PAGE)

    def test_enter_sends_and_shift_enter_breaks_the_line(self):
        self.assertRegex(PAGE, r'e\.key === "Enter" && !e\.shiftKey')
        self.assertIn("form.requestSubmit()", PAGE)

    def test_grow_follows_every_way_words_arrive(self):
        # typed, dictated live (window.voice), hold-space (window.heard) and after a send
        self.assertRegex(PAGE, r'addEventListener\("input", \(\) => grow\(\)\)')
        voice = PAGE.split("window.voice = ")[1].split("window.heard = ")[0]
        self.assertIn("grow(true)", voice, "live words keep the newest in view")
        heard = PAGE.split("window.heard = ")[1].split("form.onsubmit")[0]
        self.assertIn("grow(", heard)
        submit = PAGE.split("form.onsubmit = ")[1].split("};")[0]
        self.assertIn("grow()", submit, "the box shrinks back after a send")

    def test_message_types(self):
        sent = set(re.findall(r'post\(\{ type: "([a-z]+)"', PAGE))
        self.assertEqual(sent, {"send", "listen", "stop", "drag", "close", "size"})

    def test_no_outside_resources(self):
        self.assertNotRegex(PAGE, r'<(script|link|img)[^>]+(src|href)=["\']?https?:')
        self.assertNotIn("fetch(", PAGE)
        self.assertNotIn("XMLHttpRequest", PAGE)

    @unittest.skipUnless(shutil.which("node"), "node isn't installed")
    def test_script_parses(self):
        init = json.dumps({"title": "Preview", "history": [], "thinking": False, "dictation": True, "grow": 160})
        script = PAGE.split("<script>", 1)[1].rsplit("</script>", 1)[0].replace("/*__INIT__*/null", init)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "page.js"
            path.write_text(script, encoding="utf-8")
            out = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)


if __name__ == "__main__":
    unittest.main()
