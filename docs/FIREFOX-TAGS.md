# Handoff: Persistent Firefox Window Tags for the Hyprland Plugin

> Optional doc. Design for future work; not yet implemented and not part of the MVP.
> The section at the end, **Implications for hyprplace**, was added when this was
> assimilated into the project notes -- everything above it is the handoff as written.

## Goal

Give each Firefox window a stable identifier that survives Firefox restarts and
reboots, exposed in a way a Wayland compositor can read, so the Hyprland plugin
can restore window → workspace mappings for Firefox windows.

## Design summary

- Firefox exposes no per-window identity to the compositor. The only channel an
  extension can write and a compositor can read is the **window title**.
- A small WebExtension assigns each normal window a tag, stores it in Firefox's
  session store (`browser.sessions.setWindowValue`, which survives session
  restore), and prepends it to the title via `browser.windows.update({titlePreface})`.
- The plugin reads tags from the title via Hyprland events. **There is no
  channel from the compositor into Firefox.** The extension is deliberately
  observe-only from the plugin's perspective; this keeps it small, auditable,
  and easy to trust. Native messaging was considered and rejected.
- Tags default to random hex but are user-renameable via a popup, so titles can
  read `[work] …` instead of `[3f9a1c2b] …`.

### Decisions already made

| Decision | Choice |
|---|---|
| Tag channel | Title preface, anchored at start of title |
| Default tag | 8 lowercase hex chars from `crypto.getRandomValues` |
| Tag alphabet (after rename) | `[A-Za-z0-9_-]{1,32}` |
| Title format | `[<tag>] <page title> — Mozilla Firefox` |
| Renaming | Yes, via browserAction popup; duplicates rejected |
| Collision handling | Checked against live windows on every assignment; serialized |
| Private windows | Not tagged (extension not enabled there; not restored anyway) |
| Popups / PiP | Not tagged (`window.type !== "normal"`) |
| Multiple profiles | Out of scope for now (see Known limitations) |
| Native messaging / back-channel | Rejected |
| Manifest version | MV2 (persistent background script; simpler than MV3 event pages) |

### Prerequisites

- Firefox must restore the previous session on startup (`browser.startup.page = 3`).
  If not, windows aren't restored and the feature is a harmless no-op.
- Release Firefox only loads **signed** extensions. See Distribution.

## Plugin-side contract

This is the whole interface between plugin and extension.

1. **Match**: a Firefox toplevel (app_id `firefox` or `firefox-*` etc.) whose title
   matches `^\[([A-Za-z0-9_-]{1,32})\] ` carries tag = capture group 1.
2. **Delayed tagging is the normal case.** On startup, Hyprland sees the restored
   window *before* the extension applies the preface. The window first appears
   untagged; the tag arrives via a later `windowtitle` event. The plugin must:
   - not act on Firefox windows until a tag is seen (or a timeout passes), and
   - re-evaluate on every `windowtitle` event for Firefox windows.
3. **Placement must be done by the plugin**, not by static `windowrule`s
   (`workspace`, `float`, etc. only evaluate at window open, before the tag
   exists). Dispatch `movetoworkspacesilent` (or equivalent) when the tag
   matches a stored mapping.
4. **Untagged Firefox windows** (popups, PiP, private, not-yet-tagged) get no
   special handling.
