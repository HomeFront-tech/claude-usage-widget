"""Buddy ledger tally and period report, exercised through the command-line scripts."""
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "bin" / "claude-tokens"
USAGE = ROOT / "bin" / "buddy-usage"


class BuddyUsageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.agent = self.home / "agent"
        self.agent.mkdir()
        self.ledger = self.agent / "usage.jsonl"
        self.out = self.home / "Library" / "Application Support" / "claude-usage-widget"
        self.env = dict(os.environ, HOME=str(self.home), BUDDY_AGENT_DIR=str(self.agent))
        self.at = datetime.now().astimezone().isoformat(timespec="seconds")
        self.haiku = self.entry("quip", "claude-haiku-5-5", [2, 4, 3044, 649, 1])
        self.opus = self.entry("chat", "claude-opus-5-5", [10, 8, 20, 30, 0])
        self.ollama = self.entry("quip", "ollama:gemma3:4b", [11, 7, 0, 0, 0], "ollama")
        self.tool = {"tool": "read_file", "ok": True, "mode": "chat", "at": self.at}

    def entry(self, kind, model, counts, engine="claude"):
        return {"kind": kind, "engine": engine, "model": model,
                "models": {model: counts}, "ok": True, "at": self.at}

    def run_script(self, path, *args):
        result = subprocess.run(["/usr/bin/python3", str(path), *args], env=self.env,
                                capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def write_lines(self, *entries):
        self.ledger.write_text("".join(json.dumps(entry) + "\n" for entry in entries))

    def tally(self):
        return json.loads((self.out / "tokens.json").read_text())

    def buddy_hour(self):
        return next(iter(self.tally()["buddy"].values()))

    def test_incremental_tally_report_and_truncation(self):
        later = self.entry("note", "claude-haiku-5-5", [3, 2, 0, 0, 0])
        self.write_lines(self.haiku, self.opus, self.ollama, self.tool)
        with self.ledger.open("a") as out:
            out.write(json.dumps(later)[:-5])

        first = self.run_script(TOKENS)
        hour = self.buddy_hour()
        haiku_cost = round((2 * .10 + 4 * .50 + 649 * .01 + 3043 * .10 * 1.25 + .10 * 2) / 1e6, 6)
        opus_cost = round((10 * 4 + 8 * 20 + 30 * .20 + 20 * 4 * 1.25) / 1e6, 6)
        self.assertEqual(hour["m"]["claude-haiku-5-5"], [2, 4, 3044, 649, 1, haiku_cost])
        self.assertEqual(hour["m"]["ollama:gemma3:4b"][5], 0)
        self.assertEqual(set(hour["m"]), {"claude-haiku-5-5", "claude-opus-5-5", "ollama:gemma3:4b"})
        self.assertEqual(hour["k"]["quip"][0], 2 + 4 + 3044 + 649 + 11 + 7)
        self.assertEqual(first["buddy24h"]["calls"], 3)
        self.assertEqual(first["share24h"], 1)
        self.assertEqual(self.run_script(TOKENS)["buddy24h"], first["buddy24h"])

        report = self.run_script(USAGE)["periods"]["today"]
        self.assertEqual(report["calls"], 3)
        self.assertEqual(report["local_calls"], 1)
        self.assertEqual(report["models"]["claude-haiku-5-5"]["cost"], haiku_cost)
        self.assertEqual(report["models"]["claude-opus-5-5"]["cost"], opus_cost)
        self.assertEqual(report["models"]["ollama:gemma3:4b"]["cost"], 0)
        self.assertEqual(report["kinds"]["chat"]["cost"], opus_cost)

        with self.ledger.open("a") as out:
            out.write(json.dumps(later)[-5:] + "\n")
        self.assertEqual(self.run_script(TOKENS)["buddy24h"]["calls"], 4)
        self.assertEqual(self.run_script(TOKENS)["buddy24h"]["calls"], 4)
        self.write_lines(self.ollama)
        self.assertEqual(self.run_script(TOKENS)["buddy24h"]["calls"], 1)
        self.assertEqual(self.run_script(USAGE)["periods"]["today"]["local_calls"], 1)

    def test_old_lines_and_failed_empty_lines(self):
        old = {"kind": "learn", "ok": True, "at": self.at,
               "input_tokens": 3, "output_tokens": 5,
               "cache_creation_input_tokens": 7, "cache_read_input_tokens": 9}
        empty = {"kind": "quip", "ok": False, "at": self.at, "models": {}}
        self.write_lines(old, empty)
        self.run_script(TOKENS)
        hour = self.buddy_hour()
        self.assertEqual(hour["m"]["unknown"], [3, 5, 7, 9, 1, 0])
        self.assertEqual(hour["k"]["learn"], [24, 0])
        self.assertEqual(self.run_script(USAGE)["periods"]["today"]["calls"], 1)

    def test_missing_ledger_keeps_prior_totals_and_offset(self):
        self.write_lines(self.haiku)
        first = self.run_script(TOKENS)["buddy24h"]
        offset = json.loads((self.out / "tokens-state.json").read_text())["buddy_offset"]
        self.ledger.unlink()
        self.assertEqual(self.run_script(TOKENS)["buddy24h"], first)
        self.assertEqual(json.loads((self.out / "tokens-state.json").read_text())["buddy_offset"], offset)
        self.assertEqual(self.run_script(USAGE)["periods"]["today"]["calls"], 1)

    def test_calls_count_ledger_entries_even_with_helper_model(self):
        entry = self.entry("chat", "claude-opus-5-5", [10, 2, 0, 0, 0])
        entry["models"]["claude-haiku-5-5"] = [3, 1, 0, 0, 0]
        self.write_lines(entry)
        self.assertEqual(self.run_script(TOKENS)["buddy24h"]["calls"], 1)
        hour = self.buddy_hour()
        self.assertEqual(hour["n"], 1)
        self.assertEqual(sum(m[4] for m in hour["m"].values()), 2)
        for report in self.run_script(USAGE)["periods"].values():
            self.assertEqual(report["calls"], 1)

    def test_periods_use_complete_hour_buckets(self):
        now_h = int(datetime.now().timestamp() // 3600 * 3600)
        entries = []
        for hours_ago in (23, 24, 167, 168):
            entry = self.entry("chat", "claude-opus-5-5", [hours_ago, 1, 0, 0, 0])
            # The last second of the excluded bucket exposes an exact-time cutoff.
            second = 3599 if hours_ago == 168 else 60
            entry["at"] = datetime.fromtimestamp(now_h - hours_ago * 3600 + second).astimezone().isoformat()
            entries.append(entry)
        self.write_lines(*entries)
        # Claude Code's token strip already uses these same 24 hour keys.
        self.out.mkdir(parents=True)
        (self.out / "tokens.json").write_text(json.dumps({"hours": {
            str(now_h - 23 * 3600): {"m": {"test": [10, 0, 0, 0, 1, 0]}, "s": []},
            str(now_h - 24 * 3600): {"m": {"test": [100, 0, 0, 0, 1, 0]}, "s": []},
        }}))
        summary = self.run_script(TOKENS)
        self.assertEqual(summary["tokens24h"], 10)
        self.assertEqual(summary["buddy24h"]["calls"], 1)
        self.assertEqual(summary["buddy24h"]["tokens"], 24)
        self.assertEqual(summary["share24h"], 24 / 34)
        report = self.run_script(USAGE)["periods"]
        self.assertEqual(report["week"]["calls"], 3)
        self.assertEqual(report["week"]["tokens"], (23 + 1) + (24 + 1) + (167 + 1))

    def test_share_leaves_out_ollama_tokens(self):
        now_h = int(datetime.now().timestamp() // 3600 * 3600)
        self.out.mkdir(parents=True)
        (self.out / "tokens.json").write_text(json.dumps({"hours": {
            str(now_h): {"m": {"test": [100, 0, 0, 0, 1, 0]}, "s": []},
        }}))
        # Claude: 10 + 20 = 30 tokens; Ollama: 11 + 7 = 18 tokens that never reach Anthropic
        self.write_lines(self.entry("chat", "claude-opus-5-5", [10, 20, 0, 0, 0]), self.ollama)
        summary = self.run_script(TOKENS)
        self.assertEqual(summary["buddy24h"]["tokens"], 48)  # the report still counts every token
        self.assertEqual(summary["buddy24h"]["models"]["ollama:gemma3:4b"], 18)
        self.assertEqual(summary["share24h"], 30 / 130)
        self.write_lines(self.ollama)  # only local calls: no share of your Claude tokens at all
        self.assertEqual(self.run_script(TOKENS)["share24h"], 0)

    def test_tallies_rebuild_when_tokens_json_is_lost(self):
        self.write_lines(self.haiku, self.opus)
        first = self.run_script(TOKENS)["buddy24h"]
        self.assertGreater(json.loads((self.out / "tokens-state.json").read_text())["buddy_offset"], 0)
        (self.out / "tokens.json").unlink()
        rebuilt = self.run_script(TOKENS)["buddy24h"]
        self.assertEqual(rebuilt, first)
        self.assertEqual(rebuilt["calls"], 2)
        # a normal second run does not count the same calls twice
        self.assertEqual(self.run_script(TOKENS)["buddy24h"], first)


if __name__ == "__main__":
    unittest.main()
