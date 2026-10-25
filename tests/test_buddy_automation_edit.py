"""The desktop watch commands share the brain tools' job-file transaction."""
import json
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
