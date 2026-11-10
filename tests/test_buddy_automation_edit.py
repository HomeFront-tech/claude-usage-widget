"""The desktop watch commands share the brain tools' job-file transaction."""
import json
import io
import os
import runpy
from contextlib import redirect_stdout
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
import buddy_agent


class WatchEditTest(unittest.TestCase):
    def test_stalled_lock_gives_up_without_changing_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            agent_dir = Path(directory)
            (agent_dir / "automations.json").write_text('[{"id":"existing"}]')
            with mock.patch.object(buddy_agent, "AGENT", agent_dir), \
                 mock.patch.object(buddy_agent.fcntl, "flock", side_effect=BlockingIOError) as flock, \
                 mock.patch.object(buddy_agent.time, "monotonic", side_effect=[0, 1, 5]), \
                 mock.patch.object(buddy_agent.time, "sleep") as sleep:
                with self.assertRaisesRegex(TimeoutError, "Watch changes are busy"):
                    buddy_agent.mutate_jobs({"action": "add_watch", "job": {"id": "new"}})
                self.assertEqual(buddy_agent.load_jobs(), [{"id": "existing"}])
                self.assertEqual(flock.call_count, 2)
                self.assertEqual(flock.call_args.args[1], buddy_agent.fcntl.LOCK_EX | buddy_agent.fcntl.LOCK_NB)
                sleep.assert_called_once_with(0.05)

    def test_edit_cli_only_exposes_lock_timeout_message(self):
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / "request.json"
            request.write_text('{"action":"add_watch","job":{"id":"test"}}')
            for failure, message in ((BlockingIOError(), "Watch changes are busy; try again shortly."),
                                     (PermissionError("private path and details"), "Couldn't change the watch."),
                                     (RuntimeError("private runtime details"), "Couldn't change the watch.")):
                out = io.StringIO()
                with mock.patch.dict(os.environ, BUDDY_AGENT_DIR=directory), \
                     mock.patch.object(sys, "argv", [buddy_agent.__file__, "edit-jobs", str(request)]), \
                     mock.patch.object(buddy_agent.fcntl, "flock", side_effect=failure), \
                     mock.patch.object(buddy_agent.time, "monotonic", side_effect=[0, 6]), \
                     redirect_stdout(out), self.assertRaises(SystemExit):
                    runpy.run_path(buddy_agent.__file__, run_name="__main__")
                self.assertEqual(json.loads(out.getvalue()), {"error": message})
            request.write_text('{"action":"unknown private value"}')
            out = io.StringIO()
            with mock.patch.dict(os.environ, BUDDY_AGENT_DIR=directory), \
                 mock.patch.object(sys, "argv", [buddy_agent.__file__, "edit-jobs", str(request)]), \
                 redirect_stdout(out), self.assertRaises(SystemExit):
                runpy.run_path(buddy_agent.__file__, run_name="__main__")
            self.assertEqual(json.loads(out.getvalue()), {"error": "Couldn't change the watch."})

    def test_watch_add_waits_for_brain_edit_and_preserves_it(self):
        with tempfile.TemporaryDirectory() as directory:
            agent_dir = Path(directory)
            loaded = threading.Event()
            release = threading.Event()
            errors = []

            def brain_edit():
                try:
                    with buddy_agent.edit_jobs() as jobs:
                        loaded.set()
                        if not release.wait(2):
                            raise AssertionError("watch edit never attempted")
                        jobs.append({"id": "brain", "trigger": {"type": "daily_at"}})
                except Exception as exc:
                    errors.append(exc)

            def watch_edit():
                try:
                    buddy_agent.mutate_jobs({"action": "add_watch", "job":
                        {"id": "watch", "trigger": {"type": "every", "minutes": 30}}})
                except Exception as exc:
                    errors.append(exc)

            with mock.patch.object(buddy_agent, "AGENT", agent_dir):
                first = threading.Thread(target=brain_edit)
                second = threading.Thread(target=watch_edit)
                first.start()
                self.assertTrue(loaded.wait(2))
                second.start()
                time.sleep(0.05)
                release.set()
                first.join(3)
                second.join(3)
                self.assertFalse(first.is_alive() or second.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual({job["id"] for job in buddy_agent.load_jobs()}, {"brain", "watch"})

    def test_remove_and_expire_preserve_other_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(buddy_agent, "AGENT", Path(directory)):
                with buddy_agent.edit_jobs() as jobs:
                    jobs.extend([
                        {"id": "old", "name": "Old", "trigger": {"type": "every", "until": 10}},
                        {"id": "new", "name": "New", "trigger": {"type": "every", "until": 100}},
                        {"id": "daily", "trigger": {"type": "daily_at"}},
                    ])
                self.assertEqual(buddy_agent.mutate_jobs({"action": "expire", "now": 20}), {"removed": 1})
                self.assertEqual(buddy_agent.mutate_jobs({"action": "remove_watch", "id": "new"})["name"], "New")
                self.assertEqual([job["id"] for job in buddy_agent.load_jobs()], ["daily"])


if __name__ == "__main__":
    unittest.main()
