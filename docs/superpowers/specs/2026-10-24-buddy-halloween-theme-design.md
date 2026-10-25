# Buddy Halloween theme — design

Date: 2026-10-24 · Branch: `halloween-theme` · Ships in tonight's combined release (merge order: `skins`, `bubble-click`, `halloween-theme`)

## Intent

For Halloween week, the owner wants Buddy's corner of the desktop to become a little spooky pixel world. Buddy wears a witch hat and holds a jack-o'-lantern candy pail. A spider web hangs in the corner with a spider dangling from it, bats flap past, and Buddy's lines, jokes and brain all know it's Halloween. Funny little scenes ("skits") happen every so often: a bat lands on the hat until Buddy shakes it off, a bat steals the candy pail, a zombie chases Buddy, trick-or-treaters come by, and there are nods to horror movies. The owner's words: "fun things like that, and other sort of events in this little pixel world that happen like that, that are funny." The owner loved the real-size mockup (`.superpowers/brainstorm/96122-1792904181/content/halloween-scene.html` in the main checkout) and wants all of it, every skit included, in tonight's update.

## Goals

1. **Theme switch, on by itself:** active October 24–31 (local time), off from November 1. `halloween = true` or `false` in config.lua forces it on or off. *(the owner)*
2. **Costume:** when the theme starts, Buddy wears the **Witch** skin unless it's already wearing a Halloween skin. When the theme ends, Buddy goes back to its own skin. *(the owner: "default the witch hat"; the rest was played back to the owner and not objected to)*
3. **The world:** a corner spider web, a spider hanging from it and bobbing on its thread, the candy pail in Buddy's hand whenever its hands are free, and bats. Looks exactly like the approved mockup. *(the owner)*
4. **Skits:** about 41 short scenes (list below) that play every couple of minutes, all shipped tonight. *(the owner: "all in tonights update")*
5. **Lines and jokes:** spooky idle lines, click lines and jokes ("Boo!", "Trick or treat!", "Got any candy?"). *(the owner)*
6. **Brain:** the persona knows it's Halloween week, and on the 31st that it's Halloween today. *(the owner)*
7. **Preview page:** a browser gallery that plays every skit from its data file, so the owner can review them as they're built. *(my call, matching the skins gallery)*

## Non-goals

- Skins themselves, the Skin menu and per-skin particle reactions. The skins session owns those (`docs/superpowers/specs/2026-10-24-buddy-skins-design.md` on `skins`). Each Halloween skin already themes its own reactions.
- Other seasons (Christmas and so on). The skit engine is generic, so a later theme could reuse it, but nothing else ships tonight.
- Clicking the bats, spider or other actors. Clicks still go to Buddy only.
- Sound.

## Anti-goals (failure even if it works)

