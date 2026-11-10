-- Brain dumps and long utterances: pure turn rules, driven with supplied time and no microphone.
return function(t, dir)
  local V = dofile(dir .. "/voice.lua")
  local function kinds(actions)
    local k = {}
    for _, a in ipairs(actions) do k[#k + 1] = a[1] end
    return table.concat(k, ",")
  end
  local function has(actions, kind)
    for _, a in ipairs(actions) do if a[1] == kind then return a end end
  end
  local function live(opts)
    opts = opts or {}
    return V.turns({ phrase = "okay Buddy", timeout = 6, live = opts.live ~= false, liveTimeout = opts.liveTimeout })
  end

  -- what starts a brain dump, and what's left after the phrase
  t.eq(V.dumpStart("Okay Buddy, brain dump."), "", "okay Buddy, brain dump")
  t.eq(V.dumpStart("Brain dump. So I was thinking about the snow."), "So I was thinking about the snow.",
    "the words after the phrase keep their capitals and punctuation")
  t.eq(V.dumpStart("OK Buddy, brain-dump mode"), "", "brain-dump mode")
  t.eq(V.dumpStart("OK Buddy braindom so I have been thinking"), "so I have been thinking",
    "how dictation hears it without the hint")
  t.eq(V.dumpStart("so, let's do a brain dump"), "", "let's do a brain dump")
  t.eq(V.dumpStart("Let's brainstorm names for the app"), "Let's brainstorm names for the app",
    "a brainstorm keeps its words: they say what it's about")
  t.eq(V.dumpStart("okay buddy let me think out loud for a minute"), "let me think out loud for a minute",
    "thinking out loud keeps its words")
  t.eq(V.dumpStart("hello Buddy, brain dump", "hello Buddy"), "", "a custom wake phrase")
  for _, p in ipairs({ "what's a brain dump", "I need to dump the brain fluid", "send it", "brainstorming is fun",
      "" }) do
    t.eq(V.dumpStart(p), nil, "no dump: " .. p)
  end

  -- what finishes one: said on its own, or naming Buddy at the end of a longer utterance
  for _, p in ipairs({ "Send it.", "send", "Okay, send it!", "Done.", "I'm done.", "I’m done", "all done",
      "That's all, thanks Buddy", "that's everything", "Over to you, Buddy.", "What do you think?",
      "okay Buddy send it", "end brain dump", "end of the brain dump" }) do
    t.eq(V.dumpFinish(p), "", "finishes: " .. p)
  end
  t.eq(V.dumpFinish("And that's the plan. Okay Buddy, send it."), "And that's the plan.",
    "naming Buddy at the end finishes, and the words before it stay")
  t.eq(V.dumpFinish("the trucks need tires. Send it, Buddy."), "the trucks need tires.", "send it, Buddy")
  t.eq(V.dumpFinish("ok that's the list, end brain dump"), "ok that's the list", "end brain dump at the end")
  t.eq(V.dumpFinish("That's the plan. Okay Buddy, over to you."), "That's the plan.", "over to you at the end")
  t.eq(V.dumpFinish("so that's it. Send it, Buddy, thanks."), "so that's it.", "send it, Buddy, thanks")
  t.eq(V.dumpFinish("I told my buddy send it"), nil, "my buddy isn't Buddy")
  for _, p in ipairs({ "and then I make the quote and send it", "I'm done with the snow contracts",
      "when I'm done", "that's it", "the trucks are done", "so what do you think about the trucks", "" }) do
    t.eq(V.dumpFinish(p), nil, "keeps going: " .. p)
  end

  -- a whole brain dump in a live chat: pauses don't send, "send it" does
  local a = live()
  local r = a:event({ ev = "start", utt = 1 }, 0)
  r = a:event({ ev = "words", utt = 1, text = "Okay Buddy brain dump" }, 0.5)
  t.eq(kinds(r), "wake,liveStart,dumpStart", "the wake and the phrase start a dump")
  t.ok(a.dump ~= nil, "dumping")
  r = a:event({ ev = "words", utt = 1, text = "Okay Buddy brain dump so I was" }, 1)
  t.eq(kinds(r), "words", "words as they come")
  t.eq(r[1].text, "so I was", "without the phrase")
  r = a:event({ ev = "end", utt = 1, text = "Okay Buddy, brain dump. So I was thinking about the snow." }, 3)
  t.eq(kinds(r), "words", "a pause doesn't send")
  t.eq(r[1].text, "So I was thinking about the snow.", "the box holds it")
  a:event({ ev = "start", utt = 2 }, 8)
  r = a:event({ ev = "words", utt = 2, text = "We need two more" }, 8.5)
  t.eq(r[1].text, "So I was thinking about the snow. We need two more", "the box shows all of it")
  r = a:event({ ev = "end", utt = 2, text = "We need two more trucks." }, 10)
  t.eq(kinds(r), "words", "a second pause doesn't send either")
  t.eq(a:dumpText(), "So I was thinking about the snow. We need two more trucks.", "the dump so far")
  -- a long thought cut at the helper's limit is just more of the dump
  a:event({ ev = "start", utt = 3 }, 20)
  r = a:event({ ev = "end", utt = 3, text = "And the contracts", split = true }, 41)
  t.eq(kinds(r), "words", "a split end is more words")
  a:event({ ev = "start", utt = 4 }, 41.2)
  r = a:event({ ev = "end", utt = 4, text = "go out Friday." }, 44)
  t.eq(a:dumpText(), "So I was thinking about the snow. We need two more trucks. And the contracts go out Friday.",
    "joined in order")
  t.eq(#a:tick(200), 0, "a long quiet doesn't send it")
  -- "um" and Buddy's own lines change nothing
  t.eq(#a:event({ ev = "end", utt = 5, text = "um" }, 201), 0, "noise is ignored")
  a:event({ ev = "start", utt = 6 }, 210)
  r = a:event({ ev = "end", utt = 6, text = "Send it." }, 211)
  t.eq(kinds(r), "send,dumpEnd", "send it sends the dump")
  t.eq(r[1].text, "So I was thinking about the snow. We need two more trucks. And the contracts go out Friday.",
    "all of it")
  t.eq(r[1].dump, true, "marked as a brain dump")
  t.eq(r[2].sent, true, "and the dump ended with a send")
  t.eq(a.dump, nil, "not dumping")
  t.eq(a.live, true, "the live chat goes on")
  r = a:event({ ev = "end", utt = 7, text = "thanks, what's next" }, 220)
  t.eq(kinds(r), "send", "back to the short back-and-forth")

  -- started in the middle of a live chat, with words in the same breath
  local b = live()
  b:event({ ev = "end", utt = 1, text = "okay Buddy what time is it" }, 0)
  r = b:event({ ev = "end", utt = 2, text = "Let's brainstorm names for the new truck" }, 10)
  t.eq(kinds(r), "dumpStart,words", "a brainstorm starts a dump")
  t.eq(r[2].text, "Let's brainstorm names for the new truck", "with its words")
  r = b:event({ ev = "end", utt = 3, text = "Something with snow in it. Okay Buddy, what do you think?" }, 15)
  t.eq(kinds(r), "send,dumpEnd", "finished at the end of a longer utterance")
  t.eq(r[1].text, "Let's brainstorm names for the new truck Something with snow in it.", "the finish isn't sent")

  -- "send it" said alone outside a dump is an ordinary message
  local c = live()
  c:event({ ev = "end", utt = 1, text = "okay Buddy hi" }, 0)
  r = c:event({ ev = "end", utt = 2, text = "send it" }, 4)
  t.eq(kinds(r), "send", "not a dump: sent as said")
  t.eq(r[1].dump, nil, "and not marked")

  -- finishing with nothing said sends nothing
  local d = live()
  d:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  r = d:event({ ev = "end", utt = 2, text = "never mind, I'm done" }, 4)
  t.eq(kinds(r), "words", "\"never mind, I'm done\" is words, not a finish")
  r = d:event({ ev = "end", utt = 3, text = "done" }, 6)
  t.eq(kinds(r), "send,dumpEnd", "done finishes")
  local e = live()
  e:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  r = e:event({ ev = "end", utt = 2, text = "send it" }, 4)
  t.eq(kinds(r), "dumpEnd", "an empty dump sends nothing")
  t.eq(r[1].sent, false, "and says so")

  -- an ending phrase sends what was said, then ends the live chat
  local f = live()
  f:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  f:event({ ev = "end", utt = 2, text = "Order more salt." }, 3)
  r = f:event({ ev = "end", utt = 3, text = "stop listening" }, 6)
  t.eq(kinds(r), "send,dumpEnd,liveEnd", "stop listening sends it and ends the chat")

  -- Return in the box sent it: what's still being written down isn't sent again
  local g = live()
  g:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  g:event({ ev = "end", utt = 2, text = "Call the supplier." }, 3)
  g:event({ ev = "start", utt = 3 }, 5)
  g:event({ ev = "words", utt = 3, text = "and the" }, 5.5)
  r = g:dumpTaken()
  t.eq(kinds(r), "dumpEnd", "typed send ends the dump")
  t.eq(r[1].sent, true, "as sent")
  t.eq(#g:event({ ev = "end", utt = 3, text = "and the plow" }, 6.5), 0, "the rest of that utterance went with it")
  r = g:event({ ev = "end", utt = 4, text = "what's the weather" }, 9)
  t.eq(kinds(r), "send", "the next utterance is a message again")

  -- the live chat ends while dumping: the words come back as a draft, never sent
  local h = live({ liveTimeout = 600 })
  h:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  h:event({ ev = "end", utt = 2, text = "Plow route for Tuesday." }, 3)
  r = h:tick(700)
  t.eq(kinds(r), "liveEnd", "ten quiet minutes end the chat")
  t.eq(r[1].why, "quiet", "as quiet")
  t.eq(h:endLive(), "Plow route for Tuesday.", "endLive hands back the unsent words")
  t.eq(h.dump, nil, "not dumping after")
  t.eq(live():endLive(), nil, "no draft without a dump")

  -- another app takes the mic during a dump: that utterance goes, the dump stays
  local k = live()
  k:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  k:event({ ev = "end", utt = 2, text = "Snow first." }, 3)
  k:event({ ev = "start", utt = 3 }, 20)
  k:event({ ev = "busy", on = true, app = "x" }, 20.4)
  k:event({ ev = "busy", on = false }, 22)
  r = k:event({ ev = "end", utt = 3, text = "this was a call" }, 22.5)
  t.eq(kinds(r), "words", "dropped, the box goes back to the dump")
  t.eq(r[1].text, "Snow first.", "without the call")

  -- with the live chat off, a brain dump opens one and closes it once sent
  local m = live({ live = false })
  r = m:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 0)
  t.eq(kinds(r), "wake,liveStart,dumpStart", "live off: the dump still opens a chat")
  m:event({ ev = "end", utt = 2, text = "Fix the gate." }, 3)
  r = m:event({ ev = "end", utt = 3, text = "send it" }, 5)
  t.eq(kinds(r), "send,dumpEnd,liveEnd", "and closes it after the send")
  t.eq(r[3].why, "dump", "quietly")
  t.eq(m:endLive(), nil, "nothing left over")
  r = m:event({ ev = "end", utt = 4, text = "what's the time" }, 8)
  t.eq(has(r, "send"), nil, "the wake word is needed again")

  -- outside a dump, a split end waits for the rest instead of being sent
  local n = live()
  n:event({ ev = "end", utt = 1, text = "okay Buddy hi" }, 0)
  n:event({ ev = "start", utt = 2 }, 5)
  n:event({ ev = "start", utt = 3 }, 26.2)
  r = n:event({ ev = "end", utt = 2, text = "So the first thing is the", split = true }, 26.5)
  t.eq(kinds(r), "words", "a split end isn't sent")
  r = n:event({ ev = "words", utt = 3, text = "plow" }, 26.8)
  t.eq(r[1].text, "So the first thing is the plow", "the next words join it")
  r = n:event({ ev = "end", utt = 3, text = "plow schedule." }, 29)
  t.eq(kinds(r), "send", "the real pause sends")
  t.eq(r[1].text, "So the first thing is the plow schedule.", "both halves")
  -- a split end with nothing after it is sent once it's clearly over
  n:event({ ev = "start", utt = 4 }, 40)
  n:event({ ev = "end", utt = 4, text = "and that's about it", split = true }, 61)
  t.eq(#n:tick(62), 0, "not yet")
  r = n:tick(64)
  t.eq(kinds(r), "send", "sent after the wait")
  t.eq(r[1].text, "and that's about it", "on its own")
  t.eq(#n:tick(70), 0, "once")

  -- the one-shot mode (live chat off) joins them too
  local o = live({ live = false })
  o:event({ ev = "start", utt = 1 }, 0)
  o:event({ ev = "words", utt = 1, text = "okay Buddy remind me" }, 1)
  o:event({ ev = "start", utt = 2 }, 21)
  r = o:event({ ev = "end", utt = 1, text = "okay Buddy remind me to call", split = true }, 21.3)
  t.eq(has(r, "send"), nil, "one-shot: a split isn't sent")
  r = o:event({ ev = "words", utt = 2, text = "Sam" }, 21.5)
  t.eq(r[1] and r[1].text, "remind me to call Sam", "one-shot: the next words join it")
  r = o:event({ ev = "end", utt = 2, text = "Sam tomorrow" }, 23)
  t.eq(r[1] and r[1][1], "send", "one-shot: sent at the pause")
  t.eq(r[1] and r[1].text, "remind me to call Sam tomorrow", "one-shot: both halves")
  local p = live({ live = false })
  p:event({ ev = "end", utt = 1, text = "okay Buddy remind me to call", split = true }, 21)
  r = p:tick(24)
  t.eq(r[1] and r[1][1], "send", "one-shot: a lone split is sent after the wait")
  t.eq(r[1] and r[1].text, "remind me to call", "one-shot: its words")

  -- v1.16 audit: the rules below each failed before it

  -- dictation's curly apostrophe after the wake phrase still ends the chat
  local c = live()
  c:event({ ev = "start", utt = 1 }, 0)
  c:event({ ev = "end", utt = 1, text = "Okay Buddy" }, 1)
  c:event({ ev = "start", utt = 2 }, 2)
  r = c:event({ ev = "end", utt = 2, text = "Okay Buddy, we\226\128\153re done." }, 3)
  t.eq(kinds(r), "liveEnd", "okay Buddy, we’re done (curly apostrophe) ends the live chat")
  t.eq(V.isEnd("that\226\128\153s all"), true, "that’s all")

  -- "...okay Buddy, send it" right at the helper's 20 s limit: it sends when nothing follows
  local s1 = live()
  s1:event({ ev = "start", utt = 1 }, 0)
  s1:event({ ev = "end", utt = 1, text = "Okay Buddy brain dump" }, 1)
  s1:event({ ev = "start", utt = 2 }, 2)
  r = s1:event({ ev = "end", utt = 2, text = "so the trucks need tires. Okay Buddy, send it", split = true }, 23)
  t.eq(has(r, "send"), nil, "a finishing phrase at a split waits")
  t.eq(#s1:tick(24), 0, "for the rest")
  r = s1:tick(26)
  t.eq(has(r, "send") and has(r, "send").text, "so the trucks need tires.", "then it sends the dump without the phrase")
  t.ok(has(r, "dumpEnd") and has(r, "dumpEnd").sent, "and the dump is over")
  -- ...and is part of the dump when you carry on
  local s2 = live()
  s2:event({ ev = "start", utt = 1 }, 0)
  s2:event({ ev = "end", utt = 1, text = "Okay Buddy brain dump" }, 1)
  s2:event({ ev = "start", utt = 2 }, 2)
  s2:event({ ev = "start", utt = 3 }, 22.9)
  s2:event({ ev = "end", utt = 2, text = "then I told my helper, okay Buddy, send it", split = true }, 23)
  t.eq(#s2:tick(26), 0, "more is being said: it doesn't send")
  r = s2:event({ ev = "end", utt = 3, text = "and he laughed" }, 27)
  t.eq(has(r, "send"), nil, "still a dump")
  t.eq(s2:dumpText(), "then I told my helper, okay Buddy, send it and he laughed", "the phrase was part of it")

  -- Return sends a one-shot dump while its first utterance is open: the rest of that
  -- utterance mustn't wake him and start the dump again
  local k = live({ live = false })
  k:event({ ev = "start", utt = 1 }, 0)
  k:event({ ev = "words", utt = 1, text = "okay Buddy brain dump the plan is" }, 2)
  t.ok(k.dump ~= nil, "one-shot: a dump is on")
  r = k:dumpTaken()
  t.eq(kinds(r), "dumpEnd,liveEnd", "Return ends it")
  k:endLive()
  r = k:event({ ev = "words", utt = 1, text = "okay Buddy brain dump the plan is simple" }, 3)
  t.eq(#r, 0, "later words of the same utterance are ignored")
  r = k:event({ ev = "end", utt = 1, text = "okay Buddy brain dump the plan is simple" }, 4)
  t.eq(#r, 0, "and its end")
  k:event({ ev = "start", utt = 2 }, 5)
  r = k:event({ ev = "end", utt = 2, text = "okay Buddy what time is it" }, 6)
  t.eq(has(r, "send") and has(r, "send").text, "what time is it", "the next utterance works as usual")

  -- an echo of one message that ends after his next message has started is still an echo
  local e = live()
  e:event({ ev = "start", utt = 1 }, 0)
  e:event({ ev = "end", utt = 1, text = "okay Buddy" }, 1)
  e.saying = "The trucks are ready for the morning"
  e:event({ ev = "speaking", id = 1 }, 2)
  e:event({ ev = "start", utt = 2 }, 2.5)
  r = e:event({ ev = "words", utt = 2, text = "trucks are ready" }, 3)
  t.eq(#r, 0, "his own words are dropped")
  e:event({ ev = "spoken", id = 1 }, 4)
  e.saying = "Next, the weather"
  e:event({ ev = "speaking", id = 2 }, 4.1)
  r = e:event({ ev = "end", utt = 2, text = "trucks are ready for the morning" }, 4.5)
  t.eq(#r, 0, "and still dropped when its end comes during the next message")

  -- one-shot: the question starts while "okay Buddy" is still being written down
  local q = live({ live = false })
  q:event({ ev = "start", utt = 1 }, 0)
  q:event({ ev = "words", utt = 1, text = "okay Buddy" }, 0.8)
  q:event({ ev = "start", utt = 2 }, 1.6)
  q:event({ ev = "end", utt = 1, text = "okay Buddy" }, 1.8)
  r = q:event({ ev = "end", utt = 2, text = "how much snow tonight" }, 4)
  t.eq(has(r, "send") and has(r, "send").text, "how much snow tonight", "one-shot: a question that began early is caught")

  -- "brain dump", then "send it" with nothing said: over, nothing sent, the chat stays live
  local m = live()
  m:event({ ev = "start", utt = 1 }, 0)
  m:event({ ev = "end", utt = 1, text = "okay Buddy brain dump" }, 1)
  m:event({ ev = "start", utt = 2 }, 2)
  r = m:event({ ev = "end", utt = 2, text = "send it" }, 3)
  t.eq(kinds(r), "dumpEnd", "an empty dump just ends")
  t.eq(r[1].sent, false, "nothing was sent")
  t.ok(m.live, "the live chat goes on")

  -- a dump left alone for ten minutes is saved, with no liveTimeout set
  local w = live()
  w:event({ ev = "start", utt = 1 }, 0)
  w:event({ ev = "end", utt = 1, text = "okay Buddy brain dump first thought" }, 1)
  t.eq(#w:tick(500), 0, "eight quiet minutes: still on")
  r = w:tick(602)
  t.eq(kinds(r), "liveEnd", "ten quiet minutes ends it")
  t.eq(r[1].why, "quiet", "as quiet")
  t.eq(w:endLive(), "first thought", "and what was said comes back as a draft")
  local w2 = live()
  w2:event({ ev = "start", utt = 1 }, 0)
  w2:event({ ev = "end", utt = 1, text = "okay Buddy" }, 1)
  t.eq(#w2:tick(5000), 0, "a live chat without a dump still has no timeout")

  -- words said while another app had the microphone never show in a dump
  local b = live()
  b:event({ ev = "start", utt = 1 }, 0)
  b:event({ ev = "end", utt = 1, text = "okay Buddy brain dump mine" }, 1)
  b:event({ ev = "busy", on = true }, 2)
  b:event({ ev = "start", utt = 2 }, 3)
  b:event({ ev = "words", utt = 2, text = "hello this is a call" }, 4)
  b:event({ ev = "busy", on = false }, 5)
  r = b:event({ ev = "words", utt = 2, text = "hello this is a call about" }, 5.5)
  t.eq(#r, 0, "an utterance from the other app's time adds nothing")
  t.eq(b:dumpText(), "mine", "the dump holds only what was said to him")
  b:event({ ev = "end", utt = 2, text = "hello this is a call about snow" }, 6)
  t.eq(b:dumpText(), "mine", "also after it ends")
end
