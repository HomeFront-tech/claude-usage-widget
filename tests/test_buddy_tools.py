"""Subprocess tests for Buddy's stdio MCP tools."""
import json
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
import threading
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "bin" / "buddy-tools"
sys.path.insert(0, str(ROOT / "bin"))
import buddy_agent


def load_server():
    spec = importlib.util.spec_from_file_location("buddy_tools_test", SERVER)
    if spec is None:
        from importlib.machinery import SourceFileLoader
        spec = importlib.util.spec_from_loader("buddy_tools_test", SourceFileLoader("buddy_tools_test", str(SERVER)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuddyToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.agent = Path(self.tmp.name) / "agent"
        self.agent.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), BUDDY_AGENT_DIR=str(self.agent))
        self.proc = None
        self.seq = 0

    def tearDown(self):
        if self.proc:
            self.proc.kill()
            self.proc.wait()
            self.proc.stdin.close()
            self.proc.stdout.close()
        self.tmp.cleanup()

    def config(self, **values):
        (self.agent / "config.json").write_text(json.dumps(values))

    def start(self, **env):
        self.env.update(env)
        self.proc = subprocess.Popen([sys.executable, str(SERVER)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, env=self.env)

    def rpc(self, method, params=None):
        self.seq += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.seq,
                                          "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        reply = json.loads(self.proc.stdout.readline())
        self.assertEqual(reply["id"], self.seq)
        return reply.get("result", reply.get("error"))

    def call(self, tool_name, **args):
        return self.rpc("tools/call", {"name": tool_name, "arguments": args})

    def text(self, result):
        return result["content"][0]["text"]

    def test_initialize_and_list_chat_mode(self):
        self.start()
        init = self.rpc("initialize", {"protocolVersion": "2025-06-18"})
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        self.assertEqual(init["serverInfo"]["name"], "buddy")
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertEqual(names, {"find_files", "list_folder", "read_file", "reveal", "open",
                                 "read_source", "automations_list", "automations_add",
                                 "automations_change", "automations_remove", "remember"})

    def test_chat_mode_lists_health_tools_only_with_health_on(self):
        self.health_dir()
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertTrue({"health_log", "health_get"} <= names)

    def test_job_mode_has_no_open_or_reveal(self):
        self.start(BUDDY_TOOLS_MODE="job")
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertEqual(names, {"find_files", "list_folder", "read_file", "read_source",
                                 "automations_list", "remember"})
        self.assertTrue(self.call("open", target="Calculator")["isError"])

    def test_no_send_or_shell_tool_exists(self):
        self.start()
        banned = {"send", "mail", "email", "message", "post", "reply", "shell", "exec",
                  "run", "bash", "write", "edit", "delete", "move", "rename"}
        for tool in self.rpc("tools/list")["tools"]:
            self.assertFalse(set(tool["name"].split("_")) & banned)

    def test_open_rejects_other_schemes(self):
        self.start(BUDDY_OPEN="/usr/bin/true")
        for target in ("mailto:a@b.c", "sms:1", "tel:1", "imessage:x",
                       "file:///etc/passwd", "javascript:x"):
            self.assertTrue(self.call("open", target=target)["isError"])

    def test_reveal_odd_name(self):
        target = self.home / 'a "b" ü \'c\'.txt'
        target.write_text("hello")
        stub = Path(self.tmp.name) / "open-stub"
        argv_file = Path(self.tmp.name) / "argv.json"
        stub.write_text("#!/usr/bin/python3\nimport json,os,sys\nopen(os.environ['ARGV_FILE'],'w').write(json.dumps(sys.argv[1:]))\n")
        stub.chmod(0o755)
        self.start(BUDDY_OPEN=str(stub), ARGV_FILE=str(argv_file))
        self.assertFalse(self.call("reveal", path=str(target))["isError"])
        self.assertEqual(json.loads(argv_file.read_text()), ["-R", str(target.resolve())])

    def test_read_file_refuses_symlink_into_ssh(self):
        ssh = self.home / ".ssh"
        ssh.mkdir()
        (ssh / "id").write_text("private")
        (self.home / "link").symlink_to(ssh / "id")
        self.start()
        self.assertTrue(self.call("read_file", path="~/link")["isError"])

    def test_read_file_refuses_private_glob(self):
        target = self.home / "x" / "payroll-2026.txt"
        target.parent.mkdir()
        target.write_text("private")
        self.config(private_paths=["*payroll*"])
        self.start()
        self.assertTrue(self.call("read_file", path=str(target))["isError"])

    def test_read_file_binary_refused(self):
        target = self.home / "binary"
        target.write_bytes(b"hi\0there")
        self.start()
        out = self.call("read_file", path=str(target))
        self.assertTrue(out["isError"])
        self.assertEqual(self.text(out), "That's not a text file.")

    def test_read_file_truncates(self):
        target = self.home / "large.txt"
        target.write_text("x" * 50000)
        self.start()
        out = self.call("read_file", path=str(target))
        self.assertFalse(out["isError"])
        self.assertEqual(self.text(out), "x" * 20000 + "\n[… truncated, about 30000 more bytes]")

    def test_private_folder_blocks_descendants_in_every_path_tool(self):
        folder = self.home / "Private Folder"
        folder.mkdir()
        target = folder / "notes.txt"
        target.write_text("private")
        alias = self.home / "alias.txt"
        alias.symlink_to(target)
        search = Path(self.tmp.name) / "search"
        search.write_text("#!/usr/bin/python3\nprint(%r)\n" % str(target))
        search.chmod(0o755)
        self.config(private_paths=[str(folder)], search=[str(search)])
        self.start(BUDDY_OPEN="/usr/bin/true")
        for name, key in (("read_file", "path"), ("list_folder", "path"),
                          ("open", "target"), ("reveal", "path")):
            for path in (target, alias):
                with self.subTest(tool=name, path=path):
                    out = self.call(name, **{key: str(path)})
                    self.assertTrue(out["isError"])
                    self.assertEqual(self.text(out), "That path is private.")
        self.assertNotIn(str(target), self.text(self.call("find_files", query="notes")))

    def test_private_folder_data_volume_alias(self):
        folder = self.home / "Private Folder"
        folder.mkdir()
        target = folder / "notes.txt"
        target.write_text("private")
        alias = Path("/System/Volumes/Data" + str(target.resolve()))
        if not alias.exists():
            self.skipTest("Data volume alias is unavailable")
        with mock.patch.dict(os.environ, HOME=str(self.home)):
            self.assertTrue(buddy_agent.denied(str(alias), [str(folder)]))

    def test_private_glob_folder_blocks_nested_file(self):
        folder = self.home / "Clients" / "A"
        folder.mkdir(parents=True)
        target = folder / "nested" / "notes.txt"
        target.parent.mkdir()
        target.write_text("private")
        with mock.patch.dict(os.environ, HOME=str(self.home)):
            self.assertTrue(buddy_agent.denied(str(target), ["~/Clients/*"]))

    def test_private_glob_uses_real_path_of_symlinked_prefix(self):
        folder = self.home / "Real Folder"
        folder.mkdir()
        target = folder / "notes.txt"
        target.write_text("private")
        (self.home / "alias").symlink_to(folder, target_is_directory=True)
        with mock.patch.dict(os.environ, HOME=str(self.home)):
            self.assertTrue(buddy_agent.denied(str(target), ["~/alias/*"]))

    def test_private_glob_blocks_data_volume_alias(self):
        folder = self.home / "Private Folder"
        folder.mkdir()
        target = folder / "notes.txt"
        target.write_text("private")
        alias = Path("/System/Volumes/Data" + str(target.resolve()))
        if not alias.exists():
            self.skipTest("Data volume alias is unavailable")
        self.assertTrue(buddy_agent.denied(str(alias), [str(self.home / "Private*")]))

    def test_find_files_drops_denied(self):
        (self.home / ".ssh").mkdir()
        (self.home / ".ssh" / "id_rsa").write_text("private")
        (self.home / "ok.txt").write_text("ok")
        stub = Path(self.tmp.name) / "search"
        stub.write_text("#!/usr/bin/python3\nprint('Search results:')\nprint('~/.ssh/id_rsa  (doc, 1K) [private]')\nprint('~/ok.txt  (doc, 1K)')\n")
        stub.chmod(0o755)
        self.config(search=[str(stub)])
        self.start()
        out = self.call("find_files", query="ok", limit=2)
        self.assertFalse(out["isError"])
        self.assertEqual(self.text(out), str((self.home / "ok.txt").resolve()))

    def test_source_runs_fixed_argv(self):
        self.config(sources={"echo_src": {"cmd": ["/bin/echo", "hi", "{arg}"], "arg": "[0-9]+"}})
        self.start()
        self.assertEqual(self.text(self.call("read_source", name="echo_src", arg="42")), "hi 42")
        self.assertTrue(self.call("read_source", name="echo_src", arg="4; rm")["isError"])

    def test_source_timeout_returns_error(self):
        self.config(sources={"slow": {"cmd": ["/bin/sleep", "5"]}})
        self.start(BUDDY_SOURCE_TIMEOUT="1")
        began = time.monotonic()
        out = self.call("read_source", name="slow")
        self.assertTrue(out["isError"])
        self.assertIn("slow", self.text(out))
        self.assertLess(time.monotonic() - began, 3)

    def test_source_output_truncated(self):
        self.config(sources={"long": {"cmd": ["/usr/bin/python3", "-c", "print('x'*200000)"]}})
        self.start()
        out = self.call("read_source", name="long")
        self.assertFalse(out["isError"])
        self.assertTrue(self.text(out).startswith("x" * 60000))
        self.assertIn("truncated", self.text(out))

    def test_exited_source_still_returns_truncated_output(self):
        module = load_server()
        config = {"sources": {"short_overflow": {"cmd": ["/usr/bin/python3", "-c",
            "import sys; sys.stdout.write('x'*61000)"]}}}
        with mock.patch.object(module.agent, "load_config", return_value=config), \
             mock.patch.object(module.os, "killpg", side_effect=ProcessLookupError):
            out = module.read_source({"name": "short_overflow"})
        self.assertEqual(out, "x" * 60000 + "\n[… truncated]")

    def test_noisy_source_is_stopped_at_output_cap(self):
        pid_file = Path(self.tmp.name) / "source.pid"
        script = Path(self.tmp.name) / "noisy"
        script.write_text("#!/usr/bin/python3\nimport os,sys,time\n"
                          "open(sys.argv[1], 'w').write(str(os.getpid()))\n"
                          "sys.stdout.write('x'*5000000); sys.stdout.flush()\n"
                          "time.sleep(10)\n")
        script.chmod(0o755)
        self.config(sources={"noisy": {"cmd": [str(script), str(pid_file)]}})
        self.start()
        began = time.monotonic()
        out = self.call("read_source", name="noisy")
        self.assertFalse(out["isError"])
        self.assertLessEqual(len(self.text(out).split("\n[… truncated")[0]), 60000)
        self.assertIn("truncated", self.text(out))
        self.assertLess(time.monotonic() - began, 3)
        pid = int(pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_tools_list_includes_source_catalog(self):
        self.config(sources={"inbox": {"cmd": ["/bin/echo"], "about": "Recent messages", "arg": "[0-9]+"},
                             "weather": {"cmd": ["/bin/echo"], "about": "Current conditions"}})
        self.start()
        specs = {tool["name"]: tool["description"] for tool in self.rpc("tools/list")["tools"]}
        for name in ("read_source", "automations_add", "automations_change"):
            self.assertIn("inbox", specs[name])
            self.assertIn("Recent messages", specs[name])
            self.assertIn("[0-9]+", specs[name])
            self.assertIn("weather", specs[name])
            self.assertIn("Current conditions", specs[name])
            self.assertIn("names from this list", specs[name])

    def test_job_catalog_only_shows_allowed_sources(self):
        self.config(sources={"inbox": {"cmd": ["/bin/echo"], "about": "Recent messages"},
                             "weather": {"cmd": ["/bin/echo"], "about": "Current conditions"}})
        self.start(BUDDY_TOOLS_MODE="job", BUDDY_ALLOWED_SOURCES="weather")
        desc = {tool["name"]: tool["description"] for tool in self.rpc("tools/list")["tools"]}
        self.assertIn("weather", desc["read_source"])
        self.assertNotIn("inbox", desc["read_source"])

    def test_empty_source_catalog_says_none_configured(self):
        self.start()
        desc = {tool["name"]: tool["description"] for tool in self.rpc("tools/list")["tools"]}
        self.assertIn("No sources configured", desc["read_source"])

    def test_job_mode_sources_limited(self):
        self.config(sources={"a": {"cmd": ["/bin/echo", "a"]},
                             "b": {"cmd": ["/bin/echo", "b"]}})
        self.start(BUDDY_TOOLS_MODE="job", BUDDY_ALLOWED_SOURCES="a")
        self.assertTrue(self.call("read_source", name="b")["isError"])
        self.assertFalse(self.call("read_source", name="a")["isError"])

    def test_automations_roundtrip(self):
        self.config(sources={"a": {"cmd": ["/bin/echo", "a"]}})
        self.start()
        added = self.call("automations_add", name="Morning check", trigger={"type": "sit_down"},
                          instructions="Check status", sources=["a"])
        self.assertFalse(added["isError"])
        job = json.loads(self.text(added))
        self.assertIn(job["id"], self.text(self.call("automations_list")))
        changed = self.call("automations_change", id=job["id"], enabled=False)
        self.assertFalse(json.loads(self.text(changed))["enabled"])
        self.assertIn("Removed Morning check.", self.text(self.call("automations_remove", id=job["id"])))
        self.assertNotIn(job["id"], self.text(self.call("automations_list")))
        self.assertTrue(self.call("automations_add", name="Bad", trigger={"type": "daily_at", "at": "25:00"},
                                  instructions="x", sources=[])["isError"])

    def test_automation_trigger_schema_and_error(self):
        self.start()
        specs = {tool["name"]: tool["inputSchema"]["properties"]
                 for tool in self.rpc("tools/list")["tools"]}
        expected = {"type": "object", "properties": {
            "type": {"type": "string", "enum": ["sit_down", "daily_at"],
                     "description": "sit_down = the first time the owner sits down at the Mac after a long break (the morning); daily_at = every day at a set time"},
            "at": {"type": "string", "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$",
                   "description": "24-hour HH:MM, only for daily_at"}}, "required": ["type"]}
        for name in ("automations_add", "automations_change"):
            self.assertEqual(specs[name]["trigger"], expected)
            for field in ("name", "instructions", "sources"):
                self.assertTrue(specs[name][field].get("description"))
        out = self.call("automations_add", name="Bad", trigger={"type": "daily_at"},
                        instructions="Check", sources=[])
        self.assertEqual(self.text(out), 'Invalid trigger. Use {"type": "sit_down"} or {"type": "daily_at", "at": "HH:MM"}.')

    def test_automations_list_shows_finished_run_outcome(self):
        self.start()
        (self.agent / "automations.json").write_text(json.dumps([{"id": "daily", "name": "Daily",
            "trigger": {"type": "sit_down"}, "sources": [], "enabled": True}]))
        (self.agent / "runs.json").write_text(json.dumps({"daily": {"day": "2026-10-20",
            "startedAt": 100, "finishedAt": 110, "ok": False, "result": "error", "delivered": False}}))
        line = self.text(self.call("automations_list"))
        self.assertIn("last run: 110", line)
        self.assertIn("failed", line)

    def test_concurrent_adds_keep_both_jobs(self):
        module = load_server()
        first_loaded = threading.Event()
        second_attempt = threading.Event()
        original = buddy_agent.load_jobs
        errors = []
        loads = []
        def racing_load():
            jobs = original()
            loads.append([job["name"] for job in jobs])
            if len(loads) == 1:
                first_loaded.set()
                if not second_attempt.wait(timeout=2):
                    raise AssertionError("second add never attempted")
                time.sleep(0.1)
            return jobs
        def add(name):
            try:
                if name == "Second":
                    second_attempt.set()
                module.automations_add({"name": name, "trigger": {"type": "sit_down"},
                    "instructions": "Check", "sources": []})
            except Exception as exc:
                errors.append(exc)
        with mock.patch.object(buddy_agent, "AGENT", self.agent), \
             mock.patch.object(buddy_agent, "load_jobs", side_effect=racing_load):
            threads = [threading.Thread(target=add, args=("First",)),
                       threading.Thread(target=add, args=("Second",))]
            threads[0].start()
            self.assertTrue(first_loaded.wait(timeout=2))
            threads[1].start()
            for thread in threads: thread.join(timeout=4)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertEqual(errors, [])
        self.assertEqual(loads, [[], ["First"]])
        self.assertEqual({job["name"] for job in json.loads((self.agent / "automations.json").read_text())},
                         {"First", "Second"})

    def test_remember_appends(self):
        self.start()
        self.call("remember", note="one")
        self.call("remember", note="two")
        notes = [json.loads(x) for x in (self.agent / "notes-new.jsonl").read_text().splitlines()]
        self.assertEqual([n["note"] for n in notes], ["one", "two"])

    def health_dir(self):
        folder = Path(self.tmp.name) / "health"
        self.start(BUDDY_HEALTH_DIR=str(folder))
        return folder

    def test_health_log_writes_one_line(self):
        folder = self.health_dir()
        before = int(time.time())
        result = self.call("health_log", kind="goal", text="Run 5k by June")
        self.assertFalse(result["isError"], self.text(result))
        lines = (folder / "health-new.jsonl").read_text().splitlines()
        self.assertEqual(len(lines), 1)
        entry = json.loads(lines[0])
        self.assertEqual((entry["kind"], entry["text"]), ("goal", "Run 5k by June"))
        self.assertGreaterEqual(entry["at"], before)
        self.call("health_log", kind="meal", text="lunch: soup")
        self.assertEqual(len((folder / "health-new.jsonl").read_text().splitlines()), 2)

    def test_health_log_refuses_other_kinds_and_empty_text(self):
        folder = self.health_dir()
        self.assertTrue(self.call("health_log", kind="shell", text="rm -rf /")["isError"])
        self.assertTrue(self.call("health_log", kind="goal", text="  ")["isError"])
        self.assertFalse((folder / "health-new.jsonl").exists())

    def test_health_off_means_no_tools_and_calls_rejected(self):
        self.env.pop("BUDDY_HEALTH_DIR", None)
        self.start()
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertFalse({"health_log", "health_get"} & names)
        self.assertEqual(self.text(self.call("health_log", kind="goal", text="x")), "That tool isn't available.")
        self.assertEqual(self.text(self.call("health_get")), "That tool isn't available.")
        self.assertTrue(self.call("health_log", kind="goal", text="x")["isError"])
        self.assertTrue(self.call("health_get")["isError"])

    def test_health_get_returns_goals_plans_and_a_week(self):
        folder = self.health_dir()
        folder.mkdir()
        now = time.time()
        (folder / "health.json").write_text(json.dumps({
            "goals": [{"text": "Sleep 8 hours", "at": now - 100}],
            "plans": [{"text": "Mon: run", "at": now - 100}],
            "log": [{"kind": "meal", "text": "old", "at": now - 8 * 86400},
                    {"kind": "workout", "text": "yoga", "at": now - 86400}],
            "eaten": {"2026-01-01": {"lunch": True}}}))
        self.call("health_log", kind="break", text="walked")
        got = json.loads(self.text(self.call("health_get")))
        self.assertEqual([g["text"] for g in got["goals"]], ["Sleep 8 hours"])
        self.assertEqual([p["text"] for p in got["plans"]], ["Mon: run"])
        self.assertEqual([e["text"] for e in got["log"]], ["yoga", "walked"])
        self.assertNotIn("eaten", got)

    def test_health_get_empty_and_corrupt(self):
        folder = self.health_dir()
        self.assertEqual(json.loads(self.text(self.call("health_get"))),
                         {"goals": [], "plans": [], "log": []})
        folder.mkdir()
        (folder / "health.json").write_text("{nope")
        self.assertEqual(json.loads(self.text(self.call("health_get")))["goals"], [])

    def test_job_mode_has_no_health_tools(self):
        self.start(BUDDY_TOOLS_MODE="job", BUDDY_HEALTH_DIR=str(Path(self.tmp.name) / "health"))
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertFalse({"health_log", "health_get"} & names)
        self.assertTrue(self.call("health_log", kind="goal", text="x")["isError"])
        self.assertTrue(self.call("health_get")["isError"])

    def tasks_on(self, **config):
        self.config(tasks=True, **config)
        tasks = Path(self.tmp.name) / "tasks"
        self.start(BUDDY_TASKS_DIR=str(tasks))
        return tasks

    def test_task_tools_only_when_tasks_are_on(self):
        self.config()
        self.start(BUDDY_TASKS_DIR=str(Path(self.tmp.name) / "tasks"))
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertFalse({"task_start", "task_send", "task_list"} & names)
        self.assertTrue(self.call("task_start", task="x", name="y")["isError"])

    def test_job_mode_has_no_task_tools(self):
        self.config(tasks=True)
        self.start(BUDDY_TOOLS_MODE="job", BUDDY_TASKS_DIR=str(Path(self.tmp.name) / "tasks"))
        names = {t["name"] for t in self.rpc("tools/list")["tools"]}
        self.assertFalse({"task_start", "task_send", "task_list"} & names)

    def test_task_start_only_proposes(self):
        project = self.home / "dev" / "app"
        project.mkdir(parents=True)
        tasks = self.tasks_on(projects=[str(project)])
        start = next(t for t in self.rpc("tools/list")["tools"] if t["name"] == "task_start")
        self.assertIn(str(project), start["inputSchema"]["properties"]["folder"]["description"])
        result = self.call("task_start", task="Add a dark mode", name="Dark mode", folder=str(project))
        self.assertFalse(result["isError"], self.text(result))
        self.assertIn("yes or no", self.text(result))
        pending = json.loads((tasks / "pending.json").read_text())
        self.assertEqual((pending["kind"], pending["name"], pending["folder"]),
                         ("start", "Dark mode", os.path.realpath(project)))
        self.assertEqual(sorted(p.name for p in tasks.iterdir()), ["pending.json"], "nothing opened")
        self.call("task_start", task="Tidy up", name="Tidy")
        self.assertEqual(json.loads((tasks / "pending.json").read_text())["folder"], os.path.realpath(self.home))

    def test_task_start_refuses_private_and_missing_folders(self):
        private = self.home / ".ssh"
        private.mkdir()
        tasks = self.tasks_on()
        self.assertTrue(self.call("task_start", task="x", name="y", folder=str(private))["isError"])
        self.assertTrue(self.call("task_start", task="x", name="y", folder=str(self.home / "nope"))["isError"])
        self.assertTrue(self.call("task_start", task=" ", name="y")["isError"])
        self.assertFalse((tasks / "pending.json").exists())

    def test_task_send_and_list(self):
        tasks = self.tasks_on()
        self.assertTrue(self.call("task_send", id="nope", text="hi")["isError"])
        (tasks / "meal-1a2b").mkdir(parents=True)
        (tasks / "meal-1a2b" / "task.json").write_text(json.dumps({
            "id": "meal-1a2b", "name": "Meal tracker", "state": "waiting", "folder": str(self.home),
            "created": time.time(), "pid": os.getpid(), "tmux": False, "url": "https://claude.ai/code/s1",
            "last": "Which file should meals go in?"}))
        listed = self.text(self.call("task_list"))
        self.assertIn("meal-1a2b | Meal tracker | waiting", listed)
        self.assertIn("Which file should meals go in?", listed)
        result = self.call("task_send", id="meal-1a2b", text="A new one")
        self.assertFalse(result["isError"], self.text(result))
        pending = json.loads((tasks / "pending.json").read_text())
        self.assertEqual((pending["kind"], pending["id"], pending["text"]), ("send", "meal-1a2b", "A new one"))

    def test_only_generic_denied_folders_are_built_in(self):
        self.assertEqual(set(buddy_agent.BANNED_FOLDERS),
                         {".ssh", ".aws", ".gnupg", "Library/Keychains"})

    def test_all_generic_denials(self):
        folders = (".ssh", ".aws", ".gnupg", "Library/Keychains")
        for folder in folders:
            target = self.home / folder / "plain.txt"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("private")
            with mock.patch.dict(os.environ, HOME=str(self.home)):
                self.assertTrue(buddy_agent.denied(str(target), []), folder)
                self.assertTrue(buddy_agent.denied(str(target.parent), []), folder)
        for name in (".env.local", "item.pem", "item.key", "MyCredentialFile", "mySECRETfile", "myTOKENfile"):
            target = self.home / name
            target.write_text("private")
            self.assertTrue(buddy_agent.denied(str(target), []), name)

    def test_private_patterns_match_basename_and_spaced_path(self):
        nested = self.home / "any" / "dir" / "payroll.txt"
        nested.parent.mkdir(parents=True)
        nested.write_text("private")
        spaced = self.home / "Folder Name" / "plain.txt"
        spaced.parent.mkdir()
        spaced.write_text("private")
        with mock.patch.dict(os.environ, HOME=str(self.home)):
            self.assertTrue(buddy_agent.denied(str(nested), ["*payroll.txt"]))
            self.assertTrue(buddy_agent.denied(str(spaced), ["~/Folder Name/*"]))

    def test_denied_folder_via_parent_alias(self):
        protected = self.home / ".ssh"
        protected.mkdir()
        target = protected / "plain.txt"
        target.write_text("private")
        alias = self.home / "alias"
        alias.symlink_to(protected, target_is_directory=True)
        with mock.patch.dict(os.environ, HOME=str(self.home)):
            self.assertTrue(buddy_agent.denied(str(alias / "plain.txt"), []))
            volume_alias = Path("/System/Volumes/Data" + str(self.home.resolve())) / ".ssh" / "plain.txt"
            if volume_alias.exists():
                self.assertTrue(buddy_agent.denied(str(volume_alias), []))

    def test_denied_folder_via_symlink_to_volume_alias(self):
        protected = self.home / ".ssh"
        protected.mkdir()
        nested = protected / "nested"
        nested.mkdir()
        (nested / "plain.txt").write_text("private")
        volume_alias = Path("/System/Volumes/Data" + str(self.home.resolve())) / ".ssh"
        if not volume_alias.is_dir():
            self.skipTest("Data volume alias is unavailable")
        alias = self.home / "alias"
        alias.symlink_to(volume_alias / "nested", target_is_directory=True)
        file_alias = self.home / "file-alias"
        file_alias.symlink_to(volume_alias / "nested" / "plain.txt")
        with mock.patch.dict(os.environ, HOME=str(self.home)):
            self.assertTrue(buddy_agent.denied(str(alias), []))
            self.assertTrue(buddy_agent.denied(str(file_alias), []))
        self.start()
        out = self.call("list_folder", path=str(alias))
        self.assertTrue(out["isError"])
        self.assertEqual(self.text(out), "That path is private.")

    def test_open_refuses_scripts_and_executable_files(self):
        script = self.home / "start.command"
        script.write_text("hello")
        executable = self.home / "plain"
        executable.write_text("hello")
        executable.chmod(0o755)
        app = self.home / "Example.app"
        app.mkdir()
        marker = Path(self.tmp.name) / "opened"
        stub = Path(self.tmp.name) / "open-stub"
        stub.write_text("#!/usr/bin/python3\nimport os\nopen(os.environ['OPEN_MARKER'],'a').write('called\\n')\n")
        stub.chmod(0o755)
        self.start(BUDDY_OPEN=str(stub), OPEN_MARKER=str(marker))
        for target in (script, executable):
            out = self.call("open", target=str(target))
            self.assertTrue(out["isError"])
            self.assertEqual(self.text(out), "I don't open scripts or installers.")
            self.assertFalse(marker.exists())
        self.assertFalse(self.call("open", target=str(app))["isError"])
        self.assertTrue(marker.exists())

    def test_open_and_reveal_refuse_private_paths(self):
        target = self.home / ".ssh" / "plain.txt"
        target.parent.mkdir()
        target.write_text("private")
        self.start(BUDDY_OPEN="/usr/bin/true")
        for name, key in (("open", "target"), ("reveal", "path")):
            out = self.call(name, **{key: str(target)})
            self.assertTrue(out["isError"])
            self.assertEqual(self.text(out), "That path is private.")

    def test_read_file_allows_100000_characters(self):
        target = self.home / "large.txt"
        target.write_text("x" * 110000)
        self.start()
        out = self.call("read_file", path=str(target), max_chars=100000)
        self.assertEqual(self.text(out), "x" * 100000 + "\n[… truncated, about 10000 more bytes]")

    def test_read_file_limit_counts_unicode_characters(self):
        target = self.home / "unicode.txt"
        target.write_text("ü" * 30000)
        self.start()
        out = self.call("read_file", path=str(target), max_chars=20000)
        self.assertEqual(self.text(out), "ü" * 20000 + "\n[… truncated, about 20000 more bytes]")

    def test_read_file_stops_after_cap(self):
        import io
        module = load_server()
        class CountingStream(io.BytesIO):
            def __init__(self, content):
                super().__init__(content)
                self.bytes_read = 0

            def read(self, size=-1):
                data = super().read(size)
                self.bytes_read += len(data)
                return data

            def read1(self, size=-1):
                data = super().read1(size)
                self.bytes_read += len(data)
                return data

        stream = CountingStream(b"x" * (5 * 1024 * 1024))
        with mock.patch.object(module, "path_of", return_value="/tmp/plain"), \
             mock.patch.object(module.os.path, "isfile", return_value=True), \
             mock.patch("builtins.open", return_value=stream):
            module.read_file({"path": "/tmp/plain", "max_chars": 20000})
        self.assertGreater(stream.bytes_read, 0)
        self.assertLessEqual(stream.bytes_read, 20000 * 4 + 8192)

    def test_child_timeout_returns_tool_error(self):
        module = load_server()
        with mock.patch.object(module, "child", side_effect=subprocess.TimeoutExpired(["/usr/bin/open"], 15)), \
             mock.patch.object(module, "path_of", return_value=str(self.home)), \
             mock.patch.object(module.agent, "log"):
            for name, arguments in (("open", {"target": str(self.home)}),
                                    ("reveal", {"path": str(self.home)})):
                out = module.handle({"method": "tools/call", "params": {"name": name, "arguments": arguments}})
                self.assertTrue(out["isError"])
                self.assertIsInstance(self.text(out), str)


if __name__ == "__main__":
    unittest.main()
