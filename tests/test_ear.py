"""buddy-ear, the voice helper: utterances from audio files, and speaking.

Runs only on macOS 26 or later with the Command Line Tools (it builds ear/buddy-ear).
The speaking tests play through the speakers, at volume zero so a test run never talks to the
room, and never use the microphone (--no-listen).
"""
import difflib
import json
import os
import re
import shutil
import platform
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EAR = os.path.join(ROOT, "ear")
BIN = os.path.join(EAR, "buddy-ear")


# A brain dump said out loud: what test_long_brain_dump plays to the helper.
BRAIN_DUMP = " ".join("""
Okay Buddy, brain dump. So I have been thinking about how we plan the week when the snow comes early.
[[slnc 2500]] The first thing is the route. We should start with the driveways that have steep slopes,
because those get icy fastest. [[slnc 6000]] Hmm, let me think about the trucks for a second. [[slnc 8000]]
We have two trucks, but one of them needs new tires before the end of the month, and the other one is fine.
[[slnc 3000]] Now here is the long part where I just keep talking without stopping, because sometimes an idea
comes all at once, and you want to get the whole thing out, so the plan would be to call every customer on the
list, confirm the address, confirm the gate code if there is one, ask whether they want salt on the steps or only
on the walkway, write all of that into the sheet, and then sort the sheet by neighbourhood so the drivers never
cross the river twice in one morning, which wastes fuel and time and makes everyone grumpy, and while we are at it
we could also send a short text the night before so people know roughly when to expect us. [[slnc 4000]]
Second idea. A simple price for small walkways, and a different price for corner lots, because corner lots have
twice the sidewalk. [[slnc 5000]] Third, I want a checklist for the start of the season. Shovels, salt, spare
gloves, phone chargers in the trucks. [[slnc 2000]] And maybe a coffee budget, honestly. [[slnc 7000]]
Last thing. Remind me to look at the insurance renewal next week. [[slnc 3000]] Okay, that's everything.
Actually, wait, I am not done yet. [[slnc 4000]] For the spring, I want to try a newsletter. Nothing fancy, one
email a month with a tip, a photo of a finished job, and a reminder that we book up fast in April. [[slnc 6000]]
I keep going back and forth on whether to hire one more person or rent a second mower. Hiring is more work up
front, but renting doesn't help on the days when we are short a pair of hands. [[slnc 5000]] So maybe the answer
is, hire for the busy months only, May through September, and keep it simple. [[slnc 3000]] Another thing that
bugs me is the invoices. They go out late because I write them at night. If the app could draft them right after
each job, I would just check and send. [[slnc 8000]] Okay. Let me also say something long again to see what
happens when I talk for a really long time with no real break, like when I'm explaining the whole season to a new
person, you start with the fall cleanups, leaves and gutters and the last cut, then the first snow, then the long
middle of winter where it is mostly checking the forecast and going out early, then the thaw where everything is
mud, and then aeration and the first cuts in spring, and then the summer which is mostly mowing, trimming, and the
odd landscaping job that takes a whole week, and then it all starts again. [[slnc 4000]] That's the season in one
breath. [[slnc 3000]] Okay Buddy, send it.
""".split())


def macos_major():
    v = platform.mac_ver()[0]
    return int(v.split(".")[0]) if v else 0


def built():
    if macos_major() < 26:
        return False
    return subprocess.run([os.path.join(EAR, "build.sh")], capture_output=True).returncode == 0


BUILT = built()


def say(tmp, name, text, silent=False):
    path = os.path.join(tmp, name + ".aiff")
    # "[[volm 0]]" keeps the words' timing but renders them silent: what the speaking tests
    # play through the speakers is never heard (the listening tests need the real speech)
    subprocess.run(["/usr/bin/say", "-o", path, ("[[volm 0]] " if silent else "") + text], check=True)
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

    def test_long_brain_dump(self):
        # about four minutes at talking pace: pauses of up to eight seconds to think, and two
        # stretches of 40 s or more without a pause, which the helper splits between words
        path = os.path.join(self.tmp, "dump.aiff")
        subprocess.run(["/usr/bin/say", "-r", "150", "-o", path, BRAIN_DUMP], check=True)
        out = subprocess.run([BIN, "--file", path], capture_output=True, text=True, timeout=180,
                             stdin=subprocess.DEVNULL).stdout
        evs = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
        ends = [e for e in evs if e["ev"] == "end"]
        self.assertEqual(evs[-1]["ev"], "eof")
        self.assertGreaterEqual(sum(1 for e in ends if e.get("split")), 2, "both long stretches are split")
        self.assertGreaterEqual(sum(1 for e in ends if not e.get("split")), 15, "every pause ends an utterance")
        # a split lands between words and loses none: the words either side of it are
        # next to each other in what was said
        said = " ".join(plain(re.sub(r"\[\[.*?\]\]", " ", BRAIN_DUMP)).split())
        for i, e in enumerate(ends[:-1]):
            if e.get("split"):
                pair = plain(e["text"]).split()[-1] + " " + plain(ends[i + 1]["text"]).split()[0]
                self.assertIn(pair, said, "nothing lost at the split")
        lua = shutil.which("lua") or ("/opt/homebrew/bin/lua" if os.path.exists("/opt/homebrew/bin/lua") else None)
        if not lua:
            self.skipTest("no standalone lua to replay the turn rules")
        events = os.path.join(self.tmp, "events.jsonl")
        with open(events, "w") as f:
            f.write(out)
        replay = subprocess.run([lua, os.path.join(ROOT, "tests", "fakes", "dump_replay.lua"),
                                 os.path.join(ROOT, "voice.lua"), events], capture_output=True, text=True, timeout=30)
        self.assertEqual(replay.returncode, 0, replay.stderr)
        actions = [line.split("\t") for line in replay.stdout.splitlines()]
        kinds = [a[0] for a in actions]
        self.assertEqual(kinds, ["wake", "liveStart", "dumpStart", "send", "dumpEnd"], "one message, at the end")
        sent = [a for a in actions if a[0] == "send"][0]
        self.assertEqual(sent[1], "dump")
        want = plain(re.sub(r"\[\[.*?\]\]", " ", BRAIN_DUMP)).split()
        want = want[want.index("dump") + 1:-4]  # between "brain dump" and "okay buddy send it"
        got = plain(sent[2]).split()
        same = sum(b.size for b in difflib.SequenceMatcher(a=want, b=got, autojunk=False).get_matching_blocks())
        self.assertGreater(same / len(want), 0.9, "nearly every word arrives: %d of %d" % (same, len(want)))

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
        path = say(self.tmp, "hi", "Hello there, nice to meet you.", silent=True)
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
        path = say(self.tmp, "long", "This is a much longer sentence that keeps going for a good few seconds, on and on.",
                   silent=True)
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
