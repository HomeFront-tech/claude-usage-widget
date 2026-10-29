-- setup.lua: switching brains keeps unrelated settings and chooses each engine's model.
return function(t, dir)
  local S = dofile(dir .. "/setup.lua")
  local tmp = t.tmpdir()
  local savedVoice = hs.settings.get("claudeBuddy.voice")
  local voiceOK, voiceError = pcall(function()
    hs.settings.set("claudeBuddy.voice", nil)
    local post = { type = "save", config = { voice = { listen = true, outLoud = 40 } } }
    S.saveVoice(post.config.voice)
    local voice = hs.settings.get("claudeBuddy.voice")
    t.eq(voice.listen, true, "wizard save turns listening on")
    t.eq(voice.outLoud, 40, "wizard save keeps the dial value")
    t.eq(voice.answers, true, "first-time listening defaults spoken answers on")
    S.saveVoice({ listen = true, answers = false })
    t.eq(hs.settings.get("claudeBuddy.voice").answers, false, "an explicit answer switch wins")
    t.eq(hs.settings.get("claudeBuddy.voice").bubbles, true, "a slider above never saves the bubble switch on")
    S.saveVoice({ outLoud = 40, bubbles = false })
    t.eq(hs.settings.get("claudeBuddy.voice").bubbles, false, "the bubble switch off is saved after the slider")
    t.eq(hs.settings.get("claudeBuddy.voice").outLoud, 40, "and the slider is kept")
  end)
  hs.settings.set("claudeBuddy.voice", savedVoice)
  t.ok(voiceOK, "voice save specs ran" .. (voiceOK and "" or ": " .. tostring(voiceError)))
  t.eq(S.voiceTrouble({ major = 26 }, function() return true end), nil, "voice works on macOS 26 with tools")
  t.eq(S.voiceTrouble({ major = 25 }, function() return true end), "Voice needs macOS 26 or later.", "older macOS explains why")
  t.eq(S.voiceTrouble({ major = 26 }, function() return false end),
    "Voice needs Apple's Command Line Tools: xcode-select --install", "missing tools explains how to install")
  local original = { ai = { model = "gemma3:4b", peek_every = 120, sources = { x = {} } } }
  S.save(tmp, original, { brain = "claude", chatter = "normal" })
  local c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.engine, "claude", "engine set")
  t.eq(c.ai.model, "haiku", "gemma swapped for haiku")
  t.eq(c.ai.peek_every, 120, "other ai keys kept")
  t.ok(c.ai.sources and c.ai.sources.x, "sources kept")
  S.save(tmp, c, { brain = "claude", chatter = "normal" })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.model, "haiku", "claude model kept")
  S.save(tmp, c, { brain = "ollama", chatter = "normal" })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.engine, nil, "back to ollama")
  t.eq(c.ai.model, "gemma3:4b", "ollama model")
  t.eq(c.ai.peek_every, 120, "other keys survive return")
  c.ai.model = "llava:7b"
  S.save(tmp, c, { brain = "ollama", chatter = "normal" })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.model, "llava:7b", "ollama model kept")
  S.save(tmp, c, { brain = false, chatter = "normal" })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai, nil, "plain rules clears brain")
  t.eq(S.initial({ ai = { engine = "claude" } }).brain, "haiku", "a claude config without a model starts on haiku")
  t.eq(S.initial({ ai = {} }).brain, "ollama", "wizard starts on ollama")
  t.eq(S.initial({}).brain, false, "wizard starts without brain")
  t.eq(S.initial({}).apps, nil, "initial leaves app scanning to open")

  -- personality dials: only dials off their defaults are saved; untouched config keeps its own
  S.save(tmp, {}, { chatter = "normal", personality = { humor = 90, sarcasm = 60, honesty = 60, warmth = 60, wordiness = 30 } })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.personality.humor, 90, "a moved dial is saved")
  t.eq(c.personality.sarcasm, nil, "a dial at its default is not")
  S.save(tmp, c, { chatter = "normal" })
  t.eq(dofile(tmp .. "/config.lua").personality.humor, 90, "a wizard that leaves dials alone keeps them")
  S.save(tmp, c, { chatter = "normal", personality = { humor = 75 } })
  t.eq(dofile(tmp .. "/config.lua").personality, nil, "all defaults clears the key")
  t.eq(S.initial({ personality = { wordiness = 80 } }).personality.wordiness, 80, "wizard starts on the saved dial")
  t.eq(S.initial({}).personality.humor, 75, "and on the default when none is saved")

  -- telegram: a new pairing is written with a whole-number chat id; nil keeps it, false removes it
  S.save(tmp, {}, { chatter = "normal", telegram = { chat_id = 42.0, bot = "MyBuddyBot", name = "Sam" } })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.telegram.chat_id, 42, "chat id saved")
  t.eq(math.type(c.telegram.chat_id), "integer", "as a whole number")
  t.eq(c.telegram.bot, "MyBuddyBot", "bot name saved")
  c.telegram.extra = true
  S.save(tmp, c, { chatter = "normal" })
  c = dofile(tmp .. "/config.lua")
  t.ok(c.telegram and c.telegram.chat_id == 42 and c.telegram.extra, "kept when the wizard leaves it alone")
  S.save(tmp, c, { chatter = "normal", telegram = { chat_id = 7, bot = "OtherBot", name = "Al" } })
  c = dofile(tmp .. "/config.lua")
  t.ok(c.telegram.chat_id == 7 and c.telegram.extra, "pairing again replaces the chat, keeps the rest")
  S.save(tmp, c, { chatter = "normal", telegram = false })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.telegram, nil, "turned off")
  t.eq(S.initial({ telegram = { chat_id = 42, bot = "MyBuddyBot", name = "Sam" } }).telegram.bot, "MyBuddyBot", "wizard shows the paired bot")
  t.eq(S.initial({}).telegram, false, "wizard starts without telegram")
  t.eq(S.initial({ telegram = {} }).telegram, false, "no chat id is no telegram")
  t.ok((S.qrCode("https://t.me/MyBuddyBot?start=123456") or ""):match("^data:image/png;base64,") ~= nil, "QR code for the phone")
  S.save(tmp, {}, { chatter = "normal", planPrice = "100" })
  t.eq(dofile(tmp .. "/config.lua").plan_price, 100, "plan price saved as a number")
  S.save(tmp, { plan_price = 100 }, { chatter = "normal", planPrice = "" })
  t.eq(dofile(tmp .. "/config.lua").plan_price, nil, "skip clears the plan price")
  t.eq(S.initial({ plan_price = 200 }).planPrice, 200, "wizard starts on the saved plan price")
  t.eq(dofile(dir .. "/config.example.lua").plan_price, nil, "the example doesn't assume a plan price")
  -- switching brains from the menu writes only that change
  local base = { name = "Pat", ai = { engine = "claude", model = "haiku", peek_every = 120 } }
  local nb = S.setBrain(tmp, base, "opus")
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.model, "opus", "setBrain writes the model")
  t.eq(c.ai.engine, "claude", "setBrain keeps the claude engine")
  t.eq(c.ai.peek_every, 120, "setBrain keeps other ai keys")
  t.eq(c.name, "Pat", "setBrain keeps other settings")
  t.eq(nb.ai.model, "opus", "setBrain returns the new table")
  t.eq(base.ai.model, "haiku", "setBrain leaves the old table alone")
  c = S.setBrain(tmp, c, "auto")
  t.eq(dofile(tmp .. "/config.lua").ai.model, "auto", "auto is a model choice")
  c = S.setBrain(tmp, c, "ollama")
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.engine, nil, "ollama clears the engine")
  t.eq(c.ai.model, "gemma3:4b", "ollama gets its model")
  t.eq(c.ai.peek_every, 120, "ollama keeps other ai keys")
  S.setBrain(tmp, c, false)
  t.eq(dofile(tmp .. "/config.lua").ai, nil, "false is plain rules")
  local fresh = S.setBrain(tmp, {}, "sonnet")
  t.eq(fresh.ai.engine, "claude", "a claude choice works from plain rules")
  t.eq(fresh.ai.model, "sonnet", "and picks that model")
  local opt = S.setOption(tmp, { name = "Pat" }, "chatter", "quiet")
  c = dofile(tmp .. "/config.lua")
  t.eq(c.chatter, "quiet", "setOption writes the key")
  t.eq(c.name, "Pat", "setOption keeps the rest")
  t.eq(opt.chatter, "quiet", "setOption returns the new table")
  S.setOption(tmp, c, "chatter", nil)
  t.eq(dofile(tmp .. "/config.lua").chatter, nil, "nil removes the key")

  -- the menu's choice -> key/label/kind (buddy.lua's M.setBrain relies on it)
  local k, label, claude = S.brainInfo(false)
  t.eq(k, "plain", "false is plain rules")
  t.eq(label, "Plain rules", "false label")
  t.eq(claude, false, "plain is not claude")
  k, label, claude = S.brainInfo(true)
  t.eq(k, "ollama", "true is ollama")
  t.eq(label, "Ollama on this Mac", "true label")
  t.eq(claude, false, "ollama is not claude")
  k, label, claude = S.brainInfo("auto")
  t.eq(label, "Auto", "auto label")
  t.eq(claude, true, "auto is claude")
  k, label, claude = S.brainInfo("opus")
  t.eq(k .. "|" .. label, "opus|Opus", "opus key and label")
  t.eq(claude, true, "opus is claude")

  -- the wizard's brain, reactions, watching and health answers
  t.eq(S.initial({ ai = { engine = "claude", model = "haiku" } }).brain, "haiku", "haiku config starts on haiku")
  t.eq(S.initial({ ai = { engine = "claude", model = "auto" } }).brain, "auto", "auto config starts on auto")
  t.eq(S.initial({ ai = { engine = "claude", model = "fable" } }).brain, "fable", "fable config starts on fable")
  t.eq(S.initial({ ai = { engine = "claude", model = "claude-x-1" } }).brain, "haiku", "a full model name starts on haiku")
  t.eq(S.initial({ ai = { model = "gemma3:4b" } }).brain, "ollama", "ollama config starts on ollama")
  local fresh0 = S.initial({})
  t.eq(fresh0.watch, true, "watching defaults on")
  t.eq(fresh0.health, false, "health defaults off")
  t.eq(fresh0.sitMinutes, 60, "sit default")
  t.eq(fresh0.autoReactions, false, "auto reactions default off")
  local set0 = S.initial({ watch = false, health = { sit_minutes = 90 }, auto_reactions = true })
  t.eq(set0.watch, false, "watch off is kept")
  t.eq(set0.health, true, "a health table turns health on")
  t.eq(set0.sitMinutes, 90, "sit minutes are read")
  t.eq(set0.autoReactions, true, "auto reactions are read")
  t.eq(S.initial({ health = true }).health, true, "health = true is on")

  t.eq(S.rowMood({ never_look = { "n" } }, "n", "generic"), "never", "never look wins")
  t.eq(S.rowMood({ auto_reactions = true, apps = { p = "music" } }, "p", "generic"), "music", "a pin beats auto")
  t.eq(S.rowMood({ auto_reactions = true }, "q", "generic"), "auto", "auto when on")
  t.eq(S.rowMood({}, "q", "coding"), "coding", "built-in default when auto is off")
  t.eq(S.rowMood({ apps = { Name = "chat" } }, "q", "coding", "Name"), "chat", "older name-keyed pin")

  local m, own = S.rowMood({ auto_reactions = true, apps = { b = "coding" } }, "b", "coding")
  t.eq(m .. "|" .. tostring(own), "coding|true", "a pin equal to the built-in is the user's own pick")
  t.eq(select(2, S.rowMood({ never_look = { "n" } }, "n", "generic")), true, "never look is a pick")
  t.eq(select(2, S.rowMood({ auto_reactions = true }, "q", "generic")), nil, "auto is not a pick")
  t.eq(select(2, S.rowMood({}, "q", "generic")), nil, "a built-in default is not a pick")

  local rows = {
    { id = "a", mood = "auto", default = "coding" },
    { id = "b", mood = "coding", default = "coding" },
    { id = "c", mood = "never", default = "generic" },
  }
  local wiz = { brain = "opus", watch = false, health = true, sitMinutes = 90, autoReactions = true, apps = rows }
  S.save(tmp, { apps = { a = "music", z = "chat" }, never_look = { "old", "c" }, health = { daily_cap = 3 } }, wiz)
  c = dofile(tmp .. "/config.lua")
  t.eq(c.ai.model, "opus", "wizard writes the chosen model")
  t.eq(c.ai.engine, "claude", "and the claude engine")
  t.eq(c.watch, false, "watch false is written")
  t.eq(c.health.sit_minutes, 90, "sit minutes written")
  t.eq(c.health.daily_cap, 3, "other health keys kept")
  t.eq(c.auto_reactions, true, "auto reactions written")
  t.eq(c.apps.b, "coding", "a pin equal to the built-in is kept under auto")
  t.eq(c.apps.a, nil, "an auto row has no pin")
  t.eq(c.apps.z, "chat", "pins for apps not on the list survive")
  t.eq(#c.never_look, 2, "never look keeps old ids and adds new")
  t.eq(c.never_look[1] .. c.never_look[2], "oldc", "never look order, no duplicates")
  wiz.autoReactions = false
  S.save(tmp, {}, wiz)
  c = dofile(tmp .. "/config.lua")
  t.eq(c.apps, nil, "without auto only changed rows are stored")
  t.eq(c.auto_reactions, nil, "auto reactions off writes nothing")
  t.eq(c.never_look[1], "c", "never look stays without auto")
  S.save(tmp, {}, { brain = false, autoReactions = true, apps = {} })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.auto_reactions, nil, "auto reactions need a brain")
  t.eq(c.watch, true, "watch is always written")
  t.eq(c.wizard, 2, "the wizard marks the configs it saves")
  local page = io.open(dir .. "/setup.html"):read("a")
  t.ok(page:find("Meal check-ins need a brain; goals and plans need Claude.", 1, true), "the health step says what needs a brain")
  local viaMenu = S.setOption(tmp, { name = "Pat" }, "watch", true)
  t.eq(viaMenu.wizard, nil, "the watching switch does not mark a config as wizard-made")
  t.eq(dofile(tmp .. "/config.lua").wizard, nil, "and nothing is written for it")
  S.save(tmp, {}, { brain = false, autoReactions = true, apps = {} })
  t.eq(c.health, nil, "health off writes nothing")
  t.eq(c.never_look, nil, "no never list when empty")
  S.save(tmp, { health = { sit_minutes = 45 }, never_look = { "x" } }, { brain = false, health = false, apps = { { id = "x", mood = "generic", default = "generic" } } })
  c = dofile(tmp .. "/config.lua")
  t.eq(c.health, nil, "health off removes the table")
  t.eq(c.never_look, nil, "an app moved off Never look leaves the list")
  S.save(tmp, {}, { brain = false, health = true, sitMinutes = "x", apps = {} })
  t.eq(dofile(tmp .. "/config.lua").health.sit_minutes, 60, "bad sit minutes fall back to 60")

  -- the model check: cached for a day, else a ping through bin/buddy-agent
  local savedChecks = hs.settings.get("claudeBuddy.modelChecks")
  local realNew = hs.task.new
  local seen, answers = {}, {}
  local function fake(out)
    return function(cmd, cb, args)
      seen.cmd, seen.args = cmd, args
      return {
        setEnvironment = function(self, env) seen.env = env return self end,
        setInput = function(self, s) seen.input = s return self end,
        start = function(self) cb(0, out, "") return self end,
      }
    end
  end
  local ok, err = pcall(function()
    hs.settings.set("claudeBuddy.modelChecks", nil)
    hs.task.new = fake('noise\n{"ok":true,"text":"OK"}\n')
    S.checkModel(tmp, {}, "sonnet", function(good) answers[#answers + 1] = good end)
    t.eq(answers[1], true, "a good ping is on your plan")
    local req = hs.json.decode(seen.input)
    t.eq(req.kind .. "|" .. req.model, "ping|sonnet", "ping request")
    t.eq(req.system .. "|" .. req.prompt, "Reply with OK.|OK?", "ping text")
    t.ok(seen.env.BUDDY_AGENT_DIR and seen.env.HOME and seen.env.PATH, "ping env")
    t.ok(seen.args[1]:match("/bin/buddy%-agent$"), "runs bin/buddy-agent")
    t.eq(hs.settings.get("claudeBuddy.modelChecks").sonnet.ok, true, "result cached")
    seen.input = nil
    S.checkModel(tmp, {}, "sonnet", function(good) answers[#answers + 1] = good end)
    t.eq(seen.input, nil, "a fresh cache entry skips the ping")
    t.eq(answers[2], true, "cached answer")
    hs.settings.set("claudeBuddy.modelChecks", { opus = { ok = false, at = os.time() - 90000 } })
    hs.task.new = fake('{"ok":false,"error":"nope"}')
    S.checkModel(tmp, {}, "opus", function(good) answers[#answers + 1] = good end)
    t.eq(answers[3], false, "a stale entry is checked again")
    t.eq(hs.settings.get("claudeBuddy.modelChecks").opus.ok, false, "failure cached")
    hs.task.new = fake("garbage")
    hs.settings.set("claudeBuddy.modelChecks", nil)
    S.checkModel(tmp, {}, "haiku", function(good) answers[#answers + 1] = good end)
    t.eq(answers[4], false, "an unreadable answer is not on your plan")
    t.eq(hs.settings.get("claudeBuddy.modelChecks"), nil, "an unreadable answer is not cached")
    -- start() returning false with no callback still answers, and drops the task
    local stuck = {
      setEnvironment = function(self) return self end, setInput = function(self) return self end,
      start = function() return false end,
    }
    hs.task.new = function() return stuck end
    hs.settings.set("claudeBuddy.modelChecks", nil)
    local before = #answers
    S.checkModel(tmp, {}, "fable", function(good) answers[#answers + 1] = good end)
    t.eq(#answers, before + 1, "a task that won't start still answers")
    t.eq(answers[#answers], false, "and says not on your plan")
    t.eq(S.modelTasks.fable, nil, "the task reference is cleared")
    hs.task.new = function() return { setEnvironment = function() error("boom") end } end
    S.checkModel(tmp, {}, "fable", function(good) answers[#answers + 1] = good end)
    t.eq(#answers, before + 2, "a start error still answers")
    t.eq(S.modelTasks.fable, nil, "and clears the reference")
    seen.input = nil
    S.checkModel(tmp, {}, "bogus", function(good) answers[#answers + 1] = good end)
    t.eq(seen.input, nil, "unknown aliases are not pinged")
  end)
  hs.task.new = realNew
  hs.settings.set("claudeBuddy.modelChecks", savedChecks)
  t.ok(ok, "model check specs ran" .. (ok and "" or ": " .. tostring(err)))

  -- Opening the wizard runs nothing synchronously (a slow command would freeze the buddy):
  -- the voice lists load in the background. The window is a stand-in; nothing shows.
  local realExecute, realView, realUC, realFocus = hs.execute, hs.webview.new, hs.webview.usercontent.new, hs.focus
  local executed = 0
  local openOK, openErr = pcall(function()
    hs.execute = function(...) executed = executed + 1; return realExecute(...) end
    hs.webview.new = function()
      return setmetatable({}, { __index = function() return function(self) return self end end })
    end
    hs.webview.usercontent.new = function() return { setCallback = function(self) return self end } end
    hs.focus = function() end
    local W = dofile(dir .. "/setup.lua")
    W.open({ dir = dir, config = {}, builtinMood = function() return "generic" end })
    W.wv = nil
  end)
  hs.execute, hs.webview.new, hs.webview.usercontent.new, hs.focus = realExecute, realView, realUC, realFocus
  t.ok(openOK, "the wizard opens" .. (openOK and "" or ": " .. tostring(openErr)))
  t.eq(executed, 0, "opening the wizard runs no hs.execute")

  -- the other AIs on the usage card: saved only when they differ from Claude only
  S.save(tmp, {}, { chatter = "normal" })
  t.eq(dofile(tmp .. "/config.lua").usage, nil, "no usage answers, no usage table")
  S.save(tmp, {}, { chatter = "normal", usage = { order = { "claude" }, warn_at = 70, hot_at = 90, alert_red = false,
    providers = { claude = { refresh = 300, hide = {} } } } })
  t.eq(dofile(tmp .. "/config.lua").usage, nil, "all defaults write nothing")
  S.save(tmp, {}, { chatter = "normal", usage = { order = { "claude", "codex", "grok_plan" }, warn_at = 60, hot_at = 85,
    alert_red = true, providers = { claude = { refresh = 300, hide = { "Week · Sonnet" } }, codex = { refresh = 300 },
      openrouter = { refresh = 900, budget = 50, key = "sk-or-v1-testkey123" }, grok_plan = { plan = "SuperGrok", renews_day = 14 } } } })
  local u = dofile(tmp .. "/config.lua").usage
  t.eq(table.concat(u.order, ","), "claude,codex,grok_plan", "order saved")
  t.eq(u.warn_at .. "/" .. u.hot_at, "60/85", "levels saved")
  t.eq(u.alert_red, true, "alert saved")
  t.eq(u.providers.claude.hide[1], "Week · Sonnet", "hidden labels saved")
  t.eq(u.providers.claude.refresh, nil, "default refresh dropped")
  t.eq(u.providers.codex, nil, "an all-default provider dropped")
  t.eq(u.providers.openrouter.budget, 50, "budget kept while OpenRouter is off")
  t.eq(u.providers.grok_plan.renews_day, 14, "renewal day")
  t.ok(not io.open(tmp .. "/config.lua"):read("a"):find("testkey123", 1, true), "a key never reaches config.lua")
  local back = S.initial(dofile(tmp .. "/config.lua")).usage
  t.eq(table.concat(back.order, ","), "claude,codex,grok_plan", "round trip order")
  t.eq(back.providers.claude.hide[1], "Week · Sonnet", "round trip hide")
  t.eq(back.providers.openrouter.budget, 50, "round trip budget")
  t.eq(table.concat(S.initial({}).usage.order, ","), "claude", "wizard starts Claude only")
  t.eq(#S.initial({}).usage.known, 5, "every provider offered")
  S.save(tmp, { usage = { alert_red = true } }, { chatter = "normal" })
  t.eq(dofile(tmp .. "/config.lua").usage.alert_red, true, "kept when the page sends none")

  -- keys wait in memory until Save: each saved in turn, then removals; the first failure stops it
  local stub = { saved = {}, forgot = {} }
  function stub.save(id, key, done) stub.saved[id] = key; done(true) end
  function stub.forget(id, done) stub.forgot[id] = true; done(true) end
  local failed = "unset"
  S.saveKeys(stub, { openrouter = "k1" }, { xai = true }, function(f) failed = f end)
  t.eq(stub.saved.openrouter, "k1", "key saved")
  t.ok(stub.forgot.xai, "removed key forgotten")
  t.eq(failed, nil, "nothing failed")
  S.saveKeys({ save = function(_, _, done) done(false) end, forget = function(_, done) done(true) end },
    { openrouter = "k1" }, {}, function(f) failed = f end)
  t.eq(failed, "openrouter", "a failed save names the AI")
  local how
  S.saveKeys({ save = function(_, _, done) done(true) end, forget = function(_, done) done(false) end },
    {}, { xai = true }, function(f, what) failed, how = f, what end)
  t.eq(failed .. "|" .. tostring(how), "xai|remove", "a failed removal stops Save too")
  S.save(tmp, {}, { chatter = "normal", usage = { order = { "claude" }, warn_at = 80, hot_at = 90, alert_red = false, providers = {} } })
  t.eq(S.initial(dofile(tmp .. "/config.lua")).usage.warn_at, 80, "yellow moved alone survives a reload")

  -- the page's messages: checks, keys held in memory, never echoed back
  local sent, cb, runs = {}, nil, {}
  local view = setmetatable({ evaluateJavaScript = function(self, s) sent[#sent + 1] = s; return self end },
    { __index = function() return function(self) return self end end })
  local msgOK, msgErr = pcall(function()
    hs.webview.new = function() return view end
    hs.webview.usercontent.new = function() return { setCallback = function(self, fn) cb = fn; return self end } end
    hs.focus = function() end
    local W = dofile(dir .. "/setup.lua")
    W.poll = { run = function(_, script, args, input, done) runs[#runs + 1] = { script = script, args = args, input = input, done = done } end }
    W.open({ dir = dir, config = {}, builtinMood = function() return "generic" end })
    cb({ body = { type = "providerCheck", id = "grok_plan", fields = { plan = "SuperGrok", renews_day = 14 } } })
    t.ok(sent[#sent]:find("window.onProviderCheck", 1, true) and sent[#sent]:find("Working · Renews", 1, true), "Grok check answers")
    cb({ body = { type = "providerCheck", id = "openrouter", key = "bad key", fields = {} } })
    t.ok(sent[#sent]:find("That doesn't look like a key", 1, true), "a malformed key is refused")
    t.eq(W.keys.openrouter, nil, "and not held")
    cb({ body = { type = "providerCheck", id = "openrouter", key = " sk-or-v1-testkey123\n", fields = { budget = 50 } } })
    t.eq(W.keys.openrouter, "sk-or-v1-testkey123", "a key is held until Save")
    local run = runs[#runs]
    t.ok(run and run.script:match("/bin/ai%-usage$"), "the check runs bin/ai-usage")
    t.eq(run and table.concat(run.args, " "), "openrouter --budget 50 --key-stdin", "with the key on stdin")
    t.eq(run and run.input, "sk-or-v1-testkey123\n", "the key goes in on stdin")
    run.done({ ok = true, provider = "openrouter", credits = { { label = "This month", used = 12.5, limit = 50, pct = 25 } } })
    t.ok(sent[#sent]:find("This month", 1, true), "the check's labels go back")
    for _, s in ipairs(sent) do t.ok(not s:find("testkey123", 1, true), "the page never gets the key back") end
    cb({ body = { type = "keyRemove", id = "openrouter" } })
    t.eq(W.keys.openrouter, nil, "remove drops the held key")
    t.ok(W.removeKeys.openrouter, "and deletes the saved one at Save")
    cb({ body = { type = "providerCheck", id = "nope" } })
    W.wv = nil
  end)
  hs.webview.new, hs.webview.usercontent.new, hs.focus = realView, realUC, realFocus
  t.ok(msgOK, "the wizard's provider messages" .. (msgOK and "" or ": " .. tostring(msgErr)))
end
