"""Task sessions (bin/buddy_tasks.py, bin/buddy-task) against fake open, tmux and claude.

The fake open runs the .command file the way Terminal would; the fake tmux runs the
session's command in place and writes down what gets typed; the fake claude writes the
session file Claude Code keeps (with a Remote Control id) and waits to be stopped.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bin"))
import buddy_tasks as bt  # noqa: E402

FAKE_OPEN = """#!/usr/bin/python3
import os, subprocess, sys
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("open " + " ".join(sys.argv[1:]) + "\\n")
subprocess.Popen([sys.argv[-1]], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
"""
FAKE_TMUX = """#!/usr/bin/python3
import os, signal, sys
args = sys.argv[1:]
while args and args[0] in ("-L", "-f"):
    args = args[2:]
state = os.environ["FAKE_STATE"]
def opt(flag):
    return args[args.index(flag) + 1]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("tmux " + " ".join(args) + "\\n")
cmd = args[0]
if cmd == "new-session":
    with open(os.path.join(state, opt("-s")), "w") as out:
        out.write(str(os.getpid()))
    os.chdir(opt("-c"))
    os.execv("/bin/bash", ["/bin/bash", "-c", args[-1]])
marker = os.path.join(state, opt("-t") if "-t" in args else "none")
if cmd == "has-session":
    try:
        os.kill(int(open(marker).read()), 0)
    except (OSError, ValueError):
        sys.exit(1)
elif cmd == "kill-session":
    try:
        os.kill(int(open(marker).read()), signal.SIGTERM)
        os.remove(marker)
    except (OSError, ValueError):
        sys.exit(1)
elif cmd == "load-buffer":
    with open(os.path.join(state, "buffer"), "w") as out:
        out.write(sys.stdin.read())
elif cmd == "paste-buffer":
    with open(os.path.join(state, "typed"), "a") as out:
        out.write(open(os.path.join(state, "buffer")).read())
elif cmd == "send-keys":
    with open(os.path.join(state, "typed"), "a") as out:
        out.write("<" + args[-1] + ">")
"""
FAKE_CLAUDE = """#!/usr/bin/python3
import json, os, signal, sys, time
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write("claude " + json.dumps(sys.argv[1:]) + "\\n")
sessions = os.environ["BUDDY_SESSIONS_DIR"]
with open(os.path.join(sessions, "%d.json" % os.getpid()), "w") as out:
    json.dump({"pid": os.getpid(), "sessionId": "sess-1", "bridgeSessionId": os.environ.get("FAKE_BRIDGE") or None}, out)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
for _ in range(300):
    time.sleep(0.1)
"""


class TaskTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.tasks, self.sessions, self.state = root / "tasks", root / "sessions", root / "state"
        for d in (self.sessions, self.state, root / "fakes", root / "work"):
            d.mkdir()
        self.work = str((root / "work").resolve())
        self.log = root / "log"
        fakes = {}
        for name, body in (("open", FAKE_OPEN), ("tmux", FAKE_TMUX), ("claude", FAKE_CLAUDE)):
            path = root / "fakes" / name
            path.write_text(body)
            path.chmod(0o755)
            fakes[name] = str(path)
        self.env = {"BUDDY_OPEN": fakes["open"], "BUDDY_TMUX": fakes["tmux"], "BUDDY_CLAUDE": fakes["claude"],
                    "BUDDY_SESSIONS_DIR": str(self.sessions), "BUDDY_TASKS_DIR": str(self.tasks),
                    "FAKE_LOG": str(self.log), "FAKE_STATE": str(self.state), "FAKE_BRIDGE": "session_abc"}
        patches = [mock.patch.dict(os.environ, self.env), mock.patch.object(bt, "TASKS", self.tasks),
                   mock.patch.object(bt, "SESSIONS", self.sessions), mock.patch.object(bt, "PID_WAIT", 10),
                   mock.patch.object(bt, "LINK_WAIT", 5)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.started = []

    def tearDown(self):
        for task in self.started:
            try:
                bt.stop(task["id"])
            except bt.TaskError:
                pass
        self.tmp.cleanup()

    def start(self, **req):
        task = bt.start(dict({"task": "Build a meal tracker", "name": "Meal tracker", "folder": self.work,
                              "origin": "telegram", "owner": "Sam"}, **req))
        self.started.append(task)
        return task

    def events(self, task_id):
        lines = (self.tasks / task_id / "events.jsonl").read_text().splitlines()
        return [json.loads(line) for line in lines]

    def typed(self):
        path = self.state / "typed"
        return path.read_text() if path.exists() else ""

    def test_start_opens_a_remote_session_in_tmux(self):
        task = self.start()
        self.assertTrue(task["id"].startswith("meal-tracker-"))
        self.assertEqual(task["url"], "https://claude.ai/code/session_abc")
        self.assertEqual(task["state"], "working")
        self.assertTrue(task["tmux"])
        self.assertTrue(bt.pid_alive(task["pid"]))
        log = self.log.read_text()
        self.assertIn("open -a Terminal", log)
        self.assertIn("tmux new-session -A -s buddy-" + task["id"] + " -c " + self.work, log)
        argv = json.loads(next(l for l in log.splitlines() if l.startswith("claude "))[7:])
        self.assertEqual(argv[:4], ["--remote-control", "Meal tracker", "-n", "Meal tracker"])
        self.assertEqual(argv[4], "--settings")
        self.assertTrue(argv[-1].startswith("Build a meal tracker"), "the task is its first message")
        self.assertIn("over Telegram", argv[-1])
        self.assertIn("Sam can follow along", argv[-1])
        hooks = json.loads(Path(argv[5]).read_text())["hooks"]
        self.assertEqual(set(hooks), set(bt.HOOKED))
        command = hooks["Stop"][0]["hooks"][0]["command"]
        self.assertTrue(command.endswith("hook " + task["id"]))
        self.assertTrue(command.startswith("BUDDY_TASKS_DIR=" + str(self.tasks)), "the hook knows the folder without Buddy's environment")
        quiet = subprocess.run(command, shell=True, input=json.dumps({"hook_event_name": "Stop", "last_assistant_message": "hi"}),
                               capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})
        self.assertEqual((quiet.returncode, quiet.stdout), (0, ""))
        self.assertEqual(self.events(task["id"])[-1]["text"], "hi")
        self.assertEqual(hooks["PostToolUse"][0]["matcher"], "*")
        self.assertTrue(bt.alive(bt.load(task["id"])))

    def test_start_saves_topic_and_enabled_permission_hook(self):
        task = self.start(approvals=True, thread=77, thread_bot="123")
        self.assertEqual(bt.load(task["id"])["thread"], 77)
        self.assertEqual(bt.describe(task)["thread"], 77)
        self.assertEqual(bt.describe(task)["thread_bot"], "123")
        settings = json.loads((self.tasks / task["id"] / "settings.json").read_text())
        self.assertIn("PermissionRequest", settings["hooks"])

    def test_model_and_effort_pass_through_and_bad_ones_drop(self):
        self.start(model="opus", effort="xhigh")
        argv = json.loads(next(l for l in self.log.read_text().splitlines() if l.startswith("claude "))[7:])
        self.assertIn("--model", argv)
        self.assertIn("xhigh", argv)
        self.log.write_text("")
        self.start(model="opus; rm -rf /", effort="ultra")
        argv = json.loads(next(l for l in self.log.read_text().splitlines() if l.startswith("claude "))[7:])
        self.assertNotIn("--model", argv)
        self.assertNotIn("--effort", argv)

    def test_start_without_tmux_runs_in_terminal(self):
        with mock.patch.dict(os.environ, {"BUDDY_TMUX": ""}):
            task = self.start(origin="chat")
        self.assertFalse(task["tmux"])
        self.assertNotIn("tmux", self.log.read_text())
        self.assertIn("in Buddy's chat", (self.tasks / task["id"] / "prompt.md").read_text())
        with self.assertRaises(bt.TaskError) as err:
            bt.send(task["id"], "hello")
        self.assertIn("tmux", str(err.exception))

    def test_start_needs_a_real_folder_and_a_task(self):
        with self.assertRaises(bt.TaskError):
            bt.start({"task": "x", "name": "x", "folder": self.work + "/nope"})
        with self.assertRaises(bt.TaskError):
            bt.start({"task": "  ", "name": "x", "folder": self.work})

    def test_no_link_yet_still_starts(self):
        with mock.patch.dict(os.environ, {"FAKE_BRIDGE": ""}):
            task = self.start()
        self.assertIsNone(task["url"])
        self.assertTrue(task["pid"])

    def test_claude_never_starting_is_an_error(self):
        broken = Path(self.tmp.name) / "fakes" / "dead-claude"
        broken.write_text("#!/bin/sh\nexit 1\n")
        broken.chmod(0o755)
        with mock.patch.dict(os.environ, {"BUDDY_CLAUDE": str(broken)}), \
                mock.patch.object(bt, "launcher", lambda *a: "#!/bin/bash\nexit 1\n"), \
                mock.patch.object(bt, "PID_WAIT", 1):
            with self.assertRaises(bt.TaskError):
                bt.start({"task": "x", "name": "Broken", "folder": self.work})
        task = next(t for t in bt.all_tasks() if t["name"] == "Broken")
        self.assertEqual(task["state"], "ended")

    def test_hooks_track_state_and_report_what_matters(self):
        task = self.start()
        tid = task["id"]
        bt.hook(tid, {"hook_event_name": "UserPromptSubmit", "session_id": "s"})
        self.assertEqual(bt.load(tid)["state"], "working")
        bt.hook(tid, {"hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "waiting"})
        self.assertEqual(self.events(tid), [], "idle reminders aren't news")
        bt.hook(tid, {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                      "message": "Claude needs your permission to use Bash"})
        self.assertEqual(bt.load(tid)["state"], "asking")
        bt.hook(tid, {"hook_event_name": "PostToolUse"})
        self.assertEqual(bt.load(tid)["state"], "working", "the tool ran, so the question was answered")
        bt.hook(tid, {"hook_event_name": "Stop", "last_assistant_message": "Done: added the meal log."})
        self.assertEqual(bt.load(tid)["state"], "waiting")
        self.assertEqual(bt.load(tid)["last"], "Done: added the meal log.")
        self.assertEqual([(e["kind"], e["text"]) for e in self.events(tid)],
                         [("asking", "Claude needs your permission to use Bash"), ("done", "Done: added the meal log.")])
        bt.hook(tid, {"hook_event_name": "SessionEnd"})
        bt.hook(tid, {"hook_event_name": "SessionEnd"})
        self.assertEqual([e["kind"] for e in self.events(tid)].count("ended"), 1)
        bt.hook(tid, {"hook_event_name": "Stop", "last_assistant_message": "late"})
        self.assertEqual(len(self.events(tid)), 3, "nothing after the end")

    def test_stop_hook_without_the_message_reads_the_transcript(self):
        task = self.start()
        transcript = Path(self.tmp.name) / "t.jsonl"
        transcript.write_text("\n".join(json.dumps(x) for x in [
            {"type": "user", "message": {"role": "user", "content": "hi"}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on it"}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "All done."}]}},
        ]) + "\nnot json\n")
        bt.hook(task["id"], {"hook_event_name": "Stop", "transcript_path": str(transcript)})
        self.assertEqual(self.events(task["id"])[-1]["text"], "All done.")

    def test_send_pastes_then_presses_enter(self):
        task = self.start()
        bt.send(task["id"], "Use a new file.\nAnd add water tracking.")
        self.assertEqual(self.typed(), "Use a new file.\nAnd add water tracking.<Enter>")
        self.assertIn("paste-buffer -p -d -b buddy-send-%s -t buddy-%s" % (task["id"], task["id"]), self.log.read_text())

    def test_send_waits_while_a_permission_question_is_open(self):
        task = self.start()
        bt.hook(task["id"], {"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "?"})
        with self.assertRaises(bt.TaskError) as err:
            bt.send(task["id"], "yes")
        self.assertIn("permission", str(err.exception))
        self.assertEqual(self.typed(), "")

    def test_stop_ends_it_once(self):
        task = self.start()
        bt.stop(task["id"])
        bt.hook(task["id"], {"hook_event_name": "SessionEnd"})
        self.assertEqual(bt.load(task["id"])["state"], "ended")
        self.assertEqual([e["kind"] for e in self.events(task["id"])], ["ended"])
        self.assertFalse(bt.alive(bt.load(task["id"])))
        with self.assertRaises(bt.TaskError):
            bt.send(task["id"], "hello?")

    def test_sweep_marks_a_vanished_session_ended(self):
        task = self.start()
        os.kill(task["pid"], 15)
        time.sleep(0.3)
        shown = bt.sweep()
        self.assertEqual([t["state"] for t in shown], ["ended"], "ended today, so still listed")
        self.assertEqual([e["kind"] for e in self.events(task["id"])], ["ended"])
        with bt.edit(task["id"]) as old:
            old["ended"] = time.time() - 2 * bt.KEEP_ENDED
        self.assertEqual(bt.sweep(), [])

    def test_reopen_attaches_a_new_window(self):
        task = self.start()
        bt.reopen(task["id"], "Terminal")
        time.sleep(0.5)
        self.assertIn("tmux attach -t buddy-" + task["id"], self.log.read_text())

    def test_propose_and_unknown_ids(self):
        bt.propose({"kind": "start", "task": "x", "name": "y"})
        pending = json.loads((self.tasks / bt.PENDING).read_text())
        self.assertEqual(pending["kind"], "start")
        self.assertGreater(pending["at"], time.time() - 5)
        self.assertIsNone(bt.load("../../etc"))
        with self.assertRaises(bt.TaskError):
            bt.stop("nope")

    def test_folders_prefers_configured_projects(self):
        self.assertEqual(bt.folders({"projects": [self.work, self.work + "/missing"]}), [self.work])

    def test_cli(self):
        env = dict(os.environ)
        cli = [sys.executable, str(ROOT / "bin" / "buddy-task")]
        out = subprocess.run(cli + ["hook", "nope"], input="not json", capture_output=True, text=True, env=env)
        self.assertEqual((out.returncode, out.stdout), (0, ""), "a hook is silent and never fails")
        out = subprocess.run(cli + ["send", "nope"], input="hi", capture_output=True, text=True, env=env)
        self.assertEqual(json.loads(out.stdout), {"ok": False, "error": "That session has ended."})
        out = subprocess.run(cli + ["start"], input=json.dumps({"task": "Fix the build", "name": "Fix build",
                             "folder": self.work}), capture_output=True, text=True, env=env, timeout=30)
        reply = json.loads(out.stdout)
        self.started.append(reply["task"])
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["task"]["url"], "https://claude.ai/code/session_abc")
        out = subprocess.run(cli + ["list"], capture_output=True, text=True, env=env)
        self.assertEqual([t["name"] for t in json.loads(out.stdout)["tasks"]], ["Fix build"])
        hook = subprocess.run(cli + ["hook", reply["task"]["id"]], capture_output=True, text=True, env=env,
                              input=json.dumps({"hook_event_name": "Stop", "last_assistant_message": "ok"}))
        self.assertEqual(hook.stdout, "")
        self.assertEqual(self.events(reply["task"]["id"])[-1]["text"], "ok")


class PermitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tasks = Path(self.tmp.name)
        patch = mock.patch.object(bt, "TASKS", self.tasks)
        patch.start()
        self.addCleanup(patch.stop)
        self.tid = "job-1234"
        self.folder = self.tasks / self.tid
        self.folder.mkdir()
        bt.write_json(self.folder / "task.json", {"id": self.tid, "state": "working"})
        (self.folder / "events.jsonl").touch()
        self.payload = {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                        "tool_input": {"command": "printf hello"}}

    def events(self):
        return [json.loads(s) for s in (self.folder / "events.jsonl").read_text().splitlines()]

    def pending(self):
        return self.events()[-1]["rid"]

    def test_hook_settings_off_are_unchanged_and_on_are_scoped(self):
        off = bt.hook_settings(self.tid)
        self.assertEqual(off, bt.hook_settings(self.tid, False))
        self.assertEqual(set(off["hooks"]), set(bt.HOOKED))
        on = bt.hook_settings(self.tid, True)
        for name in bt.HOOKED:
            self.assertEqual(on["hooks"][name], off["hooks"][name])
        hook = on["hooks"]["PermissionRequest"][0]
        self.assertEqual(hook["matcher"], "*")
        self.assertEqual(hook["hooks"][0]["timeout"], 600)
        self.assertIn(" permit " + self.tid, hook["hooks"][0]["command"])
        self.assertEqual(bt.PERMIT_WAIT, 570)
        self.assertIn("PostToolUseFailure", on["hooks"])

    def test_allow_and_deny_are_one_call_only(self):
        for choice in ("allow", "deny"):
            with self.subTest(choice=choice):
                def tap(_):
                    rid = self.pending()
                    self.assertRegex(rid, r"^[0-9a-f]{12}$")
                    self.assertTrue(bt.answer(self.tid, rid, choice))
                    self.assertFalse(bt.answer(self.tid, rid, choice))
                with mock.patch.object(bt.time, "sleep", tap):
                    result = bt.permit(self.tid, self.payload)
                decision = {"behavior": choice}
                if choice == "deny":
                    decision["message"] = "The owner said no from Buddy."
                self.assertEqual(result, {"hookSpecificOutput": {
                    "hookEventName": "PermissionRequest", "decision": decision}})
                rid = self.pending()
                self.assertFalse(bt.answer(self.tid, rid, "allow"))
                self.assertEqual(bt.read_permit(self.tid, rid)["state"], "closed")
                self.assertEqual(bt.load(self.tid)["open_permits"], [])

    def test_matching_later_hook_closes_an_unanswered_permit(self):
        def elsewhere(_):
            bt.hook(self.tid, dict(self.payload, hook_event_name="PostToolUse"))
        with mock.patch.object(bt.time, "sleep", elsewhere):
            self.assertIsNone(bt.permit(self.tid, self.payload))
        self.assertEqual(self.events()[-1]["reason"], "Answered on the Mac")

    def test_timeout_leaves_prompt_alone_and_refuses_late_tap(self):
        with mock.patch.object(bt, "PERMIT_WAIT", 0):
            self.assertIsNone(bt.permit(self.tid, self.payload))
        rid = self.pending()
        self.assertEqual(self.events()[-1]["reason"], "Timed out")
        self.assertFalse(bt.answer(self.tid, rid, "allow"))
        self.assertFalse((self.folder / "permits" / (rid + ".decision")).exists())

    def test_expired_open_permit_is_rejected(self):
        def expire(_):
            rid = self.pending()
            with mock.patch.object(bt, "now", return_value=time.time() + 600):
                self.assertFalse(bt.answer(self.tid, rid, "allow"))
        with mock.patch.object(bt.time, "sleep", expire):
            self.assertIsNone(bt.permit(self.tid, self.payload))
        self.assertEqual(self.events()[-1]["reason"], "Timed out")

    def test_unknown_malformed_wrong_task_and_invalid_decisions(self):
        for rid in ("../task", "A" * 12, "0" * 11, "0" * 12):
            self.assertFalse(bt.answer(self.tid, rid, "allow"))
        def tap(_):
            rid = self.pending()
            self.assertFalse(bt.answer("other-1234", rid, "allow"))
            self.assertFalse(bt.answer(self.tid, rid, "always"))
            self.assertFalse(bt.answer("../escape", rid, "allow"))
            bt.hook(self.tid, dict(self.payload, hook_event_name="PostToolUse"))
        with mock.patch.object(bt.time, "sleep", tap):
            self.assertIsNone(bt.permit(self.tid, self.payload))

    def test_notification_is_not_duplicated_while_permit_open(self):
        def notify(_):
            rid = self.pending()
            bt.hook(self.tid, {"hook_event_name": "Notification", "notification_type": "permission_prompt"})
            self.assertEqual([e["kind"] for e in self.events()], ["permit"])
            bt.answer(self.tid, rid, "deny")
        with mock.patch.object(bt.time, "sleep", notify):
            self.assertIsNotNone(bt.permit(self.tid, self.payload))

    def test_internal_error_is_silent_and_closes_pending_permit(self):
        with mock.patch.object(bt.time, "sleep", side_effect=OSError("failed")):
            self.assertIsNone(bt.permit(self.tid, self.payload))
        self.assertEqual(self.events()[-1]["kind"], "permit_closed")
        self.assertEqual(bt.load(self.tid)["open_permits"], [])
        self.assertIsNone(bt.permit("missing", self.payload))

    def test_busy_lock_obeys_deadline(self):
        with bt.edit(self.tid), mock.patch.object(bt, "PERMIT_WAIT", 0):
            self.assertIsNone(bt.permit(self.tid, self.payload))
        self.assertEqual(self.events(), [])

    def test_summaries_are_tool_specific_and_keep_visible_commands(self):
        for tool, args, expected in (
            ("Bash", {"command": "echo one\necho two"}, "echo one\necho two"),
            ("Edit", {"file_path": "src/app.lua"}, "src/app.lua"),
            ("Write", {"file_path": "src/app.lua"}, "src/app.lua"),
            ("MultiEdit", {"file_path": "src/app.lua"}, "src/app.lua"),
            ("NotebookEdit", {"notebook_path": "demo.ipynb"}, "demo.ipynb"),
            ("WebFetch", {"url": "https://example.com"}, "https://example.com"),
            ("mcp__demo__run", {}, "demo / run: {}"),
            ("Read", {"file_path": "notes.txt"}, "Read: notes.txt"),
        ):
            self.assertEqual(bt.permit_summary({"tool_name": tool, "tool_input": args}), expected)
        self.assertEqual(len(bt.permit_summary({"tool_name": "Bash", "tool_input": {"command": "é" * 400}})), 400)

    def test_real_cli_allow_and_malformed_payloads(self):
        cli = [sys.executable, str(ROOT / "bin/buddy-task")]
        env = dict(os.environ, BUDDY_TASKS_DIR=str(self.tasks))
        for payload in ("bad json", "[]", "{}"):
            out = subprocess.run(cli + ["permit", self.tid], input=payload, text=True,
                                 capture_output=True, env=env, timeout=5)
            self.assertEqual((out.returncode, out.stdout, out.stderr), (0, "", ""))
        proc = subprocess.Popen(cli + ["permit", self.tid], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=env)
        try:
            proc.stdin.write(json.dumps(self.payload))
            proc.stdin.close()
            deadline = time.monotonic() + 5
            while not self.events() and time.monotonic() < deadline:
                time.sleep(0.02)
            rid = self.pending()
            for accepted in (True, False):
                out = subprocess.run(cli + ["answer", self.tid, rid, "allow"], capture_output=True,
                                     text=True, env=env, timeout=5)
                self.assertEqual(json.loads(out.stdout), {"ok": True, "answered": accepted})
            proc.wait(timeout=5)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(json.loads(proc.stdout.read())["hookSpecificOutput"]["decision"], {"behavior": "allow"})
            self.assertEqual(proc.stderr.read(), "")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()
            proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
