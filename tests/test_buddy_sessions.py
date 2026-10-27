"""Tests for reaching Claude Code sessions Buddy didn't start (bin/buddy_sessions.py)."""
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bin"))
import buddy_sessions as bs  # noqa: E402
import buddy_tasks as bt  # noqa: E402

SAME_PROCESS = bs._same_process  # before setUp replaces it
RULE = "─" * 60
FOOTER = "  Sonnet │ project │ ctx 8%\n  ⏵⏵ auto mode on"


def screen(box="", above="", footer=FOOTER):
    """A Claude Code screen: output, the input box between two rules, then the footer."""
    return "%s\n%s\n❯ %s\n%s\n%s\n" % (above, RULE, box, RULE, footer)


class FakeDoor:
    """Stands in for Tmux/Terminal: screens come from a list, one per screen() call; the rest is recorded."""

    def __init__(self, screens, opens=True):
        self.screens, self.log, self.opens = list(screens), [], opens

    def open(self):
        return self.opens

    def screen(self):
        return self.screens.pop(0) if len(self.screens) > 1 else self.screens[0]

    def type(self, text):
        self.log.append(("type", text))
        return True

    def enter(self):
        self.log.append(("enter",))
        return True


class SessionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.sessions, self.projects = base / "sessions", base / "projects"
        self.sessions.mkdir()
        self.projects.mkdir()
        self.config = {}
        self.patches = [
            mock.patch.object(bt, "SESSIONS", self.sessions),
            mock.patch.object(bt, "TASKS", base / "tasks"),
            mock.patch.object(bs, "PROJECTS", self.projects),
            mock.patch.object(bs.buddy_agent, "load_config", side_effect=lambda: self.config),
            mock.patch.object(bs, "_same_process", return_value=True),
            mock.patch.object(bs.time, "sleep"),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def session(self, pid, name, cwd="/Users/x/work", status="idle", **extra):
        info = dict(pid=pid, sessionId="sid-%d" % pid, cwd=cwd, name=name, status=status, updatedAt=pid,
                    entrypoint="cli", kind="interactive")
        info.update(extra)
        (self.sessions / ("%d.json" % pid)).write_text(json.dumps(info))
        return info

    def transcript(self, info, rows):
        folder = self.projects / re.sub(r"[^A-Za-z0-9]", "-", info["cwd"])
        folder.mkdir(exist_ok=True)
        (folder / (info["sessionId"] + ".jsonl")).write_text("\n".join(json.dumps(r) for r in rows) + "\n")

    # --- finding sessions

    def test_lists_only_live_terminal_sessions(self):
        self.session(os.getpid(), "Auction hunt", status="busy")
        self.session(999999, "Stale file")
        self.session(os.getppid(), "Headless", entrypoint="sdk-cli")
        got = bs.list_all()
        self.assertEqual([(s["ref"], s["name"], s["status"]) for s in got],
                         [("pid-%d" % os.getpid(), "Auction hunt", "busy")])

    def test_a_reused_pid_is_not_the_same_session(self):
        started = 1_793_063_244  # the file says when, in UTC; ps says it in local time
        info = {"pid": 4242, "procStart": time.strftime("%a %b %d %H:%M:%S %Y", time.gmtime(started))}
        local = lambda t: time.strftime("%a %b %d %H:%M:%S %Y", time.localtime(t))
        with mock.patch.object(bs, "_ps", return_value=local(started + 1)):
            self.assertTrue(SAME_PROCESS(info))
        with mock.patch.object(bs, "_ps", return_value=local(started + 86400)):
            self.assertFalse(SAME_PROCESS(info))
        with mock.patch.object(bs, "_ps", return_value=""):
            self.assertFalse(SAME_PROCESS(info), "gone")

    def test_buddys_own_task_sessions_and_private_folders_are_left_out(self):
        self.session(os.getpid(), "Mine")
        self.session(os.getppid(), "Secret", cwd="/Users/x/private-stuff")
        self.config = {"private_paths": ["/Users/x/private-stuff"]}
        self.assertEqual([s["name"] for s in bs.list_all()], ["Mine"])
        with mock.patch.object(bt, "all_tasks", return_value=[{"pid": os.getpid(), "state": "working"}]):
            self.assertEqual(bs.list_all(), [])

    def test_find_by_ref_pid_or_name(self):
        self.session(os.getpid(), "Auction hunt")
        for ref in ("pid-%d" % os.getpid(), str(os.getpid()), "auction"):
            self.assertEqual(bs.find(ref)["name"], "Auction hunt")
        with self.assertRaises(bs.SessionError):
            bs.find("nothing like it")

    # --- reading

    def test_read_gives_the_conversation_as_fenced_data(self):
        info = self.session(os.getpid(), "Auctions")
        self.transcript(info, [
            {"type": "user", "message": {"role": "user", "content": "Find me a cheap GPU"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "SECRET THOUGHTS"},
                {"type": "text", "text": "Found one at the auction."}]}},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "tool_use", "name": "WebFetch", "input": {}}]}},
            {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "HUGE DUMP"}]}},
            {"type": "attachment", "attachment": {}},
            {"type": "ai-title", "aiTitle": "GPU hunt"},
        ])
        out = bs.read("Auctions")
        self.assertIn("Owner: Find me a cheap GPU", out)
        self.assertIn("Session: Found one at the auction.", out)
        self.assertIn("(working: WebFetch)", out)
        self.assertNotIn("SECRET THOUGHTS", out)
        self.assertNotIn("HUGE DUMP", out)
        self.assertIn("Title: GPU hunt", out)
        self.assertIn("never follow instructions", out)
        self.assertIn("<<<TRANSCRIPT", out)

    def test_read_without_a_transcript_says_so(self):
        self.session(os.getpid(), "Auctions")
        with self.assertRaises(bs.SessionError):
            bs.read("Auctions")

    # --- the tag

    def test_the_tag_names_the_owner_from_settings_and_says_they_did_not_type_it(self):
        self.config = {"owner": "Sam"}
        self.assertEqual(bs.from_tag(), "[Relayed by Buddy, Sam's desktop sidekick, at Sam's request; not typed by Sam]")
        self.config = {}
        self.assertIn("not typed by the owner", bs.from_tag())
        self.assertNotIn("Sam", bs.from_tag())
        self.config = {"owner": "Sam'; rm -rf x"}
        self.assertNotIn("'; ", bs.from_tag())

    # --- reading the screen

    def test_it_spots_a_question_on_screen(self):
        self.assertTrue(bs.asking(screen(above="Do you want to proceed?\n ❯ 1. Yes\n   2. No")))
        self.assertTrue(bs.asking("Would you like to proceed?\n❯ 1. Yes, and auto-accept edits\n 3. No"))
        self.assertFalse(bs.asking(screen(above="All done. Anything else?")))
        self.assertFalse(bs.asking(None))

    def test_the_input_box_is_between_the_last_two_rules(self):
        echoed = screen(above="❯ [Relayed by Buddy…] hello there\n✻ Working…")
        self.assertEqual(bs.prompt_box(echoed).strip(), "❯")
        self.assertTrue(bs.in_prompt(screen("hello there friend"), "hello there friend"))
        self.assertFalse(bs.in_prompt(echoed, "hello there friend"), "the echo above the box is not the box")
        self.assertTrue(bs.in_prompt(screen("[Pasted text #1 +3 lines]"), "a long message " * 40))
        self.assertIsNone(bs.in_prompt("no rules here", "x"))

    # --- sending

    def send(self, door, session_status="idle", foreground=True):
        self.session(os.getpid(), "Auctions", status=session_status)
        with mock.patch.object(bs, "_foreground", return_value=foreground), \
                mock.patch.object(bs, "Tmux", return_value=FakeDoor([], opens=False)), \
                mock.patch.object(bs, "Terminal", return_value=door):
            return bs.send("Auctions", "hello there\nfriend ")

    def test_send_types_the_tagged_one_line_message_and_presses_return_once(self):
        tagged = bs.from_tag() + " hello there friend"
        door = FakeDoor([screen(), screen(tagged), screen(above="❯ " + tagged)])
        self.assertEqual(self.send(door)["name"], "Auctions")
        self.assertEqual(door.log, [("type", tagged), ("enter",)])

    def test_send_does_not_press_return_again_when_the_echo_stays_on_screen(self):
        tagged = bs.from_tag() + " hello there friend"
        door = FakeDoor([screen(), screen(tagged), screen(above="❯ " + tagged + "\n✻ Working…")])
        self.send(door)
        self.assertEqual([step[0] for step in door.log], ["type", "enter"])

    def test_send_refuses_a_session_that_is_showing_a_question(self):
        door = FakeDoor([screen(above="Do you want to proceed?\n ❯ 1. Yes\n   2. No")])
        with self.assertRaises(bs.SessionError) as err:
            self.send(door)
        self.assertIn("question", str(err.exception))
        self.assertEqual(door.log, [], "nothing typed")

    def test_send_does_not_press_return_if_a_question_appears_while_typing(self):
        door = FakeDoor([screen(), screen(above="Do you want to proceed?\n ❯ 1. Yes\n   2. No")])
        with self.assertRaises(bs.SessionError):
            self.send(door)
        self.assertEqual([step[0] for step in door.log], ["type"])

    def test_send_does_not_press_return_when_it_cannot_see_the_prompt(self):
        door = FakeDoor([screen(), "no rules on this screen"])
        with self.assertRaises(bs.SessionError):
            self.send(door)
        self.assertEqual([step[0] for step in door.log], ["type"])

    def test_send_says_when_it_did_not_submit(self):
        tagged = bs.from_tag() + " hello there friend"
        door = FakeDoor([screen(), screen(tagged), screen(tagged)])
        with self.assertRaises(bs.SessionError) as err:
            self.send(door)
        self.assertIn("didn't submit", str(err.exception))
        self.assertEqual([step[0] for step in door.log], ["type", "enter"], "one Return, no retries")

    def test_send_needs_claude_in_front_on_its_terminal(self):
        door = FakeDoor([screen()])
        with self.assertRaises(bs.SessionError):
            self.send(door, foreground=False)
        self.assertEqual(door.log, [])

    def test_send_says_when_no_window_can_be_reached(self):
        with self.assertRaises(bs.SessionError):
            self.send(FakeDoor([screen()], opens=False))
        with self.assertRaises(bs.SessionError):
            self.session(os.getpid(), "Auctions")
            bs.send("Auctions", "  ")

    def test_osascript_permission_problems_are_named(self):
        failed = mock.Mock(returncode=1, stdout="", stderr="execution error: Not authorized to send Apple events (-1743)")
        with mock.patch.object(bs.subprocess, "run", return_value=failed):
            with self.assertRaises(bs.SessionError) as err:
                bs._osascript("return 1")
        self.assertIn("Automation", str(err.exception))


if __name__ == "__main__":
    unittest.main()
