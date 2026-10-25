"""tools/whatsnew: release content validation and version stamping.

Run: /usr/bin/python3 -m unittest tests.test_whatsnew -v
"""
import copy
import importlib.machinery
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "whatsnew"
_loader = importlib.machinery.SourceFileLoader("whatsnew_tool", str(TOOL))
_spec = importlib.util.spec_from_loader("whatsnew_tool", _loader)
check = importlib.util.module_from_spec(_spec)
_loader.exec_module(check)


class CheckWhatsNew(unittest.TestCase):
    def release(self):
        return {"version": "next", "title": "Hello", "summary": "See what's new.",
                "hero": {"skin": "vampire", "wave": True, "lines": ["Hello!"]},
                "slides": [{"title": "Pick a skin", "text": "Right-click Buddy and pick Skin.",
                            "scene": {"kind": "buddy", "skin": "witch", "wave": False,
                                      "lines": ["Hi!"]}}],
                "notes": {"new": ["New skins."], "better": [], "fixed": []}}

    def data(self):
        return {"releases": [self.release()]}

    def errors(self, data):
        return check.check(data, ROOT)

    def test_shipped_file_is_valid(self):
        data = json.loads((ROOT / "whatsnew" / "releases.json").read_text())
        self.assertEqual(self.errors(data), [])

    def test_title_too_long(self):
        data = self.data()
        data["releases"][0]["title"] = "x" * 41
        self.assertEqual(len(self.errors(data)), 1)
        self.assertIn("title", self.errors(data)[0])

    def test_unknown_skin(self):
        data = self.data()
        data["releases"][0]["hero"]["skin"] = "nope"
        self.assertTrue(any("nope" in e for e in self.errors(data)))

    def test_two_next_entries(self):
        data = self.data()
        data["releases"].append(copy.deepcopy(data["releases"][0]))
        self.assertTrue(any("next" in e for e in self.errors(data)))

    def test_duplicate_versions(self):
        data = self.data()
        data["releases"][0]["version"] = "1.7.0"
        data["releases"].append(copy.deepcopy(data["releases"][0]))
        self.assertTrue(any("duplicate" in e for e in self.errors(data)))

    def test_bad_version_string(self):
        data = self.data()
        data["releases"][0]["version"] = "1.7"
        self.assertTrue(any("version" in e for e in self.errors(data)))

    def test_too_many_slides(self):
        data = self.data()
        data["releases"][0]["slides"] *= 9
        self.assertTrue(any("slides" in e for e in self.errors(data)))

    def test_missing_image(self):
        data = self.data()
        data["releases"][0]["slides"][0]["scene"] = {"kind": "image", "file": "absent.png"}
        self.assertTrue(any("absent.png" in e for e in self.errors(data)))

    def test_unknown_scene_kind_ok(self):
        data = self.data()
        data["releases"][0]["slides"][0]["scene"] = {"kind": "future"}
        self.assertEqual(self.errors(data), [])

    def test_stamp_next(self):
        data, changed = check.stamp(self.data(), "1.7.0")
        self.assertTrue(changed)
        self.assertEqual(data["releases"][0]["version"], "1.7.0")

    def test_stamp_without_next_is_noop(self):
        data = self.data()
        data["releases"][0]["version"] = "1.6.0"
        result, changed = check.stamp(data, "1.7.0")
        self.assertFalse(changed)
        self.assertEqual(result, data)

    def test_stamp_conflict_raises(self):
        data = self.data()
        data["releases"].append({**self.release(), "version": "1.7.0"})
        with self.assertRaises(ValueError):
            check.stamp(data, "1.7.0")

    def test_stamp_rejects_bad_version(self):
        with self.assertRaises(ValueError):
            check.stamp(self.data(), "1.7")

    def test_cli_stamp_rewrites_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "releases.json"
            path.write_text(json.dumps(self.data()))
            result = subprocess.run(["/usr/bin/python3", str(TOOL), "stamp", "1.7.0", str(path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(path.read_text())["releases"][0]["version"], "1.7.0")


if __name__ == "__main__":
    unittest.main()
