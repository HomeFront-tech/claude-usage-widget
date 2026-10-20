"""bin/buddy-opus-approve: the MCP permission tool that asks the owner through the buddy.

Run: /usr/bin/python3 -m unittest tests.test_approve_mcp -v
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = str(ROOT / "bin" / "buddy-opus-approve")
FAKE_HS = str(ROOT / "tests" / "fakes" / "hs")
CONFIG = {"enabled": True, "cap": 10, "approve_timeout": 600, "owner": "Sam", "deny_read": []}


class ApproveServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state"
        self.env = dict(os.environ, BUDDY_STATE_DIR=str(self.state), BUDDY_HS=FAKE_HS,
                        FAKE_HS_REPLY=json.dumps(CONFIG), FAKE_HS_LOG=str(Path(self.tmp.name) / "hs.log"),
                        BUDDY_RUN_ID="run1")
        self.proc = None
        self.next_id = 0

    def tearDown(self):
        if self.proc:
            self.proc.kill()
            self.proc.wait()
            self.proc.stdin.close()
            self.proc.stdout.close()
        self.tmp.cleanup()

    def start(self, **env):
        self.env.update(env)
        self.proc = subprocess.Popen([sys.executable, SERVER], env=self.env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True)
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "test", "version": "1"}})
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.proc.stdin.flush()

    def rpc(self, method, params):
        self.next_id += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                          "params": params}) + "\n")
        self.proc.stdin.flush()
        reply = json.loads(self.proc.stdout.readline())
        self.assertEqual(reply["id"], self.next_id)
        return reply["result"]

    def approve(self, tool, tool_input):
        result = self.rpc("tools/call", {"name": "approve", "arguments": {
            "tool_name": tool, "input": tool_input, "tool_use_id": "tu1"}})
        return json.loads(result["content"][0]["text"])

    def answer_with(self, behavior):
        def watch():
            folder = self.state / "approvals"
            for _ in range(100):
                reqs = list(folder.glob("*.req.json")) if folder.exists() else []
                if reqs:
                    rid = json.loads(reqs[0].read_text())["id"]
                    (folder / (rid + ".res.json")).write_text(json.dumps({"behavior": behavior}))
                    return
                time.sleep(0.05)
        threading.Thread(target=watch, daemon=True).start()

    def test_initialize_and_list(self):
        self.proc = subprocess.Popen([sys.executable, SERVER], env=self.env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True)
        init = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                       "clientInfo": {"name": "test", "version": "1"}})
        self.assertEqual(init["serverInfo"]["name"], "buddy")
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        tools = self.rpc("tools/list", {})["tools"]
        self.assertEqual(tools[0]["name"], "approve")

    def test_allow_when_owner_approves(self):
        self.start()
        self.answer_with("allow")
        out = self.approve("Bash", {"command": "ls ~/tmp"})
        self.assertEqual(out["behavior"], "allow")
        self.assertEqual(out["updatedInput"], {"command": "ls ~/tmp"})

    def test_deny_when_owner_denies(self):
        self.start()
        self.answer_with("deny")
        out = self.approve("Write", {"file_path": "/tmp/x", "content": "hi"})
        self.assertEqual(out["behavior"], "deny")
        self.assertIn("Sam", out["message"])
        log = [json.loads(x) for x in (self.state / "approvals.jsonl").read_text().splitlines()]
        self.assertEqual(log[-1]["decision"], "deny")
        self.assertEqual(log[-1]["run"], "run1")

    def test_no_decision_times_out_to_deny(self):
        self.start(BUDDY_APPROVE_TIMEOUT="1")
        t0 = time.time()
        out = self.approve("Bash", {"command": "touch ~/tmp/x"})
        self.assertEqual(out["behavior"], "deny")
        self.assertIn("No answer from Sam", out["message"])
        self.assertLess(time.time() - t0, 3)

    def test_buddy_offline_denies_immediately(self):
        self.start(BUDDY_HS="/nonexistent/hs")
        t0 = time.time()
        out = self.approve("Bash", {"command": "rm -rf ~/tmp/x"})
        self.assertEqual(out["behavior"], "deny")
        self.assertIn("Buddy isn't running", out["message"])
        self.assertLess(time.time() - t0, 2)
        folder = self.state / "approvals"
        self.assertEqual(list(folder.glob("*.req.json")) if folder.exists() else [], [])

    def test_write_detail_shows_the_change(self):
        self.start()
        self.answer_with("deny")
        self.approve("Write", {"file_path": "/tmp/conf.txt", "content": "token = abc\nmode = on"})
        req = json.loads(next((self.state / "approvals").glob("*.req.json")).read_text())
        self.assertIn("/tmp/conf.txt", req["detail"])
        self.assertIn("mode = on", req["detail"])

    def test_edit_detail_shows_old_and_new(self):
        self.start()
        self.answer_with("deny")
        self.approve("Edit", {"file_path": "/tmp/a.py", "old_string": "x = 1", "new_string": "x = 2"})
        req = json.loads(next((self.state / "approvals").glob("*.req.json")).read_text())
        for part in ("/tmp/a.py", "x = 1", "x = 2"):
            self.assertIn(part, req["detail"])

    def test_bash_detail_is_full_command(self):
        self.start()
        self.answer_with("deny")
        command = "echo " + "x" * 5000
        self.approve("Bash", {"command": command})
        req = json.loads(next((self.state / "approvals").glob("*.req.json")).read_text())
        self.assertEqual(req["detail"], command)
        self.assertEqual(req["tool"], "Bash")
        self.assertEqual(req["run"], "run1")


if __name__ == "__main__":
    unittest.main()
