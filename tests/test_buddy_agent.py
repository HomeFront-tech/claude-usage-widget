"""The single Claude entry point used by Buddy."""
import importlib.machinery
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin" / "buddy-agent"
FAKE = ROOT / "tests" / "fakes" / "claude"
CLI_MODULE = importlib.machinery.SourceFileLoader("buddy_agent_cli", str(CLI)).load_module()
route = CLI_MODULE.route
research_signal = CLI_MODULE.research_signal


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

    def test_note_profile_has_no_tools(self):
        self.run_cli("note")
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

    def test_telegram_origin_reaches_chat_tools_only(self):
        self.run_cli("chat", origin="telegram")
        config = json.loads(self.option("--mcp-config"))["mcpServers"]["buddy"]
        self.assertEqual(config["env"]["BUDDY_TOOLS_ORIGIN"], "telegram")
        self.run_cli("job", origin="telegram")
        config = json.loads(self.option("--mcp-config"))["mcpServers"]["buddy"]
        self.assertNotIn("BUDDY_TOOLS_ORIGIN", config["env"])

    def health_env(self, kind):
        self.run_cli(kind)
        return json.loads(self.option("--mcp-config"))["mcpServers"]["buddy"]["env"]

    def test_health_folder_only_in_chat_mode_with_health_on(self):
        self.agent.mkdir()
        (self.agent / "config.json").write_text('{"health": true}')
        self.assertEqual(self.health_env("chat")["BUDDY_HEALTH_DIR"], os.path.expanduser(
            "~/Library/Application Support/claude-usage-widget/health"))
        self.assertNotIn("BUDDY_HEALTH_DIR", self.health_env("job"))

    def test_no_health_folder_with_health_off_or_unset(self):
        self.assertNotIn("BUDDY_HEALTH_DIR", self.health_env("chat"))
        (self.agent / "config.json").write_text('{"health": false}')
        self.assertNotIn("BUDDY_HEALTH_DIR", self.health_env("chat"))

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
        self.assertIsNone(usage["cache_read_input_tokens"])
        self.assertIsNone(usage["cache_creation_input_tokens"])

    def test_ledger_records_claude_model_usage(self):
        self.env["FAKE_CLAUDE_MODEL_USAGE"] = json.dumps({"claude-haiku-5-5": {
            "inputTokens": 2, "outputTokens": 4, "cacheReadInputTokens": 649,
            "cacheCreationInputTokens": 3044}})
        self.env["FAKE_CLAUDE_USAGE"] = json.dumps({
            "cache_creation_input_tokens": 3044,
            "cache_creation": {"ephemeral_1h_input_tokens": 3044,
                               "ephemeral_5m_input_tokens": 0}})
        self.run_cli()
        usage = json.loads((self.agent / "usage.jsonl").read_text().splitlines()[-1])
        self.assertEqual(usage["engine"], "claude")
        self.assertEqual(usage["model"], "haiku")
        self.assertEqual(usage["models"], {"claude-haiku-5-5": [2, 4, 3044, 649, 3044]})

    def test_ledger_has_empty_models_without_model_usage(self):
        self.run_cli()
        usage = json.loads((self.agent / "usage.jsonl").read_text().splitlines()[-1])
        self.assertEqual(usage["models"], {})

    def test_models_from_apportions_one_hour_writes(self):
        result = {"usage": {"cache_creation_input_tokens": 10,
                            "cache_creation": {"ephemeral_1h_input_tokens": 5}},
                  "modelUsage": {"claude-a": {"inputTokens": 1, "outputTokens": 2,
                                               "cacheCreationInputTokens": 3},
                                 "claude-b": {"inputTokens": 4, "outputTokens": 5,
                                               "cacheCreationInputTokens": 7}}}
        self.assertEqual(CLI_MODULE.models_from(result), {
            "claude-a": [1, 2, 3, 0, 2], "claude-b": [4, 5, 7, 0, 4]})

    def test_error_result_keeps_full_text(self):
        message = "failure details " * 30
        self.env["FAKE_CLAUDE_RESULT"] = message
        self.env["FAKE_CLAUDE_RC"] = "1"
        result = self.run_cli()
        self.assertFalse(result["ok"])
        self.assertEqual(result["text"], message)
        self.assertEqual(result["error"], message[:300])

    def test_result_status_comes_from_is_error(self):
        failing_exit = self.root / "failing-exit-claude"
        failing_exit.write_text("#!/usr/bin/python3\nimport json, sys\n"
                                "print(json.dumps({'type': 'result', 'result': 'Completed', 'is_error': False}))\n"
                                "sys.exit(1)\n")
        failing_exit.chmod(0o755)
        self.env["BUDDY_CLAUDE"] = str(failing_exit)
        result = self.run_cli()
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], "Completed")
        self.assertIsNone(result["error"])

    def test_timeout_reports_error_promptly(self):
        self.env["FAKE_CLAUDE_SLEEP"] = "3"
        self.env["BUDDY_AGENT_TIMEOUT"] = "0.2"
        started = time.monotonic()
        result = self.run_cli()
        self.assertLess(time.monotonic() - started, 2)
        self.assertFalse(result["ok"])
        self.assertIsNone(result["text"])
        self.assertEqual(result["error"], "timeout")

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
                             "print('{\"type\":\"result\",\"result\":\"Found it\",\"is_error\":false,\"usage\":{\"input_tokens\":12,\"output_tokens\":3,\"cache_read_input_tokens\":456,\"cache_creation_input_tokens\":78}}')\n")
        streaming.chmod(0o755)
        self.env["BUDDY_CLAUDE"] = str(streaming)
        result = self.run_cli("chat")
        self.assertEqual(result["text"], "Found it")
        self.assertEqual(result["tools"], ["mcp__buddy__find_files"])
        usage = json.loads((self.agent / "usage.jsonl").read_text().splitlines()[0])
        self.assertEqual(usage["input_tokens"], 12)
        self.assertEqual(usage["output_tokens"], 3)
        self.assertEqual(usage["cache_read_input_tokens"], 456)
        self.assertEqual(usage["cache_creation_input_tokens"], 78)

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

    def test_auto_routes_by_kind(self):
        for kind, model, effort in (("quip", "haiku", "low"), ("note", "haiku", "low"),
                                    ("learn", "haiku", "low"), ("chat", "opus", None),
                                    ("job", "opus", None)):
            r = route(kind, {"prompt": "Them: hi"}, {"model": "auto"}, set())
            self.assertEqual((r["model"], r["effort"], r["helpers"]), (model, effort, False))

    def test_auto_research_gets_sonnet_helpers(self):
        r = route("chat", {"prompt": "You: hey\nThem: can you research standing desks"},
                  {"model": "auto"}, set())
        self.assertEqual((r["model"], r["helpers"], r["helper_model"]), ("opus", True, "sonnet"))

    def test_auto_research_skips_unavailable_helper(self):
        request = {"prompt": "Them: research standing desks"}
        r = route("chat", request, {"model": "auto"}, {"sonnet"})
        self.assertEqual((r["model"], r["helper_model"]), ("opus", "haiku"))
        r = route("chat", request, {"model": "auto"}, {"opus", "sonnet"})
        self.assertEqual((r["model"], r["helper_model"]), ("haiku", "haiku"))

    def test_model_updates_preserve_other_alias_with_stale_reads(self):
        self.agent.mkdir()
        original_agent = CLI_MODULE.agent.AGENT
        CLI_MODULE.agent.AGENT = self.agent
        try:
            stale_opus = CLI_MODULE.model_cache()
            stale_haiku = CLI_MODULE.model_cache()
            CLI_MODULE.mark_model(stale_opus, "opus", False)
            CLI_MODULE.mark_model(stale_haiku, "haiku", True)
        finally:
            CLI_MODULE.agent.AGENT = original_agent
        cache = json.loads((self.agent / "models.json").read_text())
        self.assertFalse(cache["opus"]["ok"])
        self.assertTrue(cache["haiku"]["ok"])

    def test_research_signal_only_reads_latest_turn(self):
        self.assertFalse(research_signal("Them: research this\nYou: done\nThem: thanks"))

    def test_named_model_used_for_everything(self):
        for kind in ("quip", "note", "learn", "chat", "job"):
            self.assertEqual(route(kind, {"prompt": "Them: research x"},
                                   {"model": "sonnet"}, set())["model"], "sonnet")
        self.assertEqual(route("chat", {"prompt": "Them: research x"},
                               {"model": "fable"}, set())["helper_model"], "fable")

    def test_legacy_config_is_haiku(self):
        self.assertEqual(route("chat", {"prompt": "Them: hi"}, {}, set())["model"], "haiku")

    def test_timeouts(self):
        self.assertEqual(route("quip", {"prompt": ""}, {"model": "auto"}, set())["timeout"], 45)
        self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "haiku"}, set())["timeout"], 180)
        self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "auto"}, set())["timeout"], 300)
        self.assertEqual(route("chat", {"prompt": "Them: research x"}, {"model": "auto"}, set())["timeout"], 600)

    def test_auto_skips_unavailable(self):
        self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "auto"}, {"opus"})["model"], "sonnet")
        self.assertEqual(route("chat", {"prompt": "Them: hi"}, {"model": "auto"}, {"opus", "sonnet"})["model"], "haiku")

    def test_helpers_argv_keeps_tools_read_only(self):
        self.agent.mkdir()
        (self.agent / "config.json").write_text('{"model": "auto"}')
        self.run_cli(kind="chat", prompt="Them: research standing desks")
        argv = self.argv()
        agents = json.loads(argv[argv.index("--agents") + 1])
        self.assertNotIn("Bash", json.dumps(agents))
        self.assertNotIn("Write", json.dumps(agents))
        self.assertIn("Agent", argv[argv.index("--allowedTools") + 1])

    def test_helpers_respect_web_search_off(self):
        self.agent.mkdir()
        (self.agent / "config.json").write_text('{"model": "auto", "web_search": false}')
        self.run_cli(kind="chat", prompt="Them: research standing desks")
        helper = json.loads(self.option("--agents"))["helper"]
        self.assertNotIn("WebSearch", helper["tools"])

    def test_auto_falls_back_when_model_missing(self):
        self.agent.mkdir()
        (self.agent / "config.json").write_text('{"model": "auto"}')
        self.env["FAKE_CLAUDE_FAIL_MODEL"] = "opus"
        out = self.run_cli(kind="chat")
        self.assertTrue(out["ok"])
        self.assertEqual(out["model"], "sonnet")
        self.assertFalse(json.loads((self.agent / "models.json").read_text())["opus"]["ok"])

    def test_named_model_missing_says_so(self):
        self.agent.mkdir()
        (self.agent / "config.json").write_text('{"model": "opus"}')
        self.env["FAKE_CLAUDE_FAIL_MODEL"] = "opus"
        out = self.run_cli(kind="chat")
        self.assertFalse(out["ok"])
        self.assertIn("Opus isn't on your plan", out["error"])

    def test_ping_uses_requested_model(self):
        self.run_cli(kind="ping", model="fable")
        self.assertEqual(self.option("--model"), "fable")


if __name__ == "__main__":
    unittest.main()
