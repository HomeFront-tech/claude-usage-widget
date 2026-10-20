"""Subprocess tests for Buddy's stdio MCP tools."""
import json
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
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
        self.assertEqual(self.text(out), "x" * 20000 + "\n[… truncated, 30000 more characters]")

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

    def test_remember_appends(self):
        self.start()
        self.call("remember", note="one")
        self.call("remember", note="two")
        notes = [json.loads(x) for x in (self.agent / "notes-new.jsonl").read_text().splitlines()]
        self.assertEqual([n["note"] for n in notes], ["one", "two"])

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
            self.assertTrue(buddy_agent.denied(str(nested), ["payroll.txt"]))
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
        self.assertEqual(self.text(out), "x" * 100000 + "\n[… truncated, 10000 more characters]")

    def test_read_file_limit_counts_unicode_characters(self):
        target = self.home / "unicode.txt"
        target.write_text("ü" * 30000)
        self.start()
        out = self.call("read_file", path=str(target), max_chars=20000)
        self.assertTrue(self.text(out).startswith("ü" * 20000 + "\n[… truncated,"))

    def test_read_file_stops_after_cap(self):
        import io
        module = load_server()
        stream = io.BytesIO(b"x" * 200000)
        reads = []
        original = stream.read

        def tracked(size=-1):
            reads.append(size)
            return original(size)

        stream.read = tracked
        with mock.patch.object(module, "path_of", return_value="/tmp/plain"), \
             mock.patch.object(module.os.path, "isfile", return_value=True), \
             mock.patch("builtins.open", return_value=stream):
            module.read_file({"path": "/tmp/plain", "max_chars": 20000})
        self.assertTrue(all(size >= 0 for size in reads), reads)
        self.assertLessEqual(sum(reads), 20001 + 4096)

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
