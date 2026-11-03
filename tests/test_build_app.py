"""tools/build-app and tools/app-icon.py: the pieces that make Claude Buddy.app.

Nothing here builds or installs an app: each test calls one function on made-up input
(and reads Hammerspoon's own menu file when it's installed). The engine check signs a
made-up app in a temp folder.
Run: /usr/bin/python3 -m unittest tests.test_build_app -v
"""
import importlib.machinery
import importlib.util
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, str(path)))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


B = load("build_app", ROOT / "tools/build-app")
ICON = load("app_icon", ROOT / "tools/app-icon.py")
HAMMERSPOON = Path("/Applications/Hammerspoon.app")
MAIN_MENU = HAMMERSPOON / "Contents/Resources/MainMenu.nib"


def nib(strings):
    """A small NIBArchive: one object whose values are these strings, then an int."""
    v = B._put_varint
    keys = v(4) + b"NSKy"
    values = b"".join(v(0) + b"\x08" + v(len(s)) + s for s in strings) + v(0) + b"\x00\x07"
    objects = v(0) + v(0) + v(len(strings) + 1)
    classes = v(9) + v(0) + b"NSObject\x00"
    body = [objects, keys, values, classes]
    offsets, at = [], 50
    for part in body:
        offsets.append(at)
        at += len(part)
    head = [1, 10, 1, offsets[0], 1, offsets[1], len(strings) + 1, offsets[2], 1, offsets[3]]
    return b"NIBArchive" + b"".join(struct.pack("<I", h) for h in head) + b"".join(body)


class Info(unittest.TestCase):
    ENGINE = {
        "CFBundleIdentifier": "org.hammerspoon.Hammerspoon", "CFBundleName": "Hammerspoon",
        "CFBundleExecutable": "Hammerspoon", "CFBundleIconName": "AppIcon", "CFBundleIconFile": "AppIcon",
        "SUFeedURL": "https://example.invalid/appcast.xml", "SUEnableAutomaticChecks": True,
        "CFBundleURLTypes": [{"CFBundleURLSchemes": ["hammerspoon"]}], "NSServices": [{}],
        "NSCameraUsageDescription": "Some Hammerspoon extensions require access to the camera.",
        "LSUIElement": True, "CFBundleShortVersionString": "1.1.1",
    }

    def test_becomes_claude_buddy(self):
        out = B.app_info(self.ENGINE, B.BUNDLE_ID, "1.1.1")
        self.assertEqual(out["CFBundleIdentifier"], B.BUNDLE_ID)
        self.assertEqual((out["CFBundleName"], out["CFBundleExecutable"]), ("Claude Buddy", "Claude Buddy"))
        self.assertEqual(out["CFBundleIconFile"], "ClaudeBuddy")
        self.assertEqual(out["ClaudeBuddyEngine"], "1.1.1")
        self.assertTrue(out["LSUIElement"], "still an agent app: the Dock icon comes and goes from Lua")

    def test_never_updates_into_hammerspoon_or_takes_its_links(self):
        out = B.app_info(self.ENGINE, B.BUNDLE_ID, "1.1.1")
        for key in ("SUFeedURL", "CFBundleURLTypes", "NSServices", "CFBundleIconName"):
            self.assertNotIn(key, out)
        self.assertFalse(out["SUEnableAutomaticChecks"])

    def test_permission_prompts_name_buddy(self):
        out = B.app_info(self.ENGINE, B.BUNDLE_ID, "1.1.1")
        self.assertNotIn("Hammerspoon", out["NSCameraUsageDescription"])
        self.assertIn("Buddy", out["NSMicrophoneUsageDescription"])
        self.assertIn("NSSpeechRecognitionUsageDescription", out)
        self.assertIn("Hammerspoon", out["NSHumanReadableCopyright"], "credit where it's due")


class Nib(unittest.TestCase):
    def test_varints_round_trip(self):
        for n in (0, 1, 127, 128, 300, 70000):
            self.assertEqual(B._varint(B._put_varint(n), 0), (n, len(B._put_varint(n))))

    def test_relabels_whole_strings_only(self):
        data = nib([b"About Hammerspoon", b"quitHammerspoon:", b"Hammerspoon"])
        out, n = B.relabel_nib(data, B.LABELS)
        self.assertEqual(n, 2)
        self.assertEqual(B.nib_strings(out), ["About Claude Buddy", "quitHammerspoon:", "Claude Buddy"])

    def test_sections_after_the_values_move(self):
        data = nib([b"Hammerspoon"])
        out, _ = B.relabel_nib(data, B.LABELS)
        classes = struct.unpack("<I", out[46:50])[0]
        self.assertEqual(out[classes:classes + 2], B._put_varint(9) + B._put_varint(0))
        self.assertEqual(out[classes + 2:classes + 11], b"NSObject\x00")

    def test_not_a_nib(self):
        with self.assertRaises(ValueError):
            B.relabel_nib(b"bplist00", B.LABELS)

    @unittest.skipUnless(MAIN_MENU.exists(), "Hammerspoon isn't installed")
    def test_hammerspoons_own_menu(self):
        out, n = B.relabel_nib(MAIN_MENU.read_bytes(), B.LABELS)
        texts = B.nib_strings(out)
        self.assertGreaterEqual(n, 4)
        self.assertIn("Quit Claude Buddy", texts)
        self.assertIn("quitHammerspoon:", texts, "the Quit item's action keeps its name")
        self.assertNotIn("Quit Hammerspoon", texts)


class Engine(unittest.TestCase):
    @unittest.skipUnless(HAMMERSPOON.exists(), "Hammerspoon isn't installed")
    def test_hammerspoon_as_its_team_signed_it(self):
        self.assertEqual(B.verify_engine(HAMMERSPOON), HAMMERSPOON)

    def test_a_folder_named_like_the_signature_isnt_enough(self):
        # `codesign -dv` prints the file's path too, so this folder name once got an
        # app signed on any Mac past a check that only looked for the team's ID in it
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / ("Identifier=%s TeamIdentifier=%s" % (B.ENGINE_ID, B.ENGINE_TEAM)) / "Hammerspoon.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            shutil.copy("/usr/bin/true", app / "Contents/MacOS/Hammerspoon")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(
                {"CFBundleIdentifier": B.ENGINE_ID, "CFBundleExecutable": "Hammerspoon", "CFBundlePackageType": "APPL"}))
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            info = subprocess.run(["/usr/bin/codesign", "-dv", str(app)], capture_output=True, text=True).stderr
            self.assertIn("TeamIdentifier=" + B.ENGINE_TEAM, info, "the old check would have passed it")
            with self.assertRaises(B.BuildError):
                B.verify_engine(app)


class Icon(unittest.TestCase):
    def test_every_size_is_a_square_png(self):
        for n in (16, 64):
            png = ICON.draw(n)
            self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
            w, h = struct.unpack(">II", png[16:24])
            self.assertEqual((w, h), (n, n))

    def test_corners_clear_and_buddy_orange(self):
        png = ICON.draw(64)
        raw = zlib.decompress(png[png.index(b"IDAT") + 4:png.index(b"IEND") - 8])
        row = lambda y: raw[y * (64 * 4 + 1) + 1:(y + 1) * (64 * 4 + 1)]
        self.assertEqual(row(0)[3], 0, "outside the rounded square is see-through")
        mid = row(25)[32 * 4:32 * 4 + 4]  # between the eyes, on the body
        self.assertEqual(tuple(mid[:3]), ICON.BODY)


if __name__ == "__main__":
    unittest.main()
