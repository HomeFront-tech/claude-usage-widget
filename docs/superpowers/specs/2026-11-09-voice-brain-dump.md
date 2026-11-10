# Brain dump: long spoken messages for Buddy

2026-11-09. Asked for by voice: talk to Buddy for minutes (a brain dump, a brainstorm),
with pauses to think, and have nothing sent until he's completely done.

## What happens today

- The live voice chat ("okay Buddy" opens it) sends each utterance as a message. The helper
  (`ear/ear.swift`) ends an utterance after `gap` seconds of quiet (1.0 by default), so any
  pause to think sends what came before it, and Buddy starts answering.
- The helper also ends an utterance after 30 s of talking without a pause
  (`MAX_UTTERANCE`). Apple's transcriber costs more CPU the longer one result runs, so
  that limit stays. The cut can land mid-word, and in a live chat it sends the first
  30 s as a message of its own.
- Once text reaches the chat, nothing trims it: chat.lua, brain.lua (`B.request`) and
  `bin/buddy-agent` pass a message through whole.
- Bug found on the way: the "● Live" pill in the chat header never shows. The page sets the
  class `live`, the CSS shows `.on`.

## Design

**Brain dump mode** is a state inside the live chat (`turn.dump` in `V.turns`).

- Starts with "brain dump" (also "let's brainstorm", "let me think out loud", "long
  message"), said first after "okay Buddy" or at the start of any utterance in a live chat.
  With the live chat switched off, a brain dump still opens one, and closes it quietly once
  the dump is sent.
- While it's on, pauses don't send. Each utterance's words are added to the dump, and the
  whole dump so far goes to the chat box live. Buddy says nothing out loud: his own lines
  are dropped, and answers (task updates) show in the chat without being spoken. Anything
  he was saying when it started is cut.
- Ends and sends with a finishing phrase said on its own: "send it", "send", "done", "I'm
  done", "all done", "that's all", "that's everything", "over to you", "what do you think",
  "end brain dump" (with or without "okay", "Buddy", "thanks"). At the end of a longer
  utterance only a phrase that names Buddy counts ("…okay Buddy, send it"), so a sentence
  like "…and then I send it" never sends. Pressing Return (or Send) in the box sends it too.
- The message goes to the brain marked `dump`. The voice prompt then asks for a few short
  spoken sentences: what Buddy took from it and a next step, and an offer to write it up.
- Nothing is lost. If the dump ends any other way (panel closed, screen locked, ten quiet
  minutes, helper trouble), its words go back into the box as typed text and are saved as
  a draft (`claudeBuddy.chatDraft`). A draft comes back in the box the next time the panel
  opens, until it's sent or the box is emptied by hand.
- The display doesn't sleep while a dump is on (`hs.caffeinate` `displayIdle`). Display
  sleep would end the live chat as "away".
- The chat header shows "● Brain dump 3:42" while it's on, and "Paused" while another app
  has the microphone. The box's placeholder says how to finish.

**Long utterances** (helper):

- After 20 s of talking, a dip of 0.24 s ends the utterance, so the cut lands between
  words. 30 s stays as the hard limit. Both kinds of end carry `"split": true`.
- Outside a brain dump, a split end isn't a message. Its words wait and join the next
  utterance's words, and the joined text is sent at the next real pause. If nothing follows
  within `gap` + 1 s (2 s by default), the words are sent on their own. After 20 s every
  pause ends as a split first, so a long message waits about a second longer than a short
  one before it's sent. The one-shot mode (live chat off) joins them the same way.

**Short back-and-forth is unchanged:** the same `gap`, the same ending phrases, the same
interrupt and echo rules. The only differences are that talking for 20 s or more without
a pause is no longer sent in pieces, and that "send it" said alone outside a dump is still
an ordinary message.

## Tests

- `tests/voice_dump_spec.lua`: the turn rules (start, add, finish, Return, split joins,
  draft on end, quiet line during a dump).
- `tests/voice_spec.lua` / `tests/voice_live_spec.lua`: the split joins in both modes.
- `tests/chat_voice_spec.lua`: dump send meta, draft saved and restored.
- `tests/test_chat_page.py`: the page in node with a stub DOM (dump pill, Return during a
  dump, draft back in the box).
- `tests/test_ear.py`: a long recording (`say`, several minutes, pauses up to 8 s) through
  the real helper. Utterance limits and `split` hold, and the turn rules rebuild the whole
  script from its events.