5. **Renames** show up as a title change to a new tag. The plugin should treat
   the new tag as a new identity; whether to migrate the old mapping is a
   plugin-side choice (simplest: don't; the user re-assigns).
6. Tag → workspace mappings live in the plugin's own state store, keyed by tag
   string. Nothing about mappings is stored in Firefox.

Rename is the only way a tag changes. A tag is freed when its window is
closed. A reopened closed window brings its old tag back; if that tag is now
held by a live window, the reopened one is re-tagged.

## Extension

Directory layout:

```
extension/
  manifest.json
  background.js
  popup.html
  popup.js
```

### manifest.json

```json
{
  "manifest_version": 2,
  "name": "hypr-tags",
  "description": "Prefixes each Firefox window title with a persistent tag so a Wayland compositor can identify windows across restarts.",
  "version": "0.1.0",
  "browser_specific_settings": {
    "gecko": {
      "id": "hypr-tags@CHANGEME",
      "strict_min_version": "115.0"
    }
  },
  "permissions": ["sessions"],
  "background": { "scripts": ["background.js"] },
  "browser_action": {
    "default_title": "Window tag",
    "default_popup": "popup.html"
  }
}
```

`gecko.id` must be fixed before the first signing run; it is bound to the AMO
account that signs it and cannot change afterward.

### background.js

```js
const KEY = "hyprTag";
const TAG_RE = /^[A-Za-z0-9_-]{1,32}$/;

// Serialize all tag operations so concurrent window creation can't race.
let chain = Promise.resolve();
const serialize = (fn) => (chain = chain.then(fn, fn));

const randomTag = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(4)),
             (b) => b.toString(16).padStart(2, "0")).join("");

const applyPreface = (windowId, tag) =>
  browser.windows.update(windowId, { titlePreface: `[${tag}] ` });

async function liveTags(exceptId) {
  const taken = new Set();
  for (const w of await browser.windows.getAll()) {
    if (w.id === exceptId) continue;
    const t = await browser.sessions.getWindowValue(w.id, KEY);
    if (t) taken.add(t);
  }
  return taken;
}

async function ensureTag(win) {
  if (win.type !== "normal" || win.incognito) return;
  const taken = await liveTags(win.id);
  let tag = await browser.sessions.getWindowValue(win.id, KEY);
  if (!tag || !TAG_RE.test(tag) || taken.has(tag)) {
    do tag = randomTag(); while (taken.has(tag));
    await browser.sessions.setWindowValue(win.id, KEY, tag);
  }
  await applyPreface(win.id, tag);
}

async function renameTag(windowId, tag) {
  if (!TAG_RE.test(tag)) throw new Error("Tag must match [A-Za-z0-9_-]{1,32}");
  const taken = await liveTags(windowId);
  if (taken.has(tag)) throw new Error(`Tag "${tag}" is already in use`);
  await browser.sessions.setWindowValue(windowId, KEY, tag);
  await applyPreface(windowId, tag);
  return tag;
}

browser.windows.onCreated.addListener((w) => serialize(() => ensureTag(w)));

// titlePreface is not persisted; reapply to every window on every startup.
browser.windows.getAll().then((ws) =>
  ws.forEach((w) => serialize(() => ensureTag(w))));

browser.runtime.onMessage.addListener((msg) => {
  if (msg.type === "get") {
    return browser.sessions.getWindowValue(msg.windowId, KEY);
  }
  if (msg.type === "rename") {
    return serialize(() => renameTag(msg.windowId, msg.tag));
  }
});
```

Notes:
- `ensureTag` is idempotent; a restored window may hit both the startup loop and
  `onCreated`, which is fine.
- The TAG_RE check on a stored value guards against a corrupted or hand-edited
  session store.
- `onMessage` returning a Promise is how Firefox delivers async responses to the
  popup.

### popup.html

```html
<!doctype html>
<meta charset="utf-8">
<style>
  body { font: 13px system-ui; padding: 10px; min-width: 220px; }
  input { width: 100%; box-sizing: border-box; margin: 6px 0; }
  #err { color: #c00; min-height: 1em; }
</style>
<div>Current tag: <code id="cur">…</code></div>
<input id="tag" placeholder="new tag" maxlength="32" spellcheck="false">
<button id="save">Rename</button>
<div id="err"></div>
<script src="popup.js"></script>
```

### popup.js

```js
const $ = (id) => document.getElementById(id);

(async () => {
  const win = await browser.windows.getCurrent();
  const cur = await browser.runtime.sendMessage({ type: "get", windowId: win.id });
  $("cur").textContent = cur ?? "(none)";
  $("tag").value = cur ?? "";
  $("tag").focus();

  const save = async () => {
    $("err").textContent = "";
    try {
      const t = await browser.runtime.sendMessage(
        { type: "rename", windowId: win.id, tag: $("tag").value.trim() });
      $("cur").textContent = t;
      window.close();
    } catch (e) {
      $("err").textContent = e.message;
    }
  };
  $("save").addEventListener("click", save);
  $("tag").addEventListener("keydown", (e) => { if (e.key === "Enter") save(); });
})();
```

## Distribution

### Signing (required for release Firefox)

Submit as an unlisted / self-distributed add-on. It never appears on AMO; you
just get a signed `.xpi` back.

```
npx web-ext sign -s extension -a dist --channel unlisted
```

with `WEB_EXT_API_KEY` / `WEB_EXT_API_SECRET` from the AMO developer hub of the
signing account. Each version string can be signed exactly once.

**Open item:** which AMO account owns the extension ID.

### GitHub Actions

```yaml
name: sign-extension
on:
  push:
    tags: ["v*"]
jobs:
  sign:
    runs-on: ubuntu-latest
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - name: Set manifest version from tag
        run: |
          v="${GITHUB_REF_NAME#v}"
          sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$v\"/" extension/manifest.json
      - run: npx web-ext lint -s extension
      - run: npx web-ext sign -s extension -a dist --channel unlisted
        env:
          WEB_EXT_API_KEY: ${{ secrets.AMO_JWT_ISSUER }}
          WEB_EXT_API_SECRET: ${{ secrets.AMO_JWT_SECRET }}
      - uses: softprops/action-gh-release@v2
        with: { files: dist/*.xpi }
```

### Install (plugin install script, opt-in)

Primary: enterprise policy. Write/merge into `/etc/firefox/policies/policies.json`
(requires root). Do **not** clobber an existing file; merge the
`ExtensionSettings` key.

```json
{
  "policies": {
    "ExtensionSettings": {
      "hypr-tags@CHANGEME": {
        "installation_mode": "normal_installed",
        "install_url": "file:///usr/share/hypr-tags/hypr-tags.xpi"
      }
    }
  }
}
```

- `normal_installed` lets the user disable it in about:addons;
  `force_installed` does not.
- Firefox installs on next launch for all profiles. Removing the entry
  uninstalls.
- Flatpak/Snap Firefox read policies from inside their sandbox paths; detect
  and either handle separately or print instructions.

Fallback (no root, per profile): copy the signed `.xpi` to
`<profile>/extensions/hypr-tags@CHANGEME.xpi` (filename must equal the ID).
Installs on next startup; may prompt on some versions. Test on target versions.

Interactive fallback: `firefox /path/to/hypr-tags.xpi` opens the normal install
dialog.

Optionally: warn if `user_pref("browser.startup.page", 3)` is absent from the
profile's `prefs.js`.

### Development

- `npx web-ext run -s extension` loads it temporarily in a scratch profile with
  auto-reload. No signing needed.
- `xpinstall.signatures.required=false` only works on Nightly, Developer
  Edition, ESR, and unbranded builds. Do not build the install path around it.
- Verify from the compositor side with `hyprctl clients -j | jq '.[] | select(.class|test("firefox")) | .title'`.

## Testing checklist

- [ ] New window gets `[xxxxxxxx] ` preface within ~1s of creation.
- [ ] Restart Firefox: restored windows get the *same* tags back.
- [ ] Reboot: same.
- [ ] Open 5 windows quickly (e.g. `for i in $(seq 5); do firefox --new-window; done`): all tags unique.
- [ ] Rename via popup: title updates immediately; survives restart.
- [ ] Rename to a tag already in use: rejected with message.
- [ ] Rename to invalid characters: rejected.
- [ ] Close window, reopen via Ctrl+Shift+N: old tag returns.
- [ ] Close window A (tag T), rename window B to T, reopen A: A gets a fresh tag.
- [ ] Popup / PiP / private windows: no preface.
- [ ] Plugin: window appears untagged at startup, plugin waits, then places it on `windowtitle` event.
- [ ] Disable extension: prefaces disappear; re-enable: they return with the same tags.

## Known limitations

- **Multiple profiles**: each profile runs its own extension instance with its
  own tag space, so two profiles can hold the same tag. Not handled. If needed
  later: launch profiles with distinct `--name` values (sets Wayland `app_id`)
  and key the plugin's mappings on `(app_id, tag)`.
- **Tag reuse**: a freed tag can theoretically be re-drawn by a new window,
  which would inherit the old workspace mapping. With 32-bit random tags this
  is negligible and the consequence (wrong workspace once) is acceptable.
- **Visible in the titlebar**: the tag is part of the window title and appears
  wherever titles do. This is inherent to the channel and is the price of not
  having a back-channel.
- **No compositor → Firefox path**: the plugin can observe tags but cannot set
  or rename them. By design.
- **Session restore off**: feature silently does nothing across restarts.

## Explicitly out of scope

- Native messaging host or any mechanism by which the plugin sends data into
  Firefox.
- Tab-level tracking (tags are per window; dragging tabs into a new window
  yields a new tag).
- Chromium-based browsers (no `titlePreface` / `sessions.setWindowValue`
  equivalent).

---

# Implications for hyprplace

Added during assimilation. How this lands against the design already in
[DESIGN.required.md](DESIGN.required.md) and [FUTURE.md](FUTURE.md).

## It supersedes the title heuristics for Firefox, but does not replace them

FUTURE.md proposes delayed title resolution and dwell sampling to tell multi-window
apps apart. That is a *heuristic* -- it infers identity from a string the app controls
for other purposes, and the identity goes stale the moment the user navigates.

A tag is the opposite: a real, stable, explicit identity, deliberately published for
this purpose. Where it is available it should win outright.

But it is available only for Firefox, only with the extension installed, and only when
session restore is on. Title sampling remains the general fallback for every other
multi-window app, so both are wanted. Tags are a **new highest-priority identity tier**
above the cmdline tier, not a replacement for the layered model:

    0. explicit tag        firefox + tag:work
    1. class + cmdline     kitty + kitty btop
    2. class               firefox

## The two features share the machinery hyprplace does not have yet

Contract item 2 -- appear untagged, wait, re-evaluate on a later title event -- is
exactly the "observe after open" capability FUTURE.md describes for title sampling.
Neither feature can be built without it, so it should be designed once for both.

That machinery does not exist today and it is a real change to the placement path:

- Placement currently acts at `window.open_early` and never reconsiders. Tagged windows
  need a **deferred decision**: hold the window, watch for the tag, act when it arrives
  or give up on a timeout.
- That implies a pending-placement set, a timeout, and a `window.title` subscription (or
  the sampler) feeding it. All in-compositor, so all subject to the hot-path constraints
  already noted.

## It stretches AC-4, and the wording should change

AC-4 says a window the user moves stays moved -- hyprplace acts only at open time. A
deferred placement moves a window some time *after* it opened, which is still "at open"
in spirit but not by the current wording.

The rule should be restated as something like: hyprplace places a window only before the
user has acted on it, and only within a bounded settling window after it appears. Worth
fixing in DESIGN.required.md when this is built, because the current phrasing would
forbid the feature.

## It is privacy-positive, and removes a prerequisite

FUTURE.md notes that persisting window titles would write an email address and browsing
history to disk, which is why titles must be hashed if stored.

A tag has none of that problem. `work` or `3f9a1c2b` is a meaningless token by
construction, safe to store in the clear and readable in the debugging tools. Where tags
are available, hyprplace does not need to store titles at all -- so this **eliminates**
the hashing prerequisite for Firefox rather than merely working around it.

## Renames fall out of the existing model

Contract item 5 leaves migration to the plugin. The distribution model already answers
it: a renamed tag is a new key, it gets learned on the next deliberate move or close,
and the abandoned key expires under the TTL. No migration logic, no user action beyond
placing the window once. That is the simplest option the handoff suggests, and it needs
no new mechanism.

## Decisions

**The scope increase is accepted.** This adds a signed browser extension, an AMO
account, a release pipeline, and an installer path wanting root. That is a large
expansion for a workspace-placement plugin, the concern is real, and the capability is
judged to outweigh it. Conditions:

- **Separable.** The extension is its own component with a documented contract, not
  something entangled with the plugin. The plugin side is only the matching rule and the
  deferral; keep that boundary crisp.
- **Clearly indicated.** Never silent, never a side effect of installing hyprplace.
- **Root is explained, not just requested.** The extension install path needs root to
  write `/etc/firefox/policies/policies.json`. Both install *and* uninstall must say
  plainly what they are touching and why, before doing it. `install.lua` otherwise
  touches only the user's own files, so this is a categorically different step and must
  be opt-in and separately invoked -- never part of the default install.

**Sequencing: this comes after its prerequisites.** The deferred-decision machinery
(hold a window, watch for a later title, act or time out) must exist first. Both this
and title sampling depend on it. Do not start the extension before that lands.

**The timeout is configured, not measured.** The whole design rests on the preface
reappearing before the plugin stops waiting, so the number matters. An earlier plan
built a title-timing instrument into `hyprplace watch` and derived it from a real
Firefox restart; that was dropped as more machinery than the answer is worth. Instead
the deferral timeout is a config value with a conservative default, tuned by hand
against a real session -- including a cold boot as well as a warm restart, since
session restore has more to do at boot.

**The extension lives in `extension/` in this repo.** Separable does not have to mean a
separate repository, and one repo keeps the plugin-side contract and the code that
satisfies it in view of each other. The release pipelines differ, which is a CI concern
rather than a reason to split: the extension tags and signs independently of the plugin.

**The AMO account is deferred to the distribution phase.** `gecko.id` is bound to the
signing account and cannot change afterward, so it is a real decision -- but development
uses `web-ext run` with a throwaway id and does not need it. Deciding it later costs
nothing; deciding it early would commit an account before there is anything to sign.

## Open questions this raises for us

- **`--name` for `app_id`.** Closed for this feature: every window of one Firefox
  instance shares an `app_id`, so it cannot separate windows within a profile and is no
  alternative to tags. It remains the answer for *multiple profiles*, and the broader
  idea -- launching an app under a distinct `app_id` to make it trivially identifiable
  -- is still worth considering for other apps.
