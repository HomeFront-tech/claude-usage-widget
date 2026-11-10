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
        self.assertRegex(PAGE, r'addEventListener\("input", \(\) => \{\s*grow\(\);')
        voice = PAGE.split("window.voice = ")[1].split("window.heard = ")[0]
        self.assertIn("grow(true)", voice, "live words keep the newest in view")
        heard = PAGE.split("window.heard = ")[1].split("form.onsubmit")[0]
        self.assertIn("grow(", heard)
        submit = PAGE.split("form.onsubmit = ")[1].split("};")[0]
        self.assertIn("grow()", submit, "the box shrinks back after a send")

    def test_message_types(self):
        sent = set(re.findall(r'post\(\{ type: "([a-z]+)"', PAGE))
        self.assertEqual(sent, {"send", "listen", "stop", "drag", "close", "size", "resize", "draft"})

    def test_resizing_the_panel_measures_the_box_again(self):
        # a wider panel rewraps the box; after an edge drag Hammerspoon sends its new room
        self.assertRegex(PAGE, r'addEventListener\("resize", \(\) => \{ grow\(\);')
        self.assertRegex(PAGE, r'window\.setGrow = \(n\) => \{ INIT\.grow = [^}]*grow\(\); \}')

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


# A stand-in DOM, just enough for chat.html's script: elements remember their listeners, and
# everything the page posts to Hammerspoon lands in posted.
HARNESS = r"""
const posted = [];
function el(id) {
  const e = { id, className: "", textContent: "", innerHTML: "", value: "", placeholder: id === "text" ? "Talk to me…" : "",
    style: {}, dataset: {}, classList: { toggle() {} }, offsetHeight: 20, clientHeight: 18, scrollHeight: 20,
    scrollTop: 0, selectionStart: 0, selectionEnd: 0, listeners: {}, children: [],
    appendChild(c) { this.children.push(c); }, insertBefore(c) { this.children.push(c); },
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    fire(type, ev) { for (const fn of this.listeners[type] || []) fn(ev || {}); },
    focus() {}, setRangeText() {}, getContext() { return { fillRect() {} }; },
    requestSubmit() { this.onsubmit({ preventDefault() {} }); } };
  return e;
}
const els = {};
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.webkit = { messageHandlers: { buddy: { postMessage: (m) => posted.push(m) } } };
globalThis.document = {
  getElementById: (id) => (els[id] = els[id] || el(id)),
  createElement: () => el(""),
  querySelector: () => el("header"),
  querySelectorAll: () => [],
  addEventListener() {},
};
"""

CHECKS = r"""
const box = document.getElementById("text"), badge = document.getElementById("live");
const hints = () => els.log.children.map((c) => c.textContent).join(" | ");
const last = () => posted[posted.length - 1] || {};
const results = {};
// a draft from last time is back in the box, and emptying the box forgets it
results.draftInBox = box.value;
results.draftNote = hints().includes("back in the box");
box.value = ""; box.fire("input");
results.draftCleared = last().type === "draft";
// the live pill shows
window.voice({ state: "live" });
results.livePill = badge.className + "/" + badge.textContent;
// a brain dump: pauses add up, a hold keeps the words, Return sends it all as a dump
window.voice({ state: "listening", text: "okay Buddy brain dump" });
window.voice({ state: "dump", text: "" });
results.dumpPill = badge.className + "/" + badge.textContent;
results.dumpEmpty = box.value;
window.voice({ state: "listening", text: "First the trucks." });
window.voice({ state: "listening", text: "First the trucks. Then the salt" });
results.dumpHint = box.placeholder;
window.voice({ state: "hold" });
results.holdKeeps = box.value + "/" + badge.textContent;
window.voice({ state: "dump", text: "First the trucks. Then the salt." });
els.form.requestSubmit();
results.returnSends = JSON.stringify(last());
results.boxAfter = box.value;
window.voice({ state: "live" });
results.pillAfter = badge.textContent;
// a dump sent by voice is marked
window.voice({ state: "dump", text: "" });
window.voice({ state: "listening", text: "one idea" });
window.voice({ state: "send", text: "one idea", dump: true });
results.voiceSends = JSON.stringify(last());
window.voice({ state: "live" });
// the live chat ends during a dump: the words stay in the box as typed text
window.voice({ state: "dump", text: "" });
window.voice({ state: "listening", text: "unsent thought" });
window.voice({ state: "liveoff" });
results.kept = box.value + "/" + badge.className;
window.voice({ state: "listening", text: "next" });
results.typedStays = box.value;
console.log(JSON.stringify(results));
"""


class PageBehaviour(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node"), "node isn't installed")
    def test_brain_dump_and_draft(self):
        init = json.dumps({"title": "Preview", "history": [], "thinking": False, "dictation": True, "grow": 160,
                           "draft": "an old brain dump"})
        script = PAGE.split("<script>", 1)[1].rsplit("</script>", 1)[0].replace("/*__INIT__*/null", init)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "page.js"
            path.write_text(HARNESS + script + CHECKS + "\nprocess.exit(0);\n", encoding="utf-8")
            out = subprocess.run(["node", str(path)], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        r = json.loads(out.stdout.strip().splitlines()[-1])
        self.assertEqual(r["draftInBox"], "an old brain dump")
        self.assertTrue(r["draftNote"], "the page says the draft is back")
        self.assertTrue(r["draftCleared"], "emptying the box tells Hammerspoon")
        self.assertEqual(r["livePill"], "on live/● Live", "the live pill shows")
        self.assertTrue(r["dumpPill"].startswith("on dump/● Brain dump 0:0"), r["dumpPill"])
        self.assertEqual(r["dumpEmpty"], "", "the wake words leave the box")
        self.assertIn("send it", r["dumpHint"])
        self.assertEqual(r["holdKeeps"], "First the trucks. Then the salt/Paused")
        self.assertEqual(json.loads(r["returnSends"]),
                         {"type": "send", "text": "First the trucks. Then the salt.", "voice": True, "dump": True})
        self.assertEqual(r["boxAfter"], "")
        self.assertEqual(r["pillAfter"], "● Live")
        self.assertEqual(json.loads(r["voiceSends"]), {"type": "send", "text": "one idea", "voice": True, "dump": True})
        self.assertEqual(r["kept"], "unsent thought/", "a dump that ends unsent stays in the box")
        self.assertEqual(r["typedStays"], "unsent thought next", "and later words go after it")


if __name__ == "__main__":
    unittest.main()
