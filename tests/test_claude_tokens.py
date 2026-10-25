"""bin/claude-tokens: the card's API value per period.

Run: /usr/bin/python3 -m unittest tests.test_claude_tokens -v
"""
import calendar
import importlib.machinery
import importlib.util
import io
import json
import os
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
            self.assertEqual(set(v), {"from", "value", "buddy", "paid", "spread", "rolling"})
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
                    mock.patch("sys.argv", ["claude-tokens", "--session-start", "1792900000", "--plan-price", "100"]), \
                    redirect_stdout(out):
                cli.main()
            res = json.loads(out.getvalue())
            self.assertTrue(res["ok"])
            self.assertEqual(res["periods"]["list"]["session"]["from"], 1792900000)
            self.assertIsNone(res["periods"]["first"])
            saved = json.load(open(os.path.join(d, "tokens.json")))
            self.assertNotIn("periods", saved)


if __name__ == "__main__":
    unittest.main()
