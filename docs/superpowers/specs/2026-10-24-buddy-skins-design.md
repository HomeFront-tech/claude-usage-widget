# Buddy skins — design

Date: 2026-10-24 · Branch: `skins` · Ships in tonight's combined release (with `bubble-click` and `halloween-theme`)

## Intent

The owner wants Buddy to have **skins**: costumes and colour swaps the user picks from a menu. Some are seasonal (Halloween), most are "everyday" fun: outfits, memes, superheroes, games, anime, movies. Each skin is themed through and through. It changes how Buddy looks, and also the little emoji-style reactions that float off it when you shake it, click it, or it gets happy, dizzy or sleepy. The owner's words: "It should all be unique and themed accordingly, respectively for each skin."

The **Halloween theme** (spider web, spider, bats, candy pail, spooky lines, a Halloween-aware brain, auto-on in late October) is a separate feature built in a separate session on branch `halloween-theme`. This design only gives it a way to put Buddy in a skin (see "Theme contract").

## Goals

1. A skin system: skins are **data files** (JSON) in `skins/`. Buddy loads them all, and the right-click menu has a **Skin** submenu to switch. The choice survives restarts and updates.
2. Every skin can theme Buddy's **reactions**: the particles for any action or mood (shaken, dizzy, joy, dance, love, worried, money, sleep, and so on), with emoji allowed.
3. Every skin can carry a few of its own **lines** that mix into what Buddy says on clicks and when idle.
4. A **review gallery** in Chrome (`tools/skins-gallery`) shows every skin animated, with buttons to preview its reactions. It picks up new skin files by itself every few seconds, so the owner can watch skins arrive as agents build them.
5. A **checker** (`tools/check-skins`) that validates skin files, so parallel builders can't ship a broken one.
6. Skins to ship tonight:
   - **Batch 1 (approved in the mockup):** Classic (today's Buddy), Witch, Vampire (cute fangs), Pumpkin, Ghost, Franken-Buddy, Winter (toque **plus a Santa beard**), Hard hat (**plus a hammer**), Midnight, Mint.
   - **Batch 2 (requested; built by parallel Sonnet agents, reviewed by the owner in the gallery):** see "Batch 2 skins".
7. Users can add **their own skins**: any `.json` in `~/Library/Application Support/claude-usage-widget/skins/` loads too, same format.

## Non-goals

- The Halloween theme itself (other session).
- A skin picker inside the setup wizard (the gallery's renderer makes this easy later).
- Changing how Buddy behaves per skin beyond looks, particles and a few lines. Moods, eyes and timing stay the engine's.
- Animated multi-frame "costume changes" between skins.

## Anti-goals (failure even if it works)

- A skin hides Buddy's face so moods stop reading. Eyes and mouth stay engine-drawn and visible. A skin may add things over them (fangs, a beard around the mouth, shades) only where the costume needs it.
- A bad skin file crashes or freezes Buddy. Loading is defensive: an invalid file is skipped with a console warning.
- The speech bubble covers Buddy's face. It may overlap the tip of a tall hat.
- Personal data or business details in the public repo.

## Constraints

- Hammerspoon Lua, no build step. Buddy draws at 12 fps on a 200x170 `hs.canvas`, with one character pixel = S = 5 points. The body sits on a 14x12 grid (cols 0–13, rows 0–11, legs on rows 10–11). Grid origin on the canvas is x = 65, y = 98, so the canvas spans cols −13..26 and rows −19..14.
- Public repo, auto-updated installs (`updater.lua`). Skins must work on a fresh install with no config.
- Several sessions edit `buddy.lua` tonight. Keep `buddy.lua` changes contained: new code goes in `skins.lua`, and `buddy.lua` gets small call sites.

## Decided

- **Skins are data, not code.** Agents write JSON only. No agent-written Lua runs inside Buddy. *(my call: safer, checkable, and the browser gallery can render the exact same files)*
- **Menu:** right-click → **Skin ▸** with a submenu per group and a check mark on the current skin, plus **Surprise me** (random skin). *(Surprise me is my call)*
- **Persistence:** `hs.settings` key `claudeBuddy.skin`, not config.lua, so the setup wizard never touches it. *(my call)*
- **The brain knows the costume:** when the skin isn't Classic, the persona gets one sentence, "You're dressed as <name> right now." *(my call)*
- **Per-skin lines** mix in about one time in three. `idle` lines join the plain idle mood's lines and the unprompted ambient chatter, never the context moods (like "Claude's done! Your turn."). `click` lines join `CLICK_LINES`, which only shows without a brain. With a brain, the persona sentence makes the brain's own lines costume-themed instead. *(my call)*
- **Tall hats and the bubble:** the bubble rises by the height of the skin's `top` layer, clamped to the canvas top. A long bubble may cover the top of a tall hat, but never the face. The canvas size and `BODY_TOP` stay the same, so saved positions don't move. *(my call)*
- **Batch 2 review:** every Batch 2 skin must pass the checker, and I look at each one in the gallery. The owner flags any skin to fix or drop in chat. Whatever isn't flagged at release time ships; anything flagged and not fixed by then is left out. The gallery stays view-only. *(my call)*
- **Mockup:** batch 1 is ported from `.superpowers/brainstorm/70514-1792901697/content/skins-v2.html` in the main checkout. Winter gets a Santa beard (leaving the mouth visible), and Hard hat gets a hammer (`hand` layer, tapping). *(the owner's picks; the pixel details are my call)*

## Skin file format

One file per skin: `skins/<id>.json`, where `id` matches the filename.

```json
{
  "id": "witch",
  "name": "Witch",
  "group": "halloween",
  "colors":  { "body": "#d97857", "shade": "#b35c42", "shine": "#f09e80", "eye": "#1a1414" },
  "palette": { "hat": "#3d2459", "band": "#7bd14b", "buckle": "#f5c542" },
  "float": 0,
  "shadow": 36,
  "legs": null,
  "behind": [],
  "body": [],
  "face": [],
  "hand": [],
  "top": [[-2, -1, 18, 1, "hat"], [2, -2, 10, 1, "band"], [6, -2, 2, 1, "buckle"]],
  "reactions": {
    "shaken": { "glyphs": ["🦇", "✦"], "color": "hat", "size": 13 },
    "joy":    { "glyphs": ["🎃"] }
  },
  "lines": { "click": ["Hehehe!"], "idle": ["Double, double…"] }
}
```

- Only `id`, `name` and `group` are required. Everything else is optional.
- **group**: one of `classic`, `outfits`, `memes`, `heroes`, `games`, `screen`, `halloween`. Menu labels: Classic & colours, Outfits, Memes, Heroes, Games & anime, Movies & TV, Halloween.
- **colors**: overrides for the base body colours (`body`, `shade`, `shine`, `eye`). The engine draws the body, arms and legs in these.
- **palette**: the skin's own named colours.
- **A rect** is `[col, row, w, h, color]`, in character pixels. Ints only. `color` is a palette name, a base name (`body shade shine eye white grey dark red yellow gold brown blue pink`), or `#rrggbb` / `#rrggbbaa`.
- **A layer** is an array of rects, or an animated layer `{ "fps": 3, "frames": [[rects], [rects], …] }`.
- **Layers and draw order:** shadow → `behind` (capes, wings, bolts) → legs (engine; `legs` replaces them with a layer, or `false` for none) → body (engine, in `colors`) → `body` (markings on the body: ribs, hair, logos) → eyes and mouth (engine, mood-driven) → `face` (fangs, beard, mask edges; keep the eyes visible) → engine glasses and sweat → arms (engine, in body colour) → the mood's prop, or `hand` when the mood has none and the arms are resting → `top` (hats, hair, horns, ears) → particles → bubble.
- **float**: points to lift Buddy off the ground (the Ghost floats). **shadow**: shadow half-width in points (default 36).
- **Bounds:** keep rects within cols −6..20 and rows −9..12. Tall hats use at most 8 rows above the head (row −8).
- **reactions**: particle overrides keyed by an action or mood name (`shaken dizzy joy dance love blush ponder worried money call sleep morning claudeWork proud music curious snow`) or by an emitter name (`heart spark note z snow steam question coin bang stars`). Lookup order: current action → current mood → emitter. Fields override `EMIT` in buddy.lua: `glyphs`, `color`, `size`, `rate`, `vy`, `vx`, `spread`, `life`, `from` (`head side sky mug`), `grow`. A reaction can also be added to an action that has no emitter today (for example `wave` or `hop`).
- **lines**: `click` and `idle`, each 2–6 lines of at most 40 characters, in Buddy's voice. `{name}` becomes the user's name.

## Gallery and checker

- `tools/skins-gallery`: serves the repo on `localhost:8742` and opens `tools/skins.html` in Chrome. The page loads every `skins/*.json` from the directory listing and re-checks every 3 seconds. New skins appear with a NEW badge. Each card shows the skin animated at real size and in 2x, with buttons for shake, joy, dizzy, love, dance and sleep that play its reactions, plus its lines. An invalid file shows as a red card with the reason.
- The page's renderer follows the draw order above exactly, using the same constants as `buddy.lua`.
- `tools/check-skins [files…]`: Python 3, standard library only. It checks the schema, `id` = filename, unique ids, colour references, int rects inside the bounds, known reaction keys, and line lengths. Exit code 0 means clean. `tests/test_skins.py` runs it over `skins/`.

## Engine (`skins.lua` + small `buddy.lua` changes)

- `skins.lua` loads the repo's `skins/` and the user folder, validates each file defensively, and exposes:
  - `Skins.current()` → the skin being worn
  - `Skins.pick(id)` → the user's choice, saved
  - `Skins.wear(id)` / `Skins.wear(nil)` → a temporary override for themes, not saved
  - `Skins.list()` → every skin with id, name and group
  - `Skins.particle(emitName, actionName, moodName)` → the merged emitter
  - a draw helper that `frame()` calls at each layer point
- `buddy.lua`: the layer call sites in `frame()`, colours from the skin, the reaction lookup in the particle code, skin lines in `lineFor` and the click lines, the Skin menu, and the persona sentence (via brain.lua).
- **Emoji particles:** colour emoji ignore text-colour alpha, so they would pop out instead of fading. Make them fade (for example, render each glyph once to an image and draw it with `imageAlpha`), or shrink them out. Builder's call.
- Missing or broken current skin → Classic.

## Theme contract (for `halloween-theme`)

The theme calls `Skins.wear(id)` while it's active and `Skins.wear(nil)` when it ends. Halloween ids: `witch vampire pumpkin ghost franken`. Whether the theme picks a skin, and which one, is decided in the theme session.

- **One instance:** `buddy.lua` loads `skins.lua` once and exposes it as `ClaudeBuddy.skins` (`M.skins`). It hands the same object to any theme module. A theme never `dofile`s its own copy. *(my call)*
- **The user's pick wins:** picking a skin from the menu clears any `wear` override, and the theme doesn't re-apply it until its next start. The check mark is on the skin Buddy is actually wearing. *(my call)*
- `wear` is idempotent and cheap. The theme calls it when it turns on and off, not every frame. *(my call)*

## Batch 2 skins

The owner asked for a wide spread, all Claude-themed. Grouped by builder:

- **Memes:** Nyan (pop-tart body, rainbow trail), Unicorn rainbow, MLG/Illuminati (deal-with-it shades, hitmarkers, triangle-eye), "Nice" 69, Money gangster (cap, gold chain, cash), Doge, This-is-fine (fire), Rickroll.
- **Outfits:** Beach, Vacation (tourist), Office, Suit, 007 agent (tux, martini), Chef, Astronaut, Pirate, Cowboy, Rock star.
- **Heroes:** Batman, Superman, Spider-Man, Wonder Woman, Iron Man, Captain America, Hulk, Flash, Thor, Deadpool.
- **Games & anime:** Pikachu, Pokémon trainer (cap + Poké Ball), Charmander, Squirtle, Bulbasaur, Super Saiyan Goku, Vegeta, Piccolo, Naruto, Mario, Link, Sonic, Creeper, Among Us crewmate.
- **Movies & TV:** Darth Vader, Jedi (lightsaber), Grogu, Wizard (Harry Potter), Gandalf, Shrek, SpongeBob, Minion, Ninja Turtle, Ghostbuster.

**Naming (the owner decided): Claude-themed homage names.** Each pop-culture skin gets a Claude pun name that makes the character obvious without using its trademarked name or copying its logo, for example "Bat-Claude", "Super Claude", "Spider-Claude", "Darth Claude", "Super Saiyan Claude". The ids are plain and stable (`batclaude`, `superclaude`, …) because the saved choice uses the id. Emblems are the builder's own pixel shapes, never copied logos. Lines and the persona use the homage name too. Reason: the repo is public and is everyone's update channel, so a takedown notice would stop updates for all installs.

## Left to the builder

- Exact pixel art, palettes, reactions and lines for every skin, within the format.
- The gallery's look.
- How emoji particles fade.
- README: a short Skins section with how to switch and how to add your own.
