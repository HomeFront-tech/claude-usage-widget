"""buddy-ear, the voice helper: utterances from audio files, and speaking.

Runs only on macOS 26 or later with the Command Line Tools (it builds ear/buddy-ear).
The speaking tests use the speakers but never the microphone (--no-listen).
"""
import json
import os
import platform
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EAR = os.path.join(ROOT, "ear")
BIN = os.path.join(EAR, "buddy-ear")


def macos_major():
    v = platform.mac_ver()[0]
    return int(v.split(".")[0]) if v else 0


def built():
    if macos_major() < 26:
        return False
    return subprocess.run([os.path.join(EAR, "build.sh")], capture_output=True).returncode == 0


BUILT = built()


def say(tmp, name, text):
    path = os.path.join(tmp, name + ".aiff")
    subprocess.run(["/usr/bin/say", "-o", path, text], check=True)
    return path


def events_from_file(path):
    out = subprocess.run([BIN, "--file", path], capture_output=True, text=True, timeout=60,
                         stdin=subprocess.DEVNULL).stdout
    return [json.loads(line) for line in out.splitlines() if line.startswith("{")]


def plain(text):
    return "".join(c for c in text.lower() if c.isalnum() or c == " ").strip()


@unittest.skipUnless(BUILT, "needs macOS 26+ and the Command Line Tools")
class EarTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_build_hash(self):
        with open(os.path.join(EAR, "ear.swift"), "rb") as a, open(os.path.join(EAR, "Info.plist"), "rb") as b:
            sources = a.read() + b.read()
        want = subprocess.run(["shasum", "-a", "256"], input=sources, capture_output=True).stdout.split()[0].decode()
        with open(os.path.join(EAR, "buddy-ear.hash")) as f:
            self.assertEqual(f.read().strip(), want)

    def test_two_utterances(self):
        evs = events_from_file(say(self.tmp, "two", "Okay Buddy, what's the weather? [[slnc 2000]] Tell me a joke."))
        starts = [e for e in evs if e["ev"] == "start"]
        ends = [e for e in evs if e["ev"] == "end"]
        self.assertEqual(len(starts), 2)
        self.assertEqual(len(ends), 2)
        self.assertTrue(plain(ends[0]["text"]).startswith("okay buddy"), ends[0]["text"])
        self.assertIn("joke", plain(ends[1]["text"]))
        for end in ends:
            words = [i for i, e in enumerate(evs) if e["ev"] == "words" and e["utt"] == end["utt"]]
            self.assertTrue(words and words[-1] < evs.index(end), "words come before their end")
        self.assertEqual(evs[-1]["ev"], "eof")

    def test_pause_after_phrase_is_its_own_utterance(self):
        evs = events_from_file(say(self.tmp, "three", "OK Buddy. [[slnc 1500]] Set a timer for ten minutes."))
        ends = [plain(e["text"]) for e in evs if e["ev"] == "end"]
        self.assertEqual(ends[0], "ok buddy")
        self.assertIn("timer", ends[1])

    def test_silence_feeds_nothing(self):
        evs = events_from_file(say(self.tmp, "quiet", "[[slnc 5000]]"))
        self.assertEqual([e["ev"] for e in evs], ["ready", "eof"])


@unittest.skipUnless(BUILT, "needs macOS 26+ and the Command Line Tools")
class SpeakTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.p = subprocess.Popen([BIN, "--no-listen"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.assertEqual(self.next()["ev"], "ready")

    def tearDown(self):
        if self.p.poll() is None:
            self.send({"cmd": "quit"})
            self.p.wait(5)

    def send(self, cmd):
        self.p.stdin.write(json.dumps(cmd) + "\n")
        self.p.stdin.flush()

    def next(self, want=None):
        while True:
            e = json.loads(self.p.stdout.readline())
            if want is None or e["ev"] == want:
                return e

    def test_speak_events(self):
        path = say(self.tmp, "hi", "Hello there, nice to meet you.")
        info = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
        length = float(info.split("estimated duration:")[1].split()[0])
        self.send({"cmd": "speak", "id": 7, "file": path})
        e = self.next("speaking")
        began = time.time()
        self.assertEqual(e["id"], 7)
        self.assertAlmostEqual(e["secs"], length, delta=0.1)
        e = self.next("spoken")
        took = time.time() - began
        self.assertEqual(e, {"ev": "spoken", "id": 7, "cut": False})
        self.assertTrue(length - 0.3 <= took <= length + 1.5, took)

    def test_stop_cuts(self):
        path = say(self.tmp, "long", "This is a much longer sentence that keeps going for a good few seconds, on and on.")
        self.send({"cmd": "speak", "id": 1, "file": path})
        self.next("speaking")
        time.sleep(1)
        stopped = time.time()
        self.send({"cmd": "stop"})
        e = self.next("spoken")
        self.assertEqual(e["cut"], True)
        self.assertLess(time.time() - stopped, 0.5)

    def test_quits_when_stdin_closes(self):
        self.p.stdin.close()
        self.assertEqual(self.p.wait(5), 0)


if __name__ == "__main__":
    unittest.main()
