"""app/dockmenu.sh and app/dockmenu.m: the Dock menu's "Check for Updates..." in
Claude Buddy.app runs Buddy's own update check.

Builds the library into a temp folder (never app/) and loads it into a stand-in for the
app's engine (tests/fakes/dockmenu_harness.m): a Dock menu and an app menu whose
"Check for Updates..." is wired to a fake Sparkle. Skipped without Apple's Command Line
Tools. Run: /usr/bin/python3 -m unittest tests.test_dock_menu -v
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = subprocess.run(["/usr/bin/xcode-select", "-p"], capture_output=True).returncode == 0 \
    and os.access("/usr/bin/clang", os.X_OK)


@unittest.skipUnless(TOOLS, "needs Apple's Command Line Tools")
class DockMenu(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="buddy-dock-")
        cls.out = Path(cls.tmp.name)
        cls.build = subprocess.run([str(ROOT / "app/dockmenu.sh"), "--if-stale", str(cls.out)],
                                   capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        harness = cls.out / "harness"
        subprocess.run(["/usr/bin/clang", "-fobjc-arc", "-framework", "Cocoa", "-o", str(harness),
                        str(ROOT / "tests/fakes/dockmenu_harness.m")], check=True, capture_output=True, timeout=120)
        run = subprocess.run([str(harness), str(cls.out / "dockmenu.dylib")], capture_output=True, text=True,
                             stdin=subprocess.DEVNULL, timeout=30)
        cls.result = json.loads(run.stdout or "{}")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_builds_for_both_kinds_of_mac(self):
        self.assertEqual(self.build.returncode, 0, self.build.stderr)
        archs = subprocess.run(["/usr/bin/lipo", "-archs", str(self.out / "dockmenu.dylib")],
                               capture_output=True, text=True).stdout.split()
        self.assertEqual(sorted(archs), ["arm64", "x86_64"])

    def test_second_build_does_nothing_when_nothing_changed(self):
        before = (self.out / "dockmenu.dylib").stat().st_mtime_ns
        again = subprocess.run([str(ROOT / "app/dockmenu.sh"), "--if-stale", str(self.out)],
                               capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(again.returncode, 0)
        self.assertEqual((self.out / "dockmenu.dylib").stat().st_mtime_ns, before)
        self.assertFalse((self.out / "dockmenu.tmp").exists())

    def test_every_check_for_updates_item_goes_to_buddy(self):
        r = self.result
        self.assertNotIn("error", r)
        self.assertEqual(r["results"], 1, "hands Lua one value")
        self.assertEqual(r["found"], 2, "the Dock menu's item and the app menu's")
        self.assertEqual(r["found_again"], 2, "calling it again after a reload is fine")
        self.assertTrue(r["retargeted"])
        self.assertTrue(r["app_menu_too"])
        self.assertTrue(r["enabled"])

    def test_other_items_and_sparkle_are_left_alone(self):
        self.assertTrue(self.result["reload_untouched"])
        self.assertEqual(self.result["sparkle_calls"], 0)

    def test_a_click_posts_the_apps_notification(self):
        self.assertTrue(self.result["sent"])
        self.assertEqual(self.result["heard"], 1)


if __name__ == "__main__":
    unittest.main()
