"""tools/check-skins: what a skin file may hold.

Run: /usr/bin/python3 -m unittest tests.test_skins -v
"""
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader("check_skins", str(ROOT / "tools" / "check-skins"))
_spec = importlib.util.spec_from_loader("check_skins", _loader)
check = importlib.util.module_from_spec(_spec)
_loader.exec_module(check)


class CheckSkins(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, skin):
        path = self.dir / f"{name}.json"
        path.write_text(json.dumps(skin))
        return path

    def errors(self, **extra):
        skin = {"id": "test", "name": "Test", "group": "outfits"}
        skin.update(extra)
        return check.check_file(self.write("test", skin))

    def test_classic_is_clean(self):
        self.assertEqual(check.check_file(ROOT / "skins" / "classic.json"), [])

    def test_id_must_match_filename(self):
        path = self.write("other", {"id": "test", "name": "Test", "group": "outfits"})
        self.assertTrue(any("filename" in e for e in check.check_file(path)))

    def test_unknown_group(self):
        self.assertTrue(self.errors(group="spooky"))

    def test_unknown_color_name(self):
        self.assertTrue(self.errors(top=[[0, -1, 2, 1, "chartreuse"]]))

    def test_hex_colors_ok(self):
        self.assertEqual(self.errors(top=[[0, -1, 2, 1, "#a1b2c3"], [2, -1, 2, 1, "#a1b2c3cc"]]), [])

    def test_palette_and_base_colors_ok(self):
        self.assertEqual(self.errors(palette={"hat": "#3d2459"}, top=[[0, -1, 2, 1, "hat"], [3, -1, 1, 1, "gold"]]), [])

    def test_rect_must_be_ints(self):
        self.assertTrue(self.errors(top=[[0.5, -1, 2, 1, "eye"]]))
        self.assertTrue(self.errors(top=[[0, -1, True, 1, "eye"]]))

    def test_rect_out_of_bounds(self):
        self.assertTrue(self.errors(top=[[-7, 0, 1, 1, "eye"]]))
        self.assertTrue(self.errors(top=[[18, 0, 4, 1, "eye"]]))
        self.assertTrue(self.errors(top=[[0, -10, 1, 1, "eye"]]))
        self.assertEqual(self.errors(top=[[-6, -9, 27, 22, "eye"]]), [])

    def test_bad_animated_layer(self):
        self.assertTrue(self.errors(hand={"fps": 0, "frames": [[[15, 5, 1, 1, "grey"]]]}))
        self.assertTrue(self.errors(hand={"fps": 3, "frames": []}))
        self.assertEqual(self.errors(hand={"fps": 3, "frames": [[[15, 5, 1, 1, "grey"]], [[15, 4, 1, 1, "grey"]]]}), [])

    def test_legs_false_ok(self):
        self.assertEqual(self.errors(legs=False), [])
        self.assertEqual(self.errors(legs=None), [])

    def test_unknown_reaction_key(self):
        self.assertTrue(self.errors(reactions={"sneeze": {"glyphs": ["!"]}}))

    def test_unknown_reaction_field(self):
        self.assertTrue(self.errors(reactions={"shaken": {"sparkle": 3}}))
        self.assertTrue(self.errors(reactions={"shaken": {"from": "floor"}}))
        self.assertEqual(self.errors(reactions={"shaken": {"glyphs": ["👻"], "color": "white", "from": "sky"}}), [])

    def test_line_too_long(self):
        self.assertTrue(self.errors(lines={"click": ["x" * 41, "ok"]}))
        self.assertEqual(self.errors(lines={"click": ["x" * 40, "ok"]}), [])

    def test_duplicate_ids(self):
        a = self.write("test", {"id": "test", "name": "A", "group": "outfits"})
        sub = self.dir / "more"
        sub.mkdir()
        b = sub / "test.json"
        b.write_text(json.dumps({"id": "test", "name": "B", "group": "outfits"}))
        report = check.check_all([a, b])
        self.assertTrue(any("duplicate" in e for e in report[str(b)]))

    def test_bad_json(self):
        path = self.dir / "test.json"
        path.write_text("{nope")
        self.assertTrue(check.check_file(path))

    def test_nan_rejected(self):
        path = self.dir / "test.json"
        path.write_text('{"id": "test", "name": "T", "group": "outfits", "float": NaN}')
        self.assertTrue(check.check_file(path))

    def test_reaction_ranges(self):
        self.assertTrue(self.errors(reactions={"shaken": {"life": 50}}))
        self.assertTrue(self.errors(reactions={"shaken": {"vy": -500}}))
        self.assertTrue(self.errors(reactions={"shaken": {"spread": 300}}))
        self.assertTrue(self.errors(reactions={"shaken": {"grow": 40}}))
        self.assertEqual(self.errors(reactions={"shaken": {"life": 2, "vy": -30, "vx": 7, "spread": 60, "grow": 8}}), [])

    def test_glyphs_needed_without_base_emitter(self):
        self.assertTrue(self.errors(reactions={"wave": {"color": "white"}}))
        self.assertEqual(self.errors(reactions={"wave": {"glyphs": ["👋"]}}), [])
        self.assertEqual(self.errors(reactions={"joy": {"color": "white"}}), [])

    def test_repo_skins_are_clean(self):
        report = check.check_all(sorted((ROOT / "skins").glob("*.json")))
        self.assertEqual({p: e for p, e in report.items() if e}, {})


if __name__ == "__main__":
    unittest.main()
