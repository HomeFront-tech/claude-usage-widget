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
        self.assertEqual(sent, {"send", "listen", "stop", "drag", "close", "size", "resize", "draft", "ready"})

    def test_resizing_the_panel_measures_the_box_again(self):
        # a wider panel rewraps the box; after an edge drag Hammerspoon sends its new room
        self.assertRegex(PAGE, r'addEventListener\("resize", \(\) => \{ grow\(\);')
        self.assertRegex(PAGE, r'window\.setGrow = \(n, base\) => \{ INIT\.grow = [^}]*INIT\.base = [^}]*grow\(\); \}')

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
globalThis.innerHeight = 400;
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
results.ready = posted.some((m) => m.type === "ready");
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
    def test_bubble_lines_are_asides_and_the_session_card_folds_its_brief(self):
        init = json.dumps({"title": "Preview", "history": [], "thinking": False, "dictation": True, "grow": 160})
        script = PAGE.split("<script>", 1)[1].rsplit("</script>", 1)[0].replace("/*__INIT__*/null", init)
        # createElement keeps its tag, and append() keeps what it was given, in order
        dom = HARNESS.replace('createElement: () => el(""),', 'createElement: (tag) => Object.assign(el(""), '
                              '{ tag, parts: [], append(...p) { this.parts.push(...p); } }),')
        self.assertNotEqual(dom, HARNESS)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "page.js"
            path.write_text(dom + script + MESSAGE_CHECKS + "\nprocess.exit(0);\n", encoding="utf-8")
            out = subprocess.run(["node", str(path)], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        r = json.loads(out.stdout.strip().splitlines()[-1])
        self.assertEqual(r["aside"], "aside", "a bubble line is not a message bubble")
        self.assertEqual(r["answer"], "msg assistant/A real answer.")
        self.assertEqual(r["card"], "Start a Claude Code session for this?"
                         "|Fix it, in ~/dev, on Fable 5.2 at medium effort[]"
                         "|[What I'll tell it[]|Line one of the brief.\n\nLine two: with a colon.[]]"
                         "|Reply yes or no.")
        self.assertEqual(r["where"], "where")
        self.assertEqual(r["fold"], "details", "the brief is folded, one click away")
        self.assertTrue(r["ended"].startswith("That session has ended, so I couldn't pass it on.\n\n"
                                              "Start a Claude Code session for this?|Fix it, in ~[]|"), r["ended"])
        self.assertEqual(r["send"], "Send this to Fix it?\n\nGo ahead.\n\nReply yes or no.", "a message to pass on shows whole")
        self.assertEqual(r["sendParts"], 0)

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
        self.assertTrue(r["ready"], "the page says when it has loaded")
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


# Which lines look like what: his bubble lines are small asides, and the yes/no card for a
# new session folds its brief away under what and where.
MESSAGE_CHECKS = r"""
const shown = () => els.log.children.filter((c) => c.className !== "hint" && c.className !== "dots");
const flat = (e) => (e.parts || []).map((p) => typeof p === "string" ? p : p.textContent + "[" + flat(p) + "]").join("|");
window.add({ role: "assistant", content: "Fixing things!", said: true });
window.add({ role: "assistant", content: "A real answer." });
const brief = "Line one of the brief.\n\nLine two: with a colon.";
window.add({ role: "assistant", content: "Start a Claude Code session for this?\n\nFix it, in ~/dev, on Fable 5.2 at medium effort:\n" + brief + "\n\nReply yes or no." });
window.add({ role: "assistant", content: "That session has ended, so I couldn't pass it on.\n\nStart a Claude Code session for this?\n\nFix it, in ~:\nDo it.\n\nReply yes or no." });
window.add({ role: "assistant", content: "Send this to Fix it?\n\nGo ahead.\n\nReply yes or no." });
const m = shown();
console.log(JSON.stringify({ aside: m[0].className, answer: m[1].className + "/" + m[1].textContent,
  card: flat(m[2]), where: m[2].parts[1].className, fold: m[2].parts[2].tag,
  ended: flat(m[3]), send: m[4].textContent, sendParts: (m[4].parts || []).length }));
"""


# A stand-in layout, just enough for grow(): the box is 20 px a line at 50 characters, plus 16
# px of padding and 2 of border; the conversation gets the window's height less AROUND (header,
# form padding, panel edges) and the box. Hammerspoon's "size" grows the window, up to INIT.grow.
LAYOUT = r"""
const AROUND = 85, LINE = 20, PAD = 16, BORDER = 2;
const lines = (v) => v ? v.split("\n").reduce((n, l) => n + Math.max(1, Math.ceil(l.length / 50)), 0) : 1;
const text = document.getElementById("text"), logEl = document.getElementById("log");
Object.defineProperties(text, {
  offsetHeight: { get() { return Math.max(parseFloat(this.style.height) || 0, PAD + BORDER); } },
  clientHeight: { get() { return this.offsetHeight - BORDER; } },
  scrollHeight: { get() { return Math.max(this.clientHeight, lines(this.value) * LINE + PAD); } },
});
Object.defineProperty(logEl, "offsetHeight", { get() { return Math.max(0, innerHeight - AROUND - text.offsetHeight); } });
"""

GROW_CHECKS = r"""
const box = document.getElementById("text");
const sizes = () => posted.filter((m) => m.type === "size").map((m) => m.grow);
const lastSize = () => sizes().slice(-1)[0] || 0;
// Hammerspoon grows the window by what the page asks, up to its room
const apply = () => { innerHeight = INIT.base + Math.min(lastSize(), INIT.grow); };
const state = () => ({ h: parseFloat(box.style.height), scroll: box.style.overflowY, log: els.log.offsetHeight, size: lastSize() });
const results = {};
// opened with a long unsent dump (30 lines): one line is still one line
results.draftOpen = state();
box.value = ""; box.fire("input");
results.draftSent = state();
// a brain dump of 12 lines: more than the old eight-line cap, and it all shows
const para = "x".repeat(49) + " ";
window.voice({ state: "dump", text: "" });
window.voice({ state: "listening", text: para.repeat(12).trim() });
apply(); window.voice({ state: "listening", text: para.repeat(12).trim() });
results.twelve = state();
// 100 lines: the box takes the conversation's room down to LOG_MIN, then scrolls
window.voice({ state: "listening", text: para.repeat(100).trim() });
apply(); window.voice({ state: "listening", text: para.repeat(100).trim() });
results.hundred = state();
results.hundredAtEnd = box.scrollTop === box.scrollHeight;
// sent: back to one line, and the window back to its height
els.form.requestSubmit();
results.sent = state();
// a taller panel after a resize: more room
window.setGrow(160, 600); innerHeight = 600;
box.value = para.repeat(100).trim(); box.fire("input");
results.resized = state();
console.log(JSON.stringify(results));
"""


class LongMessages(unittest.TestCase):
    """A long brain dump shows whole in the box: past what the window may grow, the box takes
    the conversation's room (leaving LOG_MIN of it), and only then scrolls."""

    @unittest.skipUnless(shutil.which("node"), "node isn't installed")
    def test_box_takes_the_conversations_room(self):
        draft = "\n".join(["y" * 50] * 30)
        init = json.dumps({"title": "Preview", "history": [], "thinking": False, "dictation": True,
                           "grow": 160, "base": 400, "draft": draft})
        script = PAGE.split("<script>", 1)[1].rsplit("</script>", 1)[0].replace("/*__INIT__*/null", init)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "page.js"
            path.write_text(HARNESS + LAYOUT + script + GROW_CHECKS + "\nprocess.exit(0);\n", encoding="utf-8")
            out = subprocess.run(["node", str(path)], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        r = json.loads(out.stdout.strip().splitlines()[-1])
        LINE = 20
        one = LINE + 16 + 2  # one line in the box: 38 px
        most = 400 + 160 - 85 - 96  # the window grown, less what's around, less LOG_MIN: 379 px
        # a dump back in the box: it fills the room, and after it's gone the box is one line again
        self.assertEqual(r["draftOpen"]["h"], most, r)
        self.assertEqual(r["draftOpen"]["scroll"], "auto")
        self.assertEqual(r["draftSent"]["h"], one, "an emptied box is one line, not the old dump's height")
        self.assertEqual(r["draftSent"]["size"], 0)
        # 12 lines (258 px) is past the old cap (one line + 160 = 198 px) and shows whole
        self.assertEqual(r["twelve"]["h"], 12 * LINE + 16 + 2, r)
        self.assertEqual(r["twelve"]["scroll"], "hidden", "no scrolling inside the box")
        self.assertEqual(r["twelve"]["size"], 12 * LINE + 16 + 2 - one)
        self.assertGreaterEqual(r["twelve"]["log"], 96)
        # 100 lines: as tall as the panel allows, the conversation keeps LOG_MIN, newest words in view
        self.assertEqual(r["hundred"]["h"], most, r)
        self.assertEqual(r["hundred"]["scroll"], "auto")
        self.assertEqual(r["hundred"]["log"], 96, "the conversation keeps two lines")
        self.assertTrue(r["hundredAtEnd"])
        self.assertEqual(r["sent"]["h"], one)
        self.assertEqual(r["sent"]["size"], 0)
        # resized to 600 px tall: the room follows
        self.assertEqual(r["resized"]["h"], 600 + 160 - 85 - 96, r)


if __name__ == "__main__":
    unittest.main()
