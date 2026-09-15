# hypr-tags

A Firefox WebExtension that gives each window a stable identity hyprplace can read.

Firefox tells Wayland nothing that distinguishes one of its windows from another: every
window shares an `app_id` and a pid, so at `window.open_early` hyprplace sees nine
identical `firefox` windows and can only guess which is which. This extension assigns
each window a tag, keeps it in the session store so it survives a restart, and publishes
it as a title preface:

```
[work] Inbox - Mozilla Firefox
```

The title is the only channel an extension can write and a compositor can read. The full
design, and why native messaging was rejected, is in
[../docs/FIREFOX-TAGS.md](../docs/FIREFOX-TAGS.md).

## Contract with the plugin

This is the whole interface. The extension never learns anything about workspaces, and
hyprplace never sets or renames a tag -- there is no channel in that direction.

- A tag matches `[A-Za-z0-9_-]{1,32}`, bracketed, anchored at the start of the title,
  followed by a space. `tag.lua` implements the reading side, and a test asserts the two
  definitions have not drifted apart.
- **A window appears untagged and is tagged a moment later.** This is the normal case at
  startup, not an error: Hyprland sees a restored window before this script has run. The
  plugin must wait rather than decide at open, which is what `defer_classes` and
  `defer_timeout_ms` are for.
- Untagged windows -- private, popups, picture-in-picture, and any window before its
  preface lands -- get no special handling. They fall through to ordinary class-based
  placement.
- A rename is just a title change to a new tag. The plugin treats it as a new identity;
  the old one expires under the TTL on its own.

## Status: not signed, not installed, development only

`gecko.id` is **`hypr-tags@hyprplace.invalid`, a placeholder**. The id is bound to the
AMO account that signs the extension and cannot change afterwards, so it must be settled
before the first signing run -- deliberately deferred until there is something worth
signing. `.invalid` is a reserved TLD, so the current value cannot collide with a real
extension and cannot be mistaken for a decision that has been made.

Release Firefox loads only signed extensions. Until then this runs in a scratch profile:

```sh
npx web-ext run -s extension          # scratch profile, auto-reload, no signing
```

That opens a real Firefox window, and `-s extension` must point at this directory.

Verify from the compositor side:

```sh
hyprctl clients -j | jq -r '.[] | select(.class | test("firefox")) | .title'
```

## Files

| | |
|---|---|
| `manifest.json` | MV2. A persistent background script is simpler here than an MV3 event page, which would be unloaded between window events |
| `background.js` | Tag assignment, collision handling, and the title preface |
| `popup.html` / `popup.js` | Renaming a window's tag |

## Notes on the implementation

- **Operations are serialized.** Assigning a tag reads every window's tag and then
  writes one; two windows opening at once would interleave those steps and could pick
  the same tag.
- **`ensureTag` is idempotent.** A restored window arrives through both the startup
  sweep and `onCreated`.
- **The preface is applied after the collision check, not before.** Publishing the
  stored tag immediately would be faster, but a window that then has to be re-tagged
  would have published an identity the compositor may already have acted on. A late
  placement is recoverable; a wrong one is not.
- **`titlePreface` is not persisted**, so every window is swept each time the script
  starts -- at browser startup, and on install, enable or reload. The tags themselves
  come back from the session store.
- Startup is O(windows²) session reads. At realistic window counts this is nothing, and
  it buys the collision guarantee above.

## Prerequisite

Firefox must restore the previous session (`browser.startup.page = 3`). Without it no
windows are restored, and the feature is a harmless no-op.
