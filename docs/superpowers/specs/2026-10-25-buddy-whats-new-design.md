# Buddy "What's New" window — design

Date: 2026-10-25 · Branch: `whats-new` (worktree `.claude/worktrees/whats-new`, off `main` 5b77576 = v1.6.0) · Ships in the next release, which the release captain session (`claude-usage-widget-69`) cuts.

## Intent

After someone clicks Update and Buddy restarts on the new version, a window pops up to greet them and show what's new. Today that moment only gets a speech bubble ("I just got updated to v1.6.0!") and the update dialog shows a dozen lines of plain-text notes. The owner wants a proper welcome: a picture of the new thing (for a Halloween release, the Vampire Buddy smiling and waving), then a short slide-by-slide tour of the new features, then a page that asks how Buddy has been, takes feature ideas and makes it easy to recommend Buddy to a friend. The full patch notes are one click away for people who want them.

The owner approved a clickable mock of exactly this (the mockup server's `whats-new-flow.html`, kept in the main checkout under `.superpowers/brainstorm/89540-1792911854/content/`). The build should look and behave like that mock.

## Goals

1. **Shows by itself, once per update.** The first time Buddy starts on a version newer than the one it last ran, and the release file has at least one entry newer than that old version, the window opens a few seconds after start. *(the owner)*
2. **Welcome page.** A live, animated Buddy in the release's hero skin (the scene is data: skin, wave or not, a few bubble lines), the version, a title, one summary sentence, a "Read the patch notes" link bottom left and **See what's new →** bottom right. *(the owner)*
3. **Slides.** One feature per slide with its own scene, title and one or two sentences. Back, Next and dots along the bottom. A slide may carry one action button ("Wear the Witch now"). *(the owner; the action button was in the approved mock)*
4. **Help shape Buddy (always the last slide).** A five-face rating, an idea box ("I wish Buddy could…") with Send, an optional "your email, if you'd like a reply", and **Copy the link** / **Share…** to recommend Buddy. *(the owner: request-a-feature form, ask how their experience has been, option to share or recommend)*
5. **Feedback reaches the owner by email.** Ratings and ideas arrive as an email with a fixed subject and body layout so one of the owner's agents can pick them up. *(the owner)*
6. **Patch notes page.** Everything new since the version they came from, grouped New / Better / Fixed per version, plus a link to the GitHub release. *(the owner)*
7. **Reopen any time** from Buddy's right-click menu: "What's new". *(played back to the owner; not objected to)*
8. **Content is data, written last.** Slides and notes live in one data file. The owner's words: "we will just update it last before finalizing the update." The release tool stamps the draft entry with the version number being released. *(the owner + my call on the stamping)*
9. **First content.** The next release's entry covers the v1.6.0 features (skins, click the speech bubble, Telegram, the card's API value row), because people already on v1.6.0 never got a window for them, and leaves room for what the next release adds (Buddy's companion and the Halloween theme are still being built in other sessions). *(the release captain, relaying the owner)*

## Non-goals

- Changing how updating itself works (the update dialog, git fast-forward, reload).
- A window on a fresh install. New installs get the setup wizard, as today.
- Storing feedback anywhere but the email (no database, no dashboard).
- Translations, sound, video.
- Making the skins gallery (`tools/skins.html`) share the new drawing code. It could later; not tonight.

## Anti-goals (failure even if it works)

- The owner's email address, a sending address, API tokens or anything secret in the public repo. The destination and sender addresses are Worker secrets. *(the release captain)*
- Personal data or business details in the public repo, including docs and commit messages. Use "the owner".
- Anything sent without the person clicking Send or picking a face. No silent telemetry, no install ids, no usage stats.
- A broken or missing release file, scene, or skin breaks Buddy or the card, or throws on start. The window falls back to the plain bubble; a bad slide is skipped.
- The window opens on every reload, or twice for one update.
- The window steals focus from what someone is typing in at the moment Buddy restarts more than once. It opens once, a few seconds after start.
- Feedback can be used to flood the owner's inbox from one machine.
- Copied character names or likenesses in slide text (same rule as skins: homage names only).

## Constraints

- Hammerspoon Lua, no build step. Pages are HTML strings handed to `hs.webview:html()` with `/*__INIT__*/null` replaced by JSON (see `chat.lua`, `setup.lua`); there is no file URL, so anything the page needs (JS, skin data, images) is inlined by Lua. JS talks back through `hs.webview.usercontent` messages named `buddy`.
- Lua specs run inside the live Hammerspoon through `tests/lua-tests`, always under the shared lock: `/usr/bin/lockf -k /tmp/buddy-hs.lock timeout 600 tests/lua-tests`. No other ad-hoc `hs -c`, and specs must not lazily load a new `hs.*` extension (a first load inside `hs -c` recursed through `hs.ipc` print once). Code paths that need `hs.sharing`, `hs.webview` or `hs.http` take them through injectable functions so specs pass fakes. *(the release captain)*
- Python tests: `/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py'`.
- Several sessions edit `buddy.lua` and `updater.lua`. New code goes in new files; those two get small call sites only.
- Deploying the Worker or sending any real email reaches the outside world: build and test it locally, and ask the owner before deploying. `wrangler email sending list` currently answers "Unauthorized" for this account, so enabling Email Sending on a domain is a deploy-time step for the owner. *(the release captain)*
- No pushing, no `tools/release`, no reloading the live Hammerspoon. When done, message the release captain with the branch head and the Lua and Python test counts. *(the release captain)*

## How it works (decided)

### Files

| File | What |
|---|---|
| `whatsnew.lua` | Decides when to show, builds the page data, opens the window, handles the page's messages, sends feedback. Pure parts (version picking, payload, caps, queue) are plain functions the spec tests. |
| `whatsnew.html` | The page: welcome, slides, Help shape Buddy, patch notes. Looks like the approved mock. |
| `buddy_draw.js` | Buddy's renderer in JS (mirrors `buddy.lua`'s drawing, started from the skins gallery's copy) with hooks for scene extras. Inlined into the page by `whatsnew.lua`. |
| `whatsnew/releases.json` | The content. |
| `whatsnew/*.png` | Optional pictures for `image` scenes (inlined as data URIs). |
| `tools/whatsnew` | Python: `check` validates `releases.json`; `stamp <version>` turns the `"next"` entry into that version. |
| `worker/feedback/` | The Cloudflare Worker that turns a POST into an email: `src/index.js`, `wrangler.jsonc` (no secrets), `test/` (node:test), `README.md` with deploy steps. |
| Tests | `tests/whatsnew_spec.lua`, `tests/test_whatsnew.py`; Worker tests run with `node --test worker/feedback/test`. |
| Small edits | `updater.lua` (trigger), `buddy.lua` (menu item, `M.whatsNew()`, `M.wearSkin(id)`), `tools/release` (calls `tools/whatsnew stamp` and `check`), `config.example.lua` (`feedback_url`), README (Updates section, maintainer section). |

### When it shows

- `updater.lua` already knows "first start after an update" (`claudeWidget.lastRunVersion` older than `VERSION`). At that moment it saves the old version as `claudeWidget.whatsNewFrom` (Hammerspoon settings), then keeps setting `lastRunVersion` as today.
- About 6 s after start, if `whatsNewFrom` is set, `whatsnew.lua` picks the releases with `from < version <= VERSION`. If there are any it opens the window and clears `whatsNewFrom`; if there are none it clears it and Buddy just says the old "I just got updated" line. A reload before the 6 s are up leaves `whatsNewFrom` set, so the window still shows once.
- No `lastRunVersion` at all (fresh install) shows nothing, as today.
- Menu "What's new" opens it on the newest entry whose version is `<= VERSION` (or the newest entry if none is), with slides and notes for that one release.
- Several releases at once (someone skipped one): the hero and title come from the newest; slides run newest release first; patch notes list every version, newest first.
- Buddy says one line when the window opens ("I got updated! Come see what's new.").

### `whatsnew/releases.json`

```json
{
  "releases": [
    {
      "version": "next",
      "title": "The Halloween Update",
      "summary": "One sentence for the welcome page.",
      "hero": { "skin": "vampire", "wave": true, "lines": ["Happy Halloween!", "Fangs for updating!"] },
      "slides": [
        { "title": "63 skins", "text": "…", "scene": { "kind": "skins", "skins": ["witch", "vampire", "…"] },
          "action": { "label": "Wear the Witch now", "skin": "witch" } }
      ],
      "notes": { "new": ["…"], "better": ["…"], "fixed": ["…"] }
    }
  ]
}
```

- Exactly zero or one entry may have `"version": "next"`; all others are `x.y.z`, unique.
- Scene kinds: `buddy` (a skin, `wave`, `lines`), `skins` (2–8 skin ids in a grid; click one to hear its line), `bubble` (the click-the-speech-bubble demo: a line, then a cursor clicks it and a mini chat opens on it), `phone` (a phone frame with `messages: [{ "from": "you"|"buddy", "text" }]`), `card` (a mini usage-card with `rows: [{ "label", "value", "sub" }]`), `image` (`file` under `whatsnew/`, PNG or JPEG, at most 600 KB). An unknown kind draws a plain `buddy` scene in the slide's `skin` or Classic, so a newer release file never breaks an older page.
- Limits `tools/whatsnew check` enforces (and `whatsnew.lua` re-checks at load, skipping what fails): title ≤ 40 chars, summary ≤ 140, slide text ≤ 220, ≤ 8 slides per release, ≤ 12 notes per group, skin ids must exist in `skins/`, image files must exist.
- `tools/release <version>`: run `tools/whatsnew check` first and stop on errors (before anything is written). Then, if an entry says `"next"`, stamp it with `<version>` and `git add` it together with `VERSION`, so the stamp lands **inside the release commit** (the tool refuses a dirty tree, so it can't be a separate step). A release with no `"next"` entry (a fix-only patch) works exactly as today, plus one note: "no What's New entry for vX; people get the plain bubble". A test covers both cases: it runs the real `tools/release` in a temporary clone with a bare `origin` and a fake `gh` on `PATH`, then checks the release commit holds the stamped file and `VERSION`, the tag exists, the tree is clean, and the fix-only case leaves `releases.json` untouched. *(the release captain: "every install depends on it")*
- The release's GitHub notes stay whatever `tools/release` is given. *(my call: keeps the captain's flow unchanged)*

### First content (draft entry, `"next"`)

Hero: the Vampire, waving, Halloween lines. Slides, in order:
1. **63 skins** — `skins` scene (witch, vampire, pumpkin, ghost, franken, winter, hardhat, pirate), action "Wear the Witch now".
2. **Click what Buddy says** — `bubble` scene.
3. **Text Buddy from your phone** — `phone` scene: you ask about usage, Buddy answers; text mentions pairing in the setup wizard.
4. **What your Claude use is worth** — `card` scene with an API value row ("This week · $412", "6.4× your plan", "🍕 That's 71 large pepperoni pizzas"); text explains the period picker and the comparisons. Numbers are clearly examples.
5. Placeholders for **Halloween week** and **Buddy's companion**, left out of the file until those branches merge; the design names them so the captain knows where they go. *(my call: a half-written slide must never ship)*

Notes: the v1.6.0 items plus this window, under New / Better / Fixed. The captain edits all of it last.

### The window

- Titled, closable, 600 × 520, centred on the main screen, title "What's new in Buddy", floating level only while it's open, not on all spaces. Escape closes.
- Pages exactly as in the mock: welcome (no bottom nav), slides with Back / dots / Next, last slide's Next reads **Done**, patch notes with Back and Close.
- Scenes animate at 12 fps only while their page is showing; the page stops all timers when hidden.
- Action button "Wear the Witch now" calls `ClaudeBuddy.wearSkin(id)` (the menu's own pick: saved, Buddy cheers and says the skin's line). The button is hidden when Buddy isn't running or the skin isn't installed.
- Theme: the page is dark like the mock in both system appearances. *(my call: matches the mock the owner approved; the chat panel is dark too)*

### Help shape Buddy

- Faces 1–5 (😖 🙁 😐 🙂 😍), idea box (≤ 2000 chars), "Your email, if you'd like a reply" (optional, ≤ 200 chars, must look like an email or is ignored with a hint).
- One small line under the form: "Sends your rating, idea, and Buddy and macOS versions. Nothing else."
- **Send** sends the rating (if picked), idea and email together, then shows "Sent. Thanks!". A face picked but never sent goes out on its own when the window closes (Done, Close, ✕ or Escape). Each window sends at most one rating.
- **Copy the link** puts the repo's GitHub page on the clipboard (`update_repo` respected) and says "Copied". **Share…** pops a small native menu: Messages, Mail, AirDrop, through `hs.sharing` with the text "Buddy is a little pixel Claude that lives on your desktop and shows your Claude usage." and the link.

### Sending feedback

- `whatsnew.lua` POSTs JSON to the feedback URL: `{ "rating": 1-5 | null, "idea": "…" | null, "reply_to": "…" | null, "version": "1.7.0", "macos": "15.1" }` with `Content-Type: application/json` and `User-Agent: claude-usage-widget/<version>`.
- The URL: `feedback_url` in config.lua if set (for forks), else a constant in `whatsnew.lua` that the owner fills in after deploying (a plain `https://…workers.dev/feedback` URL with nothing secret in it). While the constant is empty and there's no `feedback_url`, Send opens a new GitHub issue in the browser with the title "Idea: …" and a body holding **only** what the person typed (the idea, the rating if picked, the reply email if they typed one) plus the Buddy version and the macOS version. No usage numbers, paths, machine name, config values or chat text. It is public: the person sees the issue on GitHub and files it themselves with Submit; nothing is filed for them. A lone rating with no idea is dropped. The page's small line says "Opens a public GitHub issue you can check before posting" in this mode. *(my call to have a fallback; its limits are the release captain's)*
- Caps on the Mac: 5 sends a day (Hammerspoon settings counter, reset by date). Over the cap, Send says "That's plenty for today. Thanks!".
- Offline or 5xx: the payload goes in a queue in Hammerspoon settings (at most 5, oldest dropped), retried 30 s after each start and every hour, and dropped after 3 days. 4xx is not retried.
- Nothing else is ever sent; no install id.

### The Worker (`worker/feedback/`)

- `POST /feedback` only; anything else 404. Body ≤ 16 KB JSON (room for a 2000-character idea in any script), else 413/400; a declared length over that is refused unread.
- Validates: `rating` null or integer 1–5; `idea` null or ≤ 2000 chars; at least one of them present; `reply_to` null or a plausible email ≤ 200; `version` `^\d+\.\d+\.\d+$`; `macos` ≤ 40 printable chars. Strips control characters.
- Rate limit: Workers Rate Limiting binding keyed on `CF-Connecting-IP`, 3 per 60 s. 429 when over.
- Emails through the Email Service `send_email` binding. `FEEDBACK_TO` and `FEEDBACK_FROM` are Worker secrets (or vars set at deploy, never in the repo).
- Subject, fixed: `Buddy feedback · <face> <n>/5 · v<version>`; with no rating `Buddy feedback · idea · v<version>`; when both, `Buddy feedback · <face> <n>/5 + idea · v<version>`.
- Body, plain text, fixed labels in this order, one per line: `Rating:`, `Idea:` (then the idea on following lines), `Reply to:`, `Buddy:`, `macOS:`, `Received:` (ISO UTC). Missing values read `—`. `Reply-To` header set to the person's email when given.
- Logs one line per request (status, no content).
- Responds `{"ok":true}` 200 on success; `{"ok":false,"error":"…"}` otherwise.
- Tests run in Node with a fake `env` (no network): validation, subject/body format, rate-limit path, email failure → 502.

## Settled after the builder check (my calls)

- **The `"next"` entry** never auto-shows: it only exists before a release, and `tools/release` stamps it. The menu shows the newest numbered entry `<= VERSION`; when there is none (a dev checkout whose only entry is `"next"`), it shows `"next"`. `ClaudeBuddy.whatsNew(v)` opens any entry by version, `"next"` included, for previewing the draft.
- **Email binding shape**, from Cloudflare's Email Service docs: `"send_email": [{ "name": "EMAIL" }]` in `wrangler.jsonc`, and `env.EMAIL.send({ to, from: { email, name }, replyTo, subject, text })`, which throws an Error with `.code` on failure. Rate limiting is the `ratelimits` binding (`{ "name": "LIMITER", "namespace_id": "…", "simple": { "limit": 3, "period": 60 } }`, `await env.LIMITER.limit({ key })` → `{ success }`). Both are unverified against the live account until the owner's deploy, and the Worker README says so.
- **The daily cap** counts fresh sends, the close-time rating included. Queue retries don't count. An over-cap close-time rating is dropped quietly; an over-cap Send shows "That's plenty for today. Thanks!".
- **`buddy_draw.js`** is a port of the skins gallery's renderer (which is already kept in step with `buddy.lua`), so every skin draws as it does in the gallery. Pixel parity is checked by eye on the skins the first release uses, not by a test.
- **GitHub fallback wording:** while there's no feedback URL, Send reads **Open on GitHub**, the small line says "Opens a public GitHub issue you can check before posting", and after the click it says "Opened on GitHub. Click Submit there to post it." A lone rating in this mode isn't sent, and nothing says it was.
- **Release order:** `tools/whatsnew check` → `tools/whatsnew stamp <version>` (so a stamp refusal stops before anything is written) → write `VERSION` → `git add VERSION whatsnew/releases.json` → commit → tag → push → `gh release`. `stamp` is a no-op when there's no `"next"`, and an error when `"next"` and `<version>` both exist. `check` never errors because the release has no entry; only `tools/release` prints the note.

## Left to the builder

- Exact copy for slides and notes (the captain finalizes it last), exact styling details beyond the mock.
- How `buddy_draw.js` is factored, as long as it draws exactly what `buddy.lua` draws for the scenes used.
- Retry timer mechanics, settings key names beyond the two named above.
- The Worker's name and route (suggest `buddy-feedback`, `workers.dev`).
- Spec structure and fakes.
