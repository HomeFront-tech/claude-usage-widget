-- Live voice chat rules: pure, driven with supplied time and no microphone.
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
  local function live(timeout)
    return V.turns({ phrase = "okay Buddy", timeout = 6, live = true, liveTimeout = timeout })
  end

  -- ending phrases
  for _, p in ipairs({ "We're done.", "Okay, we're done!", "stop listening", "Stop listening to me",
      "that's all", "That’s all, thanks Buddy", "goodbye", "okay Buddy we are done" }) do
    t.ok(V.isEnd(p), "ends: " .. p)
  end
  for _, p in ipairs({ "are we done with the quote", "I'm done with the slide deck", "keep listening",
      "what's all this", "stop" }) do
    t.ok(not V.isEnd(p), "keeps going: " .. p)
  end
  t.ok(V.isNoise("uh") and V.isNoise("") and V.isNoise("a"), "noise")
  t.ok(not V.isNoise("hi"), "a word is not noise")
  t.ok(V.isEcho("sure go ahead", "Sure, go ahead and ask me anything"), "echo of his own words")
  t.ok(not V.isEcho("stop talking", "Sure, go ahead"), "other words are not echo")

  -- the wake word opens it, then no more wake words
  local a = live()
  local r = a:event({ ev = "words", utt = 1, text = "Okay Buddy what's the time" }, 0)
  t.eq(kinds(r), "wake,liveStart,words", "wake opens a live chat")
  r = a:event({ ev = "end", utt = 1, text = "Okay Buddy what's the time" }, 1)
  t.eq(r[1][1], "send", "first question sends")
  t.eq(r[1].text, "what's the time", "first question text")
  r = a:event({ ev = "end", utt = 2, text = "and the date" }, 5)
  t.eq(kinds(r), "send", "next turn needs no wake word")
  t.eq(r[1].text, "and the date", "next turn text")
  r = a:event({ ev = "end", utt = 3, text = "Okay, we're done." }, 9)
  t.eq(kinds(r), "liveEnd", "ending phrase ends it")
  a:endLive()
  r = a:event({ ev = "end", utt = 4, text = "what time is it" }, 12)
  t.eq(#r, 0, "back to waiting for the wake word")

  -- just the wake word: he says he's listening, and stays live
  local b = live()
  r = b:event({ ev = "end", utt = 1, text = "Okay Buddy" }, 0)
  t.eq(kinds(r), "wake,liveStart,ready", "bare wake: ready")
  t.eq(#b:tick(600), 0, "no timeout unless asked for")

  -- talking over him
  local c = live()
  c:event({ ev = "end", utt = 1, text = "okay Buddy tell me a story" }, 0)
  c:event({ ev = "speaking", id = 1 }, 2)
  c.saying = "Once upon a time there was a small robot"
  r = c:event({ ev = "words", utt = 2, text = "once upon a time" }, 3)
  t.eq(#r, 0, "his own voice coming back is ignored")
  r = c:event({ ev = "end", utt = 2, text = "once upon a time" }, 4)
  t.eq(#r, 0, "and is never sent")
  r = c:event({ ev = "words", utt = 3, text = "wait" }, 5)
  t.eq(kinds(r), "interrupt,words", "anything else while he talks cuts him off")
  r = c:event({ ev = "words", utt = 3, text = "wait what happened" }, 5.3)
  t.eq(kinds(r), "words", "only cut off once per utterance")
  c:event({ ev = "spoken", id = 1, cut = true }, 5.4)
  r = c:event({ ev = "end", utt = 3, text = "wait what happened" }, 6.5)
  t.eq(kinds(r), "send", "and what you said is sent")
  t.eq(r[1].text, "wait what happened", "interrupting words")
  c:event({ ev = "speaking", id = 2 }, 7)
  r = c:event({ ev = "words", utt = 4, text = "stop listening" }, 8)
  t.eq(kinds(r), "interrupt,words", "ending phrase over him cuts him off")
  r = c:event({ ev = "end", utt = 4, text = "stop listening" }, 9)
  t.eq(kinds(r), "liveEnd", "and ends the chat")

  -- echo whose "end" comes late (gap plus finalizing) is still echo
  local c2 = live()
  c2:event({ ev = "end", utt = 1, text = "okay Buddy tell me a story" }, 0)
  c2:event({ ev = "speaking", id = 1 }, 2)
  c2.saying = "Once upon a time there was a small robot"
  t.eq(#c2:event({ ev = "words", utt = 2, text = "there was a small robot" }, 4.8), 0, "late echo: words ignored")
  c2:event({ ev = "spoken", id = 1 }, 5)
  r = c2:event({ ev = "end", utt = 2, text = "there was a small robot" }, 7)
  t.eq(#r, 0, "late echo: end 2 s after he stopped is never sent")
  r = c2:event({ ev = "end", utt = 3, text = "there was a small robot" }, 9)
  t.eq(kinds(r), "send", "the same words later, never judged echo, are yours")

  -- another app has the microphone: not for him
  local d = live()
  d:event({ ev = "end", utt = 1, text = "okay Buddy hi" }, 0)
  r = d:event({ ev = "busy", on = true, app = "com.apple.Terminal" }, 10)
  t.eq(r[1][1], "hold", "paused while another app listens")
  t.eq(r[1].on, true, "hold is on")
  t.eq(#d:event({ ev = "words", utt = 2, text = "refactor this function" }, 11), 0, "not for him")
  t.eq(#d:event({ ev = "end", utt = 2, text = "refactor this function" }, 12), 0, "and not sent")
  r = d:event({ ev = "busy", on = false }, 13)
  t.eq(r[1].on, false, "hold released")
  r = d:event({ ev = "end", utt = 3, text = "ok back to you" }, 16)
  t.eq(kinds(r), "send", "live again after the other app lets go")

  -- the other app took the mic partway through an utterance
  local e = live()
  e:event({ ev = "end", utt = 1, text = "okay Buddy hi" }, 0)
  e:event({ ev = "start", utt = 2 }, 20)
  e:event({ ev = "busy", on = true, app = "x" }, 20.4)
  e:event({ ev = "busy", on = false }, 22)
  r = e:event({ ev = "end", utt = 2, text = "write a function" }, 22.5)
  t.eq(kinds(r), "drop", "an utterance that overlapped another app is dropped")

  -- optional quiet timeout
  local f = live(60)
  f:event({ ev = "end", utt = 1, text = "okay Buddy hi" }, 0)
  t.eq(#f:tick(59), 0, "not yet")
  t.eq(f:tick(61)[1].why, "quiet", "ends after the quiet time")

  -- off: the old one-shot behaviour
  local g = V.turns({ phrase = "okay Buddy", timeout = 6, live = false })
  r = g:event({ ev = "words", utt = 1, text = "okay Buddy hi" }, 0)
  t.ok(not has(r, "liveStart"), "live off: no live chat")

  -- he talks out loud in a live chat even with spoken answers off
  t.eq(V.decide("answer", { answers = false, live = true, muted = true }), true, "live answers aloud")
  t.eq(V.decide("answer", { answers = false, live = true, busy = true }), false, "not over another app")
end
