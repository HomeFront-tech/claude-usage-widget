"""The single Claude entry point used by Buddy."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin" / "buddy-agent"
FAKE = ROOT / "tests" / "fakes" / "claude"


class BuddyAgentTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.argv_file = self.root / "argv.json"
        self.stdin_file = self.root / "stdin.jsonl"
        self.agent = self.root / "agent"
        self.env = dict(os.environ, BUDDY_CLAUDE=str(FAKE),
                        BUDDY_AGENT_DIR=str(self.agent),
                        FAKE_CLAUDE_ARGV=str(self.argv_file),
                        FAKE_CLAUDE_STDIN=str(self.stdin_file))

    def run_cli(self, kind="quip", **fields):
        request = dict(kind=kind, system="Buddy rules", prompt="hello")
        request.update(fields)
        proc = subprocess.run([str(CLI)], input=json.dumps(request), text=True,
                              capture_output=True, env=self.env, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(proc.stdout.splitlines()), 1, proc.stdout)
        return json.loads(proc.stdout)

    def argv(self):
        return json.loads(self.argv_file.read_text())

    def option(self, name):
        argv = self.argv()
        return argv[argv.index(name) + 1]

    def test_quip_profile_has_no_tools(self):
        self.run_cli()
        self.assertEqual(self.option("--tools"), "")
        self.assertEqual(self.option("--max-turns"), "1")
        self.assertEqual(self.option("--effort"), "low")
        self.assertNotIn("--mcp-config", self.argv())

    def test_chat_profile_tools(self):
        self.run_cli("chat")
        config = json.loads(self.option("--mcp-config"))["mcpServers"]["buddy"]
        self.assertEqual(config["command"], "/usr/bin/python3")
        self.assertEqual(config["args"], [str((ROOT / "bin" / "buddy-tools").resolve())])
        self.assertEqual(config["env"]["BUDDY_TOOLS_MODE"], "chat")
        self.assertEqual(config["env"]["BUDDY_AGENT_DIR"], str(self.agent))
        self.assertEqual(self.option("--allowedTools"), "mcp__buddy,WebSearch")
        self.assertEqual(self.option("--tools"), "WebSearch")

    def test_chat_web_search_off(self):
        self.agent.mkdir()
        (self.agent / "config.json").write_text('{"web_search": false}')
        self.run_cli("chat")
        self.assertEqual(self.option("--tools"), "")
        self.assertEqual(self.option("--allowedTools"), "mcp__buddy")

    def test_job_profile_read_only(self):
        self.run_cli("job", sources=["inbox", "grok_bot"])
        config = json.loads(self.option("--mcp-config"))["mcpServers"]["buddy"]
        self.assertEqual(config["env"]["BUDDY_TOOLS_MODE"], "job")
        self.assertEqual(config["env"]["BUDDY_ALLOWED_SOURCES"], "inbox,grok_bot")
        self.assertEqual(self.option("--tools"), "")
        self.assertEqual(self.option("--allowedTools"), "mcp__buddy")

    def test_never_bare_or_dangerous(self):
        for kind in ("quip", "note", "chat", "job"):
            with self.subTest(kind=kind):
                self.run_cli(kind)
                argv = self.argv()
                self.assertNotIn("--bare", argv)
                self.assertNotIn("--dangerously-skip-permissions", argv)
                self.assertNotIn("--permission-mode", argv)
                self.assertEqual(argv[argv.index("--setting-sources") + 1], "")
                self.assertIn("--strict-mcp-config", argv)
                self.assertIn("--no-session-persistence", argv)

    def test_image_sent_as_block(self):
        self.run_cli(image="jpeg-data")
        sent = json.loads(self.stdin_file.read_text())
        content = sent["message"]["content"]
        self.assertEqual(sent["type"], "user")
        self.assertEqual(content[0], {"type": "image", "source": {
            "type": "base64", "media_type": "image/jpeg", "data": "jpeg-data"}})
        self.assertEqual(content[-1], {"type": "text", "text": "hello"})

    def test_result_printed(self):
        self.env["FAKE_CLAUDE_RESULT"] = "Hi"
        result = self.run_cli()
        self.assertEqual(result["ok"], True)
        self.assertEqual(result["text"], "Hi")
        self.assertIsNone(result["error"])
        self.assertEqual(result["tools"], [])
        self.assertIsInstance(result["ms"], int)
        lines = (self.agent / "usage.jsonl").read_text().splitlines()
        self.assertEqual(len(lines), 1)
        usage = json.loads(lines[0])
        self.assertEqual(usage["kind"], "quip")
        self.assertIsNone(usage["input_tokens"])
        self.assertIsNone(usage["output_tokens"])

    def test_claude_error_reported(self):
        failing = self.root / "failing-claude"
        failing.write_text("#!/usr/bin/python3\nimport sys\nprint('failed', file=sys.stderr)\nsys.exit(1)\n")
        failing.chmod(0o755)
        self.env["BUDDY_CLAUDE"] = str(failing)
        result = self.run_cli()
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "failed")

    def test_stream_output_collects_tools_and_usage(self):
        streaming = self.root / "streaming-claude"
        streaming.write_text("#!/usr/bin/python3\n"
                             "print('not JSON')\n"
                             "print('{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"mcp__buddy__find_files\"}]}}')\n"
                             "print('{\"type\":\"result\",\"result\":\"Found it\",\"is_error\":false,\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}')\n")
        streaming.chmod(0o755)
        self.env["BUDDY_CLAUDE"] = str(streaming)
        result = self.run_cli("chat")
        self.assertEqual(result["text"], "Found it")
        self.assertEqual(result["tools"], ["mcp__buddy__find_files"])
        usage = json.loads((self.agent / "usage.jsonl").read_text().splitlines()[0])
        self.assertEqual(usage["input_tokens"], 12)
        self.assertEqual(usage["output_tokens"], 3)

    def test_prompt_with_quotes_and_newlines(self):
        prompt = '\"; $(x)\n'
        self.run_cli(prompt=prompt)
        sent = json.loads(self.stdin_file.read_text())
        self.assertEqual(sent["message"]["content"][-1]["text"], prompt)

    def test_malformed_request_does_not_run_claude(self):
        for body in ("{", '{"kind":"other"}'):
            with self.subTest(body=body):
                proc = subprocess.run([str(CLI)], input=body, text=True,
                                      capture_output=True, env=self.env, timeout=10)
                self.assertEqual(proc.returncode, 0)
                self.assertFalse(json.loads(proc.stdout)["ok"])
                self.assertFalse(self.argv_file.exists())


if __name__ == "__main__":
    unittest.main()
