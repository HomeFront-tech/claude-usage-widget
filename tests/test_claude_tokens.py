"""bin/claude-tokens: the card's API value per period.

Run: /usr/bin/python3 -m unittest tests.test_claude_tokens -v
"""
import calendar
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import tarfile
import tempfile
import time
import unittest
from contextlib import contextmanager, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / "bin" / "claude-tokens")
MODEL = "claude-opus-5-5"


def load_cli():
    loader = importlib.machinery.SourceFileLoader("claude_tokens", CLI)
    spec = importlib.util.spec_from_loader("claude_tokens", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


cli = load_cli()


@contextmanager
def tz(name):
    old = os.environ.get("TZ")
    os.environ["TZ"] = name
    time.tzset()
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()


def local(y, mo, d, h=0, mi=0):
    return int(time.mktime((y, mo, d, h, mi, 0, 0, 0, -1)))


def utc_day(date):
    return calendar.timegm(time.strptime(date, "%Y-%m-%d"))


def hours_with(day, tokens, dollars, n=1):
    """n logged hours on a UTC day, splitting the tokens and dollars between them."""
    start = utc_day(day)
    return {str(start + i * 3600): {"m": {MODEL: [0, 0, 0, tokens // n, 1, dollars / n]}, "s": []}
            for i in range(n)}


def archive_with(day, tokens, dollars):
    return {"days": {day: {"m": {MODEL: [0, 0, 0, tokens, 0, dollars]}, "a": [5, 1, 0], "e": 1}}}


class ValueRecordsTest(unittest.TestCase):
    def test_archive_replaces_thin_logged_day(self):
        recs = cli.value_records(hours_with("2026-09-01", 100, 1.0), archive_with("2026-09-01", 1000, 9.0))
        self.assertEqual(sum(d for _, d in recs), 9.0)
        self.assertEqual(recs, [(utc_day("2026-09-01") + 43200, 9.0)])

    def test_logs_kept_when_they_hold_as_much(self):
        recs = cli.value_records(hours_with("2026-09-01", 1000, 10.0), archive_with("2026-09-01", 1000, 9.0))
        self.assertEqual(sum(d for _, d in recs), 10.0)

    def test_archive_fills_days_without_logs(self):
        hours = hours_with("2026-09-02", 500, 4.0)
        recs = cli.value_records(hours, archive_with("2026-09-01", 1000, 9.0))
        self.assertEqual(sorted(d for _, d in recs), [4.0, 9.0])

    def test_no_archive_means_hours_only(self):
        recs = cli.value_records(hours_with("2026-09-01", 300, 3.0, n=3), None)
        self.assertEqual(len(recs), 3)
        self.assertAlmostEqual(sum(d for _, d in recs), 3.0)

    def test_records_are_sorted_by_time(self):
        hours = hours_with("2026-09-03", 500, 4.0)
        recs = cli.value_records(hours, archive_with("2026-09-01", 1000, 9.0))
        self.assertEqual([t for t, _ in recs], sorted(t for t, _ in recs))


class PeriodStartsTest(unittest.TestCase):
    def test_period_starts_local(self):
        with tz("America/Edmonton"):
            now = local(2026, 10, 24, 15, 30)
            s = cli.period_starts(now, None, None)
            self.assertEqual(s["today"], local(2026, 10, 24))
            self.assertEqual(s["week"], local(2026, 10, 19))  # Monday
            self.assertEqual(s["month"], local(2026, 10, 1))
            self.assertEqual(s["ytd"], local(2026, 1, 1))
            self.assertEqual(s["session"], now - 5 * 3600)
            self.assertEqual(s["all"], 0)

    def test_plan_windows_win(self):
        now = local(2026, 10, 24, 15, 30)
        s = cli.period_starts(now, 111, 222)
        self.assertEqual(s["session"], 111)
        self.assertEqual(s["week"], 222)

    def test_period_starts_across_dst(self):
        with tz("America/New_York"):
            now = local(2026, 11, 1, 12, 0)  # clocks go back at 02:00 that morning
            s = cli.period_starts(now, None, None)
            self.assertEqual(s["today"], local(2026, 11, 1))
            self.assertEqual(now - s["today"], 13 * 3600)

    def test_monday_is_its_own_week_start(self):
        with tz("America/Edmonton"):
            now = local(2026, 10, 19, 0, 5)
            self.assertEqual(cli.period_starts(now, None, None)["week"], local(2026, 10, 19))


class SumValueTest(unittest.TestCase):
    def test_sum_value_whole_buckets(self):
        recs = [(1000, 1.0), (4600, 2.0), (8200, 4.0)]
        self.assertEqual(cli.sum_value(recs, 4600, 8200), 2.0)
        self.assertEqual(cli.sum_value(recs, 1001, 9000), 6.0)
        self.assertEqual(cli.sum_value(recs, 0, 1000), 0.0)


def hourly(start, n, dollars, step=3600):
    return {str(start + i * step): {"m": {MODEL: [1, 1, 1, 1, 1, dollars]}, "s": []} for i in range(n)}


class SpreadTest(unittest.TestCase):
    def test_spread_needs_five(self):
        self.assertIsNone(cli.spread([1, 2, 3, 4]))
        self.assertAlmostEqual(cli.spread([2, 4, 4, 4, 5, 5, 7, 9]), 2.0)

    def test_past_days_skip_today_and_empty_days(self):
        with tz("America/New_York"):
            now = local(2026, 10, 24, 15)
            recs = [(local(2026, 10, 20, 9), 2.0), (local(2026, 10, 21, 9), 3.0), (local(2026, 10, 23, 9), 5.0),
                    (local(2026, 10, 24, 9), 7.0)]
            starts = cli.period_starts(now, None, None)
            self.assertEqual(sorted(cli.past_totals(recs, "today", starts, now)), [2.0, 3.0, 5.0])

    def test_past_months_for_long_periods(self):
        with tz("America/New_York"):
            now = local(2026, 10, 24, 15)
            recs = [(local(2026, 7, 3), 10.0), (local(2026, 7, 9), 5.0), (local(2026, 9, 1), 20.0),
                    (local(2026, 10, 2), 99.0)]
            starts = cli.period_starts(now, None, None)
            for key in ("month", "ytd", "all"):
                self.assertEqual(sorted(cli.past_totals(recs, key, starts, now)), [15.0, 20.0], key)

    def test_past_sessions_are_five_hour_windows(self):
        now = 1_000_000_000
        recs = [(now - 4 * 3600, 1.0), (now - 6 * 3600, 2.0), (now - 7 * 3600, 3.0), (now - 11 * 3600, 4.0)]
        starts = {"session": now - 4.5 * 3600}
        # windows end at the session start: [-9.5h, -4.5h) holds 2+3, [-14.5h, -9.5h) holds 4
        self.assertEqual(sorted(cli.past_totals(recs, "session", starts, now)), [4.0, 5.0])


class PaidTest(unittest.TestCase):
    def test_paid_to_is_exclusive(self):
        with tz("America/New_York"):
            billing = {"charges": [
                {"date": "2026-03-04", "amount": 31.0, "from": "2026-03-04", "to": "2026-04-04"},
                {"date": "2026-04-04", "amount": 30.0, "from": "2026-04-04", "to": "2026-05-04"}]}
            self.assertAlmostEqual(cli.paid_between(billing, None, local(2026, 4, 4), local(2026, 4, 5)), 1.0)
            self.assertAlmostEqual(cli.paid_between(billing, None, local(2026, 3, 4), local(2026, 5, 4)), 61.0)

    def test_paid_missing_to_is_one_month(self):
        with tz("America/New_York"):
            billing = {"charges": [{"date": "2026-03-04", "amount": 31.0}]}
            self.assertAlmostEqual(cli.paid_between(billing, None, local(2026, 4, 3), local(2026, 4, 4)), 1.0)
            self.assertIsNone(cli.paid_between(billing, None, local(2026, 4, 4), local(2026, 4, 5)))

    def test_paid_gap_uses_plan_price(self):
        with tz("America/New_York"):
            self.assertAlmostEqual(cli.paid_between(None, 31.0, local(2026, 10, 5), local(2026, 10, 6)), 1.0)

    def test_paid_part_day(self):
        with tz("America/New_York"):
            self.assertAlmostEqual(cli.paid_between(None, 31.0, local(2026, 10, 5, 6), local(2026, 10, 5, 12)), 0.25)

    def test_paid_none_when_nothing_covers(self):
        self.assertIsNone(cli.paid_between(None, None, 0, 86400))
        self.assertIsNone(cli.paid_between({"charges": []}, None, 0, 86400))


class PeriodsTest(unittest.TestCase):
    def test_periods_shape_and_buddy(self):
        hour = int(time.time()) // 3600 * 3600
        now = hour + 1800
        hours = hourly(hour - 6 * 3600, 6, 2.0)
        buddy = {str(hour): {"m": {"claude-haiku-5-5": [1, 1, 0, 0, 1, 0.5]}, "k": {}, "n": 1}}
        p = cli.periods(hours, None, buddy, None, None, now, None, None)
        self.assertTrue(p["has_buddy"])
        self.assertEqual(p["first"], hour - 6 * 3600)
        self.assertEqual(set(p["list"]), {"session", "today", "week", "month", "ytd", "all"})
        self.assertAlmostEqual(p["list"]["all"]["value"], 12.0)
        self.assertAlmostEqual(p["list"]["all"]["buddy"], 0.5)
        self.assertAlmostEqual(p["list"]["session"]["value"], 8.0)  # hours starting inside the last 5
        for v in p["list"].values():
            self.assertEqual(set(v), {"from", "value", "buddy", "paid", "spread", "rolling", "missing", "partial"})
            self.assertIsNone(v["paid"])
        self.assertTrue(p["list"]["session"]["rolling"])  # no plan session: the last 5 hours, always moving
        self.assertFalse(p["list"]["today"]["rolling"])
        self.assertFalse(cli.periods(hours, None, None, None, None, now, now - 3600, None)["list"]["session"]["rolling"])

    def test_periods_without_buddy_or_data(self):
        p = cli.periods({}, None, None, None, 100.0, int(time.time()), None, None)
        self.assertFalse(p["has_buddy"])
        self.assertIsNone(p["first"])
        self.assertEqual(p["list"]["all"]["value"], 0)
        self.assertIsNone(p["list"]["all"]["paid"])

    def test_all_time_paid_starts_with_your_data(self):
        with tz("America/New_York"):
            now = local(2026, 10, 24, 12)
            hours = hourly(local(2026, 10, 20, 9), 1, 1.0)
            p = cli.periods(hours, None, None, None, 31.0, now, None, None)
            self.assertAlmostEqual(p["list"]["all"]["paid"], 4.5, places=2)  # Oct 20 00:00 → Oct 24 12:00

    def test_periods_is_fast_on_a_year_of_hours(self):
        now = int(time.time())
        start = now - 9000 * 3600
        hours = hourly(start, 9000, 0.01)
        t0 = time.time()
        cli.periods(hours, None, None, None, 100.0, now, None, None)
        self.assertLess(time.time() - t0, 0.3)

    def test_main_prints_periods(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "billing.json"), "w") as f:
                json.dump({"charges": [{"date": "2026-01-01", "amount": 100, "from": "2026-01-01", "to": "2027-01-01"}]}, f)
            out = io.StringIO()
            with mock.patch.object(cli, "OUT_DIR", d), mock.patch.object(cli, "TALLY", os.path.join(d, "tokens.json")), \
                    mock.patch.object(cli, "STATE", os.path.join(d, "tokens-state.json")), \
                    mock.patch.object(cli, "log_files", return_value=[]), \
                    mock.patch.object(cli, "desktop_files", return_value=[]), \
                    mock.patch.object(cli, "TASKS_DIR", d), mock.patch.dict(os.environ, {"BUDDY_TASKS_DIR": d}), \
                    mock.patch("sys.argv", ["claude-tokens", "--session-start", "1792900000", "--plan-price", "100"]), \
                    redirect_stdout(out):
                cli.main()
            res = json.loads(out.getvalue())
            self.assertTrue(res["ok"])
            self.assertEqual(res["periods"]["list"]["session"]["from"], 1792900000)
            self.assertIsNone(res["periods"]["first"])
            saved = json.load(open(os.path.join(d, "tokens.json")))
            self.assertNotIn("periods", saved)


def reply(mid, ts, out=10, session="aaaaaaaa-1111-2222", model=MODEL, inp=1, write=2, read=3, **line):
    return dict({"type": "assistant", "timestamp": ts, "sessionId": session, "message": {
        "id": mid, "model": model, "usage": {
            "input_tokens": inp, "output_tokens": out, "cache_creation_input_tokens": write,
            "cache_read_input_tokens": read}}}, **line)


TS = "2026-10-20T15:30:00.000Z"
HOUR = str(utc_day("2026-10-20") + 15 * 3600)


class ReplyLinesTest(unittest.TestCase):
    """One reply is logged as several lines and only the last has its final output count."""

    def tally(self, *lines, live=None, sessions=None):
        hours, seen = {}, set()
        live = {} if live is None else live
        sessions = {} if sessions is None else sessions
        counted = [cli.tally_line(d, hours, seen, live, sessions) for d in lines]
        return hours, counted, sessions

    def test_a_later_line_tops_up_the_output(self):
        hours, counted, _ = self.tally(reply("msg_1", TS, out=8), reply("msg_1", TS, out=3661))
        self.assertEqual(counted, [True, False])
        m = hours[HOUR]["m"][MODEL]
        self.assertEqual(m[:5], [1, 3661, 2, 3, 1], "one reply, its final output")
        self.assertAlmostEqual(m[5], cli.usage_cost(MODEL, 1, 3661, 2, 3, 0), places=6)

    def test_a_smaller_later_line_changes_nothing(self):
        hours, _, _ = self.tally(reply("msg_1", TS, out=100), reply("msg_1", TS, out=40))
        self.assertEqual(hours[HOUR]["m"][MODEL][1], 100)

    def test_top_up_reaches_a_reply_counted_on_an_earlier_run(self):
        hours, seen, live, sessions = {}, set(), {}, {}
        cli.tally_line(reply("msg_1", TS, out=8), hours, seen, live, sessions)
        live = json.loads(json.dumps(live))  # the saved state, read back on the next run
        self.assertFalse(cli.tally_line(reply("msg_1", TS, out=500), hours, seen, live, sessions))
        self.assertEqual(hours[HOUR]["m"][MODEL][1], 500)

    def test_a_reply_replayed_in_a_resumed_log_is_not_counted_again(self):
        hours, seen, live, sessions = {}, set(), {}, {}
        cli.tally_line(reply("msg_1", TS, out=50), hours, seen, live, sessions)
        cli.tally_line(reply("msg_1", TS, out=50, session="bbbbbbbb-3333"), hours, seen, live, sessions)
        self.assertEqual(hours[HOUR]["m"][MODEL][4], 1)
        self.assertEqual(list(sessions), ["aaaaaaaa"])

    def test_tokens_and_dollars_are_kept_per_session(self):
        _, _, sessions = self.tally(reply("msg_1", TS, out=8), reply("msg_1", TS, out=20),
                                    reply("msg_2", TS, out=10, session="bbbbbbbb-3333"))
        self.assertEqual(sessions["aaaaaaaa"][HOUR][0], 1 + 20 + 2 + 3)
        self.assertEqual(sessions["aaaaaaaa"][HOUR][2], 1)
        self.assertEqual(sessions["bbbbbbbb"][HOUR][0], 1 + 10 + 2 + 3)


class HaikuLongPromptTest(unittest.TestCase):
    def test_prompts_over_100k_use_the_higher_rate(self):
        short = cli.usage_cost("claude-haiku-5-5", 100_000, 1000, 0, 0, 0)
        self.assertAlmostEqual(short, 0.0105)
        self.assertAlmostEqual(cli.usage_cost("claude-haiku-5-5", 100_001, 1000, 0, 0, 0), 0.0525, places=4)
        self.assertAlmostEqual(cli.usage_cost("claude-haiku-5-5", 10, 1000, 0, 200_000, 0), 0.0125, places=3)

    def test_a_top_up_keeps_the_long_prompt_rate(self):
        hours, seen, live, sessions = {}, set(), {}, {}
        line = lambda out: reply("msg_1", TS, out=out, model="claude-haiku-5-5", inp=100_001, write=0, read=0)
        cli.tally_line(line(0), hours, seen, live, sessions)
        cli.tally_line(line(1000), hours, seen, live, sessions)
        self.assertAlmostEqual(hours[HOUR]["m"]["claude-haiku-5-5"][5], 0.0525, places=4)

    def test_other_models_have_no_such_tier(self):
        self.assertAlmostEqual(cli.usage_cost(MODEL, 200_000, 0, 0, 0, 0), 0.8)

    def test_fable_5_2_has_its_own_lower_price(self):
        # $8 / $40 per million, cache reads $0.20; not Fable 5's $10 / $50 / $1.
        self.assertAlmostEqual(cli.usage_cost("claude-fable-5-2", 1_000_000, 1_000_000, 0, 1_000_000, 0), 48.2)
        self.assertAlmostEqual(cli.usage_cost("claude-fable-5-1", 1_000_000, 0, 0, 0, 0), 10.0)


class MergeHoursTest(unittest.TestCase):
    def test_a_rescan_cannot_lose_hours_whose_logs_are_gone(self):
        old = {"100": {"m": {MODEL: [1, 2, 3, 4, 1, 0.5]}, "s": ["aaaaaaaa"]}}
        self.assertEqual(cli.merge_hours(old, {})["100"]["m"][MODEL], [1, 2, 3, 4, 1, 0.5])

    def test_a_rescan_raises_a_count_but_never_lowers_one(self):
        old = {"100": {"m": {MODEL: [1, 2, 3, 4, 1, 0.5]}, "s": ["aaaaaaaa"]}}
        new = {"100": {"m": {MODEL: [1, 9, 3, 2, 1, 0.75]}, "s": ["bbbbbbbb"]}}
        merged = cli.merge_hours(old, new)["100"]
        self.assertEqual(merged["m"][MODEL], [1, 9, 3, 4, 1, 0.75])
        self.assertEqual(sorted(merged["s"]), ["aaaaaaaa", "bbbbbbbb"])

    def test_recovered_hours_stay_marked(self):
        old = {"100": {"m": {MODEL: [1, 2, 3, 4, 1, 0.5]}, "s": [], "r": 1}}
        self.assertEqual(cli.merge_hours(old, {})["100"]["r"], 1)

    def test_sessions_merge_the_same_way(self):
        merged = cli.merge_sessions({"a": {"100": [5, 1.0, 1]}}, {"a": {"100": [9, 2.0, 1], "200": [1, 0.1, 1]}})
        self.assertEqual(merged, {"a": {"100": [9, 2.0, 1], "200": [1, 0.1, 1]}})


class MissingDaysTest(unittest.TestCase):
    def test_active_days_with_no_token_numbers(self):
        prompts = {str(utc_day("2026-09-10") + 3600): [2, ["a"]], str(utc_day("2026-09-11")): [1, ["b"]]}
        recs = [(utc_day("2026-09-11") + 43200, 5.0)]
        self.assertEqual(cli.missing_days(recs, prompts), [utc_day("2026-09-10") // 86400])

    def test_a_cowork_hour_does_not_hide_a_day_claude_code_lost(self):
        with tz("UTC"):
            now = utc_day("2026-10-15") + 3600
            archive = {"days": {}, "prompts": {str(utc_day("2026-09-10") + 3600): [2, ["a"]]}}
            desktop = hours_with("2026-09-10", 100, 2.0)
            out = cli.periods({}, archive, None, None, None, now, None, None, desktop)["list"]
            self.assertEqual(out["all"]["missing"], 1)

    def test_periods_say_how_many_of_their_days_are_partial(self):
        with tz("UTC"):
            now = utc_day("2026-10-15") + 3600
            hours = hours_with("2026-09-10", 100, 2.0)
            hours.update(hours_with("2026-09-11", 100, 2.0))
            hours.update(hours_with("2026-09-12", 100, 2.0))
            for t, h in hours.items():
                if int(t) // 86400 != utc_day("2026-09-12") // 86400:
                    h["r"] = 1
            archive = {"days": {"2026-09-11": {"m": {MODEL: [0, 0, 0, 1000, 0, 9.0]}, "a": [1, 1, 0], "e": 1}}, "prompts": {}}
            out = cli.periods(hours, archive, None, None, None, now, None, None)["list"]
            self.assertEqual(out["all"]["partial"], 1, "Sep 11 is whole: Claude Code's total replaced it")
            self.assertEqual(out["all"]["missing"], 0)

    def test_periods_say_how_many_of_their_days_are_missing(self):
        with tz("UTC"):
            now = utc_day("2026-10-15") + 3600
            archive = {"days": {"2026-10-01": {"m": {MODEL: [0, 0, 0, 10, 0, 1.0]}, "a": [1, 1, 0]}},
                       "prompts": {str(utc_day("2026-09-10")): [1, []], str(utc_day("2026-10-10")): [1, []]}}
            out = cli.periods({}, archive, None, None, None, now, None, None)["list"]
            self.assertEqual(out["all"]["missing"], 2)
            self.assertEqual(out["month"]["missing"], 1)
            self.assertEqual(out["today"]["missing"], 0)

    def test_today_is_never_missing(self):
        with tz("UTC"):
            now = utc_day("2026-10-15") + 3600
            archive = {"days": {}, "prompts": {str(now): [1, []]}}
            self.assertEqual(cli.periods({}, archive, None, None, None, now, None, None)["list"]["all"]["missing"], 0)


class DesktopValueTest(unittest.TestCase):
    def test_desktop_sessions_add_to_a_day_claude_codes_totals_cover(self):
        desktop = hours_with("2026-09-01", 100, 2.0)
        recs = cli.value_records({}, archive_with("2026-09-01", 1000, 9.0), desktop)
        self.assertEqual(sorted(d for _, d in recs), [2.0, 9.0])


class TaskSessionsTest(unittest.TestCase):
    def test_only_sessions_buddy_started_are_tallied(self):
        sessions = {"aaaaaaaa": {"100": [5, 1.0, 2], "200": [7, 0.5, 1]}, "bbbbbbbb": {"100": [9, 9.0, 9]}}
        self.assertEqual(cli.task_tally(sessions, {"aaaaaaaa"}),
                         {"100": [5, 1.0, 2, ["aaaaaaaa"]], "200": [7, 0.5, 1, ["aaaaaaaa"]]})

    def test_ids_come_from_each_tasks_record(self):
        with tempfile.TemporaryDirectory() as d:
            for name, record in (("one", {"session_id": "aaaaaaaa-1", "session_ids": ["cccccccc-3", "aaaaaaaa-1"]}),
                                 ("two", {"session_id": None}), ("three", {"session_id": "bbbbbbbb-2"})):
                os.mkdir(os.path.join(d, name))
                Path(d, name, "task.json").write_text(json.dumps(record))
            os.mkdir(os.path.join(d, "broken"))
            Path(d, "broken", "task.json").write_text("{not json")
            self.assertEqual(cli.task_session_ids(d), {"aaaaaaaa", "bbbbbbbb", "cccccccc"})

    def test_no_tasks_folder_means_no_ids(self):
        self.assertEqual(cli.task_session_ids("/nonexistent/buddy-tasks"), set())


class RunTest(unittest.TestCase):
    """Whole runs of the script against a made-up home folder."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.out = self.home / "Library" / "Application Support" / "claude-usage-widget"
        self.logs = self.home / ".claude" / "projects" / "-Users-me-work"
        self.logs.mkdir(parents=True)
        self.env = dict(os.environ, HOME=self.tmp.name, BUDDY_TASKS_DIR=str(self.home / "tasks"))
        self.env.pop("CLAUDE_CONFIG_DIR", None)

    def write_log(self, path, *lines):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(d) + "\n" for d in lines))

    def run_cli(self, *args, stdin=None):
        r = subprocess.run(["/usr/bin/python3", CLI, *args], env=self.env, capture_output=True, input=stdin)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        return json.loads(r.stdout)

    def tally(self):
        return json.loads((self.out / "tokens.json").read_text())

    def state(self):
        return json.loads((self.out / "tokens-state.json").read_text())

    def test_a_crash_between_checkpoint_and_ui_save_does_not_double_count(self):
        log = self.logs / "s.jsonl"
        self.write_log(log, reply("msg_1", TS, out=10))
        self.run_cli()
        self.write_log(log, reply("msg_1", TS, out=10), reply("msg_2", TS, out=20))
        script = """
import runpy, sys
module = runpy.run_path(sys.argv[1])
save = module['save']
def interrupted_save(path, obj):
    if path == module['TALLY']:
        raise RuntimeError('simulated crash before UI copy')
    save(path, obj)
module['main'].__globals__['save'] = interrupted_save
module['main']()
"""
        failed = subprocess.run(["/usr/bin/python3", "-c", script, CLI], env=self.env, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"simulated crash", failed.stderr)
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][4], 1, "the UI copy is still old")
        self.assertEqual(self.state()["tally"]["hours"][HOUR]["m"][MODEL][4], 2)
        self.run_cli()
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][1:5], [30, 4, 6, 2])
        self.assertEqual(self.tally(), self.state()["tally"], "the next run repairs the UI copy")

    def test_a_truncated_buddy_ledger_keeps_old_hours_without_recounting(self):
        agent = self.home / "agent"
        self.env["BUDDY_AGENT_DIR"] = str(agent)
        ledger = agent / "usage.jsonl"
        old = {"kind": "chat", "at": "2026-10-19T09:30:00", "models": {MODEL: [1, 2, 3, 4, 0]}}
        kept = dict(old, at="2026-10-20T09:30:00")
        self.write_log(ledger, old, kept)
        self.run_cli()
        before = self.tally()["buddy"]
        self.write_log(ledger, kept)
        self.run_cli()
        self.assertEqual(self.tally()["buddy"], before)
        self.run_cli()
        self.assertEqual(self.tally()["buddy"], before)

    def test_an_equal_size_replacement_buddy_ledger_is_read_from_the_start(self):
        agent = self.home / "agent"
        self.env["BUDDY_AGENT_DIR"] = str(agent)
        ledger = agent / "usage.jsonl"
        old = {"kind": "chat", "at": "2026-10-19T09:30:00", "models": {MODEL: [1, 2, 3, 4, 0]}}
        self.write_log(ledger, old)
        self.run_cli()
        replacement = agent / "replacement.jsonl"
        self.write_log(replacement, dict(old, at="2026-10-20T09:30:00"))
        self.assertEqual(replacement.stat().st_size, ledger.stat().st_size)
        replacement.replace(ledger)
        self.run_cli()
        self.assertEqual(len(self.tally()["buddy"]), 2)
        self.assertEqual(sum(h["n"] for h in self.tally()["buddy"].values()), 2)

    def test_a_new_same_hour_ledger_record_adds_to_retained_usage(self):
        agent = self.home / "agent"
        self.env["BUDDY_AGENT_DIR"] = str(agent)
        ledger = agent / "usage.jsonl"
        old = {"kind": "chat", "at": "2026-10-20T09:30:00", "models": {MODEL: [1, 20, 3, 4, 0]}}
        self.write_log(ledger, old)
        self.run_cli()
        replacement = agent / "replacement.jsonl"
        self.write_log(replacement, dict(old, models={MODEL: [1, 10, 3, 4, 0]}))
        replacement.replace(ledger)
        self.run_cli()
        hour = next(iter(self.tally()["buddy"].values()))
        self.assertEqual(hour["m"][MODEL][:5], [2, 30, 6, 8, 2])
        self.assertEqual(hour["n"], 2)
        self.run_cli("--rebuild")
        self.assertEqual(next(iter(self.tally()["buddy"].values())), hour)

    def test_a_copied_ledger_replays_each_occurrence_only_once(self):
        agent = self.home / "agent"
        self.env["BUDDY_AGENT_DIR"] = str(agent)
        ledger = agent / "usage.jsonl"
        entry = {"kind": "chat", "at": "2026-10-20T09:30:00", "models": {MODEL: [1, 2, 3, 4, 0]}}
        self.write_log(ledger, entry, entry)
        self.run_cli()
        before = self.tally()["buddy"]
        replacement = agent / "replacement.jsonl"
        self.write_log(replacement, entry, entry)
        replacement.replace(ledger)
        self.run_cli()
        self.assertEqual(self.tally()["buddy"], before)
        self.write_log(replacement, entry)
        replacement.replace(ledger)
        self.run_cli()
        self.assertEqual(self.tally()["buddy"], before)
        with ledger.open("a") as f:
            f.write(json.dumps(entry) + "\n")
        self.run_cli()
        self.assertEqual(self.tally()["buddy"], before, "restoring the old tail is still replay")
        with ledger.open("a") as f:
            f.write(json.dumps(entry) + "\n")
        self.run_cli()
        self.assertEqual(next(iter(self.tally()["buddy"].values()))["n"], 3)
        self.run_cli("--rebuild")
        self.assertEqual(next(iter(self.tally()["buddy"].values()))["n"], 3)

    def test_agent_dir_argument_overrides_environment_and_expands_tilde(self):
        ledger = self.home / "custom-agent" / "usage.jsonl"
        self.write_log(ledger, {"kind": "chat", "at": "2026-10-20T09:30:00", "models": {MODEL: [1, 2, 3, 4, 0]}})
        self.env["BUDDY_AGENT_DIR"] = str(self.home / "unused-agent")
        self.run_cli("--agent-dir", "~/custom-agent")
        self.assertEqual(sum(h["n"] for h in self.tally()["buddy"].values()), 1)

    def test_rebuild_fixes_what_is_on_disk_and_keeps_what_is_gone(self):
        self.out.mkdir(parents=True)
        gone = str(utc_day("2026-08-01"))
        (self.out / "tokens.json").write_text(json.dumps({"hours": {
            gone: {"m": {MODEL: [1, 2, 3, 4, 1, 0.5]}, "s": ["dddddddd"]},
            HOUR: {"m": {MODEL: [1, 8, 2, 3, 1, 0.1]}, "s": ["aaaaaaaa"]}}}))
        (self.out / "tokens-state.json").write_text(json.dumps({"v": cli.VERSION, "files": {}, "seen": ["x", "msg_1"]}))
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS, out=8), reply("msg_1", TS, out=3661))
        self.run_cli("--rebuild")
        hours = self.tally()["hours"]
        self.assertEqual(hours[gone]["m"][MODEL][:5], [1, 2, 3, 4, 1], "deleted log's tally survives")
        self.assertEqual(hours[HOUR]["m"][MODEL][1], 3661, "output corrected from the log")
        self.assertIn("x", self.state()["seen"])
        backups = list((self.out / "archive").glob("backup-rebuild-*/tokens.json"))
        self.assertEqual(len(backups), 1, "the old numbers are copied first")
        self.assertEqual(json.loads(backups[0].read_text())["hours"][HOUR]["m"][MODEL][1], 8)

    def test_rebuild_adds_a_new_reply_to_an_hour_whose_older_log_is_gone(self):
        self.out.mkdir(parents=True)
        (self.out / "tokens.json").write_text(json.dumps({"hours": {
            HOUR: {"m": {MODEL: [1, 100, 2, 3, 1, 0.1]}, "s": ["dddddddd"]}}}))
        (self.out / "tokens-state.json").write_text(json.dumps({"v": cli.VERSION, "files": {}, "seen": ["gone-reply"]}))
        self.write_log(self.logs / "s.jsonl", reply("msg_new", TS, out=50))
        for _ in range(2):  # and a second rebuild changes nothing
            self.run_cli("--rebuild")
            m = self.tally()["hours"][HOUR]["m"][MODEL]
            self.assertEqual(m[1], 150)
            self.assertEqual(m[4], 2)

    def test_rebuild_keeps_buddy_use_its_ledger_no_longer_holds(self):
        self.out.mkdir(parents=True)
        agent = self.home / "agent"
        agent.mkdir()
        self.env["BUDDY_AGENT_DIR"] = str(agent)
        (agent / "usage.jsonl").write_text(json.dumps({"kind": "chat", "at": "2026-10-20T09:30:00", "models": {
            "claude-haiku-5-5": [1, 2, 3, 4, 0]}}) + "\n")
        kept = {"m": {"claude-haiku-5-5": [10, 20, 30, 40, 5, 0.5]}, "k": {"quip": [100, 0.5]}, "n": 5}
        (self.out / "tokens.json").write_text(json.dumps({"hours": {}, "buddy": {"100": kept}}))
        (self.out / "tokens-state.json").write_text(json.dumps({"v": cli.VERSION, "files": {}, "seen": [], "buddy_offset": 9}))
        self.run_cli("--rebuild")
        buddy = self.tally()["buddy"]
        self.assertEqual(buddy["100"]["m"]["claude-haiku-5-5"][:4], [10, 20, 30, 40])
        self.assertEqual(len(buddy), 2, "and the ledger's own hour is there too")

    def test_a_log_with_strange_lines_is_still_read(self):
        path = self.logs / "s.jsonl"
        strange = ['["assistant", "usage"]', '"assistant usage"', '{"type": "assistant", "usage": 1, "message": []}',
                   json.dumps(reply(12345, TS)), json.dumps(reply("msg_bad", TS, out="many"))]
        path.write_text("\n".join(strange) + "\n" + json.dumps(reply("msg_1", TS, out=70)) + "\n")
        self.run_cli()
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][:5], [1, 70, 2, 3, 1])

    def test_tallies_it_cannot_read_are_left_alone(self):
        self.out.mkdir(parents=True)
        (self.out / "tokens.json").write_text('{"hours": {"1": {"m"')
        (self.out / "tokens-state.json").write_text(json.dumps({"v": cli.VERSION, "files": {}, "seen": ["x"]}))
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS))
        r = subprocess.run(["/usr/bin/python3", CLI], env=self.env, capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.out / "tokens.json").read_text(), '{"hours": {"1": {"m"', "a broken file isn't overwritten")
        self.assertEqual(self.state()["seen"], ["x"])

    def test_two_runs_at_once_leave_whole_files(self):
        self.write_log(self.logs / "s.jsonl", *[reply("msg_%d" % i, TS, out=i) for i in range(400)])
        runs = [subprocess.Popen(["/usr/bin/python3", CLI], env=self.env, stdout=subprocess.DEVNULL) for _ in range(4)]
        for run in runs:
            self.assertEqual(run.wait(), 0)
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][4], 400)
        self.assertEqual(list(self.out.glob("*.tmp")), [])

    def test_an_older_state_upgrades_itself_once(self):
        self.out.mkdir(parents=True)
        log = self.logs / "s.jsonl"
        self.write_log(log, reply("msg_1", TS, out=8), reply("msg_1", TS, out=3661))
        size = log.stat().st_size
        (self.out / "tokens.json").write_text(json.dumps({"hours": {HOUR: {"m": {MODEL: [1, 8, 2, 3, 1, 0.1]}, "s": []}}}))
        (self.out / "tokens-state.json").write_text(json.dumps({"files": {str(log): size}, "seen": []}))
        self.run_cli()
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][1], 3661)
        self.assertEqual(self.state()["v"], cli.VERSION)
        self.run_cli()
        self.assertEqual(len(list((self.out / "archive").glob("backup-rebuild-*"))), 1)
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][4], 1, "not counted twice")

    def test_a_first_run_has_nothing_to_back_up(self):
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS))
        self.run_cli()
        self.assertEqual(list(self.out.glob("archive/backup-*")), [])

    def test_a_scan_spanning_two_runs_tops_up(self):
        log = self.logs / "s.jsonl"
        now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        self.write_log(log, reply("msg_1", now, out=8))
        self.run_cli()
        with open(log, "a") as f:
            f.write(json.dumps(reply("msg_1", now, out=900)) + "\n")
        self.run_cli()
        row = next(iter(self.tally()["hours"].values()))
        self.assertEqual(row["m"][MODEL][1], 900)
        self.assertEqual(row["m"][MODEL][4], 1)

    def test_desktop_cowork_logs_are_read_apart_from_claude_codes(self):
        cowork = (self.home / "Library" / "Application Support" / "Claude" / "local-agent-mode-sessions" /
                  "org" / "user" / "local_1" / ".claude" / "projects" / "-outputs" / "s.jsonl")
        self.write_log(cowork, reply("msg_9", TS, out=40))
        self.write_log(cowork.parent.parent.parent.parent / "audit.jsonl", reply("msg_9", TS, out=40))
        self.run_cli()
        t = self.tally()
        self.assertEqual(t["hours"], {})
        self.assertEqual(t["desktop"][HOUR]["m"][MODEL][:5], [1, 40, 2, 3, 1])

    def test_import_a_folder_marks_its_hours_recovered(self):
        backup = self.home / "backup"
        self.write_log(backup / "sessions" / "x" / "s.jsonl", reply("msg_1", TS, out=8), reply("msg_1", TS, out=70))
        self.run_cli("--import", str(backup))
        row = self.tally()["hours"][HOUR]
        self.assertEqual(row["r"], 1)
        self.assertEqual(row["m"][MODEL][1], 70)
        self.run_cli("--import", str(backup))
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][4], 1, "a second import adds nothing")
        self.assertTrue(list(self.out.glob("archive/backup-import-*/tokens.json")))

    def test_importing_again_after_a_rebuild_adds_nothing(self):
        now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        self.write_log(self.logs / "s.jsonl", reply("msg_1", now, out=10))
        backup = self.home / "backup"
        self.write_log(backup / "s.jsonl", reply("msg_1", now, out=100))
        self.run_cli()
        self.run_cli("--import", str(backup))
        self.run_cli("--rebuild")
        self.run_cli("--import", str(backup))
        self.assertEqual(next(iter(self.tally()["hours"].values()))["m"][MODEL][1], 100)

    def test_import_skips_replies_already_counted(self):
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS, out=70))
        self.run_cli()
        backup = self.home / "backup"
        self.write_log(backup / "s.jsonl", reply("msg_1", TS, out=70))
        self.run_cli("--import", str(backup))
        row = self.tally()["hours"][HOUR]
        self.assertEqual(row["m"][MODEL][4], 1)
        self.assertNotIn("r", row)

    def test_import_a_tar_from_stdin_reads_numbers_only(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            body = (json.dumps(reply("msg_1", TS, out=70)) + "\n").encode()
            info = tarfile.TarInfo("old/sessions/s.jsonl")
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
        self.run_cli("--import", "-", stdin=buf.getvalue())
        self.assertEqual(self.tally()["hours"][HOUR]["m"][MODEL][1], 70)
        self.assertEqual(sorted(p.name for p in self.home.iterdir() if p.name not in (".claude", "Library", "tasks")), [])

    def saved_cfg(self, session, cost=7.5, model="claude-opus-4-8[1m]"):
        return {"projects": {"/work": {"lastSessionId": session, "lastCost": cost, "lastModelUsage": {model: {
            "inputTokens": 10, "outputTokens": 20, "cacheCreationInputTokens": 30,
            "cacheReadInputTokens": 40, "costUSD": cost}}}}}

    def prompts_file(self, session, stamp):
        (self.home / ".claude" / "history.jsonl").write_text(
            json.dumps({"display": "not kept", "timestamp": stamp * 1000, "sessionId": session}) + "\n")

    def test_a_saved_session_total_lands_on_its_first_prompt(self):
        stamp = utc_day("2026-06-25") + 7200
        self.prompts_file("eeeeeeee-5555", stamp)
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("eeeeeeee-5555")))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(backup))
        self.run_cli("--history", "--import", str(backup))
        row = self.tally()["hours"][str(stamp)]
        self.assertEqual(row["r"], 1)
        self.assertEqual(row["m"]["claude-opus-4-8"], [10, 20, 30, 40, 0, 7.5])
        self.assertIn("eeeeeeee", row["s"])

    def test_history_import_dates_saved_totals_on_the_first_run(self):
        stamp = utc_day("2026-06-25") + 7200
        self.prompts_file("eeeeeeee-5555", stamp)
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("eeeeeeee-5555")))
        first = self.run_cli("--history", "--import", str(backup))
        self.assertEqual(first["imported"]["session_totals"], 1)
        self.assertEqual(self.tally()["hours"][str(stamp)]["m"]["claude-opus-4-8"], [10, 20, 30, 40, 0, 7.5])
        second = self.run_cli("--history", "--import", str(backup))
        self.assertEqual(second["imported"]["session_totals"], 0)

    def test_a_saved_total_is_skipped_when_the_sessions_replies_are_in(self):
        self.prompts_file("aaaaaaaa-1111-2222", utc_day("2026-10-20"))
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS, out=70))
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("aaaaaaaa-1111-2222")))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(backup))
        self.assertEqual(self.tally()["hours"][HOUR]["m"].keys(), {MODEL})
        self.assertEqual(len(self.tally()["hours"]), 1)

    def test_a_saved_total_stays_out_of_a_day_that_is_already_whole(self):
        # a resumed session keeps its replies under its earlier id, so the id alone can't tell
        self.prompts_file("eeeeeeee-5555", utc_day("2026-10-20") + 3600)
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS, out=70))
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("eeeeeeee-5555")))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(backup))
        self.assertEqual(list(self.tally()["hours"]), [HOUR])

    def test_a_saved_total_stays_out_of_a_day_claude_codes_totals_cover(self):
        stamp = utc_day("2026-09-04") + 3600
        self.prompts_file("eeeeeeee-5555", stamp)
        (self.home / ".claude" / "stats-cache.json").write_text(json.dumps({
            "dailyModelTokens": [{"date": "2026-09-04", "tokensByModel": {MODEL: 500}}],
            "dailyActivity": [{"date": "2026-09-04", "messageCount": 3, "sessionCount": 1, "toolCallCount": 0}]}))
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("eeeeeeee-5555")))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(backup))
        self.assertEqual(self.tally()["hours"], {})

    def test_a_saved_total_can_join_a_day_only_a_backup_has_filled(self):
        self.prompts_file("eeeeeeee-5555", utc_day("2026-10-20") + 3600)
        backup = self.home / "backup"
        self.write_log(backup / "s.jsonl", reply("msg_1", TS, out=70))
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("eeeeeeee-5555")))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(backup))
        self.assertEqual(len(self.tally()["hours"]), 2)

    def test_a_saved_session_with_no_numbers_leaves_no_empty_hour(self):
        self.prompts_file("eeeeeeee-5555", utc_day("2026-06-25") + 3600)
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(
            {"projects": {"/work": {"lastSessionId": "eeeeeeee-5555", "lastCost": 0, "lastModelUsage": {}}}}))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(backup))
        self.assertEqual(self.tally()["hours"], {}, "an empty row would hide a day with no numbers")

    def test_replies_found_after_a_saved_total_are_not_added_on_top(self):
        stamp = utc_day("2026-06-25") + 7200
        self.prompts_file("eeeeeeee-5555", stamp)
        saved, logs = self.home / "saved", self.home / "logs-backup"
        saved.mkdir()
        (saved / ".claude.json").write_text(json.dumps(self.saved_cfg("eeeeeeee-5555")))
        self.write_log(logs / "s.jsonl", reply("msg_7", "2026-06-25T02:30:00.000Z", out=900, session="eeeeeeee-5555"))
        self.run_cli("--history")
        self.run_cli("--history", "--import", str(saved))
        before = self.tally()["hours"]
        self.run_cli("--history", "--import", str(logs))
        self.assertEqual(self.tally()["hours"], before)

    def test_a_saved_total_with_no_date_is_left_out(self):
        backup = self.home / "backup"
        backup.mkdir()
        (backup / ".claude.json").write_text(json.dumps(self.saved_cfg("ffffffff-6666")))
        self.run_cli("--history", "--import", str(backup))
        self.assertEqual(self.tally()["hours"], {})

    def test_task_sessions_are_shown_apart_and_not_added_on_top(self):
        task = self.home / "tasks" / "one"
        task.mkdir(parents=True)
        (task / "task.json").write_text(json.dumps({"session_id": "aaaaaaaa-1111-2222"}))
        self.write_log(self.logs / "s.jsonl", reply("msg_1", TS, out=70),
                       reply("msg_2", TS, out=5, session="bbbbbbbb-3333"))
        self.run_cli()
        t = self.tally()
        self.assertEqual(t["tasks"][HOUR][:3][0], 1 + 70 + 2 + 3)
        self.assertEqual(t["tasks"][HOUR][3], ["aaaaaaaa"])
        self.assertEqual(t["hours"][HOUR]["m"][MODEL][1], 75, "hours still hold every session once")
        self.assertEqual(t["buddy"], {}, "a task session isn't Buddy's own use")


if __name__ == "__main__":
    unittest.main()
