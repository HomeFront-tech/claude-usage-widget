"""tools/check-skits: every skit rule and the shipped files.

Run: /usr/bin/python3 -m unittest tests.test_skits -v
"""
import copy
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader("check_skits", str(ROOT / "tools" / "check-skits"))
_spec = importlib.util.spec_from_loader("check_skits", _loader)
check = importlib.util.module_from_spec(_spec)
_loader.exec_module(check)

SPRITE = {"pixel": 3, "colors": {"X": "dark"},
          "anims": {"idle": {"frames": [["XX", "XX"]]}}}
SKIT = {"id": "test", "name": "Test", "group": "bats", "length": 4,
        "actors": [{"sprite": "dot", "layer": "front", "keys": [
            {"t": 0, "x": 1, "y": 2}, {"t": 4, "x": 3, "y": 4}]}],
        "buddy": [{"t": 1, "say": "Boo!"}]}


class CheckSkits(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.write("sprites", {"dot": SPRITE})

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, stem, value):
        path = self.dir / f"{stem}.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def errors(self, mutate=None, **extra):
        skit = copy.deepcopy(SKIT)
        skit.update(extra)
        if mutate:
            mutate(skit)
        return check.check_file(self.write("test", skit))

    def has(self, phrase, mutate=None, **extra):
        errs = self.errors(mutate, **extra)
        self.assertTrue(any(phrase in e for e in errs), errs)

    def test_valid_fixture(self):
        self.assertEqual(self.errors(), [])

    def test_readable_json(self):
        path = self.dir / "test.json"
        path.write_text("{broken", encoding="utf-8")
        self.assertIn("not readable JSON", check.check_file(path)[0])
        path.write_text('{"length": NaN}', encoding="utf-8")
        self.assertIn("not readable JSON", check.check_file(path)[0])
        path.write_text('{"length": Infinity}', encoding="utf-8")
        self.assertIn("not readable JSON", check.check_file(path)[0])
        path.write_text('{"length": 1e999}', encoding="utf-8")
        self.assertIn("not readable JSON", check.check_file(path)[0])

    def test_sprite_pixel(self):
        for pixel in (0, 9, 2.5, True):
            self.write("sprites", {"dot": {**SPRITE, "pixel": pixel}})
            self.assertIn("pixel", str(check.check_file(self.dir / "sprites.json")))

    def test_sprite_colors(self):
        for colors in ({".": "dark"}, {"XX": "dark"}, {"X": "chartreuse"}, {"X": "#nope"}):
            self.write("sprites", {"dot": {**SPRITE, "colors": colors}})
            self.assertTrue(check.check_file(self.dir / "sprites.json"))
        self.write("sprites", {"dot": {**SPRITE, "colors": {"X": "#aabbccdd"}}})
        self.assertEqual(check.check_file(self.dir / "sprites.json"), [])

    def test_sprite_anims_and_fps(self):
        for anims in ({}, {"idle": {"fps": 13, "frames": [["X"]]}}, {"idle": {"frames": []}}):
            self.write("sprites", {"dot": {**SPRITE, "anims": anims}})
            self.assertTrue(check.check_file(self.dir / "sprites.json"))

    def test_sprite_frame_rows_size_and_colors(self):
        for rows in (["X", "XX"], ["X" * 25], ["X"] * 25, ["Y"]):
            self.write("sprites", {"dot": {**SPRITE, "anims": {"idle": {"frames": [rows]}}}})
            self.assertTrue(check.check_file(self.dir / "sprites.json"))

    def test_anti_flash(self):
        frames = [["XXXX"], ["X..."]]
        self.write("sprites", {"dot": {**SPRITE, "anims": {"idle": {"fps": 4, "frames": frames}}}})
        self.assertIn("anti-flash", str(check.check_file(self.dir / "sprites.json")))
        self.write("sprites", {"dot": {**SPRITE, "anims": {"idle": {"fps": 3, "frames": frames}}}})
        self.assertEqual(check.check_file(self.dir / "sprites.json"), [])

    def test_local_sprites(self):
        self.has("pixel", sprites={"local": {**SPRITE, "pixel": 0}})
        self.assertEqual(self.errors(sprites={"dot": SPRITE}), [])

    def test_id_filename(self):
        self.has("filename", id="other")

    def test_name_length(self):
        self.has("name", name="")
        self.has("name", name="x" * 31)

    def test_group(self):
        self.has("group", group="other")

    def test_length(self):
        self.has("length", length=0)
        self.has("length", length=31)

    def test_weights(self):
        self.has("weight", weight=-1)
        self.has("eveningWeight", eveningWeight=-1)
        self.assertEqual(self.errors(weight=0, eveningWeight=0), [])

    def test_needs(self):
        self.has("needs", needs=["moon"])
        self.assertEqual(self.errors(needs=["pail", "evening"]), [])

    def test_next_target(self):
        self.has("next.skit", next={"skit": "missing", "after": 1})
        self.write("target", {**SKIT, "id": "target"})
        self.assertEqual(self.errors(next={"skit": "target", "after": 1}), [])

    def test_next_after_and_chance(self):
        self.has("next.after", next={"skit": "test", "after": [60, 40]})
        self.has("next.after", next={"skit": "test", "after": 151})
        self.has("next.chance", next={"skit": "test", "after": 1, "chance": 0})
        self.assertEqual(self.errors(next={"skit": "test", "after": [40, 60], "chance": 1}), [])

    def test_unknown_keys(self):
        self.has("unknown field", surprise=1)
        self.has("unknown field", mutate=lambda s: s["actors"][0].update(extra=1))
        self.has("unknown field", mutate=lambda s: s["buddy"][0].update(extra=1))

    def test_actor_sprite_layer(self):
        self.has("unknown sprite", mutate=lambda s: s["actors"][0].update(sprite="missing"))
        self.has("layer", mutate=lambda s: s["actors"][0].update(layer="sky"))

    def test_actor_keys_order_and_time(self):
        self.has("non-empty", mutate=lambda s: s["actors"][0].update(keys=[]))
        self.has("strictly ascending", mutate=lambda s: s["actors"][0]["keys"][1].update(t=0))
        self.has("keys[1].t", mutate=lambda s: s["actors"][0]["keys"][1].update(t=5))

    def test_actor_position(self):
        self.has("position needs numeric x and y", mutate=lambda s: s["actors"][0]["keys"][0].pop("x"))
        self.has("first key needs a position", mutate=lambda s: s["actors"][0]["keys"][0].clear() or
                 s["actors"][0]["keys"][0].update(t=0))
        self.has("position cannot mix", mutate=lambda s: s["actors"][0]["keys"][0].update(at="head"))
        self.has("unknown anchor", mutate=lambda s: s["actors"][0]["keys"][0].update(
            x=1, y=2, at="moon") or (s["actors"][0]["keys"][0].pop("x"), s["actors"][0]["keys"][0].pop("y")))
        self.assertEqual(self.errors(mutate=lambda s: s["actors"][0]["keys"][1].update(at="head") or
                         (s["actors"][0]["keys"][1].pop("x"), s["actors"][0]["keys"][1].pop("y"))), [])

    def test_actor_ease_anim_flip_hide(self):
        self.has("easing", mutate=lambda s: s["actors"][0]["keys"][1].update(ease="bounce"))
        self.has("animation", mutate=lambda s: s["actors"][0]["keys"][0].update(anim="missing"))
        self.has("flip", mutate=lambda s: s["actors"][0]["keys"][0].update(flip=1))
        self.has("hide", mutate=lambda s: s["actors"][0]["keys"][0].update(hide=0))
        self.write("sprites", {"dot": {**SPRITE, "anims": {"a": {"frames": [["X"]]}, "b": {"frames": [["X"]]}}}})
        self.has("first key must set animation")

    def test_actor_bob_thread(self):
        self.has("bob.amp", mutate=lambda s: s["actors"][0].update(bob={"amp": 21, "hz": 1}))
        self.has("bob.hz", mutate=lambda s: s["actors"][0].update(bob={"amp": 2, "hz": 4}))
        self.has("thread", mutate=lambda s: s["actors"][0].update(thread="hand"))

    def test_cue_time_order(self):
        self.has("buddy[0].t", mutate=lambda s: s["buddy"][0].update(t=5))
        self.has("ascending", buddy=[{"t": 2, "say": "A"}, {"t": 1, "say": "B"}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "say": "A"},
                                             {"t": 1, "action": "wave", "for": 1}]), [])

    def test_cue_exactly_one_kind(self):
        self.has("exactly one", buddy=[{"t": 1}])
        self.has("exactly one", buddy=[{"t": 1, "say": "Hi", "pail": "back"}])

    def test_cue_action_and_for(self):
        self.has("action", buddy=[{"t": 1, "action": "fly", "for": 1}])
        self.has("for", buddy=[{"t": 1, "action": "hop"}])
        self.has("for", buddy=[{"t": 1, "action": "hop", "for": 0}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "action": "trot", "for": 1}]), [])

    def test_cue_say(self):
        self.has("say", buddy=[{"t": 1, "say": []}])
        self.has("say", buddy=[{"t": 1, "say": "x" * 41}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "say": ["Boo", "Hi"]}]), [])

    def test_say_spacing(self):
        for gap in (0, 1.99):
            self.has("say cues too close: a line needs time to be read", buddy=[
                {"t": 1, "say": "First"},
                {"t": 1, "action": "wave", "for": 1},
                {"t": 1 + gap, "say": "Second"}])
        self.assertEqual(self.errors(buddy=[
            {"t": 1, "say": "First"},
            {"t": 2, "action": "wave", "for": 1},
            {"t": 3, "say": ["Second", "Another"]}]), [])

    def test_cue_look(self):
        self.has("look", buddy=[{"t": 1, "look": "moon", "for": 1}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "look": [2, 3], "for": 1}]), [])

    def test_cue_run(self):
        self.has("run", buddy=[{"t": 1, "run": 201, "for": 1}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "run": 0, "for": 1}]), [])

    def test_cue_prop(self):
        self.has("prop", buddy=[{"t": 1, "prop": "broom", "for": 1}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "prop": "phone", "for": 1}]), [])

    def test_cue_pail_spider(self):
        self.has("pail", buddy=[{"t": 1, "pail": "lost"}])
        self.has("spider", buddy=[{"t": 1, "spider": "gone"}])

    def test_cue_emit(self):
        good = {"glyphs": ["*"], "color": "white", "count": 6, "from": "head"}
        self.assertEqual(self.errors(buddy=[{"t": 1, "emit": good}]), [])
        for field, value in (("glyphs", []), ("color", "bad"), ("count", 13), ("from", "ground")):
            bad = {**good, field: value}
            self.has(f"emit.{field}", buddy=[{"t": 1, "emit": bad}])

    def test_end_state_run(self):
        self.has("end state", buddy=[{"t": 1, "run": 100, "for": 1}])
        self.has("end state", buddy=[{"t": 3.5, "run": 0, "for": 1}])

    def test_end_state_pail(self):
        self.has("end state", buddy=[{"t": 1, "pail": "gone"}])
        self.assertEqual(self.errors(buddy=[{"t": 1, "pail": "gone"}, {"t": 2, "pail": "back"}]), [])

    def test_names_denylist(self):
        self.has("character or title", name="Dracula's hat")
        self.has("character or title", name="the_scream_mask")
        self.has("character or title", mutate=lambda s: s["sprites"].update({"Jason": SPRITE}), sprites={})
        self.assertEqual(self.errors(buddy=[{"t": 1, "say": "Beetlejuice…"}]), [])

    def test_shipped_files_pass(self):
        paths = sorted((ROOT / "skits").glob("*.json"))
        if not paths:
            self.skipTest("skits/ has no files yet")
        report = check.check_all(paths)
        self.assertEqual({p: e for p, e in report.items() if e}, {})


if __name__ == "__main__":
    unittest.main()