- A skit hides Buddy's face for more than a moment, or keeps Buddy from showing a real event (a crash, a Claude session finishing, a call). Real events win: they end the skit.
- Anything flashes. No full-box flashes, and nothing blinks faster than 3 times a second.
- The pail goes missing for good, or Buddy gets stuck off to one side after a chase. Every skit ends with Buddy home and the pail back, unless a chained skit is about to bring it back, and even then within 3 minutes.
- Skit lines flood the chat transcript.
- A broken skit file crashes or freezes Buddy. It's skipped with a console warning.
- The theme costs anything when it's off. Off means no drawing, no timers and no file loading beyond the date check.
- Copied likenesses, logos, or character names or movie titles in ids, menu labels, sprite names or the README, in the public repo. Horror nods are homages: generic props and short quoted lines. A spoken line may quote a movie briefly, including the one name the "say it three times" gag needs. *(my call, matching the skins session's takedown concern)*
- Personal data or business details in the public repo.

## Constraints

- Hammerspoon Lua, no build step. Buddy draws at 12 fps on a 200×170 `hs.canvas`, with one Buddy pixel = S = 5 points. Body grid origin on the canvas is x = 65, y = 98 (`BODY_TOP`), grid 14×12. `frame()` rebuilds the element list each frame and only calls `replaceElements` when its signature changes.
- Several sessions edit `buddy.lua` tonight. New code goes in new files; `buddy.lua` gets small call sites only.
- The skins contract (from the skins session, branch `skins`, commit e840e16 or later):
  - `buddy.lua` creates one `Skins` object (`local Skins` near line 109, right after the `C` colour table) and exposes it as `M.skins`. The theme gets that same object, handed over after it exists (or looked up lazily). It never loads its own copy.
  - `Skins.current()`, `Skins.pick(id)`, `Skins.wear(id)` / `Skins.wear(nil)`, `Skins.list()`, `Skins.topRows()` (rows the hat reaches above row 0; 0 with no hat), `Skins.float()`. Hat top y = `oy - Skins.topRows() * S`. In `frame()` on `skins`, `oy` already includes the bounce and the float, so anchors use that `oy`.
  - A menu pick clears any `wear` override. `wear` is idempotent; call it on theme start and stop only.
  - brain.lua on `skins` has `B.costume(name)`. The theme adds a separate hook (below) that appends after the costume sentence. The skins session resolves the 2-line conflict in `persona()` at merge time.
- The Hammerspoon copy running now (`~/.hammerspoon/claude-usage-widget`) is a fresh-install test, and its files stay untouched. The owner OK'd running the Lua specs and a hidden test Buddy from the worktree inside that Hammerspoon (`hs -c`), with settings kept separate. The test Buddy uses its own `hs.settings` key prefix, so it never reads or writes the running copy's skin pick or theme flags. Specs never reassign globals such as `print`; they pass a logger in. The full live check waits until the owner restores the normal copy.
- Public repo: plain-English README rows, no personal data, no character names.
- Branch off `main`, rebased onto `skins` before handoff so the hooks are tested against the real skin layers. No commits to `main`, no `tools/release`. When the branch is ready, hand it to whoever merges and releases: branch, head commit, test results and the checker name. They squash-merge and release when the owner says go.

## Build order and review

- Build the engine, the gallery, the checker and the shared sprites first, plus three reference skits (`fly-by`, `hat-perch`, `pail-heist`). Then build the rest in parallel, each builder writing only its own skit files. New sprites go in each skit's own `sprites` so builders never edit `sprites.json` at the same time. *(my call)*
- The owner reviews in the gallery as skits arrive and flags any to fix or drop in chat. Every skit must pass the checker. Unflagged skits ship. A flagged skit that isn't fixed by release time is left out. This is the same rule as skins. *(my call)*
- If time runs short, the priority is: the theme itself (dates, witch, web, spider, pail, bats, lines, brain, menu), then the Bats and Spider skits, then Visitors, then Movie night. The release itself waits for the owner's go. *(my call)*

## Decided

- **Dates:** on from Oct 24 00:00 to Oct 31 23:59 local, every year. *(the owner)*
- **Override order:** config.lua `halloween = true/false` wins. Then the menu toggle for the current year. Then the dates. *(the config part is the owner's; the menu toggle is my call)*
- **Dress-up rule:** when the theme turns on (at load or at midnight on the 24th), if `Skins.current().group ~= "halloween"`, `Skins.wear("witch")`. If the user picks a skin from the menu while the theme is on, the theme notices (current skin is no longer the one it put on) and saves `claudeBuddy.halloweenDressed = { year = Y, declined = true }`, so a reload doesn't re-dress Buddy that season. When the theme turns off, `Skins.wear(nil)`. *(the witch is the owner's; the rest was played back to the owner and matches the skins contract)*
- **Look:** the web, spider, bats and pail art, sizes and positions as in the approved mockup. Web in the top-left corner of Buddy's box, centre (2, 2), radius 62, spokes at 0/22/45/68/90°, three sagging rings at 0.35/0.6/0.85. Pale lines (`#eaecf4` at 85%) with a soft dark shadow, so it shows on light wallpapers too. The spider hangs from the outer ring on the 45° spoke and bobs ±4 pt around y = 96. Critters (spider, bats and other actors) use 3-point pixels. The pail uses Buddy's 5-point pixels, cols 15–19, rows 4–9. *(the owner approved the mockup)*
- **Candy pail:** drawn in Buddy's right hand whenever the current mood or action has no prop and the arms are `rest` or `hold`. It wins over a skin's `hand` layer while the theme is on. *(my call; the skins session agreed)*
- **Skits are data:** one JSON file per skit, plus a shared sprite library. Builders write JSON only, a checker validates it, and the same files drive both the Lua engine and the browser gallery. *(my call, same reasoning as skins: safe, checkable, parallel-buildable)*
- **How often:** while the theme is on, with chatter `chatty` a skit every 75–150 s, `normal` every 3–5 min, `quiet` every 10–15 min, `silent` none (except from the menu). On the 31st, twice as often. *(my call; the owner heard "every couple of minutes" and didn't object)*
- **When a skit may start:** Buddy is awake and not bored, someone's at the Mac (idle < 60 s), the mood is calm (`idle browsing generic reading mail watching chat chatting curious music`), there's no event mood or action showing, no drag in progress, and no other skit running. Skits that need the pail only start when it's showing. *(my call)*
- **What ends a skit early:** a click or drag on Buddy, a real event mood (events.lua, Grok, a finished Claude session, a usage warning), or Buddy falling asleep. All actors vanish, Buddy snaps home and the pail comes back. An interrupted skit drops its chain. The finished-session, usage-warning and Grok paths leave no state for `tick` to see, so they call `Theme.interrupt()` directly. *(my call)*
- **Picking:** weighted random over the skits whose `needs` are met. A skit can't repeat until 8 others have played. Chained skits (`next`) play only through their chain. *(my call)*
- **Chain fallback:** if a chained follow-up can't start within 3 minutes (the owner's away, Buddy's busy or asleep), it's dropped. If the pail is gone, it quietly reappears in Buddy's hand. *(my call)*
- **Skit lines** go in the bubble but stay out of the chat transcript (`say(text, true, true)`). They follow the mute ("Quiet for an hour") like other unprompted lines, and the skit still plays silently. *(my call)*
- **Lines while the theme is on:** about half of the idle, sleepy, morning and click lines come from Halloween pools, and so do jokes when there's no brain. Lines are at most 40 characters. *(my call)*
- **Brain:** while the theme is on, the persona gets: "It's Halloween week and you love it. Now and then, slip in a spooky pun or a nod to a classic horror movie." On Oct 31: "Today is Halloween, your favourite day of the year. …" with the same second sentence. *(the owner wants the brain to know; the wording is my call)*
- **Menu:** while the theme is on (or it's Oct 24–31 and switched off from the menu), right-click shows **Halloween ▸** with:
  - **Halloween theme** ✓ (the toggle)
  - **Spooky surprise** (plays a random skit now)
  - **Skits ▸** (every skit by name, grouped into Bats, Spider, Visitors and Movie night)

  Outside those dates the menu shows nothing, and config.lua is the way to force it on. *(my call)*
- **Test hook:** `hs -c 'ClaudeBuddy.skit("hat-perch")'` plays one skit, and `ClaudeBuddy.halloween(true|false)` flips the theme for this session without saving. *(my call)*

## Files

- `halloween.lua`: the theme. Date rule, overrides, dress-up, the web, spider and pail, line pools, the persona sentence, scheduling, the menu items, and the hooks buddy.lua calls.
- `skits.lua`: the generic skit engine, pure Lua with no `hs.*` calls, so specs can test it directly. Loads and validates sprite and skit files, and given a skit, its start time, now and the anchors, it returns what to draw and which cues fired. The gallery's JS mirrors it.
- `skits/sprites.json`: the shared sprite library (bat, spider, candy, pail, puff, ghost, cat, zombie, kids and so on).
- `skits/<id>.json`: one skit per file; `id` matches the filename.
- `tools/check-skits`: Python 3, standard library only. Validates every file. `tests/test_skits.py` runs it over `skits/`.
- `tools/skits-gallery`: serves the repo on `localhost:8743` (skins uses 8742) and opens `tools/skits.html` in Chrome.
- `tests/halloween_spec.lua`, `tests/skits_spec.lua`: Lua specs for the runner.
- README: a short "Halloween" section in plain English (when it's on, how to force it, the menu, how to add a skit).

## Sprite format (`skits/sprites.json`, or a skit's own `sprites`)

```json
{
  "bat": {
    "pixel": 3,
    "colors": { "X": "#0d0b12", "e": "#f5c542" },
    "anims": {
      "fly":   { "fps": 9, "frames": [["X...X.X...X", "XX..XXX..XX", "XXXXeXeXXXX", ".XX.XXX.XX.", "....X.X...."],
                                      ["....X.X....", "...XeXeX...", ".XXXXXXXXX.", "XX..XXX..XX", "X.........X"]] },
      "perch": { "frames": [["...X.X...", "..XeXeX..", ".XXXXXXX.", ".XX.X.XX.", "...X.X..."]] }
    }
  }
}
```

- A frame is a list of equal-length strings. `.` and space are transparent; every other character maps through `colors`. A colour is `#rrggbb`, `#rrggbbaa`, or a Buddy palette name (`body shade shine eye white grey dark red yellow gold brown blue pink`).
- `pixel`: points per sprite pixel (default 3; the pail is 5).
- Sprites face right. An actor key with `flip: true` mirrors it.
- The engine turns each row into runs of same-coloured pixels, so one rectangle covers each run. Keep sprites at most 24×24.
- A skit can define its own `sprites`. A local sprite with the same name as a library sprite wins inside that skit only.

## Skit format (`skits/<id>.json`)

```json
{
  "id": "hat-perch",
  "name": "Bat on the hat",
  "group": "bats",
  "weight": 3,
  "needs": [],
  "length": 9,
  "actors": [
    { "sprite": "bat", "layer": "front",
      "keys": [
        { "t": 0,   "x": 214, "y": 30, "anim": "fly", "flip": true },
        { "t": 1.6, "at": "top", "dy": 0, "ease": "out" },
        { "t": 1.7, "at": "top", "anim": "perch" },
        { "t": 6.2, "at": "top" },
        { "t": 6.3, "at": "top", "anim": "fly" },
        { "t": 8,   "x": -40, "y": 4 }
      ] }
  ],
  "buddy": [
    { "t": 1.7, "look": "top", "for": 4 },
    { "t": 3.5, "say": ["Um. Hello?", "There's a bat on me, isn't there."] },
    { "t": 6,   "action": "shaken", "for": 0.6 },
    { "t": 6.3, "say": ["Shoo!", "Off my hat!"] }
  ]
}
```

Fields:

- `id`, `name`, `group` (`bats spider visitors movies`), and `length` (seconds, at most 30) are required.
- `weight`: relative chance (default 2). 0 means it only plays as a chain.
- `needs`: `"pail"` (Buddy is holding it), `"evening"` (17:00–23:59).
- `next`: `{ "skit": "<id>", "after": 45, "chance": 1 }` queues a follow-up `after` seconds later, with probability `chance` (default 1). The follow-up waits for the start rules and plays within 3 minutes no matter what.
- `actors`: drawn in order. Each has:
  - `sprite`
  - `layer`: `front` (over Buddy, under the bubble) or `behind` (with the web, behind Buddy)
  - `keys`: at least one, with `t` ascending and within `length`
  - optional `bob`: `{ "amp": 3, "hz": 0.8 }`, a vertical sine
  - optional `thread`: `"web"`, a line from the web anchor to the sprite's top centre (for spider actors)
- **Keys:** a key's position is `x`, `y` (canvas points), or `at` (an anchor name) plus optional `dx`, `dy`. The position is the sprite's **bottom centre**. Position eases from one key to the next (`ease` on the arriving key: `linear` by default, or `in`, `out`, `inout`). `anim`, `flip` and `hide` take effect at their key and hold until changed. An actor appears at its first key and disappears after its last.
- **Anchors** follow Buddy live, through its bounce, float, run offset and hat:
  - `top`: hat tip, or head top with no hat: (cx, oy − topRows·S)
  - `head`: (cx, oy)
  - `face`: (cx, oy + 5·S)
  - `hand`: the pail handle, (ox + 17·S, oy + 4·S)
  - `feet`: (cx, GROUND)
  - `web`: the spider's anchor on the web
  - `spider`: where the resting spider is now
- **Buddy cues** (`buddy`, `t` ascending). Each fires once, when its time is reached:
  - `action` + `for`: any Buddy action (`joy startle hop wave look stretch dance blush ponder talk shaken dizzy grumpy`) or one of the theme's own: `duck` (squash down with wide eyes), `flee` (running legs, wide eyes, arms up), `eat` (happy eyes, munching mouth), `lookUp` (eyes up).
  - `say`: a line, or a list to pick one from.
  - `look` + `for`: eyes follow an anchor name or `[x, y]`.
  - `run` + `for`: Buddy slides to x offset `run` (points, 0 = home) over `for` seconds with running legs. Offsets reset to 0 when the skit ends.
  - `prop` + `for`: Buddy holds an existing prop (`phone`, for example) for a while.
  - `pail`: `"gone"` (hide the pail; an actor usually carries it) or `"back"`.
  - `spider`: `"away"` (hide the resting spider while a skit's own spider actor plays it) or `"home"`.
  - `emit`: a one-off burst of particles, for example `{ "glyphs": ["♪"], "color": "white", "count": 6, "from": "head" }`, using Buddy's particle system.

## The skits (all tonight)

**Bats**

1. `fly-by`: one bat crosses (the most common one; weight 6).
2. `bat-chase`: two bats chase each other in a loop.
3. `bat-swarm`: rare (weight 1). Six bats burst past and Buddy ducks. "Whoa!"
4. `hat-perch`: a bat lands on the hat tip. Buddy looks up and waits, then shakes it off and it flaps away. "Shoo!"
5. `bat-nap`: a bat hangs upside down from the hat brim and z's float up, until Buddy wiggles and it flies off.
6. `pail-heist`: needs the pail. A bat swoops in and flies off with it. "Hey! My candy!" Chains to `pail-return` after 40–60 s.
7. `pail-return`: chain only. A bat drops the pail back into Buddy's hand. "…One's missing."
8. `web-crash`: a bat gets stuck in the web, the spider creeps over, and the bat wriggles free.
9. `bat-gift`: needs the pail. A bat drops a candy into it and hearts float up.
10. `hat-bonk`: a bat bumps the hat and flies off dizzy, with stars.
11. `bat-vampire`: a bat lands, there's a puff, and a tiny vampire says "I vant to suck your… candy." Another puff, and it flaps off as a bat.

**Spider**

12. `spider-eek`: the spider drops fast in front of Buddy's face. Buddy jumps. "Eek!"
13. `candy-thief`: needs the pail. The spider lowers into it and climbs back up with a candy.
14. `spider-yoyo`: it bounces on its thread.
15. `spider-swing`: it swings like a pendulum.
16. `spider-wave`: it waves a leg and Buddy waves back.
17. `web-heart`: it weaves a heart into the web, then the heart fades.
18. `boo-back`: Buddy says "Boo!" and the spider scurries up.
19. `spider-shower`: it drops, and shower-scene violins screech ("Eee! Eee! Eee!" with ♪ bursts).

**Visitors**

20. `pail-ghost`: needs the pail. A tiny ghost pops out. "boo!" Buddy jumps, and the ghost giggles and fades.
21. `black-cat`: walks along the ground, stops to stare at Buddy, walks off. "Good kitty…?"
22. `broom-witch`: a tiny witch on a broom zooms across the sky. "Nice hat!"
23. `candy-rain`: needs the pail. Candy falls and Buddy catches it.
24. `candy-snack`: needs the pail. Buddy eats a candy. "Just one more."
25. `monster-mash`: Buddy dances and the bats bob along.
26. `skeleton-hand`: pops out of the ground, waves, sinks back. "…Did you see that?"
27. `pumpkin-roll`: a jack-o'-lantern rolls in, lights up, rolls off.
28. `full-moon`: "Full moon tonight…" A bat crosses a tiny moon, and a far-off "Awoooo!"
29. `zombie-chase`: a zombie shambles in with its arms out. Buddy flees off one side and the zombie follows. They come back the other way, Buddy now chasing the zombie, Scooby-Doo style. Chains to `zombie-dance` half the time.
30. `zombie-dance`: the zombie comes back and the two of them do the famous zombie music-video dance, claws up. The menu says "Zombie dance".
31. `trick-or-treat`: two tiny kids in costumes walk up with bags. "Trick or treat!" Buddy drops a candy in each bag, and they walk off. More often in the evening.
32. `greedy-kid`: rare, needs the pail. A kid takes the whole pail and runs. Chains to `pail-return`.

**Movie night** (homages, no names)

33. `red-balloon`: a red balloon floats up from below. "We all float down here…"
34. `scary-call`: Buddy's phone rings. "What's your favourite scary movie?"
35. `tv-static`: a tiny TV full of static. "They're heeere."
36. `run-lights`: a string of lights blinks R… U… N…, slowly enough not to flash.
37. `say-it-thrice`: "Beetlejuice… Beetlejuice…" Buddy stops before the third. "Nope." The menu says "Say it three times".
38. `its-alive`: a lightning bolt strikes beside Buddy, and sparks fly. "It's alive!"
39. `hockey-mask`: a hockey mask peeks in from the edge. "ch ch ch… ah ah ah…"
40. `twins`: two tiny twins stand at the edge. "Come play with us…" "No thank you!"
41. `ghost-call`: a ghost floats by and Buddy pulls out the phone. "Who you gonna call?"

The pixel art, timings, reactions and exact lines are the builder's, within the format.

## Gallery (`tools/skits.html`)

- Loads `skits/sprites.json` and every `skits/*.json` from the directory listing, and re-checks every 3 s. New skits get a NEW badge.
- One card per skit: a real-size 200×170 stage on a dark wallpaper (with a light-wallpaper toggle), the skit looping with a 2 s gap, and a 2× zoom button.
  - The stage shows the witch-hat Buddy (the mockup's renderer) with the web, the resting spider and the pail, plus the skit's actors and cues: bubble lines, look, run, the actions approximated (hop, jitter, sway, duck), pail gone and back, and particle bursts.
  - The card shows the skit's name, group, weight, needs, length and lines.
- An invalid file shows as a red card with the checker's reason.
- The gallery's JS uses the same sampling rules as `skits.lua` (key easing, step fields, anchors). The Lua engine is the source of truth; the gallery only has to be close enough to judge a skit by.

## buddy.lua call sites (keep them small)

- Load `halloween.lua` after `Skins` exists, then `Theme = dofile(...).configure({ cfg = CFG, skins = Skins, hooks = {...} })`. The hooks are small closures over buddy.lua's locals: `doAction`, `say`, look at a canvas point, `spawn` a particle burst, and the current mood/away/action state.
- `ACTIONS`: the theme adds `duck`, `flee`, `eat` and `lookUp` through the configure call. `drawEyes` gets an `up` eye kind (one line). Running legs reuse the existing alternating-legs code (`sway`), driven by the run offset.
- `frame()`:
  - `ox = ox + Theme.offset(t)` (run offset)
  - `Theme.behind(px, add, ox, oy, cx, f, at)` right after the shadow
  - the pail as a prop when the spec has no prop
  - `Theme.front(add, ox, oy, cx, f, at)` after particles, before the bubble

  `add` appends an element and a signature entry.
- `lineFor` and the click/joke pickers: one call each, `Theme.line(kind)`, which returns a Halloween line about half the time while the theme is on, or nil.
- `poll()`: `Theme.tick(t, state)` once a second. It does dates, dress-up and scheduling, and it ends skits on events.
- `startDrag` / `onMouseDown`: `Theme.interrupt()`.
- `showMenu()`: `Theme.menu()` returns the Halloween ▸ item, or nil.
- brain.lua: `B.addPersona(fn)` (a list of functions, each returning a sentence or nil, appended at the end of `persona()`). The theme registers its sentence.
- Exposed: `M.skit(id)` and `M.halloween(on)`.

## Testing

- `tests/skits_spec.lua`:
  - easing and interpolation
  - step fields (`anim`, `flip`, `hide`)
  - anchors with a moving Buddy, float and hat
  - cue firing (once each, in order, including cues skipped past by a slow frame)
  - run offset returns home
  - pail and spider state restored when a skit ends or is interrupted
  - loader skips bad files
  - weighted pick respects `needs`, no repeats and chains
- `tests/halloween_spec.lua`:
  - date rule: Oct 23 23:59 off, Oct 24 00:00 on, Oct 31 23:59 on, Nov 1 off
  - config true/false wins, and the menu override counts for its year only
  - dress-up with a fake Skins: dresses as witch, keeps a Halloween skin, a menu pick sticks across a reload, undresses at the end
  - persona sentence on, on the 31st, and off
- Specs inject the clock (date and time), since the theme is on in every test run this week.
- `tests/test_skits.py`: the checker passes on every shipped file, and fails on a set of broken examples.
- `tests/run.lua` passes after rebasing onto `skins` (it includes skins' spec that draws every skin through `frame()`).
- Live check once the owner restores the Hammerspoon copy: the theme on with the witch hat, every skit from the menu, a chase and a heist interrupted by a click, a Claude session finishing mid-skit, and CPU in Activity Monitor about the same as with the theme off.

## Left to the builder

- All pixel art for actors beyond the mockup's (bat frames, ghost, cat, zombie, kids, balloon, TV and so on), plus the skit timings and exact lines, within the format.
- The engine's internals, the gallery's look, and how the gallery approximates Buddy's actions.
- The Halloween line pools and jokes (at most 40 characters each, Buddy's voice, no names of real people or characters).
